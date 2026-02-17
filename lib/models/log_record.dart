/// A single logged record created every time cumulative distance
/// crosses a 100 m threshold (100 m, 200 m, 300 m, …).
class LogRecord {
  final int index;
  final String timestamp; // ISO 8601
  final double latitude;
  final double longitude;
  final double speedKmh;
  final double altitudeM;

  /// Geodesic distance between this record's position and the previous
  /// record's position.  Should be ≈ 100 m under normal conditions.
  final double segmentDistanceM;

  /// Altitude change since the last logged record (may be null when
  /// altitude data is unreliable).
  final double? elevationDeltaM;

  /// Grade (%) = (elevationDeltaM / segmentDistanceM) × 100.
  /// Null when elevation data is unavailable.
  final double? gradePercent;

  /// Running cumulative distance at this log point.
  final double totalDistanceM;

  /// Menger curvature expressed as a percentage (curvature × 100).
  ///
  /// Computed from three consecutive logged points P1, P2, P3 using:
  ///   area   = |cross product| / 2
  ///   κ      = (4 × area) / (d12 × d23 × d13)   — this equals 1/R
  ///   result = κ × 100
  ///
  /// Where R is the radius of the circumscribed circle through the 3 points.
  ///   • 0 %   = perfectly straight (R = ∞)
  ///   • 0.1 % = gentle curve (R ≈ 1000 m)
  ///   • 0.5 % = moderate curve (R ≈ 200 m)
  ///   • 1.0 % = sharp curve (R ≈ 100 m)
  ///
  /// Null for the first two records (fewer than 3 points available).
  final double? curvaturePercent;

  /// Radius of the circumscribed circle in metres (1/κ).
  /// Null when curvature is null or zero (straight line → R = ∞).
  final double? curveRadiusM;

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
    this.curvaturePercent,
    this.curveRadiusM,
  });

  /// CSV header row.
  static String get csvHeader =>
      'index,timestamp,latitude,longitude,speed_kmh,altitude_m,'
      'segment_distance_m,elevation_delta_m,grade_percent,'
      'curvature_percent,curve_radius_m,total_distance_m';

  /// Convert this record to a CSV row.
  String toCsvRow() {
    return '$index,$timestamp,$latitude,$longitude,'
        '${speedKmh.toStringAsFixed(2)},${altitudeM.toStringAsFixed(2)},'
        '${segmentDistanceM.toStringAsFixed(2)},'
        '${elevationDeltaM?.toStringAsFixed(2) ?? ""},'
        '${gradePercent?.toStringAsFixed(3) ?? ""},'
        '${curvaturePercent?.toStringAsFixed(4) ?? ""},'
        '${curveRadiusM?.toStringAsFixed(1) ?? ""},'
        '${totalDistanceM.toStringAsFixed(2)}';
  }
}