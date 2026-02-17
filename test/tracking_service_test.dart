import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:train_logger/services/tracking_service.dart';

void main() {
  // ── Grade formula tests ─────────────────────────────────────────

  group('computeGradePercent', () {
    test('flat segment → 0 %', () {
      expect(computeGradePercent(0.0, 100.0), 0.0);
    });

    test('uphill: +6 m over 100 m → 6 %', () {
      expect(computeGradePercent(6.0, 100.0), closeTo(6.0, 0.001));
    });

    test('downhill: -3 m over 100 m → -3 %', () {
      expect(computeGradePercent(-3.0, 100.0), closeTo(-3.0, 0.001));
    });

    test('handles zero segment distance gracefully', () {
      expect(computeGradePercent(5.0, 0.0), 0.0);
    });
  });

  // ── Threshold crossing tests ────────────────────────────────────

  group('hasCrossedThreshold', () {
    test('exactly at threshold → true', () {
      expect(hasCrossedThreshold(100.0, 100.0), isTrue);
    });

    test('just below threshold → false', () {
      expect(hasCrossedThreshold(99.9, 100.0), isFalse);
    });

    test('multi-threshold: 250 m jump crosses 100 and 200', () {
      double totalDistance = 50.0;
      double nextThreshold = 100.0;
      int crossings = 0;
      totalDistance += 250.0;
      while (hasCrossedThreshold(totalDistance, nextThreshold)) {
        crossings++;
        nextThreshold += 100.0;
      }
      expect(crossings, 2);
      expect(nextThreshold, 300.0);
    });
  });

  // ── Menger Curvature tests ──────────────────────────────────────

  group('computeMengerCurvature', () {
    test('three collinear points → curvature ≈ 0 (straight)', () {
      // Three points going due north, ~100 m apart.
      final result = computeMengerCurvature(
        41.0000, 69.0000, // P1
        41.0009, 69.0000, // P2 (~100 m north)
        41.0018, 69.0000, // P3 (~200 m north)
      );
      expect(result.curvaturePercent, closeTo(0.0, 0.001));
      expect(result.area, closeTo(0.0, 1.0)); // zero triangle area
      expect(result.radiusM, isNull); // R = ∞ for straight
    });

    test('three collinear points going east → curvature ≈ 0', () {
      final result = computeMengerCurvature(
        41.0000, 69.0000,
        41.0000, 69.0012,
        41.0000, 69.0024,
      );
      expect(result.curvaturePercent, closeTo(0.0, 0.001));
    });

    test('known circle: R ≈ 500 m → curvature ≈ 0.2%', () {
      // Place 3 points on a circle of radius 500 m.
      // Using a circle centred at (41.0, 69.0), R = 500 m.
      // Angular separation: with chord ~100 m on R=500, θ ≈ 0.2 rad
      const R = 500.0;
      const centerLat = 41.0;
      const centerLon = 69.0;
      const mPerDegLat = 110540.0;
      final mPerDegLon = 111320.0 * cos(centerLat * pi / 180.0);

      // Three points at angles 0°, 12°, 24° on the circle.
      final angles = [0.0, 12.0, 24.0];
      final lats = <double>[];
      final lons = <double>[];
      for (final a in angles) {
        final rad = a * pi / 180.0;
        lats.add(centerLat + (R * cos(rad)) / mPerDegLat);
        lons.add(centerLon + (R * sin(rad)) / mPerDegLon);
      }

      final result = computeMengerCurvature(
        lats[0], lons[0],
        lats[1], lons[1],
        lats[2], lons[2],
      );

      // κ = 1/500 = 0.002, κ% = 0.2%
      expect(result.curvaturePercent, closeTo(0.2, 0.05));
      expect(result.radiusM, isNotNull);
      expect(result.radiusM!, closeTo(500.0, 50.0));
    });

    test('known circle: R ≈ 200 m → curvature ≈ 0.5%', () {
      const R = 200.0;
      const centerLat = 41.0;
      const centerLon = 69.0;
      const mPerDegLat = 110540.0;
      final mPerDegLon = 111320.0 * cos(centerLat * pi / 180.0);

      final angles = [0.0, 15.0, 30.0];
      final lats = <double>[];
      final lons = <double>[];
      for (final a in angles) {
        final rad = a * pi / 180.0;
        lats.add(centerLat + (R * cos(rad)) / mPerDegLat);
        lons.add(centerLon + (R * sin(rad)) / mPerDegLon);
      }

      final result = computeMengerCurvature(
        lats[0], lons[0],
        lats[1], lons[1],
        lats[2], lons[2],
      );

      // κ = 1/200 = 0.005, κ% = 0.5%
      expect(result.curvaturePercent, closeTo(0.5, 0.1));
      expect(result.radiusM!, closeTo(200.0, 30.0));
    });

    test('known circle: R ≈ 100 m → curvature ≈ 1.0%', () {
      const R = 100.0;
      const centerLat = 41.0;
      const centerLon = 69.0;
      const mPerDegLat = 110540.0;
      final mPerDegLon = 111320.0 * cos(centerLat * pi / 180.0);

      final angles = [0.0, 30.0, 60.0];
      final lats = <double>[];
      final lons = <double>[];
      for (final a in angles) {
        final rad = a * pi / 180.0;
        lats.add(centerLat + (R * cos(rad)) / mPerDegLat);
        lons.add(centerLon + (R * sin(rad)) / mPerDegLon);
      }

      final result = computeMengerCurvature(
        lats[0], lons[0],
        lats[1], lons[1],
        lats[2], lons[2],
      );

      // κ = 1/100 = 0.01, κ% = 1.0%
      expect(result.curvaturePercent, closeTo(1.0, 0.2));
      expect(result.radiusM!, closeTo(100.0, 20.0));
    });

    test('known circle: R ≈ 1000 m → curvature ≈ 0.1%', () {
      const R = 1000.0;
      const centerLat = 41.0;
      const centerLon = 69.0;
      const mPerDegLat = 110540.0;
      final mPerDegLon = 111320.0 * cos(centerLat * pi / 180.0);

      final angles = [0.0, 6.0, 12.0];
      final lats = <double>[];
      final lons = <double>[];
      for (final a in angles) {
        final rad = a * pi / 180.0;
        lats.add(centerLat + (R * cos(rad)) / mPerDegLat);
        lons.add(centerLon + (R * sin(rad)) / mPerDegLon);
      }

      final result = computeMengerCurvature(
        lats[0], lons[0],
        lats[1], lons[1],
        lats[2], lons[2],
      );

      // κ = 1/1000 = 0.001, κ% = 0.1%
      expect(result.curvaturePercent, closeTo(0.1, 0.03));
      expect(result.radiusM!, closeTo(1000.0, 100.0));
    });

    test('duplicate points → curvature 0, no crash', () {
      final result = computeMengerCurvature(
        41.0, 69.0,
        41.0, 69.0,
        41.0, 69.0,
      );
      expect(result.curvaturePercent, 0.0);
      expect(result.radiusM, isNull);
    });

    test('area is non-negative', () {
      final result = computeMengerCurvature(
        41.0000, 69.0000,
        41.0010, 69.0000,
        41.0010, 69.0015,
      );
      expect(result.area, greaterThanOrEqualTo(0.0));
      expect(result.curvaturePercent, greaterThan(0.0));
    });
  });

  // ── Geodesic distance sanity ────────────────────────────────────

  group('geodesicDistance', () {
    test('~100 m apart', () {
      final dist = TrackingService.geodesicDistance(
        41.2995, 69.2401,
        41.3004, 69.2401,
      );
      expect(dist, closeTo(100.0, 10.0));
    });

    test('same point → 0 m', () {
      final dist = TrackingService.geodesicDistance(
        41.2995, 69.2401,
        41.2995, 69.2401,
      );
      expect(dist, closeTo(0.0, 0.01));
    });
  });
}