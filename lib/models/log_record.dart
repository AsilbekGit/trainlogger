/// A single logged record created every time cumulative distance
/// crosses a fixed distance threshold (every 50 m: 50 m, 100 m, 150 m, …).
class LogRecord {
  final int index;
  final String timestamp; // ISO 8601
  final double latitude;
  final double longitude;
  final double speedKmh;
  final double altitudeM;

  /// Geodesic distance between this record's position and the previous
  /// record's position.  Should be ≈ 50 m under normal conditions.
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
  /// Null until three points are available. The initial accepted GPS fix
  /// acts as the origin, so the second record can already have curvature.
  /// History is restarted after a pause or a rejected GPS jump.
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
}
