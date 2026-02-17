import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/log_record.dart';

/// Persists [LogRecord]s using a simple JSON file.
///
/// **Why not Hive?**
/// Hive uses a binary format that corrupts when iOS kills the app mid-write
/// (which iOS does aggressively for background apps).  A corrupted Hive box
/// prevents the app from launching at all.
///
/// **Why JSON file works:**
/// - Human-readable, easy to debug.
/// - We use atomic writes (write to .tmp, then rename) so even if the app
///   is killed mid-write, the original file is untouched.
/// - If the JSON is somehow malformed, we catch the parse error and start
///   fresh instead of crashing.
/// - Works identically on iOS and Android.
class StorageService {
  static const String _fileName = 'train_log_records.json';
  static const String _tmpFileName = 'train_log_records.tmp';

  List<LogRecord> _records = [];
  late String _filePath;
  late String _tmpFilePath;

  /// Initialise storage.  Always succeeds — never crashes the app.
  Future<void> init() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _filePath = '${dir.path}/$_fileName';
      _tmpFilePath = '${dir.path}/$_tmpFileName';
      await _loadFromDisk();
    } catch (e) {
      debugPrint('[StorageService] init error (starting empty): $e');
      _records = [];
    }
  }

  /// All records in insertion order.
  List<LogRecord> getAll() => List.from(_records);

  /// Append a new record and persist.
  Future<void> add(LogRecord record) async {
    _records.add(record);
    await _saveToDisk();
  }

  /// Append multiple records and persist once.
  Future<void> addAll(List<LogRecord> records) async {
    _records.addAll(records);
    await _saveToDisk();
  }

  /// Wipe all stored records.
  Future<void> clearAll() async {
    _records.clear();
    await _saveToDisk();
  }

  int get count => _records.length;

  // ── Private: disk I/O ─────────────────────────────────────────

  /// Load records from the JSON file on disk.
  Future<void> _loadFromDisk() async {
    final file = File(_filePath);
    if (!await file.exists()) {
      _records = [];
      return;
    }

    try {
      final jsonString = await file.readAsString();
      if (jsonString.trim().isEmpty) {
        _records = [];
        return;
      }

      final List<dynamic> jsonList = json.decode(jsonString);
      _records = jsonList.map((m) => _recordFromJson(m)).toList();
      debugPrint('[StorageService] Loaded ${_records.length} records');
    } catch (e) {
      // JSON is malformed → start fresh (don't crash).
      debugPrint('[StorageService] Corrupt file, resetting: $e');
      _records = [];
      // Delete the bad file so it doesn't happen again.
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  /// Persist records to disk using atomic write:
  ///   1. Write to .tmp file
  ///   2. Rename .tmp → .json
  /// If the app is killed between 1 and 2, the original .json is untouched.
  Future<void> _saveToDisk() async {
    try {
      final jsonList = _records.map((r) => _recordToJson(r)).toList();
      final jsonString = json.encode(jsonList);

      // Write to temp file first.
      final tmpFile = File(_tmpFilePath);
      await tmpFile.writeAsString(jsonString, flush: true);

      // Atomic rename: this is a single OS operation that can't half-fail.
      await tmpFile.rename(_filePath);
    } catch (e) {
      debugPrint('[StorageService] Save error: $e');
    }
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

  LogRecord _recordFromJson(Map<String, dynamic> m) => LogRecord(
        index: m['index'] as int,
        timestamp: m['timestamp'] as String,
        latitude: (m['latitude'] as num).toDouble(),
        longitude: (m['longitude'] as num).toDouble(),
        speedKmh: (m['speedKmh'] as num).toDouble(),
        altitudeM: (m['altitudeM'] as num).toDouble(),
        segmentDistanceM: (m['segmentDistanceM'] as num).toDouble(),
        elevationDeltaM: (m['elevationDeltaM'] as num?)?.toDouble(),
        gradePercent: (m['gradePercent'] as num?)?.toDouble(),
        totalDistanceM: (m['totalDistanceM'] as num).toDouble(),
        curvaturePercent: (m['curvaturePercent'] as num?)?.toDouble(),
        curveRadiusM: (m['curveRadiusM'] as num?)?.toDouble(),
      );
}