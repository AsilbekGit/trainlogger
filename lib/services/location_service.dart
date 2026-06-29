import 'dart:async';
import 'dart:io' show Platform;
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart'
    as perm;

/// Wraps platform location APIs.  Exposes a high-accuracy position stream
/// and permission helpers.
class LocationService {
  StreamSubscription<Position>? _subscription;
  final _controller = StreamController<Position>.broadcast();

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

  /// Opens iOS Settings so the user can grant permission manually.
  Future<void> openSettings() async {
    await perm.openAppSettings();
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
  void startListening({int distanceFilter = 0}) {
    _subscription?.cancel();

    _subscription = Geolocator.getPositionStream(
      locationSettings: _buildLocationSettings(distanceFilter),
    ).listen(
      (pos) => _controller.add(pos),
      onError: (e) => _controller.addError(e),
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
        // Poll at ~1 Hz.  geolocator's Android default is 5 s, which at train
        // speed means a single fix can jump well past one 50 m mark and emit
        // several records at the same coordinate (degenerate curvature/grade).
        // 1 Hz keeps most fixes under 50 m below ~180 km/h, matching iOS.
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

    return LocationSettings(
      accuracy: accuracy,
      distanceFilter: distanceFilter,
    );
  }

  void stopListening() {
    _subscription?.cancel();
    _subscription = null;
  }

  void dispose() {
    stopListening();
    _controller.close();
  }
}
