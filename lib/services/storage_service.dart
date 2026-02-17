import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/log_record.dart';

/// Persists [LogRecord]s using Hive so data survives app restarts.
///
/// **Crash-safe initialisation:**
/// If the Hive box file is corrupted (e.g. the app was killed mid-write,
/// or iOS reclaimed disk space), [init] catches the error, deletes the
/// broken box, and reopens a fresh one.  This prevents the app from
/// failing to launch entirely.
class StorageService {
  static const String _boxName = 'log_records';
  late Box<LogRecord> _box;

  Future<void> init() async {
    await Hive.initFlutter();

    // Only register adapter once (guards against hot-restart duplicates).
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(LogRecordAdapter());
    }

    try {
      _box = await Hive.openBox<LogRecord>(_boxName);
    } catch (e) {
      // Box is corrupted → delete it and open a fresh one.
      debugPrint('[StorageService] Hive box corrupted, resetting: $e');
      await Hive.deleteBoxFromDisk(_boxName);
      _box = await Hive.openBox<LogRecord>(_boxName);
    }
  }

  /// All records in insertion order.
  List<LogRecord> getAll() {
    try {
      return _box.values.toList();
    } catch (e) {
      debugPrint('[StorageService] Error reading records: $e');
      return [];
    }
  }

  /// Append a new record.
  Future<void> add(LogRecord record) async {
    try {
      await _box.add(record);
    } catch (e) {
      debugPrint('[StorageService] Error adding record: $e');
    }
  }

  /// Append multiple records at once.
  Future<void> addAll(List<LogRecord> records) async {
    for (final r in records) {
      await add(r);
    }
  }

  /// Wipe all stored records (new session / clear data).
  Future<void> clearAll() async {
    await _box.clear();
  }

  /// Compact the box file to reclaim disk space.
  Future<void> compact() async {
    await _box.compact();
  }

  int get count => _box.length;
}