import 'package:latlong2/latlong.dart';

/// Lightweight GPS point used for the polyline / raw stream.
class GpsPoint {
  final double lat;
  final double lon;
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

  /// Running cumulative distance (metres).
  double totalDistanceMeters = 0.0;

  /// Next 100 m threshold that triggers a log record.
  double nextLogThresholdMeters = 100.0;

  /// Index counter for log records (1-based).
  int recordIndex = 0;

  /// Previous accepted GPS point (for distance accumulation).
  GpsPoint? previousPoint;

  /// Location of the *last logged* 100 m record (for segment distance,
  /// grade computation, and curvature).
  /// This is P(n) in the Menger curvature triangle.
  GpsPoint? lastLoggedPoint;

  /// Location of the *second-to-last logged* 100 m record.
  /// This is P(n-1) in the Menger curvature triangle P(n-1) → P(n) → P(n+1).
  /// Needed to compute curvature when P(n+1) arrives.
  GpsPoint? secondLastLoggedPoint;

  /// Rolling window of recent altitude samples for median smoothing.
  final List<double> altitudeWindow = [];

  /// Points accepted for the map polyline (decimated).
  final List<LatLng> polylinePoints = [];

  /// Current live speed in km/h for the dashboard.
  double currentSpeedKmh = 0.0;

  /// Current live altitude (smoothed).
  double currentAltitude = 0.0;

  void reset() {
    isTracking = false;
    totalDistanceMeters = 0.0;
    nextLogThresholdMeters = 100.0;
    recordIndex = 0;
    previousPoint = null;
    lastLoggedPoint = null;
    secondLastLoggedPoint = null;
    altitudeWindow.clear();
    polylinePoints.clear();
    currentSpeedKmh = 0.0;
    currentAltitude = 0.0;
  }
}