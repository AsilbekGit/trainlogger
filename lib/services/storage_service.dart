import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/log_record.dart';

/// Persists [LogRecord]s using a JSON file and atomic replacement.
///
/// Writes are serialized, flushed to a temporary file, then renamed over the
/// previous file. Malformed data is backed up before valid rows are recovered;
/// an unreadable file is never treated as an empty session and overwritten.
class StorageService {
  static const String _fileName = 'train_log_records.json';
  static const String _tmpFileName = 'train_log_records.tmp';

  final Directory? _directory;
  final List<LogRecord> _records = [];
  String? _filePath;
  String? _tmpFilePath;
  bool _initialized = false;

  /// Most recent initialization or write error, cleared after a successful save.
  Object? lastError;

  StorageService({Directory? directory}) : _directory = directory;

  /// Serializes mutations as well as disk writes. In particular, a queued clear
  /// must finish before a later append, so a new session cannot resurrect rows.
  Future<void> _writeChain = Future<void>.value();

  /// Initializes storage without preventing the app from launching on failure.
  /// Callers can display [lastError]; saves fail if existing data wasn't loaded.
  Future<void> init() async {
    if (_initialized) return;
    lastError = null;
    try {
      final dir = _directory ?? await getApplicationDocumentsDirectory();
      _filePath = '${dir.path}/$_fileName';
      _tmpFilePath = '${dir.path}/$_tmpFileName';
      await _loadFromDisk();
      _initialized = true;
    } catch (e) {
      lastError = e;
      _initialized = false;
      debugPrint('[StorageService] Initialization error: $e');
    }
  }

  /// All records in insertion order.
  List<LogRecord> getAll() => List.from(_records);

  /// Append a new record and persist.
  Future<void> add(LogRecord record) => addAll([record]);

  /// Append multiple records and persist once. If saving fails, retain them in
  /// memory so a subsequent successful save can retry the complete session.
  Future<void> addAll(List<LogRecord> records) {
    final pending = List<LogRecord>.of(records);
    return _enqueue(() async {
      _ensureInitialized();
      // Reject records JSON cannot represent before they poison future saves.
      json.encode(pending.map(_recordToJson).toList());
      _records.addAll(pending);
      await _saveToDisk(_records);
    });
  }

  /// Wipe all stored records only after the empty file is safely persisted.
  Future<void> clearAll() => _enqueue(() async {
    _ensureInitialized();
    await _saveToDisk(const []);
    _records.clear();
  });

  int get count => _records.length;

  // ── Private: disk I/O ─────────────────────────────────────────

  Future<void> _loadFromDisk() async {
    final file = File(_filePath!);

    // I/O failures are not malformed JSON. Leave the original untouched and
    // prevent writes until initialization succeeds, rather than losing a trip.
    final String jsonString;
    try {
      jsonString = await file.readAsString();
    } on FileSystemException catch (e) {
      if (e.osError?.errorCode == 2) return; // File does not exist (ENOENT).
      rethrow;
    }
    if (jsonString.trim().isEmpty) return;

    final recovered = <LogRecord>[];
    Object? corruption;
    try {
      final decoded = json.decode(jsonString);
      if (decoded is! List) {
        throw const FormatException('Expected a list of log records');
      }
      for (final row in decoded) {
        try {
          recovered.add(_recordFromJson(row as Map<String, dynamic>));
        } on FormatException catch (e) {
          corruption ??= e;
        } on TypeError catch (e) {
          corruption ??= e;
        }
      }
    } on FormatException catch (e) {
      corruption = e;
    }

    if (corruption != null) {
      // Preserve the complete original (including bad rows) before any later
      // save replaces it. A failed backup leaves initialization unsuccessful.
      final backupPath =
          '${file.path}.corrupt-${DateTime.now().microsecondsSinceEpoch}';
      await file.copy(backupPath);
      lastError = corruption;
      debugPrint(
        '[StorageService] Recovered ${recovered.length} records; '
        'original saved to $backupPath',
      );
    }
    _records
      ..clear()
      ..addAll(recovered);
  }

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

  Future<void> _saveToDisk(List<LogRecord> records) async {
    final jsonString = json.encode(records.map(_recordToJson).toList());
    final tmpFile = File(_tmpFilePath!);
    await tmpFile.writeAsString(jsonString, flush: true);
    await tmpFile.rename(_filePath!);
  }

  // ── JSON serialization ────────────────────────────────────────

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
}
