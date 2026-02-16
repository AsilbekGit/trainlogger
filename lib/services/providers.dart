import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import '../models/log_record.dart';
import '../models/tracking_session.dart';
import '../services/location_service.dart';
import '../services/tracking_service.dart';
import '../services/storage_service.dart';
import '../services/export_service.dart';

// ── Singletons ──────────────────────────────────────────────────────

final locationServiceProvider = Provider<LocationService>((ref) {
  final svc = LocationService();
  ref.onDispose(() => svc.dispose());
  return svc;
});

final storageServiceProvider = Provider<StorageService>((ref) {
  return StorageService();
});

// ── Tracking Notifier ───────────────────────────────────────────────

/// Central controller that manages the tracking session, pipes GPS into
/// [TrackingService], and notifies listeners on every state change.
class TrackingNotifier extends ChangeNotifier {
  final LocationService _locationSvc;
  final StorageService _storageSvc;

  final TrackingSession session = TrackingSession();
  late final TrackingService _trackingSvc;

  StreamSubscription<Position>? _gpsSub;
  List<LogRecord> _records = [];
  LatLng? currentLatLng;

  TrackingNotifier(this._locationSvc, this._storageSvc) {
    _trackingSvc = TrackingService(session);
    // Load previously persisted records.
    _records = _storageSvc.getAll();
    // Restore session counters if resuming.
    if (_records.isNotEmpty) {
      session.recordIndex = _records.last.index;
      session.totalDistanceMeters = _records.last.totalDistanceM;
      session.nextLogThresholdMeters =
          session.totalDistanceMeters + TrackingService.kLogIntervalM;
    }
  }

  List<LogRecord> get records => List.unmodifiable(_records);
  bool get isTracking => session.isTracking;
  double get speedKmh => session.currentSpeedKmh;
  double get totalDistanceM => session.totalDistanceMeters;
  double get nextThresholdM => session.nextLogThresholdMeters;
  double get altitudeM => session.currentAltitude;
  List<LatLng> get polyline => session.polylinePoints;

  // ── Start / Stop ──────────────────────────────────────────────

  Future<bool> startTracking() async {
    final ok = await _locationSvc.requestPermission();
    if (!ok) return false;

    _locationSvc.startListening();
    _gpsSub = _locationSvc.positionStream.listen(_onPosition);
    session.isTracking = true;
    notifyListeners();
    return true;
  }

  void stopTracking() {
    _gpsSub?.cancel();
    _gpsSub = null;
    _locationSvc.stopListening();
    session.isTracking = false;
    notifyListeners();
  }

  // ── Process each GPS fix ──────────────────────────────────────

  void _onPosition(Position pos) {
    currentLatLng = LatLng(pos.latitude, pos.longitude);

    final newRecords = _trackingSvc.processPosition(pos);
    if (newRecords.isNotEmpty) {
      _records.addAll(newRecords);
      _storageSvc.addAll(newRecords);
    }

    notifyListeners(); // Triggers UI rebuild for speed / polyline / records.
  }

  // ── Session management ────────────────────────────────────────

  Future<void> newSession() async {
    stopTracking();
    session.reset();
    _records.clear();
    await _storageSvc.clearAll();
    currentLatLng = null;
    notifyListeners();
  }

  Future<void> exportCsv() async {
    await ExportService.exportAndShare(_records);
  }
}

final trackingProvider =
    ChangeNotifierProvider<TrackingNotifier>((ref) {
  final loc = ref.watch(locationServiceProvider);
  final store = ref.watch(storageServiceProvider);
  return TrackingNotifier(loc, store);
});
