import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart' as perm;

/// Wraps platform location APIs.  Exposes a high-accuracy position stream
/// and permission helpers.
class LocationService {
  StreamSubscription<Position>? _subscription;
  final _controller = StreamController<Position>.broadcast();
  final Stream<Position> Function(LocationSettings) _positionStreamFactory;
  Future<void> _cancellation = Future.value();
  int _generation = 0;
  bool _disposed = false;

  LocationService({
    Stream<Position> Function(LocationSettings)? positionStreamFactory,
  }) : _positionStreamFactory =
           positionStreamFactory ??
           ((settings) =>
               Geolocator.getPositionStream(locationSettings: settings));

  Stream<Position> get positionStream => _controller.stream;

  // ── Permission ──────────────────────────────────────────────────────

  /// Returns true when location permission is granted and services are on.
  Future<bool> requestPermission() async {
    // Check if location services are enabled at the OS level.
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return false;

    // Check / request permission.
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always;
  }

  /// Check current permission state (useful for UI).
  Future<perm.PermissionStatus> checkStatus() async {
    return await perm.Permission.locationWhenInUse.status;
  }

  /// Opens platform location settings (including macOS).
  Future<void> openSettings() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      await Geolocator.openLocationSettings();
    } else {
      await Geolocator.openAppSettings();
    }
  }

  // ── GPS stream ──────────────────────────────────────────────────────

  /// Start listening to high-accuracy position updates.
  ///
  /// Uses platform-specific [LocationSettings] so tracking keeps running while
  /// the app is in the background:
  ///   • Android → a foreground service with an ongoing notification + wake lock
  ///     (otherwise Android suspends location updates once the screen locks).
  ///   • iOS → `allowBackgroundLocationUpdates` together with the
  ///     `UIBackgroundModes: location` entry already declared in Info.plist.
  ///
  /// [distanceFilter] is in metres – 0 gives every update (we do our own
  /// distance logic in [TrackingService]).
  Future<void> startListening({int distanceFilter = 0}) async {
    if (_disposed) throw StateError('Location service has been disposed');
    final generation = ++_generation;
    _cancelSubscription();
    // Do not let an old platform cancellation tear down a newly started stream.
    await _cancellation;
    if (_disposed || generation != _generation) return;

    _subscription =
        _positionStreamFactory(_buildLocationSettings(distanceFilter)).listen(
          (position) {
            if (!_disposed && generation == _generation) {
              _controller.add(position);
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!_disposed && generation == _generation) {
              _controller.addError(error, stackTrace);
            }
          },
          onDone: () {
            if (!_disposed && generation == _generation) {
              _controller.addError(StateError('Location updates ended'));
            }
          },
        );
  }

  /// Builds [LocationSettings] tuned for continuous background tracking on the
  /// current platform.
  LocationSettings _buildLocationSettings(int distanceFilter) {
    const accuracy = LocationAccuracy.bestForNavigation;

    if (Platform.isAndroid) {
      return AndroidSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilter,
        forceLocationManager: false,
        // Poll at ~1 Hz for better curve resolution. Milestones are
        // interpolated between fixes; shorter gaps make those estimates more
        // accurate than geolocator's five-second Android default.
        intervalDuration: const Duration(seconds: 1),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Train Logger',
          notificationText: 'Logging train movement…',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    }

    if (Platform.isIOS || Platform.isMacOS) {
      return AppleSettings(
        accuracy: accuracy,
        activityType: ActivityType.otherNavigation,
        distanceFilter: distanceFilter,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
        allowBackgroundLocationUpdates: true,
      );
    }

    return LocationSettings(accuracy: accuracy, distanceFilter: distanceFilter);
  }

  void stopListening() {
    _generation++;
    _cancelSubscription();
  }

  void _cancelSubscription() {
    final subscription = _subscription;
    _subscription = null;
    if (subscription == null) return;
    _cancellation = _cancellation.then((_) => subscription.cancel()).catchError(
      (Object error, StackTrace stackTrace) {
        debugPrint('[LocationService] Error stopping GPS: $error');
      },
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    stopListening();
    _controller.close();
  }
}
