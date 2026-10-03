import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:train_logger/models/log_record.dart';
import 'package:train_logger/services/location_service.dart';
import 'package:train_logger/services/providers.dart';
import 'package:train_logger/services/storage_service.dart';

class _FakeLocation extends LocationService {
  final positions = StreamController<Position>.broadcast(sync: true);
  Completer<bool>? permission;
  bool permissionGranted = true;
  Object? startError;
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
  Future<void> clearAll() async {
    await clearGate?.future;
    if (failClear) throw StateError('read-only storage');
    saved.clear();
  }
}

Position _position(double northMeters, int second, {double accuracy = 5}) {
  return Position(
    latitude: 41 + northMeters / 111000,
    longitude: 69,
    timestamp: DateTime.utc(2026, 1, 1).add(Duration(seconds: second)),
    accuracy: accuracy,
    altitude: 100,
    altitudeAccuracy: 5,
    heading: 0,
    headingAccuracy: 0,
    speed: 10,
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
}
