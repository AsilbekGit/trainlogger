import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' as ll;
import '../models/log_record.dart';
import '../models/tracking_session.dart';

/// Core logic: accumulates distance from GPS positions, fires a [LogRecord]
/// every time cumulative distance crosses a 100 m threshold, computes grade
/// from altitude deltas.
class TrackingService {
  final TrackingSession session;
  TrackingService(this.session);

  // ── Configuration ─────────────────────────────────────────────────

  /// Threshold interval in metres.
  static const double kLogIntervalM = 100.0;

  /// Maximum acceptable horizontal accuracy (metres).  Points worse than
  /// this are silently dropped.
  static const double kMaxAccuracyM = 25.0;

  /// Minimum speed (m/s) below which poor-accuracy points are dropped to
  /// avoid phantom distance accumulation when the train is stopped.
  static const double kMinSpeedForPoorAccuracy = 1.0;

  /// Rolling altitude window size for median smoothing.
  static const int kAltWindowSize = 5;

  /// Minimum distance (m) between consecutive polyline points to avoid
  /// over-dense paths on the map.
  static const double kPolylineDecimationM = 8.0;

  /// Max sane speed jump between two consecutive GPS fixes (m/s ≈ 300 km/h).
  static const double kMaxSpeedMs = 83.0;

  // ── Public entry point ────────────────────────────────────────────

  /// Feed a raw GPS [Position] from Geolocator.
  /// Returns a list of [LogRecord]s generated (0 or 1 normally, but could
  /// be >1 if a single jump crosses multiple thresholds).
  List<LogRecord> processPosition(Position pos) {
    // ── 1. Filter noisy / inaccurate points ──────────────────────
    if (pos.accuracy > kMaxAccuracyM) {
      if (pos.speed < kMinSpeedForPoorAccuracy) return [];
    }

    // Sanity: cap impossible speed
    final speedMs = pos.speed.clamp(0.0, kMaxSpeedMs);

    // Build our lightweight GPS point.
    final point = GpsPoint(
      lat: pos.latitude,
      lon: pos.longitude,
      altitude: pos.altitude,
      speedMs: speedMs,
      accuracy: pos.accuracy,
      time: pos.timestamp,
    );

    // Update live dashboard values.
    session.currentSpeedKmh = speedMs * 3.6;

    // ── 2. Push altitude into rolling window & compute smoothed ──
    _pushAltitude(pos.altitude);
    session.currentAltitude = _smoothedAltitude();

    // ── 3. Accumulate distance ───────────────────────────────────
    final records = <LogRecord>[];

    if (session.previousPoint != null) {
      final dist = _geodesicDistance(
        session.previousPoint!.lat,
        session.previousPoint!.lon,
        point.lat,
        point.lon,
      );

      // Sanity: ignore teleport jumps > 500 m in one tick
      if (dist > 500) {
        session.previousPoint = point;
        return [];
      }

      session.totalDistanceMeters += dist;

      // ── 4. Check 100 m threshold(s) ────────────────────────────
      // A fast GPS jump might cross more than one 100 m mark at once,
      // so we loop.
      while (session.totalDistanceMeters >= session.nextLogThresholdMeters) {
        session.recordIndex++;

        // Interpolate the exact 100 m crossing point between
        // previousPoint and current point for accuracy.
        final record = _buildRecord(point);
        records.add(record);

        session.lastLoggedPoint = point;
        session.nextLogThresholdMeters += kLogIntervalM;
      }
    } else {
      // First point: set as origin.
      session.lastLoggedPoint = point;
    }

    // ── 5. Polyline decimation ───────────────────────────────────
    _maybeAppendPolyline(point);

    session.previousPoint = point;
    return records;
  }

  // ── Private helpers ───────────────────────────────────────────────

  /// Create a [LogRecord] at the current 100 m crossing.
  LogRecord _buildRecord(GpsPoint current) {
    final smoothAlt = _smoothedAltitude();

    double? elevDelta;
    double? grade;
    double segmentDist = kLogIntervalM; // nominal

    if (session.lastLoggedPoint != null) {
      segmentDist = _geodesicDistance(
        session.lastLoggedPoint!.lat,
        session.lastLoggedPoint!.lon,
        current.lat,
        current.lon,
      );

      // Grade calculation:
      //   grade(%) = (Δelevation / horizontal distance) × 100
      final prevAlt = session.lastLoggedPoint!.altitude;
      if (prevAlt != 0.0 && smoothAlt != 0.0 && segmentDist > 0) {
        elevDelta = smoothAlt - prevAlt;
        grade = (elevDelta / segmentDist) * 100.0;
      }
    }

    return LogRecord(
      index: session.recordIndex,
      timestamp: current.time.toUtc().toIso8601String(),
      latitude: current.lat,
      longitude: current.lon,
      speedKmh: current.speedMs * 3.6,
      altitudeM: smoothAlt,
      segmentDistanceM: segmentDist,
      elevationDeltaM: elevDelta,
      gradePercent: grade,
      totalDistanceM: session.nextLogThresholdMeters - kLogIntervalM,
    );
  }

  /// Geodesic (Vincenty) distance between two lat/lon pairs.
  double _geodesicDistance(
      double lat1, double lon1, double lat2, double lon2) {
    const distance = ll.Distance();
    return distance.as(
      ll.LengthUnit.Meter,
      ll.LatLng(lat1, lon1),
      ll.LatLng(lat2, lon2),
    );
  }

  // ── Altitude smoothing (median of rolling window) ─────────────

  void _pushAltitude(double alt) {
    session.altitudeWindow.add(alt);
    if (session.altitudeWindow.length > kAltWindowSize) {
      session.altitudeWindow.removeAt(0);
    }
  }

  double _smoothedAltitude() {
    if (session.altitudeWindow.isEmpty) return 0.0;
    final sorted = List<double>.from(session.altitudeWindow)..sort();
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid];
    return (sorted[mid - 1] + sorted[mid]) / 2.0;
  }

  // ── Polyline decimation ───────────────────────────────────────

  /// Only append to polyline if the new point is far enough from the last
  /// polyline vertex.  Keeps the map layer performant.
  void _maybeAppendPolyline(GpsPoint point) {
    if (session.polylinePoints.isEmpty) {
      session.polylinePoints.add(point.latLng);
      return;
    }
    final last = session.polylinePoints.last;
    final dist = _geodesicDistance(
        last.latitude, last.longitude, point.lat, point.lon);
    if (dist >= kPolylineDecimationM) {
      session.polylinePoints.add(point.latLng);
    }
  }
}

// ── Pure helpers exposed for unit testing ──────────────────────────────

/// Grade formula: (Δh / d) × 100.
double computeGradePercent(double elevationDeltaM, double segmentDistanceM) {
  if (segmentDistanceM <= 0) return 0;
  return (elevationDeltaM / segmentDistanceM) * 100.0;
}

/// Check whether a cumulative distance has crossed the next threshold.
bool hasCrossedThreshold(double totalDistance, double nextThreshold) {
  return totalDistance >= nextThreshold;
}
