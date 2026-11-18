import 'dart:io';
import 'dart:ui';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';
import '../models/log_record.dart';
import '../models/station_event.dart';

/// Generates one CSV for the whole trip and shares it via the native share
/// sheet (AirDrop, Files, Mail, etc.).
class ExportService {
  /// One row per 50 m record, automatic stop and station mark, sorted by time.
  ///
  /// `type` is `record`, `auto_stop` or `manual_mark`. `id` is the record
  /// index for records and the station id otherwise. `gps_age_s` (manual marks
  /// only) is how old the GPS fix behind the position and speed was. Columns
  /// that do not apply to a row, or have no measurement, are left empty.
  static const String csvHeader =
      'type,id,timestamp,departure_timestamp,dwell_s,latitude,longitude,'
      'speed_kmh,altitude_m,segment_distance_m,elevation_delta_m,'
      'grade_percent,curvature_percent,curve_radius_m,total_distance_m,'
      'gps_age_s';

  /// Build the trip CSV, placing each station between the records around it.
  static String buildCsv(
    List<LogRecord> records, [
    List<StationEvent> stations = const [],
  ]) {
    // Stations are kept in creation order, but a stop is created a few
    // seconds after its arrival, so a mark tapped meanwhile has a lower id.
    final sortedStations = List<StationEvent>.of(stations)
      ..sort((a, b) {
        final byTime = _time(a.timestamp).compareTo(_time(b.timestamp));
        return byTime != 0 ? byTime : a.id.compareTo(b.id);
      });

    final buf = StringBuffer()..writeln(csvHeader);
    var next = 0;
    for (final record in records) {
      final recordTime = _time(record.timestamp);
      while (next < sortedStations.length &&
          _time(sortedStations[next].timestamp).isBefore(recordTime)) {
        buf.writeln(_stationRow(sortedStations[next++]));
      }
      buf.writeln(_recordRow(record));
    }
    for (; next < sortedStations.length; next++) {
      buf.writeln(_stationRow(sortedStations[next]));
    }
    return buf.toString();
  }

  /// Write the trip CSV to a temp folder and open the share sheet.
  static Future<void> exportAndShare(
    List<LogRecord> records, {
    List<StationEvent> stations = const [],
    Rect? sharePositionOrigin,
  }) async {
    if (records.isEmpty && stations.isEmpty) return;

    final cache = await getTemporaryDirectory();
    // A separate directory prevents rapid exports from overwriting a file
    // while another share sheet or receiving app is still reading it.
    final dir = await cache.createTemp('train_logger_export_');
    final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final file = File('${dir.path}/train_log_$stamp.csv');
    await file.writeAsString(buildCsv(records, stations));

    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'text/csv')],
      subject: 'Train Logger Export $stamp',
      sharePositionOrigin: sharePositionOrigin,
    );
  }

  // Unreadable times (never written by this app) sort first instead of failing
  // the export.
  static DateTime _time(String timestamp) =>
      DateTime.tryParse(timestamp) ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  static String _recordRow(LogRecord r) => [
    'record',
    r.index,
    r.timestamp,
    '', // departure_timestamp
    '', // dwell_s
    r.latitude,
    r.longitude,
    r.speedKmh.toStringAsFixed(2),
    r.altitudeM.toStringAsFixed(2),
    r.segmentDistanceM.toStringAsFixed(2),
    r.elevationDeltaM?.toStringAsFixed(2) ?? '',
    r.gradePercent?.toStringAsFixed(3) ?? '',
    r.curvaturePercent?.toStringAsFixed(4) ?? '',
    r.curveRadiusM?.toStringAsFixed(1) ?? '',
    r.totalDistanceM.toStringAsFixed(2),
    '', // gps_age_s
  ].join(',');

  static String _stationRow(StationEvent s) {
    final dwell = s.dwell;
    return [
      s.type.code,
      s.id,
      s.timestamp,
      s.departureTimestamp ?? '',
      dwell == null ? '' : (dwell.inMilliseconds / 1000).toStringAsFixed(1),
      s.latitude,
      s.longitude,
      s.speedKmh.toStringAsFixed(2),
      s.altitudeM.toStringAsFixed(2),
      '', // segment_distance_m
      '', // elevation_delta_m
      '', // grade_percent
      '', // curvature_percent
      '', // curve_radius_m
      s.totalDistanceM.toStringAsFixed(2),
      s.gpsAgeS?.toStringAsFixed(1) ?? '',
    ].join(',');
  }
}
