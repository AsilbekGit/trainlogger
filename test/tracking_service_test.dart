import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:train_logger/models/log_record.dart';
import 'package:train_logger/models/tracking_session.dart';
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

    test(
      'multi-threshold: 50 m + 250 m jump → 300 m crosses 100, 200 and 300',
      () {
        double totalDistance = 50.0;
        double nextThreshold = 100.0;
        int crossings = 0;
        totalDistance += 250.0; // → 300 m
        while (hasCrossedThreshold(totalDistance, nextThreshold)) {
          crossings++;
          nextThreshold += 100.0;
        }
        // 300 m is itself a threshold, so under the `>=` rule it is crossed too.
        expect(crossings, 3);
        expect(nextThreshold, 400.0);
      },
    );
  });

  // ── Menger Curvature tests ──────────────────────────────────────

  group('computeMengerCurvature', () {
    test('three collinear points → curvature ≈ 0 (straight)', () {
      // Three points going due north, ~100 m apart.
      final result = computeMengerCurvature(
        41.0000,
        69.0000, // P1
        41.0009,
        69.0000, // P2 (~100 m north)
        41.0018,
        69.0000, // P3 (~200 m north)
      );
      expect(result.curvaturePercent, closeTo(0.0, 0.001));
      expect(result.area, closeTo(0.0, 1.0)); // zero triangle area
      expect(result.radiusM, isNull); // R = ∞ for straight
    });

    test('three collinear points going east → curvature ≈ 0', () {
      final result = computeMengerCurvature(
        41.0000,
        69.0000,
        41.0000,
        69.0012,
        41.0000,
        69.0024,
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
        lats[0],
        lons[0],
        lats[1],
        lons[1],
        lats[2],
        lons[2],
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
        lats[0],
        lons[0],
        lats[1],
        lons[1],
        lats[2],
        lons[2],
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
        lats[0],
        lons[0],
        lats[1],
        lons[1],
        lats[2],
        lons[2],
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
        lats[0],
        lons[0],
        lats[1],
        lons[1],
        lats[2],
        lons[2],
      );

      // κ = 1/1000 = 0.001, κ% = 0.1%
      expect(result.curvaturePercent, closeTo(0.1, 0.03));
      expect(result.radiusM!, closeTo(1000.0, 100.0));
    });

    test('duplicate points → curvature 0, no crash', () {
      final result = computeMengerCurvature(41.0, 69.0, 41.0, 69.0, 41.0, 69.0);
      expect(result.curvaturePercent, 0.0);
      expect(result.radiusM, isNull);
    });

    test('a curve crossing the date line matches the same local geometry', () {
      final ordinary = computeMengerCurvature(
        0.0,
        -0.0002,
        0.0001,
        0.0002,
        0.0003,
        0.0005,
      );
      final dateLine = computeMengerCurvature(
        0.0,
        179.9998,
        0.0001,
        -179.9998,
        0.0003,
        -179.9995,
      );
      expect(
        dateLine.curvaturePercent,
        closeTo(ordinary.curvaturePercent, 1e-6),
      );
      expect(dateLine.radiusM, closeTo(ordinary.radiusM!, 0.001));
    });

    test('area is non-negative', () {
      final result = computeMengerCurvature(
        41.0000,
        69.0000,
        41.0010,
        69.0000,
        41.0010,
        69.0015,
      );
      expect(result.area, greaterThanOrEqualTo(0.0));
      expect(result.curvaturePercent, greaterThan(0.0));
    });
  });

  // ── Geodesic distance sanity ────────────────────────────────────

  group('geodesicDistance', () {
    test('~100 m apart', () {
      final dist = TrackingService.geodesicDistance(
        41.2995,
        69.2401,
        41.3004,
        69.2401,
      );
      expect(dist, closeTo(100.0, 10.0));
    });

    test('preserves sub-metre precision for accumulated GPS segments', () {
      final distance = TrackingService.geodesicDistance(
        0.0,
        0.0,
        0.000055,
        0.0,
      );
      expect(distance, inExclusiveRange(6.07, 6.09));
      expect(distance, isNot(distance.roundToDouble()));
    });

    test('same point → 0 m', () {
      final dist = TrackingService.geodesicDistance(
        41.2995,
        69.2401,
        41.2995,
        69.2401,
      );
      expect(dist, closeTo(0.0, 0.01));
    });
  });

  // ── processPosition emission ────────────────────────────────────
  // Guards the 50 m interval and the totalDistanceM off-by-one fix
  // (record #1 used to store 0 instead of 50).
  group('processPosition', () {
    var fixNumber = 0;
    Position mkPos(
      double lat,
      double lon, {
      double altitude = 100.0,
      double accuracy = 5.0,
      double speed = 20.0,
      DateTime? time,
    }) => Position(
      longitude: lon,
      latitude: lat,
      timestamp: time ?? DateTime.utc(2026).add(Duration(seconds: fixNumber++)),
      accuracy: accuracy,
      altitude: altitude,
      altitudeAccuracy: 1.0,
      heading: 0.0,
      headingAccuracy: 1.0,
      speed: speed,
      speedAccuracy: 1.0,
    );

    test('logs every 50 m and stores the true milestone distance', () {
      final session = TrackingSession();
      final svc = TrackingService(session);

      const startLat = 41.0;
      const lon = 69.0;
      const stepDeg = 10.0 / 111320.0; // ~10 m north per fix

      final all = <LogRecord>[];
      for (var i = 0; i < 25; i++) {
        all.addAll(svc.processPosition(mkPos(startLat + stepDeg * i, lon)));
      }

      expect(all, isNotEmpty);
      // Regression: record #1 must be the 50 m milestone, not 0.
      expect(all.first.index, 1);
      expect(all.first.totalDistanceM, 50.0);

      // Milestones are exact multiples of the 50 m interval, in order.
      for (var i = 0; i < all.length; i++) {
        expect(all[i].index, i + 1);
        expect(all[i].totalDistanceM, closeTo(50.0 * (i + 1), 1e-6));
      }
    });

    test('multiple milestones interpolate distinct coordinates and times', () {
      final session = TrackingSession();
      final svc = TrackingService(session);
      final start = DateTime.utc(2026);
      const endLat = 260.0 / 111320.0;
      svc.processPosition(mkPos(0.0, 0.0, time: start));
      final records = svc.processPosition(
        mkPos(endLat, 0.0, time: start.add(const Duration(seconds: 13))),
      );

      expect(records, hasLength(5));
      var previousLat = 0.0;
      var previousTime = start;
      for (var i = 0; i < records.length; i++) {
        final record = records[i];
        final fraction = record.totalDistanceM / session.totalDistanceMeters;
        expect(record.latitude, closeTo(endLat * fraction, 1e-9));
        expect(record.latitude, greaterThan(previousLat));
        expect(record.segmentDistanceM, closeTo(50.0, 0.01));
        expect(record.gradePercent, closeTo(0.0, 1e-9));
        final time = DateTime.parse(record.timestamp);
        expect(time.isAfter(previousTime), isTrue);
        expect(
          time.difference(start).inMicroseconds,
          closeTo(13000000 * fraction, 1.0),
        );
        previousLat = record.latitude;
        previousTime = time;
      }
      expect(session.previousPoint!.lat, endLat);
      expect(session.nextLogThresholdMeters, 300.0);
    });

    test(
      'milestone interpolation includes distance carried from earlier fixes',
      () {
        final session = TrackingSession();
        final svc = TrackingService(session);
        svc.processPosition(mkPos(0.0, 0.0));
        expect(svc.processPosition(mkPos(35.0 / 111320.0, 0.0)), isEmpty);
        final records = svc.processPosition(mkPos(80.0 / 111320.0, 0.0));

        expect(records, hasLength(1));
        expect(records.single.totalDistanceM, 50.0);
        expect(
          TrackingService.geodesicDistance(
            0.0,
            0.0,
            records.single.latitude,
            records.single.longitude,
          ),
          closeTo(50.0, 0.01),
        );
        expect(session.totalDistanceMeters, greaterThan(79.0));
        expect(session.nextLogThresholdMeters, 100.0);
      },
    );

    test('grade compares consistently smoothed logged elevations', () {
      final session = TrackingSession();
      final svc = TrackingService(session);
      svc.processPosition(mkPos(0.0, 0.0, altitude: 100.0));
      final first = svc
          .processPosition(mkPos(60.0 / 111320.0, 0.0, altitude: 120.0))
          .single;
      final second = svc
          .processPosition(mkPos(120.0 / 111320.0, 0.0, altitude: 130.0))
          .single;

      expect(first.altitudeM, inExclusiveRange(100.0, 110.0));
      expect(first.elevationDeltaM, closeTo(first.altitudeM - 100.0, 1e-9));
      expect(
        second.elevationDeltaM,
        closeTo(second.altitudeM - first.altitudeM, 1e-9),
      );
      expect(
        second.gradePercent,
        closeTo(
          100.0 * second.elevationDeltaM! / second.segmentDistanceM,
          1e-9,
        ),
      );
      expect(session.lastLoggedPoint!.altitude, second.altitudeM);
    });

    test(
      'small fixes retain the distance anchor while refreshing the live fix',
      () {
        final session = TrackingSession();
        final svc = TrackingService(session);
        svc.processPosition(mkPos(0.0, 0.0));
        final origin = session.previousPoint;
        for (final metres in [2.0, 4.0]) {
          expect(svc.processPosition(mkPos(metres / 111320.0, 0.0)), isEmpty);
          expect(session.previousPoint, same(origin));
          expect(svc.currentPoint!.lat, metres / 111320.0);
          expect(session.totalDistanceMeters, 0.0);
        }
        expect(svc.processPosition(mkPos(6.0 / 111320.0, 0.0)), isEmpty);
        expect(session.previousPoint, same(svc.currentPoint));
        expect(session.totalDistanceMeters, closeTo(6.0, 0.05));
      },
    );

    test(
      'invalid GPS values cannot poison distance, smoothing, or map point',
      () {
        final session = TrackingSession();
        final svc = TrackingService(session);
        svc.processPosition(mkPos(0.0, 0.0));
        final origin = session.previousPoint;
        final invalid = [
          mkPos(double.nan, 0.0),
          mkPos(double.infinity, 0.0),
          mkPos(91.0, 0.0),
          mkPos(0.0, double.nan),
          mkPos(0.0, -181.0),
          mkPos(0.001, 0.0, altitude: double.nan),
          mkPos(0.001, 0.0, accuracy: double.infinity),
          mkPos(0.001, 0.0, accuracy: double.nan),
          mkPos(0.001, 0.0, accuracy: -1.0),
          mkPos(0.001, 0.0, accuracy: 21.0),
          mkPos(0.001, 0.0, speed: double.infinity),
          mkPos(0.001, 0.0, speed: double.nan),
        ];
        for (final position in invalid) {
          expect(svc.processPosition(position), isEmpty);
          expect(session.previousPoint, same(origin));
          expect(svc.currentPoint, same(origin));
          expect(session.totalDistanceMeters, 0.0);
          expect(session.altitudeWindow, [100.0]);
          expect(session.polylinePoints, hasLength(1));
        }
        expect(svc.processPosition(mkPos(60.0 / 111320.0, 0.0)), hasLength(1));
      },
    );

    test('duplicate and out-of-order fixes leave the session unchanged', () {
      final session = TrackingSession();
      final svc = TrackingService(session);
      final time = DateTime.utc(2026);
      svc.processPosition(mkPos(0.0, 0.0, time: time));
      svc.processPosition(
        mkPos(0.00001, 0.0, time: time.add(const Duration(seconds: 2))),
      );
      final latest = svc.currentPoint;
      for (final seconds in [0, 1, 2]) {
        expect(
          svc.processPosition(
            mkPos(
              0.001,
              0.0,
              altitude: 500.0,
              time: time.add(Duration(seconds: seconds)),
            ),
          ),
          isEmpty,
        );
        expect(svc.currentPoint, same(latest));
        expect(session.totalDistanceMeters, 0.0);
        expect(session.altitudeWindow, [100.0, 100.0]);
      }
    });

    test(
      'rejected teleport cannot seed distance, grade, or altitude history',
      () {
        final session = TrackingSession();
        final svc = TrackingService(session);
        svc.processPosition(mkPos(0.0, 0.0));
        svc.processPosition(mkPos(60.0 / 111320.0, 0.0));
        final distanceBeforeJump = session.totalDistanceMeters;
        final polylineBeforeJump = session.polylinePoints.length;
        expect(svc.processPosition(mkPos(1.0, 0.0, altitude: 9999.0)), isEmpty);
        expect(session.previousPoint, isNull);
        expect(session.lastLoggedPoint, isNull);
        expect(session.secondLastLoggedPoint, isNull);
        expect(svc.currentPoint, isNull);
        expect(session.altitudeWindow, isEmpty);
        expect(session.polylinePoints, hasLength(polylineBeforeJump));

        // A coherent fix near the rejected jump only establishes a baseline.
        expect(
          svc.processPosition(mkPos(1.0001, 0.0, altitude: 200.0)),
          isEmpty,
        );
        expect(session.totalDistanceMeters, distanceBeforeJump);
        final next = svc
            .processPosition(
              mkPos(1.0001 + 60.0 / 111320.0, 0.0, altitude: 200.0),
            )
            .single;
        expect(next.index, 2);
        expect(next.totalDistanceM, 100.0);
        expect(next.altitudeM, 200.0);
        expect(next.gradePercent, 0.0);
        expect(next.curvaturePercent, isNull);
      },
    );

    test(
      'stationary and unavailable speed update map without adding distance',
      () {
        final session = TrackingSession();
        final svc = TrackingService(session);
        for (final speed in [0.0, -1.0, 0.5]) {
          expect(svc.processPosition(mkPos(41.0, 69.0, speed: speed)), isEmpty);
          expect(svc.currentPoint!.lat, 41.0);
          expect(session.currentSpeedKmh, 0.0);
          expect(session.previousPoint, isNull);
          expect(session.totalDistanceMeters, 0.0);
        }
      },
    );

    test(
      'resetting continuity preserves milestones and excludes paused travel',
      () {
        final session = TrackingSession();
        final svc = TrackingService(session);
        svc.processPosition(mkPos(0.0, 0.0));
        svc.processPosition(mkPos(60.0 / 111320.0, 0.0));
        final distanceBeforePause = session.totalDistanceMeters;
        svc.resetPositionHistory();
        expect(session.currentSpeedKmh, 0.0);
        expect(svc.currentPoint, isNull);
        expect(session.recordIndex, 1);
        expect(session.nextLogThresholdMeters, 100.0);
        expect(session.totalDistanceMeters, distanceBeforePause);
        expect(svc.processPosition(mkPos(41.0, 69.0)), isEmpty);
        expect(session.totalDistanceMeters, distanceBeforePause);
        expect(session.polylineBreakIndices, [2]);
        expect(session.polylinePoints, hasLength(3));
      },
    );

    test('date-line milestones follow the short segment', () {
      final session = TrackingSession();
      final svc = TrackingService(session);
      svc.processPosition(mkPos(0.0, 179.9998));
      final records = svc.processPosition(mkPos(0.0, -179.9992));
      expect(records, hasLength(2));
      for (final record in records) {
        expect(record.longitude.abs(), greaterThan(179.99));
        expect(record.segmentDistanceM, closeTo(50.0, 0.01));
      }
      expect(records.last.curvaturePercent, closeTo(0.0, 1e-9));
    });
  });
}
