import 'dart:async';
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
  /// [distanceFilter] is in metres – 0 gives every update.
  void startListening({int distanceFilter = 0}) {
    _subscription?.cancel();

    const settings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0, // we do our own distance logic
    );

    _subscription = Geolocator.getPositionStream(
      locationSettings: settings,
    ).listen(
      (pos) => _controller.add(pos),
      onError: (e) => _controller.addError(e),
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
