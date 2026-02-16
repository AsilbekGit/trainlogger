import 'dart:math';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' as ll;
import '../models/log_record.dart';
import '../models/tracking_session.dart';

/// Core logic: accumulates distance from GPS positions, fires a [LogRecord]
/// every time cumulative distance crosses a 100 m threshold, computes grade
/// from altitude deltas.
///
/// **Noise filtering strategy (critical for stationary / indoor use):**
/// 1. Reject points with horizontal accuracy worse than [kMaxAccuracyM].
/// 2. Reject points where GPS-reported speed ≤ 0 or unavailable (-1 on iOS).
/// 3. Reject point-to-point jumps smaller than [kMinMovementM] — GPS drift
///    when sitting still typically produces 1–5 m jumps every second.
/// 4. Reject point-to-point jumps larger than [kMaxJumpM] — teleport glitch.
/// 5. Cap instantaneous speed at [kMaxSpeedMs].
class TrackingService {
  final TrackingSession session;
  TrackingService(this.session);

  // ── Configuration ─────────────────────────────────────────────────

  /// Threshold interval in metres.
  static const double kLogIntervalM = 100.0;

  /// Maximum acceptable horizontal accuracy (metres).
  /// Points worse than this are always dropped.
  static const double kMaxAccuracyM = 20.0;

  /// **Minimum real movement (metres) between two consecutive accepted
  /// GPS fixes.**  This is the primary defence against stationary drift.
  /// GPS drift indoors typically produces 1–5 m fake jumps; setting this
  /// to 5 m filters almost all of them while still capturing slow train
  /// movement (a train doing 10 km/h moves ~2.8 m/s, so at 1 Hz updates
  /// that's ≈ 3 m per fix — safe above 5 m at ≥ 7 km/h).
  static const double kMinMovementM = 5.0;

  /// Minimum GPS-reported speed (m/s) to consider the device moving.
  /// iOS returns -1.0 when speed is unavailable (e.g. first fix, indoors).
  /// We require at least ~3.6 km/h of reported speed.
  static const double kMinSpeedMs = 1.0;

  /// Rolling altitude window size for median smoothing.
  static const int kAltWindowSize = 5;

  /// Minimum distance (m) between consecutive polyline points to avoid
  /// over-dense paths on the map.
  static const double kPolylineDecimationM = 10.0;

  /// Max sane speed between two consecutive GPS fixes (m/s ≈ 300 km/h).
  static const double kMaxSpeedMs = 83.0;

  /// Max sane single-jump distance (metres).  Anything larger is a
  /// GPS teleport and is discarded.
  static const double kMaxJumpM = 500.0;

  // ── Public entry point ────────────────────────────────────────────

  /// Feed a raw GPS [Position] from Geolocator.
  /// Returns a list of [LogRecord]s generated (0 or 1 normally, but could
  /// be >1 if a single jump crosses multiple thresholds).
  List<LogRecord> processPosition(Position pos) {
    // ────────────────────────────────────────────────────────────────
    // FILTER 1: Reject poor horizontal accuracy.
    // ────────────────────────────────────────────────────────────────
    if (pos.accuracy > kMaxAccuracyM) {
      return [];
    }

    // ────────────────────────────────────────────────────────────────
    // FILTER 2: Handle iOS speed = -1 (unavailable).
    // Only accept positive speed above threshold.
    // ────────────────────────────────────────────────────────────────
    final rawSpeed = pos.speed; // may be -1.0 on iOS
    final speedMs = (rawSpeed > 0) ? rawSpeed.clamp(0.0, kMaxSpeedMs) : 0.0;

    // If GPS says we're not moving (or can't tell), don't accumulate
    // distance.  We still update the live speed display to 0.
    if (speedMs < kMinSpeedMs) {
      session.currentSpeedKmh = 0.0;
      // Still push altitude so the window fills up for when we do move.
      _pushAltitude(pos.altitude);
      session.currentAltitude = _smoothedAltitude();
      return [];
    }

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

    // Push altitude into rolling window & compute smoothed value.
    _pushAltitude(pos.altitude);
    session.currentAltitude = _smoothedAltitude();

    // ────────────────────────────────────────────────────────────────
    // FILTER 3 & 4: Minimum movement gate + teleport rejection.
    // ────────────────────────────────────────────────────────────────
    final records = <LogRecord>[];

    if (session.previousPoint != null) {
      final dist = _geodesicDistance(
        session.previousPoint!.lat,
        session.previousPoint!.lon,
        point.lat,
        point.lon,
      );

      // FILTER 4: Reject teleport glitches.
      if (dist > kMaxJumpM) {
        session.previousPoint = point;
        return [];
      }

      // FILTER 3: Reject tiny drift movements.
      // This is the key fix for "distance increasing while sitting still".
      if (dist < kMinMovementM) {
        return [];
      }

      // ── Accumulate distance ────────────────────────────────────
      session.totalDistanceMeters += dist;

      // ── Check 100 m threshold(s) ───────────────────────────────
      // A fast GPS jump might cross more than one 100 m mark at once,
      // so we use a while-loop.
      while (session.totalDistanceMeters >= session.nextLogThresholdMeters) {
        session.recordIndex++;

        final record = _buildRecord(point);
        records.add(record);

        session.lastLoggedPoint = point;
        session.nextLogThresholdMeters += kLogIntervalM;
      }

      // ── Polyline decimation ────────────────────────────────────
      _maybeAppendPolyline(point);
    } else {
      // First accepted point: set as origin and add to polyline.
      session.lastLoggedPoint = point;
      session.polylinePoints.add(point.latLng);
    }

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
      //
      // We use the smoothed altitude for the current point and the
      // raw altitude stored in lastLoggedPoint (which was also smoothed
      // at the time it was recorded).
      final prevAlt = session.lastLoggedPoint!.altitude;
      if (segmentDist > 1.0) {
        // Only compute grade when we have meaningful distance.
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

  /// Geodesic (Vincenty) distance between two lat/lon pairs in metres.
  static double geodesicDistance(
      double lat1, double lon1, double lat2, double lon2) {
    const distance = ll.Distance();
    return distance.as(
      ll.LengthUnit.Meter,
      ll.LatLng(lat1, lon1),
      ll.LatLng(lat2, lon2),
    );
  }

  double _geodesicDistance(
          double lat1, double lon1, double lat2, double lon2) =>
      geodesicDistance(lat1, lon1, lat2, lon2);

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