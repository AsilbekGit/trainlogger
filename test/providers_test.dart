import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:train_logger/models/log_record.dart';
import 'package:train_logger/models/station_event.dart';
import 'package:train_logger/services/location_service.dart';
import 'package:train_logger/services/providers.dart';
import 'package:train_logger/services/stop_detector.dart';
import 'package:train_logger/services/storage_service.dart';

class _FakeLocation extends LocationService {
  final positions = StreamController<Position>.broadcast(sync: true);
  Completer<bool>? permission;
  bool permissionGranted = true;
  Object? startError;
  bool precise = true;
  int permissionCalls = 0;
  int starts = 0;
  int stops = 0;

  @override
  Stream<Position> get positionStream => positions.stream;

  @override
  Future<bool> requestPermission() {
    permissionCalls++;
    return permission?.future ?? Future.value(permissionGranted);
  }

  @override
  Future<bool> hasPreciseLocation() async => precise;

  @override
  Future<void> startListening({int distanceFilter = 0}) async {
    starts++;
    if (startError != null) throw startError!;
  }

  @override
  void stopListening() => stops++;

  @override
  void dispose() {
    positions.close();
    super.dispose();
  }
}

class _FakeStorage extends StorageService {
  final List<LogRecord> saved = [];
  final List<StationEvent> savedStations = [];
  bool failWrites = false;
  bool failClear = false;
  Completer<void>? clearGate;
  int saveCalls = 0;

  @override
  List<LogRecord> getAll() => List.of(saved);

  @override
  Future<void> addAll(List<LogRecord> records) async {
    saveCalls++;
    saved.addAll(records);
    if (failWrites) throw StateError('disk full');
  }

  @override
  List<StationEvent> getStations() => List.of(savedStations);

  @override
  Future<void> saveStation(StationEvent station) async {
    savedStations
      ..removeWhere((s) => s.id == station.id)
      ..add(station);
    if (failWrites) throw StateError('disk full');
  }

  @override
  Future<void> clearAll() async {
    await clearGate?.future;
    if (failClear) throw StateError('read-only storage');
    saved.clear();
    savedStations.clear();
  }
}

StationEvent _station(int id) => StationEvent(
  id: id,
  type: StationEventType.manualMark,
  timestamp: '2026-01-01T00:00:00.000Z',
  latitude: 41,
  longitude: 69,
  altitudeM: 100,
  speedKmh: 0,
  totalDistanceM: 0,
);

Position _position(
  double northMeters,
  int second, {
  double accuracy = 5,
  double speed = 10,
}) {
  return Position(
    latitude: 41 + northMeters / 111000,
    longitude: 69,
    timestamp: DateTime.utc(2026, 1, 1).add(Duration(seconds: second)),
    accuracy: accuracy,
    altitude: 100,
    altitudeAccuracy: 5,
    heading: 0,
    headingAccuracy: 0,
    speed: speed,
    speedAccuracy: 1,
  );
}

Future<void> _drain() => Future<void>.delayed(Duration.zero);

void main() {
  late _FakeLocation location;
  late _FakeStorage storage;
  late TrackingNotifier tracker;
  late DateTime now;

  setUp(() {
    location = _FakeLocation();
    storage = _FakeStorage();
    now = DateTime.utc(2026, 1, 1);
    tracker = TrackingNotifier(location, storage, now: () => now);
  });

  tearDown(() {
    tracker.dispose();
    location.dispose();
  });

  test(
    'rapid starts share one permission request and GPS subscription',
    () async {
      location.permission = Completer<bool>();
      final first = tracker.startTracking();
      final second = tracker.startTracking();
      expect(identical(first, second), isTrue);
      expect(tracker.isStarting, isTrue);
      expect(location.permissionCalls, 1);
      location.permission!.complete(true);
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(location.starts, 1);
      expect(await tracker.startTracking(), isTrue);
      expect(location.starts, 1);
      location.positions.add(_position(0, 0));
      location.positions.add(_position(60, 6));
      expect(tracker.records, hasLength(1));
      expect(storage.saveCalls, 1);
    },
  );

  test('stop cancels a start awaiting permission', () async {
    location.permission = Completer<bool>();
    final start = tracker.startTracking();
    tracker.stopTracking();
    location.permission!.complete(true);
    expect(await start, isFalse);
    expect(location.starts, 0);
    expect(tracker.isTracking, isFalse);
    expect(tracker.needsLocationPermission, isFalse);
  });

  test(
    'permission denial and GPS startup failure remain recoverable',
    () async {
      location.permissionGranted = false;
      expect(await tracker.startTracking(), isFalse);
      expect(tracker.needsLocationPermission, isTrue);
      location.permissionGranted = true;
      location.startError = StateError('platform unavailable');
      expect(await tracker.startTracking(), isFalse);
      expect(tracker.needsLocationPermission, isFalse);
      expect(tracker.errorMessage, contains('Unable to start'));
      expect(tracker.isTracking, isFalse);
      location.startError = null;
      expect(await tracker.startTracking(), isTrue);
      expect(tracker.errorMessage, isNull);
    },
  );

  test('stop freezes elapsed time and resume excludes the pause', () async {
    await tracker.startTracking();
    now = now.add(const Duration(seconds: 12));
    expect(tracker.elapsed, const Duration(seconds: 12));
    tracker.stopTracking();
    now = now.add(const Duration(hours: 1));
    expect(tracker.elapsed, const Duration(seconds: 12));
    await tracker.startTracking();
    now = now.add(const Duration(seconds: 3));
    expect(tracker.elapsed, const Duration(seconds: 15));
    await tracker.newSession();
    expect(tracker.elapsed, Duration.zero);
  });

  test('resume does not count movement while stopped', () async {
    await tracker.startTracking();
    location.positions.add(_position(0, 0));
    location.positions.add(_position(60, 6));
    final distance = tracker.totalDistanceM;
    tracker.stopTracking();
    expect(tracker.speedKmh, 0);
    location.positions.add(_position(200, 20));
    expect(tracker.totalDistanceM, distance);
    await tracker.startTracking();
    location.positions.add(_position(300, 30));
    expect(tracker.totalDistanceM, distance);
    location.positions.add(_position(360, 36));
    expect(tracker.totalDistanceM, closeTo(distance * 2, 0.1));
    expect(tracker.routeSegments, hasLength(2));
    expect(
      tracker.routeSegments.every((segment) => segment.length == 2),
      isTrue,
    );
  });

  test('invalid fixes do not move the map marker', () async {
    await tracker.startTracking();
    location.positions.add(_position(0, 0));
    final current = tracker.currentLatLng;
    location.positions.add(_position(100, 10, accuracy: 100));
    expect(tracker.currentLatLng, current);
  });

  test('stream errors stop tracking and expose a visible error', () async {
    await tracker.startTracking();
    location.positions.addError(StateError('location disabled'));
    expect(tracker.isTracking, isFalse);
    expect(tracker.errorMessage, contains('Location updates stopped'));
    expect(tracker.errorMessage, isNot(contains('Bad state')));
    expect(location.stops, greaterThan(0));
  });

  test('stream completion stops tracking', () async {
    await tracker.startTracking();
    await location.positions.close();
    expect(tracker.isTracking, isFalse);
    expect(tracker.errorMessage, contains('Location updates ended'));
  });

  test('failed saves stop tracking but keep records exportable', () async {
    storage.failWrites = true;
    await tracker.startTracking();
    location.positions.add(_position(0, 0));
    location.positions.add(_position(60, 6));
    await _drain();
    expect(tracker.isTracking, isFalse);
    expect(tracker.records, hasLength(1));
    expect(tracker.errorMessage, contains('export your records'));
  });

  test('clear blocks new starts until deletion finishes', () async {
    await tracker.startTracking();
    location.positions.add(_position(0, 0));
    location.positions.add(_position(60, 6));
    storage.clearGate = Completer<void>();
    final clearing = tracker.newSession();
    expect(tracker.isClearing, isTrue);
    expect(tracker.records, hasLength(1));
    expect(await tracker.startTracking(), isFalse);
    storage.clearGate!.complete();
    await clearing;
    expect(tracker.isClearing, isFalse);
    expect(tracker.records, isEmpty);
    expect(tracker.totalDistanceM, 0);
    expect(tracker.currentLatLng, isNull);
    expect(await tracker.startTracking(), isTrue);
  });

  test('failed clear keeps the session and records', () async {
    await tracker.startTracking();
    location.positions.add(_position(0, 0));
    location.positions.add(_position(60, 6));
    final distance = tracker.totalDistanceM;
    storage.failClear = true;
    await tracker.newSession();
    expect(tracker.isTracking, isFalse);
    expect(tracker.records, hasLength(1));
    expect(tracker.totalDistanceM, distance);
    expect(tracker.errorMessage, contains('Could not clear'));
  });

  test('new session invalidates an outstanding permission request', () async {
    location.permission = Completer<bool>();
    final start = tracker.startTracking();
    await tracker.newSession();
    location.permission!.complete(true);
    expect(await start, isFalse);
    expect(location.starts, 0);
    expect(tracker.records, isEmpty);
  });

  test('disposal cancels subscriptions and pending permission work', () async {
    // This notifier is separate so the fixture can still be disposed normally.
    final pendingLocation = _FakeLocation()..permission = Completer<bool>();
    final pending = TrackingNotifier(pendingLocation, storage);
    final start = pending.startTracking();
    pending.dispose();
    pendingLocation.permission!.complete(true);
    expect(await start, isFalse);
    expect(pendingLocation.starts, 0);
    pendingLocation.dispose();

    final activeLocation = _FakeLocation();
    final active = TrackingNotifier(activeLocation, storage);
    await active.startTracking();
    active.dispose();
    expect(activeLocation.positions.hasListener, isFalse);
    activeLocation.positions.add(_position(60, 6));
    expect(storage.saved, isEmpty);
    activeLocation.dispose();
  });

  test(
    'a station stop is saved on arrival and completed on departure',
    () async {
      await tracker.startTracking();
      location.positions.add(_position(0, 0));
      location.positions.add(_position(60, 6));
      // Stand from 7 s until a few seconds past the stop wait.
      final last = 7 + StopDetector.kMinStopDuration.inSeconds + 3;
      for (var s = 7; s <= last; s++) {
        location.positions.add(_position(60, s, speed: 0));
      }
      await _drain();
      final arrived = tracker.stations.single;
      expect(arrived.type, StationEventType.autoStop);
      expect(arrived.timestamp, '2026-01-01T00:00:07.000Z');
      expect(arrived.departureTimestamp, isNull);
      expect(arrived.totalDistanceM, closeTo(60, 0.5));
      expect(tracker.currentStop?.id, arrived.id);
      expect(storage.savedStations.single.id, arrived.id);

      for (var s = last + 1; s <= last + 4; s++) {
        location.positions.add(_position(60 + (s - last) * 10.0, s));
      }
      await _drain();
      expect(tracker.currentStop, isNull);
      final departed = tracker.stations.single;
      final leftAt = DateTime.utc(2026).add(Duration(seconds: last + 1));
      expect(departed.departureTimestamp, leftAt.toIso8601String());
      expect(departed.dwell, Duration(seconds: last + 1 - 7));
      expect(storage.savedStations.single.departureTimestamp, isNotNull);
      // The stop does not disturb the 50 m records.
      expect(tracker.records.map((r) => r.totalDistanceM), [50, 100]);
    },
  );

  test(
    'stopping tracking during a stop leaves its departure unknown',
    () async {
      await tracker.startTracking();
      final wait = StopDetector.kMinStopDuration.inSeconds;
      for (var s = 0; s <= wait; s++) {
        location.positions.add(_position(0, s, speed: 0));
      }
      expect(tracker.currentStop, isNotNull);
      tracker.stopTracking();
      expect(tracker.currentStop, isNull);
      expect(tracker.stations.single.departureTimestamp, isNull);
    },
  );

  test('rejected fixes never feed stop detection', () async {
    await tracker.startTracking();
    location.positions.add(_position(0, 0, speed: 0));
    for (var s = 1; s <= 20; s++) {
      location.positions.add(_position(0, s, speed: 0, accuracy: 100));
    }
    expect(tracker.stations, isEmpty);
  });

  test('Mark Station saves the latest accepted fix', () async {
    expect(tracker.markStation(), isNull, reason: 'not tracking');
    await tracker.startTracking();
    expect(tracker.markStation(), isNull, reason: 'no GPS fix yet');
    location.positions.add(_position(0, 0));
    location.positions.add(_position(60, 6));
    location.positions.add(_position(500, 7, accuracy: 100));
    now = DateTime.utc(2026, 1, 1, 0, 0, 8);
    final mark = tracker.markStation()!;
    await _drain();
    expect(mark.type, StationEventType.manualMark);
    expect(mark.id, 1);
    expect(mark.latitude, closeTo(41 + 60 / 111000, 1e-9));
    expect(mark.speedKmh, closeTo(36, 1e-9));
    expect(mark.timestamp, '2026-01-01T00:00:08.000Z');
    expect(mark.totalDistanceM, tracker.totalDistanceM);
    expect(storage.savedStations.single.id, 1);
    // The fixes arrived at 0 s (device time); the tap is at 8 s.
    expect(mark.gpsAgeS, 8);
    now = now.add(TrackingNotifier.kMarkDebounce);
    expect(tracker.markStation()!.id, 2);
  });

  test('a failed station save stops tracking but keeps the mark', () async {
    await tracker.startTracking();
    location.positions.add(_position(0, 0));
    storage.failWrites = true;
    tracker.markStation();
    await _drain();
    expect(tracker.isTracking, isFalse);
    expect(tracker.stations, hasLength(1));
    expect(tracker.errorMessage, contains('could not be saved'));
  });

  test(
    'saved stations reload, ids continue, New Session clears them',
    () async {
      storage.savedStations.addAll([_station(3), _station(7)]);
      final reloaded = TrackingNotifier(location, storage, now: () => now);
      addTearDown(reloaded.dispose);
      expect(reloaded.stations.map((s) => s.id), [3, 7]);
      await reloaded.startTracking();
      location.positions.add(_position(0, 0));
      expect(reloaded.markStation()!.id, 8);
      await reloaded.newSession();
      expect(reloaded.stations, isEmpty);
      expect(storage.savedStations, isEmpty);
      await reloaded.startTracking();
      location.positions.add(_position(0, 1));
      expect(reloaded.markStation()!.id, 1);
    },
  );

  DateTime at(int second) =>
      DateTime.utc(2026, 1, 1).add(Duration(seconds: second));

  test('approximate location blocks tracking with an explanation', () async {
    location.precise = false;
    expect(await tracker.startTracking(), isFalse);
    expect(tracker.needsPreciseLocation, isTrue);
    expect(tracker.needsLocationPermission, isFalse);
    expect(location.starts, 0);
    location.precise = true;
    expect(await tracker.startTracking(), isTrue);
    expect(tracker.needsPreciseLocation, isFalse);
  });

  test('a mark under a station roof records how old its position is', () async {
    await tracker.startTracking();
    expect(tracker.isGpsStale, isTrue, reason: 'no fix yet');
    location.positions.add(_position(0, 0));
    now = at(6);
    location.positions.add(_position(60, 6));
    expect(tracker.isGpsStale, isFalse);
    // Braking under a roof: every fix is too inaccurate to accept.
    for (var s = 7; s <= 96; s++) {
      now = at(s);
      location.positions.add(_position(60, s, speed: 0, accuracy: 35));
    }
    expect(tracker.isGpsStale, isTrue);
    expect(tracker.gpsFixAge, const Duration(seconds: 90));
    final mark = tracker.markStation()!;
    expect(mark.gpsAgeS, 90);
    expect(mark.latitude, closeTo(41 + 60 / 111000, 1e-9));
    expect(mark.timestamp, '2026-01-01T00:01:36.000Z');
  });

  test('a double tap on Mark Station makes one mark', () async {
    await tracker.startTracking();
    location.positions.add(_position(0, 0));
    final first = tracker.markStation()!;
    now = at(1);
    expect(identical(tracker.markStation(), first), isTrue);
    expect(tracker.stations, hasLength(1));
    now = at(3);
    expect(tracker.markStation()!.id, 2);
    await _drain();
    expect(storage.savedStations, hasLength(2));
  });

  test(
    'stopping and restarting while standing resumes the same stop',
    () async {
      final wait = StopDetector.kMinStopDuration.inSeconds;
      await tracker.startTracking();
      for (var s = 0; s <= wait + 2; s++) {
        location.positions.add(_position(0, s, speed: 0));
      }
      final stop = tracker.currentStop!;
      tracker.stopTracking();
      await tracker.startTracking();
      for (var s = 30; s <= 30 + wait + 2; s++) {
        location.positions.add(_position(0, s, speed: 0));
      }
      expect(tracker.stations, hasLength(1));
      expect(tracker.currentStop?.id, stop.id);
      final last = 30 + wait + 2;
      for (var s = last + 1; s <= last + 4; s++) {
        location.positions.add(_position((s - last) * 10.0, s));
      }
      final departed = tracker.stations.single;
      expect(departed.timestamp, stop.timestamp);
      expect(departed.departureTimestamp, at(last + 1).toIso8601String());
    },
  );

  test('relaunch resumes distance from the furthest saved station', () async {
    storage.saved.add(
      LogRecord(
        index: 1,
        timestamp: '2026-01-01T00:00:05.000Z',
        latitude: 41,
        longitude: 69,
        speedKmh: 36,
        altitudeM: 100,
        segmentDistanceM: 50,
        totalDistanceM: 50,
      ),
    );
    storage.savedStations.add(
      const StationEvent(
        id: 1,
        type: StationEventType.manualMark,
        timestamp: '2026-01-01T00:00:07.000Z',
        latitude: 41,
        longitude: 69,
        altitudeM: 100,
        speedKmh: 36,
        totalDistanceM: 70,
      ),
    );
    final reloaded = TrackingNotifier(location, storage, now: () => now);
    addTearDown(reloaded.dispose);
    expect(reloaded.totalDistanceM, 70);
    expect(reloaded.nextThresholdM, 100);
  });

  test('a damaged stations file is reported as stations, not records', () {
    final damaged = _FakeStorage()
      ..lastError = const FormatException('bad station row')
      ..stationsDamaged = true;
    final reloaded = TrackingNotifier(location, damaged, now: () => now);
    addTearDown(reloaded.dispose);
    expect(reloaded.errorMessage, contains('stations could not be read'));
    expect(reloaded.errorMessage, contains('records are fine'));
  });
}
