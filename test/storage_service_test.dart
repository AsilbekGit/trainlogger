import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:train_logger/models/log_record.dart';
import 'package:train_logger/services/storage_service.dart';

LogRecord record(int index, {double altitude = 100.0}) => LogRecord(
  index: index,
  timestamp: '2026-10-02T12:00:00.000Z',
  latitude: 41.0,
  longitude: 69.0,
  speedKmh: 72.0,
  altitudeM: altitude,
  segmentDistanceM: 50.0,
  elevationDeltaM: index == 1 ? null : 0.5,
  gradePercent: index == 1 ? null : 1.0,
  totalDistanceM: index * 50.0,
  curvaturePercent: index < 3 ? null : 0.2,
  curveRadiusM: index < 3 ? null : 500.0,
);

void main() {
  late Directory directory;
  late StorageService storage;
  late File dataFile;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('train_logger_test_');
    storage = StorageService(directory: directory);
    dataFile = File('${directory.path}/train_log_records.json');
    await storage.init();
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('saved records survive reload with optional fields intact', () async {
    await storage.addAll([record(1), record(2), record(3)]);
    final reloaded = StorageService(directory: directory);
    await reloaded.init();

    expect(reloaded.lastError, isNull);
    expect(reloaded.getAll().map((r) => r.index), [1, 2, 3]);
    expect(reloaded.getAll().first.gradePercent, isNull);
    expect(reloaded.getAll()[1].gradePercent, 1.0);
    expect(reloaded.getAll().last.curveRadiusM, 500.0);
    expect(reloaded.getAll().last.totalDistanceM, 150.0);
  });

  test('one malformed row does not delete the rest of the trip', () async {
    await storage.addAll([record(1), record(2), record(3)]);
    final rows = json.decode(await dataFile.readAsString()) as List<dynamic>;
    rows.insert(1, {'index': 'invalid'});
    final original = json.encode(rows);
    await dataFile.writeAsString(original);

    final reloaded = StorageService(directory: directory);
    await reloaded.init();

    expect(reloaded.getAll().map((r) => r.index), [1, 2, 3]);
    expect(reloaded.lastError, isNotNull);
    expect(await dataFile.readAsString(), original);
    final backups = await directory
        .list()
        .where((entry) => entry.path.contains('.corrupt-'))
        .toList();
    expect(backups, hasLength(1));
    expect(await File(backups.single.path).readAsString(), original);

    await reloaded.add(record(4));
    expect(reloaded.lastError, isNull);
    expect(json.decode(await dataFile.readAsString()), hasLength(4));
    expect(await File(backups.single.path).readAsString(), original);
  });

  test(
    'malformed JSON is backed up before a new session can replace it',
    () async {
      const original = '[{"index":1,';
      await dataFile.writeAsString(original);
      final reloaded = StorageService(directory: directory);
      await reloaded.init();

      expect(reloaded.count, 0);
      expect(reloaded.lastError, isA<FormatException>());
      expect(await dataFile.readAsString(), original);
      final backups = await directory
          .list()
          .where((entry) => entry.path.contains('.corrupt-'))
          .toList();
      expect(backups, hasLength(1));
      await reloaded.add(record(1));
      expect(await File(backups.single.path).readAsString(), original);
    },
  );

  test('an unreadable source is never overwritten as an empty trip', () async {
    final bytes = [0xff, 0xfe, 0xfd];
    await dataFile.writeAsBytes(bytes);
    final reloaded = StorageService(directory: directory);
    await reloaded.init();

    expect(reloaded.lastError, isNotNull);
    await expectLater(reloaded.add(record(1)), throwsStateError);
    await expectLater(reloaded.clearAll(), throwsStateError);
    expect(await dataFile.readAsBytes(), bytes);
  });

  test(
    'a failed save is reported and a later save retries retained records',
    () async {
      await storage.add(record(1));
      final tmpBlocker = Directory('${directory.path}/train_log_records.tmp');
      await tmpBlocker.create();

      await expectLater(
        storage.add(record(2)),
        throwsA(isA<FileSystemException>()),
      );
      expect(storage.lastError, isA<FileSystemException>());
      expect(storage.count, 2);
      expect(json.decode(await dataFile.readAsString()), hasLength(1));

      await tmpBlocker.delete();
      await storage.add(record(3));
      expect(storage.lastError, isNull);
      final reloaded = StorageService(directory: directory);
      await reloaded.init();
      expect(reloaded.getAll().map((r) => r.index), [1, 2, 3]);
    },
  );

  test('failed clear preserves both memory and the persisted trip', () async {
    await storage.add(record(1));
    final tmpBlocker = Directory('${directory.path}/train_log_records.tmp');
    await tmpBlocker.create();

    await expectLater(storage.clearAll(), throwsA(isA<FileSystemException>()));
    expect(storage.count, 1);
    expect(json.decode(await dataFile.readAsString()), hasLength(1));

    await tmpBlocker.delete();
    await storage.clearAll();
    expect(storage.count, 0);
    expect(json.decode(await dataFile.readAsString()), isEmpty);
  });

  test(
    'overlapping append, clear and append persist only the new session',
    () async {
      final first = storage.add(record(1));
      final clear = storage.clearAll();
      final last = storage.add(record(2));
      await Future.wait([first, clear, last]);

      expect(storage.getAll().map((r) => r.index), [2]);
      final reloaded = StorageService(directory: directory);
      await reloaded.init();
      expect(reloaded.getAll().map((r) => r.index), [2]);
    },
  );

  test('a non-finite value cannot poison every later save', () async {
    await storage.add(record(1));
    await expectLater(
      storage.add(record(2, altitude: double.nan)),
      throwsA(isA<JsonUnsupportedObjectError>()),
    );
    expect(storage.count, 1);
    await storage.add(record(2));
    expect(storage.count, 2);
    expect(json.decode(await dataFile.readAsString()), hasLength(2));
  });
}
