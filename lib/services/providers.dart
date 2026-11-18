import 'dart:async';
import 'dart:collection';
import 'dart:math' show max;
import 'dart:ui' show Rect;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import '../models/log_record.dart';
import '../models/station_event.dart';
import '../models/tracking_session.dart';
import '../services/location_service.dart';
import '../services/stop_detector.dart';
import '../services/tracking_service.dart';
import '../services/storage_service.dart';
import '../services/export_service.dart';

// ── Singletons ──────────────────────────────────────────────────────

final locationServiceProvider = Provider<LocationService>((ref) {
  final svc = LocationService();
  ref.onDispose(svc.dispose);
  return svc;
});

final storageServiceProvider = Provider<StorageService>((ref) {
  // Must be overridden in main() with an initialised StorageService.
  throw UnimplementedError(
    'storageServiceProvider must be overridden in main()',
  );
});

/// Central controller for GPS, session state, persistence and UI updates.
class TrackingNotifier extends ChangeNotifier {
  final LocationService _locationSvc;
  final StorageService _storageSvc;
  final DateTime Function() _now;

  final TrackingSession session = TrackingSession();
  late final TrackingService _trackingSvc;
  final StopDetector _stopDetector = StopDetector();

  StreamSubscription<Position>? _gpsSub;
  Timer? _elapsedTimer;
  Future<bool>? _startFuture;
  Future<void>? _clearFuture;
  bool _disposed = false;
  int _operationId = 0;
  int _sessionRevision = 0;
  Duration _completedElapsed = Duration.zero;
  DateTime? _activeSince;
  List<LogRecord> _records = [];
  List<StationEvent> _stations = [];
  int _lastStationId = 0;

  /// The automatic stop the train is standing at, until it departs.
  int? _activeStopId;

  /// Device time when the tracker last accepted a GPS fix. The device clock is
  /// used rather than the fix's own timestamp, which some phones report off.
  DateTime? _lastFixAt;

  /// The previous Mark Station result, so a double tap does not mark twice.
  StationEvent? _lastMark;
  DateTime? _lastMarkAt;

  /// No accepted fix for this long means GPS is weak or lost.
  static const Duration kStaleFix = Duration(seconds: 10);

  /// Taps on Mark Station closer together than this are one mark.
  static const Duration kMarkDebounce = Duration(seconds: 2);
  LatLng? currentLatLng;
  String? errorMessage;
  bool needsLocationPermission = false;

  /// Permission was granted only as approximate location, which is too coarse
  /// for any fix to pass the 20 m accuracy filter.
  bool needsPreciseLocation = false;
  bool isStarting = false;
  bool isClearing = false;

  TrackingNotifier(
    this._locationSvc,
    this._storageSvc, {
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _trackingSvc = TrackingService(session);
    try {
      _records = _storageSvc.getAll();
      _stations = List.of(_storageSvc.getStations());
      for (final station in _stations) {
        if (station.id > _lastStationId) _lastStationId = station.id;
      }
      // Only completed milestones are persisted. GPS history and active time
      // start afresh after relaunch; never infer movement across that gap.
      if (_records.isNotEmpty) {
        session.recordIndex = _records.last.index;
        session.totalDistanceMeters = _records.last.totalDistanceM;
        session.nextLogThresholdMeters =
            session.totalDistanceMeters + TrackingService.kLogIntervalM;
      }
      // A station saved after the last 50 m record is further along; resuming
      // from the record alone would make the next station's distance go back.
      final furthest = _stations.fold<double>(
        session.totalDistanceMeters,
        (m, s) => max(m, s.totalDistanceM),
      );
      if (furthest < session.nextLogThresholdMeters) {
        session.totalDistanceMeters = furthest;
      }
      if (_storageSvc.lastError != null) {
        debugPrint('[TrackingNotifier] Load warning: ${_storageSvc.lastError}');
        if (_storageSvc.recordsDamaged) {
          errorMessage = _records.isEmpty
              ? 'Saved records could not be fully loaded. Existing files were preserved.'
              : 'Some saved records could not be read. Recovered records are '
                    'available; export them before starting a new session.';
        } else if (_storageSvc.stationsDamaged) {
          errorMessage =
              'Some saved stations could not be read. Your records are fine, '
              'and the original stations file was preserved.';
        } else {
          // Loaded fine, but an older save file could not be converted yet.
          errorMessage =
              'Your saved trip was loaded, but its file could not be updated '
              'yet. Export it before starting a new session.';
        }
      }
    } catch (error) {
      debugPrint('[TrackingNotifier] Load error: $error');
      errorMessage =
          'Saved records could not be loaded. Existing files were preserved.';
    }
  }

  // Read-only views, not copies: these are read on every GPS fix and every
  // one-second tick, and a long trip has tens of thousands of records.
  List<LogRecord> get records => UnmodifiableListView(_records);

  /// Automatic stops and manual station marks, oldest first.
  List<StationEvent> get stations => UnmodifiableListView(_stations);

  /// Time since the last accepted GPS fix while tracking; null before the
  /// first one or when not tracking.
  Duration? get gpsFixAge {
    final at = _lastFixAt;
    if (at == null || !isTracking) return null;
    final age = _now().difference(at);
    return age.isNegative ? Duration.zero : age;
  }

  /// Tracking, but no usable fix recently (or none yet): live speed and
  /// position are not current.
  bool get isGpsStale {
    if (!isTracking) return false;
    final age = gpsFixAge;
    return age == null || age >= kStaleFix;
  }

  /// The automatic stop in progress, or null while moving.
  StationEvent? get currentStop {
    final id = _activeStopId;
    if (id == null) return null;
    for (var i = _stations.length - 1; i >= 0; i--) {
      if (_stations[i].id == id) return _stations[i];
    }
    return null;
  }

  bool get isTracking => session.isTracking;
  bool get isBusy => isStarting || isClearing;
  double get speedKmh => session.currentSpeedKmh;
  double get totalDistanceM => session.totalDistanceMeters;
  double get nextThresholdM => session.nextLogThresholdMeters;
  double get altitudeM => session.currentAltitude;
  List<LatLng> get polyline => List.unmodifiable(session.polylinePoints);

  /// Disconnected routes after stops or GPS loss, without invented connectors.
  List<List<LatLng>> get routeSegments {
    final points = session.polylinePoints;
    final segments = <List<LatLng>>[];
    var start = 0;
    for (final end in session.polylineBreakIndices) {
      if (end > start && end <= points.length) {
        segments.add(List.unmodifiable(points.sublist(start, end)));
        start = end;
      }
    }
    if (start < points.length) {
      segments.add(List.unmodifiable(points.sublist(start)));
    }
    return List.unmodifiable(segments);
  }

  /// Active tracking time, frozen while stopped and resumed on the next start.
  Duration get elapsed {
    final activeSince = _activeSince;
    if (activeSince == null) return _completedElapsed;
    final active = _now().difference(activeSince);
    return _completedElapsed + (active.isNegative ? Duration.zero : active);
  }

  // ── Start / Stop ──────────────────────────────────────────────

  Future<bool> startTracking() {
    if (_disposed || isClearing) return Future.value(false);
    // Both tabs share this controller. Repeated taps must not request multiple
    // permissions or leave duplicate subscriptions processing every GPS fix.
    final pending = _startFuture;
    if (pending != null) return pending;
    if (isTracking) return Future.value(true);
    final result = Completer<bool>();
    _startFuture = result.future;
    unawaited(_startTracking(++_operationId).then(result.complete));
    return result.future;
  }

  Future<bool> _startTracking(int operation) async {
    isStarting = true;
    needsLocationPermission = false;
    needsPreciseLocation = false;
    errorMessage = null;
    notifyListeners();
    try {
      final permitted = await _locationSvc.requestPermission();
      if (_disposed || operation != _operationId) return false;
      if (!permitted) {
        needsLocationPermission = true;
        return false;
      }
      final precise = await _locationSvc.hasPreciseLocation();
      if (_disposed || operation != _operationId) return false;
      if (!precise) {
        needsPreciseLocation = true;
        return false;
      }

      session.isTracking = true;
      _activeSince = _now();
      session.startTime ??= _activeSince;
      _gpsSub = _locationSvc.positionStream.listen(
        _onPosition,
        onError: _onPositionError,
        onDone: _onPositionDone,
      );
      // Subscribe first so a position/error emitted during start is not lost.
      await _locationSvc.startListening();
      if (_disposed || !isTracking || operation != _operationId) return false;
      _elapsedTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => notifyListeners(),
      );
      return true;
    } catch (error) {
      if (!_disposed && operation == _operationId) {
        debugPrint('[TrackingNotifier] GPS start error: $error');
        errorMessage =
            'Unable to start location tracking. '
            'Check location access and try again.';
        stopTracking();
      }
      return false;
    } finally {
      _startFuture = null;
      isStarting = false;
      if (!_disposed) notifyListeners();
    }
  }

  void stopTracking() {
    if (_disposed) return;
    // Invalidate any permission request that is still awaiting the OS dialog.
    _operationId++;
    _completedElapsed = elapsed;
    _activeSince = null;
    session.isTracking = false;
    _gpsSub?.cancel();
    _gpsSub = null;
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    _locationSvc.stopListening();
    // Movement while stopped must not become distance/grade on resume.
    _trackingSvc.resetPositionHistory();
    // A stop in progress keeps its arrival; its departure stays unknown.
    _stopDetector.reset();
    _activeStopId = null;
    _lastFixAt = null;
    notifyListeners();
  }

  void _onPosition(Position pos) {
    if (_disposed || !isTracking) return;
    final previousFix = _trackingSvc.currentPoint;
    final newRecords = _trackingSvc.processPosition(pos);
    final fix = _trackingSvc.currentPoint;
    // Use the validated fix, not a rejected GPS outlier, for the map marker.
    currentLatLng = fix?.latLng ?? currentLatLng;
    if (newRecords.isNotEmpty) {
      _records.addAll(newRecords);
      final revision = _sessionRevision;
      unawaited(_persist(() => _storageSvc.addAll(newRecords), revision));
    }
    // Only fixes the tracker accepted (a new current point) feed stop
    // detection. The raw speed is passed so "unavailable" is not read as 0.
    if (fix != null && !identical(fix, previousFix)) {
      _lastFixAt = _now();
      final stop = _stopDetector.addFix(fix, pos.speed);
      if (stop != null) _onStop(stop);
    }
    notifyListeners();
  }

  void _onStop(DetectedStop stop) {
    final departure = stop.departure;
    if (departure == null) {
      final open = _openStopNear(stop);
      if (open != null) {
        // Still the same stop, interrupted by Stop/Start or a relaunch.
        _activeStopId = open.id;
        return;
      }
      final station = StationEvent(
        id: ++_lastStationId,
        type: StationEventType.autoStop,
        timestamp: stop.arrival.toUtc().toIso8601String(),
        latitude: stop.latitude,
        longitude: stop.longitude,
        altitudeM: stop.altitudeM,
        speedKmh: 0,
        totalDistanceM: session.totalDistanceMeters,
      );
      _activeStopId = station.id;
      _saveStation(station);
      return;
    }
    final arrived = currentStop;
    _activeStopId = null;
    if (arrived == null) return;
    // The position is refined with every fix taken while standing.
    _saveStation(
      arrived.copyWith(
        departureTimestamp: departure.toUtc().toIso8601String(),
        latitude: stop.latitude,
        longitude: stop.longitude,
        altitudeM: stop.altitudeM,
      ),
    );
  }

  /// The latest automatic stop if it never got a departure, is where the
  /// train is standing now and the train has not logged distance since.
  StationEvent? _openStopNear(DetectedStop stop) {
    StationEvent? last;
    for (var i = _stations.length - 1; i >= 0; i--) {
      if (_stations[i].type == StationEventType.autoStop) {
        last = _stations[i];
        break;
      }
    }
    if (last == null || last.departureTimestamp != null) return null;
    final arrivedAt = DateTime.tryParse(last.timestamp);
    if (arrivedAt == null ||
        stop.arrival.difference(arrivedAt) > const Duration(hours: 1)) {
      return null;
    }
    if (_records.isNotEmpty) {
      final lastRecordAt = DateTime.tryParse(_records.last.timestamp);
      if (lastRecordAt != null && lastRecordAt.isAfter(arrivedAt)) return null;
    }
    final metres = TrackingService.geodesicDistance(
      last.latitude,
      last.longitude,
      stop.latitude,
      stop.longitude,
    );
    return metres <= StopDetector.kMaxStopDriftM ? last : null;
  }

  /// Save the latest accepted GPS position as a station.
  ///
  /// Returns null without saving when not tracking or before the first fix.
  /// [StationEvent.gpsAgeS] says how old that fix is: under a station roof
  /// GPS can be rejected for a while, leaving the position and speed behind.
  /// A second tap within [kMarkDebounce] returns the first mark.
  StationEvent? markStation() {
    if (_disposed || !isTracking) return null;
    final fix = _trackingSvc.currentPoint;
    final fixAt = _lastFixAt;
    if (fix == null || fixAt == null) return null;
    final now = _now();
    final previous = _lastMark;
    final previousAt = _lastMarkAt;
    if (previous != null &&
        previousAt != null &&
        now.difference(previousAt) < kMarkDebounce &&
        _stations.any((s) => s.id == previous.id)) {
      return previous;
    }
    final ageMs = now.difference(fixAt).inMilliseconds;
    final station = StationEvent(
      id: ++_lastStationId,
      type: StationEventType.manualMark,
      timestamp: now.toUtc().toIso8601String(),
      latitude: fix.lat,
      longitude: fix.lon,
      altitudeM: fix.altitude,
      speedKmh: session.currentSpeedKmh,
      totalDistanceM: session.totalDistanceMeters,
      gpsAgeS: ageMs < 0 ? 0 : ageMs / 1000,
    );
    _lastMark = station;
    _lastMarkAt = now;
    _saveStation(station);
    notifyListeners();
    return station;
  }

  void _saveStation(StationEvent station) {
    final index = _stations.indexWhere((s) => s.id == station.id);
    if (index >= 0) {
      _stations[index] = station;
    } else {
      _stations.add(station);
    }
    final revision = _sessionRevision;
    unawaited(_persist(() => _storageSvc.saveStation(station), revision));
  }

  Future<void> _persist(Future<void> Function() save, int revision) async {
    try {
      await save();
    } catch (error) {
      if (_disposed || revision != _sessionRevision) return;
      debugPrint('[TrackingNotifier] Save error: $error');
      errorMessage =
          'Records could not be saved. Tracking has stopped; '
          'export your records before closing the app.';
      stopTracking();
    }
  }

  void _onPositionError(Object error, StackTrace stackTrace) {
    if (_disposed || !isTracking) return;
    debugPrint('[TrackingNotifier] GPS error: $error');
    errorMessage =
        'Location updates stopped. '
        'Check location access and start tracking again.';
    stopTracking();
  }

  void _onPositionDone() {
    if (_disposed || !isTracking) return;
    errorMessage = 'Location updates ended. Start tracking to reconnect.';
    stopTracking();
  }

  // ── Session management ────────────────────────────────────────

  Future<void> newSession() {
    if (_disposed) return Future.value();
    final pending = _clearFuture;
    if (pending != null) return pending;
    final result = Completer<void>();
    _clearFuture = result.future;
    unawaited(_newSession().then(result.complete));
    return result.future;
  }

  Future<void> _newSession() async {
    isClearing = true;
    stopTracking();
    try {
      // Preserve the current session and exportable records if deletion fails.
      // Starting is disabled until the queued disk operation has completed.
      await _storageSvc.clearAll();
      if (_disposed) return;
      _sessionRevision++;
      session.reset();
      _trackingSvc.resetPositionHistory();
      _records.clear();
      _stations.clear();
      _lastStationId = 0;
      _lastMark = null;
      _lastMarkAt = null;
      _completedElapsed = Duration.zero;
      currentLatLng = null;
      errorMessage = null;
      needsLocationPermission = false;
      needsPreciseLocation = false;
    } catch (error) {
      debugPrint('[TrackingNotifier] Clear error: $error');
      if (!_disposed) {
        errorMessage =
            'Could not clear the session. Your current records were kept.';
      }
    } finally {
      _clearFuture = null;
      isClearing = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> exportCsv({Rect? sharePositionOrigin}) async {
    try {
      // Snapshots: the trip may keep growing while the share sheet opens.
      await ExportService.exportAndShare(
        List.of(_records),
        stations: List.of(_stations),
        sharePositionOrigin: sharePositionOrigin,
      );
    } catch (error) {
      if (_disposed) return;
      debugPrint('[TrackingNotifier] Export error: $error');
      errorMessage = 'Could not export records. Please try again.';
      notifyListeners();
    }
  }

  Future<void> openSettings() async {
    try {
      await _locationSvc.openSettings();
    } catch (error) {
      if (_disposed) return;
      debugPrint('[TrackingNotifier] Settings error: $error');
      errorMessage =
          'Could not open Settings. '
          'Open device Settings to check location access.';
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _operationId++;
    _disposed = true;
    _elapsedTimer?.cancel();
    _gpsSub?.cancel();
    _locationSvc.stopListening();
    super.dispose();
  }
}

final trackingProvider = ChangeNotifierProvider<TrackingNotifier>((ref) {
  final loc = ref.watch(locationServiceProvider);
  final store = ref.watch(storageServiceProvider);
  return TrackingNotifier(loc, store);
});
