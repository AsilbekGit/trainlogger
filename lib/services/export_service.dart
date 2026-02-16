import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';
import '../models/log_record.dart';

/// Generates a CSV file from [LogRecord]s and shares it via the iOS share
/// sheet (AirDrop, Files, Mail, etc.).
class ExportService {
  /// Build CSV content string.
  static String buildCsv(List<LogRecord> records) {
    final buf = StringBuffer();
    buf.writeln(LogRecord.csvHeader);
    for (final r in records) {
      buf.writeln(r.toCsvRow());
    }
    return buf.toString();
  }

  /// Write CSV to a temp file and open the iOS share sheet.
  static Future<void> exportAndShare(List<LogRecord> records) async {
    if (records.isEmpty) return;

    final csv = buildCsv(records);
    final dir = await getApplicationDocumentsDirectory();
    final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final file = File('${dir.path}/train_log_$stamp.csv');
    await file.writeAsString(csv);

    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'text/csv')],
      subject: 'Train Logger Export $stamp',
    );
  }
}
