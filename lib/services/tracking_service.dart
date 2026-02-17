import 'dart:math';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' as ll;
import '../models/log_record.dart';
import '../models/tracking_session.dart';

/// Core logic: accumulates distance from GPS positions, fires a [LogRecord]
/// every time cumulative distance crosses a 100 m threshold, computes grade
/// and Menger curvature.
///
/// ── Menger Curvature Algorithm ──────────────────────────────────────
///
/// Given 3 consecutive 100 m nodes P1, P2, P3:
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
/// 1. Reject points with horizontal accuracy worse than [kMaxAccuracyM].
/// 2. Reject points where GPS-reported speed ≤ 0 or unavailable (-1 on iOS).
/// 3. Reject point-to-point jumps smaller than [kMinMovementM].
/// 4. Reject point-to-point jumps larger than [kMaxJumpM].
/// 5. Cap instantaneous speed at [kMaxSpeedMs].
class TrackingService {
  final TrackingSession session;
  TrackingService(this.session);

  // ── Configuration ─────────────────────────────────────────────────

  static const double kLogIntervalM = 100.0;
  static const double kMaxAccuracyM = 20.0;
  static const double kMinMovementM = 5.0;
  static const double kMinSpeedMs = 1.0;
  static const int kAltWindowSize = 5;
  static const double kPolylineDecimationM = 10.0;
  static const double kMaxSpeedMs = 83.0;
  static const double kMaxJumpM = 500.0;

  // ── Public entry point ────────────────────────────────────────────

  List<LogRecord> processPosition(Position pos) {
    // ── FILTER 1: Reject poor horizontal accuracy. ───────────────
    if (pos.accuracy > kMaxAccuracyM) {
      return [];
    }

    // ── FILTER 2: Handle iOS speed = -1 (unavailable). ──────────
    final rawSpeed = pos.speed;
    final speedMs = (rawSpeed > 0) ? rawSpeed.clamp(0.0, kMaxSpeedMs) : 0.0;

    if (speedMs < kMinSpeedMs) {
      session.currentSpeedKmh = 0.0;
      _pushAltitude(pos.altitude);
      session.currentAltitude = _smoothedAltitude();
      return [];
    }

    final point = GpsPoint(
      lat: pos.latitude,
      lon: pos.longitude,
      altitude: pos.altitude,
      speedMs: speedMs,
      accuracy: pos.accuracy,
      time: pos.timestamp,
    );

    session.currentSpeedKmh = speedMs * 3.6;
    _pushAltitude(pos.altitude);
    session.currentAltitude = _smoothedAltitude();

    // ── FILTER 3 & 4: Min movement + teleport rejection. ────────
    final records = <LogRecord>[];

    if (session.previousPoint != null) {
      final dist = _geodesicDistance(
        session.previousPoint!.lat,
        session.previousPoint!.lon,
        point.lat,
        point.lon,
      );

      if (dist > kMaxJumpM) {
        session.previousPoint = point;
        return [];
      }

      if (dist < kMinMovementM) {
        return [];
      }

      // ── Accumulate distance ────────────────────────────────────
      session.totalDistanceMeters += dist;

      // ── Check 100 m threshold(s) ───────────────────────────────
      while (session.totalDistanceMeters >= session.nextLogThresholdMeters) {
        session.recordIndex++;

        final record = _buildRecord(point);
        records.add(record);

        // Shift the logged-point history for curvature:
        //   secondLast ← last,  last ← current
        session.secondLastLoggedPoint = session.lastLoggedPoint;
        session.lastLoggedPoint = point;

        session.nextLogThresholdMeters += kLogIntervalM;
      }

      _maybeAppendPolyline(point);
    } else {
      session.lastLoggedPoint = point;
      session.polylinePoints.add(point.latLng);
    }

    session.previousPoint = point;
    return records;
  }

  // ── Private helpers ───────────────────────────────────────────────

  LogRecord _buildRecord(GpsPoint current) {
    final smoothAlt = _smoothedAltitude();

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
        elevDelta = smoothAlt - prevAlt;
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
      altitudeM: smoothAlt,
      segmentDistanceM: segmentDist,
      elevationDeltaM: elevDelta,
      gradePercent: grade,
      totalDistanceM: session.nextLogThresholdMeters - kLogIntervalM,
      curvaturePercent: curvaturePct,
      curveRadiusM: radiusM,
    );
  }

  // ── Geodesic distance ─────────────────────────────────────────

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
        last.latitude, last.longitude, point.lat, point.lon);
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
  double lat1, double lon1,
  double lat2, double lon2,
  double lat3, double lon3,
) {
  // ── Step 1: Convert to local XY metres ─────────────────────────
  // Equirectangular projection centred on P1.
  // x = Δlon × cos(midLat) × 111320
  // y = Δlat × 110540
  const double mPerDegLat = 110540.0; // metres per degree latitude
  final double midLat = (lat1 + lat2 + lat3) / 3.0;
  final double mPerDegLon = 111320.0 * cos(midLat * pi / 180.0);

  final double x1 = 0.0;
  final double y1 = 0.0;
  final double x2 = (lon2 - lon1) * mPerDegLon;
  final double y2 = (lat2 - lat1) * mPerDegLat;
  final double x3 = (lon3 - lon1) * mPerDegLon;
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