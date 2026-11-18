import 'package:flutter_test/flutter_test.dart';
import 'package:train_logger/models/tracking_session.dart';
import 'package:train_logger/services/stop_detector.dart';

final _t0 = DateTime.utc(2026, 1, 1, 10);

GpsPoint _fix(int second, {double northM = 0, double lon = 69.0}) => GpsPoint(
  lat: 41.0 + northM / 111195,
  lon: lon,
  altitude: 400,
  speedMs: 0,
  accuracy: 5,
  time: _t0.add(Duration(seconds: second)),
);

void main() {
  late StopDetector detector;
  setUp(() => detector = StopDetector());

  // Seconds of standing still before a stop counts; tests follow the setting.
  final wait = StopDetector.kMinStopDuration.inSeconds;

  /// One fix per second, [from] to [to] inclusive; returns every report.
  List<DetectedStop> feed(
    int from,
    int to,
    double speed, {
    double Function(int second)? northM,
  }) => [
    for (var s = from; s <= to; s++)
      ?detector.addFix(_fix(s, northM: northM?.call(s) ?? 0), speed),
  ];

  test('a stop counts after the wait and keeps its arrival time', () {
    expect(feed(0, 4, 15, northM: (s) => s * 15.0 - 75), isEmpty);
    expect(feed(5, 5 + wait - 1, 0), isEmpty, reason: 'one second short');
    final stops = feed(5 + wait, 5 + wait, 0);
    expect(stops, hasLength(1));
    expect(stops.single.arrival, _t0.add(const Duration(seconds: 5)));
    expect(stops.single.departure, isNull);
    expect(detector.isStopped, isTrue);
  });

  test('slowing down for less than the wait is not a stop', () {
    expect(feed(0, wait - 1, 0.4), isEmpty);
    expect(feed(wait, 40, 12, northM: (s) => (s - wait + 1) * 12.0), isEmpty);
    expect(detector.isStopped, isFalse);
  });

  test('departure needs 3 s of movement and starts at its first fix', () {
    // Stationary GPS jitter of ±2 m around the platform.
    expect(feed(0, wait, 0, northM: (s) => s.isEven ? 2 : -2), hasLength(1));
    // One noisy fast reading does not end the stop.
    final t = wait + 10;
    expect(feed(t, t, 1.5), isEmpty);
    expect(feed(t + 1, t + 9, 0.2), isEmpty);
    expect(feed(t + 10, t + 12, 2, northM: (s) => (s - t - 9) * 2.0), isEmpty);
    final departed = feed(t + 13, t + 13, 2, northM: (s) => 8);
    expect(departed, hasLength(1));
    final stop = departed.single;
    expect(stop.arrival, _t0);
    expect(stop.departure, _t0.add(Duration(seconds: t + 10)));
    expect(stop.latitude, closeTo(41.0, 2 / 111195));
    expect(stop.altitudeM, 400);
    expect(detector.isStopped, isFalse);
  });

  test('unavailable speed neither starts nor ends a stop', () {
    expect(feed(0, wait - 1, 0), isEmpty);
    expect(feed(wait, wait + 6, -1), isEmpty);
    expect(feed(wait + 7, wait + 7, 0).single.arrival, _t0);
    expect(feed(wait + 8, 60, -1, northM: (s) => s * 10.0), isEmpty);
    expect(detector.isStopped, isTrue);
  });

  test('zero speed while the position keeps moving is not a stop', () {
    // Android reports 0 when a fix has no speed; 15 m/s is 54 km/h.
    expect(feed(0, 60, 0, northM: (s) => s * 15.0), isEmpty);
    expect(detector.isStopped, isFalse);
  });

  test('a confirmed stop ends when "stationary" fixes drift away', () {
    expect(feed(0, wait, 0), hasLength(1));
    expect(feed(wait + 1, wait + 3, 0, northM: (s) => 60), isEmpty);
    final departed = feed(wait + 4, wait + 4, 0, northM: (s) => 80);
    expect(departed.single.departure, _t0.add(Duration(seconds: wait + 1)));
  });

  test('reset forgets a pending and an active stop', () {
    feed(0, wait - 1, 0);
    detector.reset();
    expect(feed(wait, 2 * wait - 1, 0), isEmpty, reason: 'restarted at wait');
    expect(feed(2 * wait, 2 * wait, 0), hasLength(1));
    detector.reset();
    expect(detector.isStopped, isFalse);
    expect(feed(30, 60, 10, northM: (s) => s * 10.0), isEmpty);
  });

  test('a stop on the date line averages to the date line, not 0°', () {
    for (var s = 0; s < wait; s++) {
      detector.addFix(_fix(s, lon: s.isEven ? 179.99995 : -179.99995), 0);
    }
    final stop = detector.addFix(_fix(wait, lon: 179.99995), 0)!;
    expect(stop.longitude.abs(), closeTo(180, 1e-4));
  });

  test('one noisy reading does not cancel a stop being confirmed', () {
    // A 1.2 m/s reading every 4 s while standing for a minute.
    final stops = feed(0, 60, 0.0);
    expect(stops, hasLength(1));
    detector.reset();
    final noisy = [
      for (var s = 0; s <= 60; s++)
        ?detector.addFix(_fix(s), s % 4 == 3 ? 1.2 : 0.0),
    ];
    expect(noisy, hasLength(1));
    expect(noisy.single.arrival, _t0);
  });

  test('a single fast reading keeps the original arrival time', () {
    feed(0, 1, 0);
    feed(2, 2, 1.2);
    final stop = feed(3, wait, 0).single;
    expect(stop.arrival, _t0);
  });

  test('leaving into a tunnel estimates the departure from distance', () {
    expect(feed(0, 20, 0), hasLength(1));
    // No fixes for 34 s, then the train is 300 m on at 20 m/s.
    expect(feed(55, 57, 20, northM: (s) => 300.0 + (s - 55) * 20), isEmpty);
    final stop = feed(58, 58, 20, northM: (s) => 360).single;
    // 300 m at 20 m/s is 15 s of travel before the first fix at 55 s.
    final departedAt = stop.departure!.difference(_t0).inMilliseconds / 1000;
    expect(departedAt, closeTo(40, 0.1));
  });

  test('a departure estimate never precedes the last stationary fix', () {
    expect(feed(0, 20, 0), hasLength(1));
    // 2 km at 20 m/s would put the departure before the train stopped.
    feed(30, 32, 20, northM: (s) => 2000.0 + (s - 30) * 20);
    final stop = feed(33, 33, 20, northM: (s) => 2060).single;
    expect(stop.departure, _t0.add(const Duration(seconds: 20)));
  });
}
