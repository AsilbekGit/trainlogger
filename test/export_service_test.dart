import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:train_logger/models/log_record.dart';
import 'package:train_logger/models/station_event.dart';
import 'package:train_logger/services/export_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('CSV keeps optional values empty and matches header column order', () {
    final record = LogRecord(
      index: 1,
      timestamp: '2026-10-02T12:00:00.000Z',
      latitude: 41.0,
      longitude: 69.0,
      speedKmh: 72.0,
      altitudeM: 100.0,
      segmentDistanceM: 50.0,
      totalDistanceM: 50.0,
    );
    final lines = ExportService.buildCsv([record]).trimRight().split('\n');
    final header = lines.first.split(',');
    final values = lines.last.split(',');
    expect(values.length, header.length);
    final row = Map.fromIterables(header, values);
    expect(row['timestamp'], record.timestamp);
    expect(row['grade_percent'], '');
    expect(row['curvature_percent'], '');
    expect(row['curve_radius_m'], '');
    expect(row['total_distance_m'], '50.00');
  });

  test('CSV preserves downhill grade and radius precision', () {
    final record = LogRecord(
      index: 3,
      timestamp: '2026-10-02T12:00:05.000Z',
      latitude: 41.0,
      longitude: 69.0,
      speedKmh: 72.345,
      altitudeM: 99.5,
      segmentDistanceM: 50.0,
      elevationDeltaM: -0.5,
      gradePercent: -1.0,
      totalDistanceM: 150.0,
      curvaturePercent: 0.2,
      curveRadiusM: 500.0,
    );
    final lines = ExportService.buildCsv([record]).trimRight().split('\n');
    final row = Map.fromIterables(
      lines.first.split(','),
      lines.last.split(','),
    );
    expect(row['elevation_delta_m'], '-0.50');
    expect(row['grade_percent'], '-1.000');
    expect(row['curvature_percent'], '0.2000');
    expect(row['curve_radius_m'], '500.0');
  });

  test(
    'sharing forwards the iPad origin and preserves earlier export files',
    () async {
      final cache = await Directory.systemTemp.createTemp('train_export_test_');
      const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
      const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <Map<dynamic, dynamic>>[];
      messenger.setMockMethodCallHandler(pathChannel, (call) async {
        expect(call.method, 'getTemporaryDirectory');
        return cache.path;
      });
      messenger.setMockMethodCallHandler(shareChannel, (call) async {
        expect(call.method, 'shareFiles');
        calls.add(call.arguments as Map<dynamic, dynamic>);
        return '';
      });
      addTearDown(() async {
        messenger.setMockMethodCallHandler(pathChannel, null);
        messenger.setMockMethodCallHandler(shareChannel, null);
        await cache.delete(recursive: true);
      });

      LogRecord record(int index) => LogRecord(
        index: index,
        timestamp: '2026-10-02T12:00:00.000Z',
        latitude: 41.0,
        longitude: 69.0,
        speedKmh: 72.0,
        altitudeM: 100.0,
        segmentDistanceM: 50.0,
        totalDistanceM: index * 50.0,
      );
      final first = [record(1)];
      final second = [record(2)];
      const origin = Rect.fromLTWH(20, 30, 120, 48);
      await ExportService.exportAndShare(first, sharePositionOrigin: origin);
      await ExportService.exportAndShare(second, sharePositionOrigin: origin);

      expect(calls, hasLength(2));
      for (final call in calls) {
        expect(call['originX'], 20.0);
        expect(call['originY'], 30.0);
        expect(call['originWidth'], 120.0);
        expect(call['originHeight'], 48.0);
        expect(call['mimeTypes'], ['text/csv']);
      }
      final firstFile = File((calls.first['paths'] as List).single as String);
      final secondFile = File((calls.last['paths'] as List).single as String);
      expect(firstFile.parent.path, isNot(secondFile.parent.path));
      expect(await firstFile.readAsString(), ExportService.buildCsv(first));
      expect(await secondFile.readAsString(), ExportService.buildCsv(second));

      // Stations go into the same single file.
      const station = StationEvent(
        id: 1,
        type: StationEventType.manualMark,
        timestamp: '2026-10-02T12:00:00.000Z',
        latitude: 41.0,
        longitude: 69.0,
        altitudeM: 100.0,
        speedKmh: 0.0,
        totalDistanceM: 50.0,
      );
      await ExportService.exportAndShare(first, stations: [station]);
      final path = (calls.last['paths'] as List).single as String;
      expect(
        await File(path).readAsString(),
        ExportService.buildCsv(first, [station]),
      );
      // A trip with stations but no 50 m record yet still exports.
      await ExportService.exportAndShare(const [], stations: [station]);
      expect(calls, hasLength(4));
    },
  );

  test('one CSV merges records and stations in time order', () {
    LogRecord record(int index, String time) => LogRecord(
      index: index,
      timestamp: time,
      latitude: 41.0,
      longitude: 69.0,
      speedKmh: 18.0,
      altitudeM: 452.0,
      segmentDistanceM: 50.0,
      elevationDeltaM: 0.1,
      gradePercent: 0.2,
      totalDistanceM: index * 50.0,
      curvaturePercent: 0.012,
      curveRadiusM: 8333.3,
    );
    const stop = StationEvent(
      id: 2,
      type: StationEventType.autoStop,
      timestamp: '2026-10-02T12:00:40.000Z',
      departureTimestamp: '2026-10-02T12:02:10.500Z',
      latitude: 41.0,
      longitude: 69.0,
      altitudeM: 452.1,
      speedKmh: 0.0,
      totalDistanceM: 12324.6,
    );
    // Tapped while the stop was still being confirmed, so its id is lower.
    const markAtStop = StationEvent(
      id: 1,
      type: StationEventType.manualMark,
      timestamp: '2026-10-02T12:00:42.000Z',
      latitude: 41.0,
      longitude: 69.0,
      altitudeM: 452.3,
      speedKmh: 0.0,
      totalDistanceM: 12324.6,
    );
    const markPassing = StationEvent(
      id: 3,
      type: StationEventType.manualMark,
      timestamp: '2026-10-02T12:10:00.000Z',
      latitude: 41.1,
      longitude: 69.1,
      altitudeM: 460.8,
      speedKmh: 72.4,
      totalDistanceM: 25010.75,
      gpsAgeS: 45.25,
    );
    final lines = ExportService.buildCsv(
      [
        record(246, '2026-10-02T12:00:31.900123Z'),
        record(247, '2026-10-02T12:02:19.400Z'),
      ],
      [stop, markAtStop, markPassing],
    ).trimRight().split('\n');
    final header = lines.first.split(',');
    final rows = [
      for (final line in lines.skip(1))
        Map.fromIterables(header, line.split(',')),
    ];
    expect(rows.map((r) => '${r['type']} ${r['id']}'), [
      'record 246',
      'auto_stop 2',
      'manual_mark 1',
      'record 247',
      'manual_mark 3',
    ]);
    final recordRow = rows.first;
    expect(recordRow['departure_timestamp'], '');
    expect(recordRow['dwell_s'], '');
    expect(recordRow['grade_percent'], '0.200');
    expect(recordRow['total_distance_m'], '12300.00');
    final stopRow = rows[1];
    expect(stopRow['departure_timestamp'], stop.departureTimestamp);
    expect(stopRow['dwell_s'], '90.5');
    expect(stopRow['segment_distance_m'], '');
    expect(stopRow['grade_percent'], '');
    expect(stopRow['curvature_percent'], '');
    expect(stopRow['total_distance_m'], '12324.60');
    expect(rows.last['departure_timestamp'], '');
    expect(rows.last['dwell_s'], '');
    expect(rows.last['speed_kmh'], '72.40');
    expect(rows.last['gps_age_s'], '45.3');
    expect(stopRow['gps_age_s'], '');
    expect(recordRow['gps_age_s'], '');
  });
}
