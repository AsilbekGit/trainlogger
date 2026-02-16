import 'package:hive_flutter/hive_flutter.dart';
import '../models/log_record.dart';

/// Persists [LogRecord]s using Hive so data survives app restarts.
class StorageService {
  static const String _boxName = 'log_records';
  late Box<LogRecord> _box;

  Future<void> init() async {
    await Hive.initFlutter();
    Hive.registerAdapter(LogRecordAdapter());
    _box = await Hive.openBox<LogRecord>(_boxName);
  }

  /// All records in insertion order.
  List<LogRecord> getAll() => _box.values.toList();

  /// Append a new record.
  Future<void> add(LogRecord record) async {
    await _box.add(record);
  }

  /// Append multiple records at once.
  Future<void> addAll(List<LogRecord> records) async {
    for (final r in records) {
      await _box.add(r);
    }
  }

  /// Wipe all stored records (new session / clear data).
  Future<void> clearAll() async {
    await _box.clear();
  }

  int get count => _box.length;
}
