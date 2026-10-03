import 'package:latlong2/latlong.dart';

/// Distance interval (in metres) between logged records.
///
/// A [LogRecord] is emitted every time cumulative travelled distance crosses
/// the next multiple of this value (50 m, 100 m, 150 m, …).  This is the single
/// source of truth — `TrackingService.kLogIntervalM` references it so the
/// interval is defined in exactly one place.
const double kLogIntervalMeters = 50.0;

/// Lightweight GPS point used for the polyline / raw stream.
class GpsPoint {
  final double lat;
  final double lon;

  /// Median-smoothed altitude for an accepted fix or interpolated log point.
  final double altitude;
  final double speedMs;
  final double accuracy;
  final DateTime time;

  const GpsPoint({
    required this.lat,
    required this.lon,
    required this.altitude,
    required this.speedMs,
    required this.accuracy,
    required this.time,
  });

  LatLng get latLng => LatLng(lat, lon);
}

/// Holds the mutable tracking-session state.
class TrackingSession {
  bool isTracking = false;

  /// When the current tracking session was started.
  DateTime? startTime;

  /// Running cumulative distance (metres).
  double totalDistanceMeters = 0.0;

  /// Next distance threshold (metres) that triggers a log record.
  double nextLogThresholdMeters = kLogIntervalMeters;

  /// Index counter for log records (1-based).
  int recordIndex = 0;

  /// Previous accepted GPS point (for distance accumulation).
  GpsPoint? previousPoint;

  /// Location of the *last logged* record (for segment distance,
  /// grade computation, and curvature).
  /// This is P(n) in the Menger curvature triangle.
  GpsPoint? lastLoggedPoint;

  /// Location of the *second-to-last logged* record.
  /// This is P(n-1) in the Menger curvature triangle P(n-1) → P(n) → P(n+1).
  /// Needed to compute curvature when P(n+1) arrives.
  GpsPoint? secondLastLoggedPoint;

  /// Rolling window of recent altitude samples for median smoothing.
  final List<double> altitudeWindow = [];

  /// Points accepted for the map polyline (decimated).
  final List<LatLng> polylinePoints = [];

  /// Indices where a new continuous route starts after tracking was paused or
  /// GPS jumped. The map must not connect these points to the preceding route.
  final List<int> polylineBreakIndices = [];

  /// Current live speed in km/h for the dashboard.
  double currentSpeedKmh = 0.0;

  /// Current live altitude (smoothed).
  double currentAltitude = 0.0;

  void reset() {
    isTracking = false;
    startTime = null;
    totalDistanceMeters = 0.0;
    nextLogThresholdMeters = kLogIntervalMeters;
    recordIndex = 0;
    previousPoint = null;
    lastLoggedPoint = null;
    secondLastLoggedPoint = null;
    altitudeWindow.clear();
    polylinePoints.clear();
    polylineBreakIndices.clear();
    currentSpeedKmh = 0.0;
    currentAltitude = 0.0;
  }
}
