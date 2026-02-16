import 'package:hive/hive.dart';

part 'log_record.g.dart';

/// A single logged record created every time cumulative distance
/// crosses a 100 m threshold (100 m, 200 m, 300 m, …).
@HiveType(typeId: 0)
class LogRecord extends HiveObject {
  @HiveField(0)
  final int index;

  @HiveField(1)
  final String timestamp; // ISO 8601

  @HiveField(2)
  final double latitude;

  @HiveField(3)
  final double longitude;

  @HiveField(4)
  final double speedKmh;

  @HiveField(5)
  final double altitudeM;

  /// Geodesic distance between this record's position and the previous
  /// record's position.  Should be ≈ 100 m under normal conditions.
  @HiveField(6)
  final double segmentDistanceM;

  /// Altitude change since the last logged record (may be null when
  /// altitude data is unreliable).
  @HiveField(7)
  final double? elevationDeltaM;

  /// Grade (%) = (elevationDeltaM / segmentDistanceM) × 100.
  /// Null when elevation data is unavailable.
  @HiveField(8)
  final double? gradePercent;

  /// Running cumulative distance at this log point.
  @HiveField(9)
  final double totalDistanceM;

  LogRecord({
    required this.index,
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    required this.speedKmh,
    required this.altitudeM,
    required this.segmentDistanceM,
    this.elevationDeltaM,
    this.gradePercent,
    required this.totalDistanceM,
  });

  /// CSV header row.
  static String get csvHeader =>
      'index,timestamp,latitude,longitude,speed_kmh,altitude_m,'
      'segment_distance_m,elevation_delta_m,grade_percent,total_distance_m';

  /// Convert this record to a CSV row.
  String toCsvRow() {
    return '$index,$timestamp,$latitude,$longitude,'
        '${speedKmh.toStringAsFixed(2)},${altitudeM.toStringAsFixed(2)},'
        '${segmentDistanceM.toStringAsFixed(2)},'
        '${elevationDeltaM?.toStringAsFixed(2) ?? ""},'
        '${gradePercent?.toStringAsFixed(3) ?? ""},'
        '${totalDistanceM.toStringAsFixed(2)}';
  }
}
