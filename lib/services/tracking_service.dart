import 'dart:math';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' as ll;
import '../models/log_record.dart';
import '../models/tracking_session.dart';

/// Core logic: accumulates distance from GPS positions, fires a [LogRecord]
/// every time cumulative distance crosses a [kLogIntervalM] threshold (50 m),
/// computes grade and Menger curvature.
///
/// ── Menger Curvature Algorithm ──────────────────────────────────────
///
/// Given 3 consecutive logged nodes P1, P2, P3:
///
///   Step 1: Convert lat/lon to local XY metres (equirectangular projection).
///   Step 2: Triangle area via cross product:
///             cross = (x2−x1)(y3−y1) − (y2−y1)(x3−x1)
///             area  = |cross| / 2
///   Step 3: Distances  d12, d23, d13.
///   Step 4: Menger curvature κ = (4 × area) / (d12 × d23 × d13)
///             κ = 1/R  where R is the circumscribed circle radius.
///   Step 5: curvature_percent = κ × 100
///
///   • 0.0 % = straight (R = ∞)
///   • 0.1 % = gentle curve (R ≈ 1000 m)
///   • 0.2 % = moderate curve (R ≈ 500 m)
///   • 0.5 % = sharp curve (R ≈ 200 m)
///   • 1.0 % = very sharp curve (R ≈ 100 m)
///
/// ── Noise filtering strategy ────────────────────────────────────────
///
/// 1. Reject invalid/stale fixes and accuracy worse than [kMaxAccuracyM].
/// 2. Ignore distance below [kMinSpeedMs] or with unavailable speed (-1 on iOS).
/// 3. Reject point-to-point jumps smaller than [kMinMovementM].
/// 4. Reject point-to-point jumps larger than [kMaxJumpM].
/// 5. Cap instantaneous speed at [kMaxSpeedMs].
class TrackingService {
  final TrackingSession session;
  TrackingService(this.session);

  GpsPoint? _currentPoint;

  /// Latest valid fix for the map, including stationary and sub-5 m updates.
  /// Rejected fixes never replace it.
  GpsPoint? get currentPoint => _currentPoint;

  /// Start a new continuous stretch without losing recorded distance.
  /// Call when GPS tracking stops so a restart does not count unobserved travel
  /// or calculate grade/curvature across the gap.
  void resetPositionHistory() {
    session.previousPoint = null;
    session.lastLoggedPoint = null;
    session.secondLastLoggedPoint = null;
    session.altitudeWindow.clear();
    session.currentSpeedKmh = 0.0;
    _currentPoint = null;
  }

  // ── Configuration ─────────────────────────────────────────────────

  static const double kLogIntervalM = kLogIntervalMeters;
  static const double kMaxAccuracyM = 20.0;
  static const double kMinMovementM = 5.0;
  static const double kMinSpeedMs = 1.0;
  static const int kAltWindowSize = 5;
  static const double kPolylineDecimationM = 10.0;
  static const double kMaxSpeedMs = 83.0;
  static const double kMaxJumpM = 500.0;

  // ── Public entry point ────────────────────────────────────────────

  List<LogRecord> processPosition(Position pos) {
    // Validate before changing counters, smoothing, or constructing a LatLng.
    if (!pos.latitude.isFinite ||
        pos.latitude.abs() > 90.0 ||
        !pos.longitude.isFinite ||
        pos.longitude.abs() > 180.0 ||
        !pos.altitude.isFinite ||
        !pos.accuracy.isFinite ||
        pos.accuracy < 0.0 ||
        pos.accuracy > kMaxAccuracyM ||
        !pos.speed.isFinite) {
      return [];
    }
    final latest = _currentPoint ?? session.previousPoint;
    if (latest != null && !pos.timestamp.isAfter(latest.time)) {
      return [];
    }

    // Preserve the existing noise policy: unavailable speed (-1 on iOS) and
    // speeds below 1 m/s update the dashboard but do not accumulate distance.
    final speedMs = pos.speed.clamp(0.0, kMaxSpeedMs).toDouble();
    final previous = session.previousPoint;
    final dist = previous == null
        ? 0.0
        : _geodesicDistance(
            previous.lat,
            previous.lon,
            pos.latitude,
            pos.longitude,
          );

    if (previous != null && dist > kMaxJumpM) {
      // A rejected jump must not become the origin for the next measurement.
      // Reacquire a baseline on the next fix and discard cross-gap geometry.
      resetPositionHistory();
      return [];
    }

    _pushAltitude(pos.altitude);
    final altitude = _smoothedAltitude();
    final point = GpsPoint(
      lat: pos.latitude,
      lon: pos.longitude,
      altitude: altitude,
      speedMs: speedMs,
      accuracy: pos.accuracy,
      time: pos.timestamp,
    );
    _currentPoint = point;
    session.currentAltitude = altitude;
    session.currentSpeedKmh = speedMs < kMinSpeedMs ? 0.0 : speedMs * 3.6;

    if (speedMs < kMinSpeedMs) return [];

    final records = <LogRecord>[];
    if (previous != null) {
      if (dist < kMinMovementM) return [];

      final distanceBeforeFix = session.totalDistanceMeters;
      session.totalDistanceMeters += dist;

      while (session.totalDistanceMeters >= session.nextLogThresholdMeters) {
        // A single GPS fix can cross several 50 m marks. Estimate each mark
        // along the accepted segment instead of duplicating its endpoint.
        final fraction =
            (session.nextLogThresholdMeters - distanceBeforeFix) / dist;
        final loggedPoint = _interpolate(previous, point, fraction);
        session.recordIndex++;
        records.add(_buildRecord(loggedPoint));
        session.secondLastLoggedPoint = session.lastLoggedPoint;
        session.lastLoggedPoint = loggedPoint;
        session.nextLogThresholdMeters += kLogIntervalM;
      }

      _maybeAppendPolyline(point);
    } else {
      session.lastLoggedPoint = point;
      if (session.polylinePoints.isNotEmpty) {
        session.polylineBreakIndices.add(session.polylinePoints.length);
      }
      session.polylinePoints.add(point.latLng);
    }

    session.previousPoint = point;
    return records;
  }

  // ── Private helpers ───────────────────────────────────────────────

  GpsPoint _interpolate(GpsPoint start, GpsPoint end, double fraction) {
    final t = fraction.clamp(0.0, 1.0).toDouble();
    double lerp(double a, double b) => a + (b - a) * t;
    final longitude = _wrappedLongitude(
      start.lon + _wrappedLongitude(end.lon - start.lon) * t,
    );
    final elapsedUs = end.time.difference(start.time).inMicroseconds;
    return GpsPoint(
      lat: lerp(start.lat, end.lat),
      lon: longitude,
      altitude: lerp(start.altitude, end.altitude),
      speedMs: lerp(start.speedMs, end.speedMs),
      accuracy: lerp(start.accuracy, end.accuracy),
      time: start.time.add(Duration(microseconds: (elapsedUs * t).round())),
    );
  }

  LogRecord _buildRecord(GpsPoint current) {
    double? elevDelta;
    double? grade;
    double segmentDist = kLogIntervalM;

    if (session.lastLoggedPoint != null) {
      segmentDist = _geodesicDistance(
        session.lastLoggedPoint!.lat,
        session.lastLoggedPoint!.lon,
        current.lat,
        current.lon,
      );

      final prevAlt = session.lastLoggedPoint!.altitude;
      if (segmentDist > 1.0) {
        elevDelta = current.altitude - prevAlt;
        grade = (elevDelta / segmentDist) * 100.0;
      }
    }

    // ── Menger curvature ─────────────────────────────────────────
    //
    // We need three points:
    //   P1 = secondLastLoggedPoint
    //   P2 = lastLoggedPoint
    //   P3 = current
    //
    // The curvature is computed at P2 (the middle node).
    // Stored in the current record (P3's record) so it describes
    // "how curved was the path at the previous node."
    double? curvaturePct;
    double? radiusM;

    if (session.secondLastLoggedPoint != null &&
        session.lastLoggedPoint != null) {
      final result = computeMengerCurvature(
        session.secondLastLoggedPoint!.lat,
        session.secondLastLoggedPoint!.lon,
        session.lastLoggedPoint!.lat,
        session.lastLoggedPoint!.lon,
        current.lat,
        current.lon,
      );
      curvaturePct = result.curvaturePercent;
      radiusM = result.radiusM;
    }

    return LogRecord(
      index: session.recordIndex,
      timestamp: current.time.toUtc().toIso8601String(),
      latitude: current.lat,
      longitude: current.lon,
      speedKmh: current.speedMs * 3.6,
      altitudeM: current.altitude,
      segmentDistanceM: segmentDist,
      elevationDeltaM: elevDelta,
      gradePercent: grade,
      totalDistanceM: session.nextLogThresholdMeters,
      curvaturePercent: curvaturePct,
      curveRadiusM: radiusM,
    );
  }

  // ── Geodesic distance ─────────────────────────────────────────

  static double geodesicDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    // Keep sub-metre precision; rounding every GPS segment biases the total.
    const distance = ll.Distance(roundResult: false);
    return distance.as(
      ll.LengthUnit.Meter,
      ll.LatLng(lat1, lon1),
      ll.LatLng(lat2, lon2),
    );
  }

  double _geodesicDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) => geodesicDistance(lat1, lon1, lat2, lon2);

  // ── Altitude smoothing ────────────────────────────────────────

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

  void _maybeAppendPolyline(GpsPoint point) {
    if (session.polylinePoints.isEmpty) {
      session.polylinePoints.add(point.latLng);
      return;
    }
    final last = session.polylinePoints.last;
    final dist = _geodesicDistance(
      last.latitude,
      last.longitude,
      point.lat,
      point.lon,
    );
    if (dist >= kPolylineDecimationM) {
      session.polylinePoints.add(point.latLng);
    }
  }
}

// =====================================================================
// Pure helpers exposed for unit testing
// =====================================================================

/// Grade formula: (Δh / d) × 100.
double computeGradePercent(double elevationDeltaM, double segmentDistanceM) {
  if (segmentDistanceM <= 0) return 0;
  return (elevationDeltaM / segmentDistanceM) * 100.0;
}

/// Check whether a cumulative distance has crossed the next threshold.
bool hasCrossedThreshold(double totalDistance, double nextThreshold) {
  return totalDistance >= nextThreshold;
}

// =====================================================================
// Menger Curvature
// =====================================================================

/// Result of the Menger curvature computation.
class CurvatureResult {
  /// Menger curvature κ = 1/R  (unit: 1/metre).
  final double curvature;

  /// κ × 100 — the percentage form for CSV / display.
  final double curvaturePercent;

  /// Radius of circumscribed circle in metres.  Null when κ ≈ 0 (straight).
  final double? radiusM;

  /// Triangle area formed by the three points (m²).
  final double area;

  const CurvatureResult({
    required this.curvature,
    required this.curvaturePercent,
    this.radiusM,
    required this.area,
  });
}

/// Compute Menger curvature from three consecutive GPS nodes.
///
/// **Algorithm (as specified):**
///
/// 1. Convert lat/lon → local XY metres using equirectangular projection
///    centred on P1.  This is accurate enough for distances < 1 km.
///
/// 2. Triangle area via cross product:
///      cross = (x2−x1)·(y3−y1) − (y2−y1)·(x3−x1)
///      area  = |cross| / 2
///
/// 3. Three side distances:
///      d12 = distance(P1, P2)
///      d23 = distance(P2, P3)
///      d13 = distance(P1, P3)
///
/// 4. Menger curvature:
///      κ = (4 × area) / (d12 × d23 × d13)
///      κ = 1/R  where R is the radius of the circumscribed circle.
///
/// 5. curvature_percent = κ × 100
///
/// Returns [CurvatureResult] with curvature, percent, radius, and area.
CurvatureResult computeMengerCurvature(
  double lat1,
  double lon1,
  double lat2,
  double lon2,
  double lat3,
  double lon3,
) {
  // ── Step 1: Convert to local XY metres ─────────────────────────
  // Equirectangular projection centred on P1.
  // x = Δlon × cos(midLat) × 111320
  // y = Δlat × 110540
  const double mPerDegLat = 110540.0; // metres per degree latitude
  final double midLat = (lat1 + lat2 + lat3) / 3.0;
  final double mPerDegLon = 111320.0 * cos(midLat * pi / 180.0);

  const double x1 = 0.0;
  const double y1 = 0.0;
  final double x2 = _wrappedLongitude(lon2 - lon1) * mPerDegLon;
  final double y2 = (lat2 - lat1) * mPerDegLat;
  final double x3 = _wrappedLongitude(lon3 - lon1) * mPerDegLon;
  final double y3 = (lat3 - lat1) * mPerDegLat;

  // ── Step 2: Triangle area via cross product ────────────────────
  final double cross = (x2 - x1) * (y3 - y1) - (y2 - y1) * (x3 - x1);
  final double area = cross.abs() / 2.0;

  // ── Step 3: Side distances ─────────────────────────────────────
  final double d12 = _dist(x1, y1, x2, y2);
  final double d23 = _dist(x2, y2, x3, y3);
  final double d13 = _dist(x1, y1, x3, y3);

  // ── Step 4: Menger curvature κ = (4 × area) / (d12 × d23 × d13) ─
  final double denominator = d12 * d23 * d13;

  // Guard: if any side is ~0 (duplicate points), curvature is undefined.
  if (denominator < 1e-9) {
    return const CurvatureResult(
      curvature: 0.0,
      curvaturePercent: 0.0,
      radiusM: null,
      area: 0.0,
    );
  }

  final double kappa = (4.0 * area) / denominator;

  // ── Step 5: Convert to percentage ──────────────────────────────
  final double kappaPct = kappa * 100.0;

  // Radius = 1/κ  (only meaningful when κ > 0).
  final double? radius = (kappa > 1e-9) ? (1.0 / kappa) : null;

  return CurvatureResult(
    curvature: kappa,
    curvaturePercent: kappaPct,
    radiusM: radius,
    area: area,
  );
}

/// Euclidean distance in local XY plane.
double _dist(double x1, double y1, double x2, double y2) {
  final dx = x2 - x1;
  final dy = y2 - y1;
  return sqrt(dx * dx + dy * dy);
}

/// Shortest signed longitude displacement, also normalises interpolated fixes.
/// Nearby points on opposite sides of the date line remain nearby in XY.
double _wrappedLongitude(double degrees) => (degrees + 180.0) % 360.0 - 180.0;
