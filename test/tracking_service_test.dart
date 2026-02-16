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

    test('steep: +10 m over 100 m → 10 %', () {
      expect(computeGradePercent(10.0, 100.0), closeTo(10.0, 0.001));
    });

    test('handles zero segment distance gracefully', () {
      expect(computeGradePercent(5.0, 0.0), 0.0);
    });

    test('non-standard segment: +4 m over 97.5 m → ~4.10 %', () {
      // grade = (4 / 97.5) * 100 = 4.1026...
      expect(computeGradePercent(4.0, 97.5), closeTo(4.1026, 0.001));
    });

    test('real-world: +1.2 m over 100.3 m → ~1.196 %', () {
      expect(computeGradePercent(1.2, 100.3), closeTo(1.196, 0.01));
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

    test('well past threshold → true', () {
      expect(hasCrossedThreshold(156.3, 100.0), isTrue);
    });

    test('first threshold not reached → false', () {
      expect(hasCrossedThreshold(42.0, 100.0), isFalse);
    });

    test('crossing second threshold (200 m)', () {
      expect(hasCrossedThreshold(200.5, 200.0), isTrue);
    });

    test('between thresholds → false', () {
      expect(hasCrossedThreshold(150.0, 200.0), isFalse);
    });
  });

  // ── Multi-threshold jump test ───────────────────────────────────

  group('multi-threshold jump scenario', () {
    test('a 250 m jump should cross thresholds 100 and 200', () {
      double totalDistance = 50.0; // starting at 50 m
      double nextThreshold = 100.0;
      int crossings = 0;

      // Simulate a single large GPS jump of 250 m
      totalDistance += 250.0; // now 300 m

      while (hasCrossedThreshold(totalDistance, nextThreshold)) {
        crossings++;
        nextThreshold += 100.0;
      }

      expect(crossings, 2); // crossed 100 and 200
      expect(nextThreshold, 300.0); // next pending is 300
    });
  });

  // ── Noise filter configuration tests ────────────────────────────

  group('filter constants are sensible', () {
    test('min movement > typical GPS drift', () {
      // Typical indoor drift: 1-5 m.  Our gate must exceed that.
      expect(TrackingService.kMinMovementM, greaterThanOrEqualTo(5.0));
    });

    test('max accuracy rejects poor fixes', () {
      expect(TrackingService.kMaxAccuracyM, lessThanOrEqualTo(25.0));
    });

    test('min speed rejects stationary', () {
      // 1 m/s = 3.6 km/h — a very slow walking pace.
      expect(TrackingService.kMinSpeedMs, greaterThanOrEqualTo(1.0));
    });

    test('max speed allows high-speed trains', () {
      // 83 m/s ≈ 300 km/h
      expect(TrackingService.kMaxSpeedMs, greaterThanOrEqualTo(80.0));
    });
  });

  // ── Geodesic distance sanity check ──────────────────────────────

  group('geodesicDistance', () {
    test('Tashkent to nearby point ≈ known distance', () {
      // Two points ~100 m apart in Tashkent
      final dist = TrackingService.geodesicDistance(
        41.2995, 69.2401,
        41.3004, 69.2401,
      );
      // ~100 m (1 degree lat ≈ 111 km, 0.0009° ≈ 100 m)
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