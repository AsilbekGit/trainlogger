import '../models/tracking_session.dart';
import 'tracking_service.dart';

/// Where and when the train stood still.
class DetectedStop {
  final DateTime arrival;

  /// Null when the stop has just been confirmed and the train is still there.
  final DateTime? departure;

  /// Average of every stationary fix, steadier than any single fix.
  final double latitude;
  final double longitude;
  final double altitudeM;

  const DetectedStop({
    required this.arrival,
    this.departure,
    required this.latitude,
    required this.longitude,
    required this.altitudeM,
  });
}

/// Turns accepted GPS fixes into station stops.
///
/// A stop begins at the first fix slower than [kStopSpeedMs] and counts once
/// the train has stayed that slow for [kMinStopDuration], so a single slow
/// reading is not a stop. Both a pending and a confirmed stop end only after
/// [kMinDepartureDuration] of continuous movement, so one noisy speed reading
/// neither cancels nor splits a stop. The departure time is the first of those
/// moving fixes, or an estimate when GPS was lost as the train left.
///
/// Every stop is reported, including stops at signals; the detector cannot
/// tell why the train stopped. It only observes fixes and never changes the
/// 50 m distance logic in [TrackingService].
class StopDetector {
  /// Matches [TrackingService.kMinSpeedMs]: slower fixes add no distance.
  static const double kStopSpeedMs = 1.0;

  /// With fixes about once a second, a stop is confirmed on the sixth slow
  /// fix in a row.
  static const Duration kMinStopDuration = Duration(seconds: 5);
  static const Duration kMinDepartureDuration = Duration(seconds: 3);

  /// Fixes normally arrive about once a second. A longer silence between the
  /// last stationary fix and the first moving one means GPS was lost as the
  /// train left (a tunnel, a station roof), so the departure is estimated.
  static const Duration kMaxFixGap = Duration(seconds: 2);

  /// A "stationary" fix this far from the first slow fix means the train is
  /// moving and the speed reading is wrong (Android reports 0 when speed is
  /// unknown). Within [kMinStopDuration] a standing phone drifts a few metres
  /// at most, so movement faster than about 14 km/h (20 m in 5 s) cannot
  /// become a stop.
  static const double kMaxPendingDriftM = 20.0;

  /// The same check for a confirmed stop, measured from its averaged
  /// position. Generous because a long dwell under a station roof can wander
  /// further, and accepted fixes may each be up to 20 m off.
  static const double kMaxStopDriftM = 50.0;

  _StopAccumulator? _candidate;
  _StopAccumulator? _active;

  /// Start of the current run of moving fixes, for a pending or active stop.
  DateTime? _movingSince;
  GpsPoint? _firstMovingFix;
  double _firstMovingSpeedMs = 0;

  /// True while a confirmed stop is in progress.
  bool get isStopped => _active != null;

  /// Feed one accepted fix with its raw GPS speed (negative = unavailable).
  ///
  /// Returns the stop when it is confirmed (departure null) and again when the
  /// train leaves (departure set). Returns null otherwise.
  DetectedStop? addFix(GpsPoint fix, double rawSpeedMs) {
    // Unknown speed (-1 on iOS) says nothing about standing or moving.
    if (!rawSpeedMs.isFinite || rawSpeedMs < 0) return null;

    final active = _active;
    final candidate = _candidate;
    final drifted = active != null
        ? active.distanceFromAverage(fix) > kMaxStopDriftM
        : (candidate?.distanceFromFirst(fix) ?? 0.0) > kMaxPendingDriftM;
    final stationary = rawSpeedMs < kStopSpeedMs && !drifted;

    if (!stationary) {
      if (active == null && candidate == null) return null;
      if (_movingSince == null) {
        _movingSince = fix.time;
        _firstMovingFix = fix;
        _firstMovingSpeedMs = rawSpeedMs;
      }
      if (fix.time.difference(_movingSince!) < kMinDepartureDuration) {
        return null;
      }
      final firstMoving = _firstMovingFix!;
      final firstSpeed = _firstMovingSpeedMs;
      _movingSince = null;
      _firstMovingFix = null;
      if (active == null) {
        _candidate = null; // It never lasted long enough to be a stop.
        return null;
      }
      _active = null;
      return active.toStop(
        departure: _departureTime(active, firstMoving, firstSpeed),
      );
    }

    _movingSince = null;
    _firstMovingFix = null;
    if (active == null) {
      final pending = _candidate ??= _StopAccumulator(fix);
      pending.add(fix);
      if (fix.time.difference(pending.arrival) < kMinStopDuration) {
        return null;
      }
      _active = pending;
      _candidate = null;
      return pending.toStop();
    }
    active.add(fix);
    return null;
  }

  /// When the train set off. Normally the first moving fix, about a second
  /// after the last stationary one. After a GPS gap, estimated from how far
  /// the train had got at that fix's speed, but never before the last
  /// stationary fix and never after the first moving one.
  DateTime _departureTime(
    _StopAccumulator stop,
    GpsPoint firstMoving,
    double speedMs,
  ) {
    if (firstMoving.time.difference(stop.lastTime) <= kMaxFixGap) {
      return firstMoving.time;
    }
    if (speedMs < kStopSpeedMs) return stop.lastTime; // Drifted; no speed.
    final seconds = stop.distanceFromAverage(firstMoving) / speedMs;
    final estimate = firstMoving.time.subtract(
      Duration(microseconds: (seconds * 1e6).round()),
    );
    return estimate.isBefore(stop.lastTime) ? stop.lastTime : estimate;
  }

  /// Forget any pending or active stop, e.g. when tracking stops.
  void reset() {
    _candidate = null;
    _active = null;
    _movingSince = null;
    _firstMovingFix = null;
  }
}

class _StopAccumulator {
  _StopAccumulator(GpsPoint first)
    : arrival = first.time,
      lastTime = first.time,
      _first = first,
      _originLon = first.lon;

  final DateTime arrival;

  /// Time of the latest stationary fix.
  DateTime lastTime;
  final GpsPoint _first;
  final double _originLon;
  double _latSum = 0;
  double _lonOffsetSum = 0;
  double _altitudeSum = 0;
  int _count = 0;

  double get latitude => _latSum / _count;

  // Averaged as offsets from the first fix so a stop on the date line does not
  // average +179.9 and -179.9 to 0.
  double get longitude => _wrap(_originLon + _lonOffsetSum / _count);

  void add(GpsPoint fix) {
    _latSum += fix.lat;
    _lonOffsetSum += _wrap(fix.lon - _originLon);
    _altitudeSum += fix.altitude;
    _count++;
    lastTime = fix.time;
  }

  double distanceFromFirst(GpsPoint fix) => TrackingService.geodesicDistance(
    _first.lat,
    _first.lon,
    fix.lat,
    fix.lon,
  );

  double distanceFromAverage(GpsPoint fix) =>
      TrackingService.geodesicDistance(latitude, longitude, fix.lat, fix.lon);

  DetectedStop toStop({DateTime? departure}) => DetectedStop(
    arrival: arrival,
    departure: departure,
    latitude: latitude,
    longitude: longitude,
    altitudeM: _altitudeSum / _count,
  );
}

double _wrap(double degrees) => (degrees + 180.0) % 360.0 - 180.0;
