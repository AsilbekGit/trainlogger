import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:train_logger/models/log_record.dart';
import 'package:train_logger/models/station_event.dart';
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

/// A row as the old array format (`train_log_records.json`) stored [record].
Map<String, dynamic> legacyRow(int index) => {
  'index': index,
  'timestamp': '2026-10-02T12:00:00.000Z',
  'latitude': 41.0,
  'longitude': 69.0,
  'speedKmh': 72.0,
  'altitudeM': 100.0,
  'segmentDistanceM': 50.0,
  'elevationDeltaM': index == 1 ? null : 0.5,
  'gradePercent': index == 1 ? null : 1.0,
  'totalDistanceM': index * 50.0,
  'curvaturePercent': index < 3 ? null : 0.2,
  'curveRadiusM': index < 3 ? null : 500.0,
};

StationEvent station(int id, {String? departure, double? gpsAgeS}) =>
    StationEvent(
      id: id,
      type: id.isOdd ? StationEventType.autoStop : StationEventType.manualMark,
      timestamp: '2026-10-02T12:00:00.000Z',
      departureTimestamp: departure,
      latitude: 41.0,
      longitude: 69.0,
      altitudeM: 400.0,
      speedKmh: 0.0,
      totalDistanceM: id * 100.0,
      gpsAgeS: gpsAgeS,
    );

/// Parses a JSON Lines file strictly: every non-empty line must be an object,
/// and the file must end with a newline.
Future<List<Map<String, dynamic>>> readLines(File file) async {
  final text = await file.readAsString();
  expect(text.isEmpty || text.endsWith('\n'), isTrue, reason: 'unterminated');
  return const LineSplitter()
      .convert(text)
      .where((line) => line.isNotEmpty)
      .map((line) => json.decode(line) as Map<String, dynamic>)
      .toList();
}

Future<List<int>> indexes(File file) async =>
    (await readLines(file)).map((row) => row['index'] as int).toList();

void main() {
  late Directory directory;
  late StorageService storage;
  late File dataFile;
  late File legacyFile;
  late File migratedFile;
  late File stationsFile;
  late String tmpPath;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('train_logger_test_');
    storage = StorageService(directory: directory);
    dataFile = File('${directory.path}/train_log_records.jsonl');
    legacyFile = File('${directory.path}/train_log_records.json');
    migratedFile = File('${directory.path}/train_log_records.json.migrated');
    stationsFile = File('${directory.path}/train_log_stations.json');
    // A directory here makes atomic rewrites fail; appends never use it.
    tmpPath = '${directory.path}/train_log_records.tmp';
    await storage.init();
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  Future<StorageService> reload() async {
    final reloaded = StorageService(directory: directory);
    await reloaded.init();
    return reloaded;
  }

  Future<List<File>> backups(String fileName) async => [
    await for (final entry in directory.list())
      if (entry.path.contains('$fileName.corrupt-')) File(entry.path),
  ];

  /// Makes appends fail by putting a directory where the records file is.
  /// The returned function restores the original file byte for byte.
  Future<Future<void> Function()> blockRecordsFile() async {
    final aside = File('${directory.path}/records.aside');
    final existed = await dataFile.exists();
    if (existed) await dataFile.rename(aside.path);
    final blocker = await Directory(dataFile.path).create();
    return () async {
      await blocker.delete();
      if (existed) await aside.rename(dataFile.path);
    };
  }

  test('saved records survive reload with optional fields intact', () async {
    await storage.addAll([record(1), record(2), record(3)]);
    final reloaded = await reload();

    expect(reloaded.lastError, isNull);
    expect(reloaded.recordsDamaged, isFalse);
    expect(reloaded.stationsDamaged, isFalse);
    expect(reloaded.getAll().map((r) => r.index), [1, 2, 3]);
    expect(reloaded.getAll().first.gradePercent, isNull);
    expect(reloaded.getAll()[1].gradePercent, 1.0);
    expect(reloaded.getAll().last.curveRadiusM, 500.0);
    expect(reloaded.getAll().last.totalDistanceM, 150.0);
    // One JSON object per line, with the same keys as the old array rows.
    expect(await readLines(dataFile), [
      legacyRow(1),
      legacyRow(2),
      legacyRow(3),
    ]);
  });

  test('saves append new lines and never rewrite earlier bytes', () async {
    await storage.addAll([record(1), record(2), record(3)]);
    // Valid but hand-formatted: a rewrite would normalize these bytes.
    await dataFile.writeAsString(
      (await dataFile.readAsString()).replaceFirst(
        '{"index":1,',
        '{ "index": 1,',
      ),
    );
    final before = await dataFile.readAsBytes();
    final reloaded = await reload();
    expect(reloaded.lastError, isNull);
    // Appends never use the temp file, so blocking it proves no rewrite.
    final tmpBlocker = await Directory(tmpPath).create();

    await reloaded.add(record(4));
    await reloaded.addAll([record(5), record(6)]);
    await reloaded.addAll(const []);

    expect(reloaded.lastError, isNull);
    final after = await dataFile.readAsBytes();
    expect(after.sublist(0, before.length), before);
    expect(
      const LineSplitter().convert(utf8.decode(after.sublist(before.length))),
      hasLength(3),
    );
    expect(await indexes(dataFile), [1, 2, 3, 4, 5, 6]);
    await tmpBlocker.delete();
  });

  test('one malformed row does not delete the rest of the trip', () async {
    await storage.addAll([record(1), record(2), record(3)]);
    final lines = const LineSplitter().convert(await dataFile.readAsString());
    final original = [
      ...utf8.encode('${lines[0]}\n{"index":"invalid"}\nnot json\n'),
      0xff, 0xfe, 0x0a, // A line that is not even UTF-8.
      ...utf8.encode('${lines[1]}\n${lines[2]}\n'),
    ];
    await dataFile.writeAsBytes(original);

    final reloaded = await reload();

    expect(reloaded.getAll().map((r) => r.index), [1, 2, 3]);
    expect(reloaded.lastError, isNotNull);
    expect(reloaded.recordsDamaged, isTrue);
    expect(reloaded.stationsDamaged, isFalse);
    expect(await dataFile.readAsBytes(), original);
    final saved = await backups('train_log_records.jsonl');
    expect(saved, hasLength(1));
    expect(await saved.single.readAsBytes(), original);

    await reloaded.add(record(4));
    expect(reloaded.lastError, isNull);
    expect(await indexes(dataFile), [1, 2, 3, 4]);
    expect(await saved.single.readAsBytes(), original);
  });

  test(
    'malformed JSON is backed up before a new session can replace it',
    () async {
      const original = '{"index":1,';
      await dataFile.writeAsString(original);
      final reloaded = await reload();

      expect(reloaded.count, 0);
      expect(reloaded.lastError, isA<FormatException>());
      expect(await dataFile.readAsString(), original);
      final saved = await backups('train_log_records.jsonl');
      expect(saved, hasLength(1));
      await reloaded.add(record(1));
      expect(await saved.single.readAsString(), original);
      expect(await indexes(dataFile), [1]);
    },
  );

  test('a torn last line is recovered, then cleanly rewritten', () async {
    await storage.addAll([record(1), record(2), record(3)]);
    // A crash in the middle of appending record 4.
    final torn = '${await dataFile.readAsString()}{"index":4,"timestamp":"20';
    await dataFile.writeAsString(torn);

    final reloaded = await reload();
    expect(reloaded.getAll().map((r) => r.index), [1, 2, 3]);
    expect(reloaded.lastError, isA<FormatException>());
    expect(reloaded.recordsDamaged, isTrue);
    expect(await dataFile.readAsString(), torn);
    final saved = await backups('train_log_records.jsonl');
    expect(await saved.single.readAsString(), torn);

    // Never appended after the fragment: the save rewrites the whole file.
    await reloaded.add(record(4));
    expect(reloaded.lastError, isNull);
    expect(await indexes(dataFile), [1, 2, 3, 4]);

    final again = await reload();
    expect(again.lastError, isNull);
    expect(again.recordsDamaged, isFalse);
    expect(again.getAll().map((r) => r.index), [1, 2, 3, 4]);
    expect(await backups('train_log_records.jsonl'), hasLength(1));
  });

  test(
    'an unterminated valid last line is rewritten, not appended to',
    () async {
      await storage.addAll([record(1), record(2)]);
      final lines = const LineSplitter().convert(await dataFile.readAsString());
      // Blank lines are skipped; a missing final newline is not damage.
      await dataFile.writeAsString('${lines[0]}\n   \n\n${lines[1]}');

      final reloaded = await reload();
      expect(reloaded.lastError, isNull);
      expect(reloaded.recordsDamaged, isFalse);
      expect(reloaded.getAll().map((r) => r.index), [1, 2]);
      expect(await backups('train_log_records.jsonl'), isEmpty);

      await reloaded.add(record(3));
      expect(await indexes(dataFile), [1, 2, 3]);
      expect((await reload()).getAll().map((r) => r.index), [1, 2, 3]);
    },
  );

  test('an unreadable source is never overwritten as an empty trip', () async {
    final bytes = [0xff, 0xfe, 0xfd];
    await legacyFile.writeAsBytes(bytes);
    final reloaded = await reload();

    expect(reloaded.lastError, isNotNull);
    expect(reloaded.recordsDamaged, isTrue);
    await expectLater(reloaded.add(record(1)), throwsStateError);
    await expectLater(reloaded.clearAll(), throwsStateError);
    expect(await legacyFile.readAsBytes(), bytes);
    expect(await dataFile.exists(), isFalse);
  });

  test(
    'an unreadable JSON Lines file blocks saving and is not migrated over',
    () async {
      final legacy = json.encode([legacyRow(1)]);
      await legacyFile.writeAsString(legacy);
      await Directory(dataFile.path).create();
      final reloaded = await reload();

      expect(reloaded.lastError, isA<FileSystemException>());
      expect(reloaded.recordsDamaged, isTrue);
      expect(reloaded.count, 0);
      await expectLater(reloaded.add(record(1)), throwsStateError);
      await expectLater(reloaded.clearAll(), throwsStateError);
      expect(await legacyFile.readAsString(), legacy);
      expect(await migratedFile.exists(), isFalse);
    },
  );

  test(
    'a failed save is reported and a later save retries retained records',
    () async {
      await storage.add(record(1));
      final unblock = await blockRecordsFile();

      await expectLater(
        storage.add(record(2)),
        throwsA(isA<FileSystemException>()),
      );
      expect(storage.lastError, isA<FileSystemException>());
      expect(storage.count, 2);
      await unblock();
      expect(await indexes(dataFile), [1]);

      await storage.add(record(3));
      expect(storage.lastError, isNull);
      final reloaded = await reload();
      expect(reloaded.getAll().map((r) => r.index), [1, 2, 3]);
    },
  );

  test(
    'a failed append is followed by a full rewrite on the next save',
    () async {
      await storage.add(record(1));
      final before = await dataFile.readAsBytes();
      final unblock = await blockRecordsFile();
      await expectLater(
        storage.add(record(2)),
        throwsA(isA<FileSystemException>()),
      );
      await unblock();

      // The next save must rewrite through the temp file, not append: blocking
      // the temp file makes it fail, and it keeps trying to rewrite.
      final tmpBlocker = await Directory(tmpPath).create();
      await expectLater(
        storage.add(record(3)),
        throwsA(isA<FileSystemException>()),
      );
      expect(storage.count, 3);
      expect(await dataFile.readAsBytes(), before);
      await tmpBlocker.delete();

      await storage.add(record(4));
      expect(storage.lastError, isNull);
      expect(await indexes(dataFile), [1, 2, 3, 4]);
      final reloaded = await reload();
      expect(reloaded.lastError, isNull);
      expect(reloaded.getAll().map((r) => r.index), [1, 2, 3, 4]);

      // Once the file matches memory again, saves go back to appending.
      final rewritten = await dataFile.readAsBytes();
      await Directory(tmpPath).create();
      await storage.add(record(5));
      final after = await dataFile.readAsBytes();
      expect(after.sublist(0, rewritten.length), rewritten);
      expect(await indexes(dataFile), [1, 2, 3, 4, 5]);
    },
  );

  test('failed clear preserves both memory and the persisted trip', () async {
    await storage.add(record(1));
    final tmpBlocker = await Directory(tmpPath).create();

    await expectLater(storage.clearAll(), throwsA(isA<FileSystemException>()));
    expect(storage.count, 1);
    expect(await indexes(dataFile), [1]);

    await tmpBlocker.delete();
    await storage.clearAll();
    expect(storage.count, 0);
    expect(await dataFile.readAsString(), isEmpty);

    await storage.add(record(1));
    expect((await reload()).getAll().map((r) => r.index), [1]);
  });

  test(
    'overlapping append, clear and append persist only the new session',
    () async {
      final first = storage.add(record(1));
      final clear = storage.clearAll();
      final last = storage.add(record(2));
      await Future.wait([first, clear, last]);

      expect(storage.getAll().map((r) => r.index), [2]);
      final reloaded = await reload();
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
    expect(await indexes(dataFile), [1, 2]);
  });

  test('a legacy array file is migrated once to JSON Lines', () async {
    final original = json.encode([legacyRow(1), legacyRow(2), legacyRow(3)]);
    await legacyFile.writeAsString(original);

    final migrated = await reload();
    expect(migrated.lastError, isNull);
    expect(migrated.recordsDamaged, isFalse);
    expect(migrated.getAll().map((r) => r.index), [1, 2, 3]);
    expect(migrated.getAll().first.gradePercent, isNull);
    expect(migrated.getAll().last.curveRadiusM, 500.0);
    expect(await readLines(dataFile), [
      legacyRow(1),
      legacyRow(2),
      legacyRow(3),
    ]);
    expect(await legacyFile.exists(), isFalse);
    expect(await migratedFile.readAsString(), original);

    // Second launch: read from JSON Lines only, nothing imported twice.
    await migrated.add(record(4));
    final second = await reload();
    expect(second.lastError, isNull);
    expect(second.getAll().map((r) => r.index), [1, 2, 3, 4]);
    expect(await legacyFile.exists(), isFalse);
    expect(await migratedFile.readAsString(), original);
  });

  test(
    'when both files exist, JSON Lines wins and legacy is untouched',
    () async {
      await storage.addAll([record(1), record(2)]);
      final legacy = json.encode([legacyRow(7), legacyRow(8)]);
      await legacyFile.writeAsString(legacy);

      final reloaded = await reload();
      expect(reloaded.lastError, isNull);
      expect(reloaded.getAll().map((r) => r.index), [1, 2]);
      expect(await legacyFile.readAsString(), legacy);
      expect(await migratedFile.exists(), isFalse);
    },
  );

  test(
    'a damaged legacy file is backed up and its valid rows migrated',
    () async {
      final original = json.encode([
        legacyRow(1),
        {'index': 'invalid'},
        legacyRow(3),
      ]);
      await legacyFile.writeAsString(original);

      final migrated = await reload();
      expect(migrated.getAll().map((r) => r.index), [1, 3]);
      expect(migrated.lastError, isNotNull);
      expect(migrated.recordsDamaged, isTrue);
      final saved = await backups('train_log_records.json');
      expect(saved, hasLength(1));
      expect(await saved.single.readAsString(), original);
      expect(await indexes(dataFile), [1, 3]);
      expect(await migratedFile.readAsString(), original);

      final second = await reload();
      expect(second.lastError, isNull);
      expect(second.recordsDamaged, isFalse);
      expect(second.getAll().map((r) => r.index), [1, 3]);
    },
  );

  test(
    'a migration that cannot write keeps the legacy file until a save works',
    () async {
      final original = json.encode([legacyRow(1), legacyRow(2)]);
      await legacyFile.writeAsString(original);
      final tmpBlocker = await Directory(tmpPath).create();

      final migrated = await reload();
      expect(migrated.lastError, isA<FileSystemException>());
      expect(migrated.recordsDamaged, isFalse);
      expect(migrated.getAll().map((r) => r.index), [1, 2]);
      expect(await dataFile.exists(), isFalse);
      expect(await legacyFile.readAsString(), original);

      await tmpBlocker.delete();
      await migrated.add(record(3));
      expect(migrated.lastError, isNull);
      expect(await indexes(dataFile), [1, 2, 3]);
      expect(await legacyFile.exists(), isFalse);
      expect(await migratedFile.readAsString(), original);
      expect((await reload()).getAll().map((r) => r.index), [1, 2, 3]);
    },
  );

  test('stations survive reload and an update replaces the same id', () async {
    await storage.add(record(1));
    await storage.saveStation(station(1));
    await storage.saveStation(station(2));
    await storage.saveStation(
      station(1, departure: '2026-10-02T12:01:30.000Z'),
    );
    final reloaded = await reload();

    expect(reloaded.lastError, isNull);
    expect(reloaded.getStations().map((s) => s.id), [1, 2]);
    expect(reloaded.getStations().first.type, StationEventType.autoStop);
    expect(reloaded.getStations().first.dwell, const Duration(seconds: 90));
    expect(reloaded.getStations().last.departureTimestamp, isNull);
    expect(reloaded.getAll(), hasLength(1));
    // Stations stay a JSON array; records stay in their own file.
    expect(json.decode(await stationsFile.readAsString()), hasLength(2));
    expect(await indexes(dataFile), [1]);
  });

  test('gpsAgeS round-trips, and old station rows without it load', () async {
    await storage.saveStation(station(1));
    await storage.saveStation(station(2, gpsAgeS: 4.5));
    final rows = json.decode(await stationsFile.readAsString()) as List;
    expect(rows.last['gpsAgeS'], 4.5);

    final reloaded = await reload();
    expect(reloaded.lastError, isNull);
    expect(reloaded.getStations().map((s) => s.gpsAgeS), [null, 4.5]);

    // Files written before the field existed have no such key.
    await stationsFile.writeAsString(
      json.encode([
        for (final row in rows) Map.of(row as Map)..remove('gpsAgeS'),
      ]),
    );
    final old = await reload();
    expect(old.lastError, isNull);
    expect(old.stationsDamaged, isFalse);
    expect(old.getStations().map((s) => s.id), [1, 2]);
    expect(old.getStations().map((s) => s.gpsAgeS), [null, null]);
  });

  test('New Session clears stations, and a failed clear keeps them', () async {
    await storage.add(record(1));
    await storage.saveStation(station(1));
    final tmpBlocker = await Directory(tmpPath).create();

    await expectLater(storage.clearAll(), throwsA(isA<FileSystemException>()));
    expect(storage.getStations(), hasLength(1));
    expect(json.decode(await stationsFile.readAsString()), hasLength(1));
    expect(await indexes(dataFile), [1]);

    await tmpBlocker.delete();
    await storage.clearAll();
    expect(storage.getStations(), isEmpty);
    expect(json.decode(await stationsFile.readAsString()), isEmpty);
  });

  test('a damaged stations row is backed up without losing the trip', () async {
    await storage.add(record(1));
    await storage.saveStation(station(1));
    final rows = json.decode(await stationsFile.readAsString()) as List;
    rows.add({...rows.first as Map<String, dynamic>, 'id': 2, 'type': 'x'});
    final original = json.encode(rows);
    await stationsFile.writeAsString(original);

    final reloaded = await reload();
    expect(reloaded.getAll(), hasLength(1));
    expect(reloaded.getStations().map((s) => s.id), [1]);
    expect(reloaded.lastError, isA<FormatException>());
    expect(reloaded.recordsDamaged, isFalse);
    expect(reloaded.stationsDamaged, isTrue);
    final saved = await backups('train_log_stations.json');
    expect(saved, hasLength(1));
    expect(await saved.single.readAsString(), original);
  });

  test('damage flags tell an unreadable stations file from records', () async {
    expect(storage.recordsDamaged, isFalse);
    expect(storage.stationsDamaged, isFalse);
    await storage.add(record(1));
    await storage.saveStation(station(1));
    await stationsFile.delete();
    await Directory(stationsFile.path).create();

    // Records load first, so the trip is still shown while saving is blocked.
    final reloaded = await reload();
    expect(reloaded.lastError, isA<FileSystemException>());
    expect(reloaded.recordsDamaged, isFalse);
    expect(reloaded.stationsDamaged, isTrue);
    expect(reloaded.getAll().map((r) => r.index), [1]);
    await expectLater(reloaded.add(record(2)), throwsStateError);
    expect(await indexes(dataFile), [1]);

    await Directory(stationsFile.path).delete();
    final restored = await reload();
    expect(restored.lastError, isNull);
    expect(restored.recordsDamaged, isFalse);
    expect(restored.stationsDamaged, isFalse);
  });

  test('appends stay cheap on a 1000 km trip (timing printout)', () async {
    const total = 20000;
    const timed = 100;
    final watch = Stopwatch()..start();
    for (var i = 1; i <= timed; i++) {
      await storage.add(record(i));
    }
    final firstMs = watch.elapsedMicroseconds / 1000 / timed;

    await storage.addAll([
      for (var i = timed + 1; i <= total - timed; i++) record(i),
    ]);
    watch.reset();
    for (var i = total - timed + 1; i <= total; i++) {
      await storage.add(record(i));
    }
    final lastMs = watch.elapsedMicroseconds / 1000 / timed;

    watch.reset();
    final reloaded = await reload();
    final reloadMs = watch.elapsedMilliseconds;
    final megabytes = await dataFile.length() / 1e6;

    // ignore: avoid_print
    print(
      'StorageService.add: first $timed avg ${firstMs.toStringAsFixed(3)} ms, '
      'last $timed of $total avg ${lastMs.toStringAsFixed(3)} ms; '
      'file ${megabytes.toStringAsFixed(1)} MB; reload $reloadMs ms',
    );
    expect(reloaded.count, total);
    expect(reloaded.getAll().last.index, total);
    expect(lastMs, lessThan(20));
  });
}
