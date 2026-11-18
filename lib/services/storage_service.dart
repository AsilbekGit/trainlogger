import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/log_record.dart';
import '../models/station_event.dart';

/// Persists [LogRecord]s and [StationEvent]s in the application documents
/// directory.
///
/// Records are append-only JSON Lines in `train_log_records.jsonl`: one JSON
/// object per '\n'-terminated line. A normal save appends only the new lines
/// and flushes, so its cost does not grow with the trip. Whenever the file
/// might not match memory (a failed or partial append, a malformed or
/// unterminated line found at load, a failed migration), the next save
/// instead rewrites the whole file from memory atomically: temporary file,
/// flush, rename. Nothing is ever appended after a torn line.
///
/// Stations are few, so `train_log_stations.json` stays a JSON array that is
/// rewritten atomically on every change.
///
/// A legacy `train_log_records.json` array is migrated once, when no `.jsonl`
/// file exists: the `.jsonl` file is written atomically, then the legacy file
/// is renamed to `train_log_records.json.migrated`. If both files exist (for
/// example after a crash between those two steps), the `.jsonl` file wins and
/// the legacy file is left untouched.
///
/// Writes are serialized. Malformed data is backed up to
/// `<file>.corrupt-<microseconds>` before valid rows are recovered; an
/// unreadable file is never treated as an empty session and overwritten.
class StorageService {
  static const String _fileName = 'train_log_records.jsonl';
  static const String _tmpFileName = 'train_log_records.tmp';
  static const String _legacyFileName = 'train_log_records.json';
  static const String _stationsFileName = 'train_log_stations.json';
  static const String _stationsTmpFileName = 'train_log_stations.tmp';
  static const int _newline = 0x0A;

  final Directory? _directory;
  final List<LogRecord> _records = [];
  final List<StationEvent> _stations = [];
  String? _filePath;
  String? _tmpFilePath;
  String? _legacyPath;
  String? _stationsPath;
  String? _stationsTmpPath;
  bool _initialized = false;

  /// The records file may not match memory, so the next save must rewrite it
  /// whole instead of appending.
  bool _needsRewrite = false;

  /// A migration could not write the `.jsonl` file, so the legacy file is
  /// still the only copy. It is renamed after the next successful rewrite.
  bool _legacyAwaitingRetirement = false;

  /// Most recent initialization or write error, cleared after a successful save.
  Object? lastError;

  /// Set by [init]: the records file had malformed data (backed up, valid rows
  /// recovered) or could not be read.
  bool recordsDamaged = false;

  /// Set by [init]: the stations file had malformed data (backed up, valid rows
  /// recovered) or could not be read.
  bool stationsDamaged = false;

  StorageService({Directory? directory}) : _directory = directory;

  /// Serializes mutations as well as disk writes. In particular, a queued clear
  /// must finish before a later append, so a new session cannot resurrect rows.
  Future<void> _writeChain = Future<void>.value();

  /// Initializes storage without preventing the app from launching on failure.
  /// Callers can display [lastError]; saves fail if existing data wasn't loaded.
  Future<void> init() async {
    if (_initialized) return;
    lastError = null;
    recordsDamaged = false;
    stationsDamaged = false;
    _needsRewrite = false;
    _legacyAwaitingRetirement = false;
    _records.clear();
    _stations.clear();
    try {
      final dir = _directory ?? await getApplicationDocumentsDirectory();
      _filePath = '${dir.path}/$_fileName';
      _tmpFilePath = '${dir.path}/$_tmpFileName';
      _legacyPath = '${dir.path}/$_legacyFileName';
      _stationsPath = '${dir.path}/$_stationsFileName';
      _stationsTmpPath = '${dir.path}/$_stationsTmpFileName';
      // Records first: if the stations file is unreadable, the trip is still
      // shown and exportable, while saving stays blocked.
      try {
        _records.addAll(await _loadRecords());
      } catch (_) {
        recordsDamaged = true;
        rethrow;
      }
      try {
        final loaded = await _loadArray(File(_stationsPath!), _stationFromJson);
        if (loaded != null) {
          _stations.addAll(loaded.rows);
          if (loaded.damaged) stationsDamaged = true;
        }
      } catch (_) {
        stationsDamaged = true;
        rethrow;
      }
      _initialized = true;
    } catch (e) {
      lastError = e;
      _initialized = false;
      debugPrint('[StorageService] Initialization error: $e');
    }
  }

  /// All records in insertion order.
  List<LogRecord> getAll() => List.from(_records);

  /// All stops and station marks in creation order.
  List<StationEvent> getStations() => List.from(_stations);

  /// Append a new record and persist.
  Future<void> add(LogRecord record) => addAll([record]);

  /// Append multiple records and persist once. If saving fails, retain them in
  /// memory so a subsequent successful save can retry the complete session.
  Future<void> addAll(List<LogRecord> records) {
    final pending = List<LogRecord>.of(records);
    return _enqueue(() async {
      _ensureInitialized();
      // Encoding first rejects records JSON cannot represent before they reach
      // memory and poison every later save.
      final lines = _encodeLines(pending);
      _records.addAll(pending);
      if (_needsRewrite) {
        await _rewriteRecords(_records);
      } else if (lines.isNotEmpty) {
        await _appendRecords(lines);
      }
    });
  }

  /// Add a station event, or replace the one with the same id (a stop gains
  /// its departure time). Kept in memory on failure so a later save retries.
  Future<void> saveStation(StationEvent station) => _enqueue(() async {
    _ensureInitialized();
    json.encode(_stationToJson(station));
    final index = _stations.indexWhere((s) => s.id == station.id);
    if (index >= 0) {
      _stations[index] = station;
    } else {
      _stations.add(station);
    }
    await _writeStations(_stations);
  });

  /// Wipe records and stations only after the empty files are safely persisted.
  Future<void> clearAll() => _enqueue(() async {
    _ensureInitialized();
    // Stations go first. If the trip itself then fails to clear, they are
    // written back so a failed New Session leaves both files as they were.
    await _writeStations(const []);
    try {
      await _rewriteRecords(const []);
    } catch (_) {
      try {
        await _writeStations(_stations);
      } catch (error) {
        debugPrint('[StorageService] Could not restore stations: $error');
      }
      rethrow;
    }
    _records.clear();
    _stations.clear();
  });

  int get count => _records.length;

  // ── Private: loading ──────────────────────────────────────────

  /// Loads the `.jsonl` file, or migrates the legacy array when it is absent.
  Future<List<LogRecord>> _loadRecords() async {
    final file = File(_filePath!);
    final bytes = await _readIfExists(file, (f) => f.readAsBytes());
    // The JSONL file wins; a legacy file next to it is never read again.
    if (bytes != null) return _parseRecordLines(file, bytes);

    final legacy = await _loadArray(File(_legacyPath!), _recordFromJson);
    if (legacy == null) return const [];
    if (legacy.damaged) recordsDamaged = true;
    _legacyAwaitingRetirement = true;
    try {
      await _rewriteRecords(legacy.rows);
    } catch (e) {
      // The legacy file stays in place as the only copy. The first successful
      // save writes the JSONL file and then retires the legacy one.
      _needsRewrite = true;
      lastError ??= e;
      debugPrint('[StorageService] Could not migrate records: $e');
    }
    return legacy.rows;
  }

  /// Parses JSON Lines, skipping blank lines. Each line is decoded on its own,
  /// so a torn or malformed line costs only that line.
  Future<List<LogRecord>> _parseRecordLines(File file, Uint8List bytes) async {
    final recovered = <LogRecord>[];
    Object? corruption;
    var start = 0;
    while (start < bytes.length) {
      var end = bytes.indexOf(_newline, start);
      if (end < 0) end = bytes.length;
      final line = Uint8List.sublistView(bytes, start, end);
      start = end + 1;
      try {
        final text = utf8.decode(line);
        if (text.trim().isEmpty) continue;
        recovered.add(
          _recordFromJson(json.decode(text) as Map<String, dynamic>),
        );
      } on FormatException catch (e) {
        corruption ??= e;
      } on TypeError catch (e) {
        corruption ??= e;
      }
    }
    // An unterminated last line, valid or torn, must not be appended to.
    if (bytes.isNotEmpty && bytes.last != _newline) _needsRewrite = true;
    if (corruption != null) {
      await _backUp(file, corruption, recovered.length);
      recordsDamaged = true;
      _needsRewrite = true;
    }
    return recovered;
  }

  /// Loads a JSON array file (the stations file, or the legacy records file).
  /// Returns null when the file does not exist.
  Future<({List<T> rows, bool damaged})?> _loadArray<T>(
    File file,
    T Function(Map<String, dynamic> row) fromRow,
  ) async {
    final jsonString = await _readIfExists(file, (f) => f.readAsString());
    if (jsonString == null) return null;
    if (jsonString.trim().isEmpty) return (rows: <T>[], damaged: false);

    final recovered = <T>[];
    Object? corruption;
    try {
      final decoded = json.decode(jsonString);
      if (decoded is! List) {
        throw const FormatException('Expected a list of rows');
      }
      for (final row in decoded) {
        try {
          recovered.add(fromRow(row as Map<String, dynamic>));
        } on FormatException catch (e) {
          corruption ??= e;
        } on TypeError catch (e) {
          corruption ??= e;
        }
      }
    } on FormatException catch (e) {
      corruption = e;
    }

    if (corruption != null) await _backUp(file, corruption, recovered.length);
    return (rows: recovered, damaged: corruption != null);
  }

  /// I/O failures are not malformed data. Leave the original untouched and
  /// prevent writes until initialization succeeds, rather than losing a trip.
  /// Only a missing file reads as null (an empty trip).
  Future<R?> _readIfExists<R>(File file, Future<R> Function(File) read) async {
    try {
      return await read(file);
    } on FileSystemException catch (e) {
      if (e is PathNotFoundException || e.osError?.errorCode == 2) return null;
      rethrow;
    }
  }

  /// Preserves the complete original (including bad rows) before any later
  /// save replaces it. A failed backup leaves initialization unsuccessful.
  Future<void> _backUp(File file, Object corruption, int recovered) async {
    final backupPath =
        '${file.path}.corrupt-${DateTime.now().microsecondsSinceEpoch}';
    await file.copy(backupPath);
    lastError = corruption;
    debugPrint(
      '[StorageService] Recovered $recovered rows; '
      'original saved to $backupPath',
    );
  }

  // ── Private: writing ──────────────────────────────────────────

  void _ensureInitialized() {
    if (!_initialized) {
      throw StateError('Storage is unavailable because initialization failed');
    }
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _writeChain.then((_) async {
      try {
        await operation();
        lastError = null;
      } catch (e) {
        lastError = e;
        debugPrint('[StorageService] Save error: $e');
        rethrow;
      }
    });
    // Keep the queue usable after a failure while returning that failure to
    // the caller, which can warn the user rather than pretending data is saved.
    _writeChain = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<void> _appendRecords(String lines) async {
    try {
      await File(
        _filePath!,
      ).writeAsString(lines, mode: FileMode.append, flush: true);
    } catch (_) {
      // Some of [lines] may have reached the disk. Never append after that:
      // the next save replaces the whole file from memory.
      _needsRewrite = true;
      rethrow;
    }
  }

  /// Replaces the records file with exactly [records]. On failure the previous
  /// file is untouched and [_needsRewrite] keeps its value.
  Future<void> _rewriteRecords(List<LogRecord> records) async {
    await _writeAtomic(_filePath!, _tmpFilePath!, _encodeLines(records));
    _needsRewrite = false;
    if (_legacyAwaitingRetirement) await _retireLegacy();
  }

  /// Renames the migrated legacy file so it is never imported twice. A failure
  /// is harmless because the JSONL file now exists and takes precedence.
  Future<void> _retireLegacy() async {
    _legacyAwaitingRetirement = false;
    try {
      var target = '$_legacyPath.migrated';
      if (await File(target).exists()) {
        target = '$target-${DateTime.now().microsecondsSinceEpoch}';
      }
      await File(_legacyPath!).rename(target);
    } on FileSystemException catch (e) {
      debugPrint('[StorageService] Could not retire legacy records: $e');
    }
  }

  Future<void> _writeStations(List<StationEvent> stations) => _writeAtomic(
    _stationsPath!,
    _stationsTmpPath!,
    json.encode(stations.map(_stationToJson).toList()),
  );

  Future<void> _writeAtomic(String path, String tmpPath, String content) async {
    final tmpFile = File(tmpPath);
    await tmpFile.writeAsString(content, flush: true);
    await tmpFile.rename(path);
  }

  // ── JSON serialization ────────────────────────────────────────

  /// One '\n'-terminated JSON object per record. Throws before returning if
  /// any record cannot be encoded (for example a NaN value).
  String _encodeLines(List<LogRecord> records) {
    final buffer = StringBuffer();
    for (final r in records) {
      buffer
        ..write(json.encode(_recordToJson(r)))
        ..write('\n');
    }
    return buffer.toString();
  }

  Map<String, dynamic> _recordToJson(LogRecord r) => {
    'index': r.index,
    'timestamp': r.timestamp,
    'latitude': r.latitude,
    'longitude': r.longitude,
    'speedKmh': r.speedKmh,
    'altitudeM': r.altitudeM,
    'segmentDistanceM': r.segmentDistanceM,
    'elevationDeltaM': r.elevationDeltaM,
    'gradePercent': r.gradePercent,
    'totalDistanceM': r.totalDistanceM,
    'curvaturePercent': r.curvaturePercent,
    'curveRadiusM': r.curveRadiusM,
  };

  double _number(Map<String, dynamic> row, String key) {
    final value = (row[key] as num).toDouble();
    if (!value.isFinite) throw FormatException('Non-finite $key');
    return value;
  }

  double? _optionalNumber(Map<String, dynamic> row, String key) =>
      row[key] == null ? null : _number(row, key);

  LogRecord _recordFromJson(Map<String, dynamic> m) => LogRecord(
    index: m['index'] as int,
    timestamp: m['timestamp'] as String,
    latitude: _number(m, 'latitude'),
    longitude: _number(m, 'longitude'),
    speedKmh: _number(m, 'speedKmh'),
    altitudeM: _number(m, 'altitudeM'),
    segmentDistanceM: _number(m, 'segmentDistanceM'),
    elevationDeltaM: _optionalNumber(m, 'elevationDeltaM'),
    gradePercent: _optionalNumber(m, 'gradePercent'),
    totalDistanceM: _number(m, 'totalDistanceM'),
    curvaturePercent: _optionalNumber(m, 'curvaturePercent'),
    curveRadiusM: _optionalNumber(m, 'curveRadiusM'),
  );

  Map<String, dynamic> _stationToJson(StationEvent s) => {
    'id': s.id,
    'type': s.type.code,
    'timestamp': s.timestamp,
    'departureTimestamp': s.departureTimestamp,
    'latitude': s.latitude,
    'longitude': s.longitude,
    'altitudeM': s.altitudeM,
    'speedKmh': s.speedKmh,
    'totalDistanceM': s.totalDistanceM,
    'gpsAgeS': s.gpsAgeS,
  };

  StationEvent _stationFromJson(Map<String, dynamic> m) {
    final timestamp = m['timestamp'] as String;
    final departure = m['departureTimestamp'] as String?;
    // Reject unparsable times here so the UI and CSV never meet them.
    DateTime.parse(timestamp);
    if (departure != null) DateTime.parse(departure);
    return StationEvent(
      id: m['id'] as int,
      type: StationEventType.fromCode(m['type'] as String),
      timestamp: timestamp,
      departureTimestamp: departure,
      latitude: _number(m, 'latitude'),
      longitude: _number(m, 'longitude'),
      altitudeM: _number(m, 'altitudeM'),
      speedKmh: _number(m, 'speedKmh'),
      totalDistanceM: _number(m, 'totalDistanceM'),
      // Absent in files written before this field existed.
      gpsAgeS: _optionalNumber(m, 'gpsAgeS'),
    );
  }
}
