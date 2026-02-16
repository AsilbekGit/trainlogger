import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import '../../services/providers.dart';

/// Live map tab.
///
/// **Implementation notes (flutter_map + OpenStreetMap):**
/// - Uses `TileLayer` pointed at the standard OSM raster tile server.
/// - No API key is needed.
/// - The polyline layer draws the train's path from the `polylinePoints`
///   list that is already decimated in [TrackingService] (only a point is
///   appended when ≥ 8 m from the previous vertex, keeping the vertex
///   count manageable).
/// - A `MarkerLayer` shows a single marker at the current GPS position.
/// - When *auto-follow* is enabled (default), the `MapController` pans
///   the camera to the latest position on every GPS tick.
class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  final MapController _mapCtrl = MapController();
  bool _autoFollow = true;

  // Default center (Tashkent) used before we get the first fix.
  static const _defaultCenter = LatLng(41.2995, 69.2401);

  @override
  Widget build(BuildContext context) {
    final tracker = ref.watch(trackingProvider);
    final polyline = tracker.polyline;
    final current = tracker.currentLatLng;

    // Auto-follow: pan map to current position.
    if (_autoFollow && current != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          _mapCtrl.move(current, _mapCtrl.camera.zoom);
        } catch (_) {}
      });
    }

    return Scaffold(
      body: Stack(
        children: [
          // ── Map ─────────────────────────────────────────────
          FlutterMap(
            mapController: _mapCtrl,
            options: MapOptions(
              initialCenter: current ?? _defaultCenter,
              initialZoom: 14,
              onPositionChanged: (pos, hasGesture) {
                // User panned manually → disable auto-follow.
                if (hasGesture) setState(() => _autoFollow = false);
              },
            ),
            children: [
              // OSM raster tiles (no API key).
              TileLayer(
                urlTemplate:
                    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.trainlogger',
              ),

              // Polyline path.
              if (polyline.length >= 2)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: polyline,
                      color: Colors.blue,
                      strokeWidth: 4,
                    ),
                  ],
                ),

              // Current position marker.
              if (current != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: current,
                      width: 40,
                      height: 40,
                      child: const Icon(
                        Icons.train,
                        color: Colors.red,
                        size: 36,
                      ),
                    ),
                  ],
                ),
            ],
          ),

          // ── Overlay stats ───────────────────────────────────
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 12,
            right: 12,
            child: _MapOverlay(
              speedKmh: tracker.speedKmh,
              totalDistance: tracker.totalDistanceM,
              nextThreshold: tracker.nextThresholdM,
              isTracking: tracker.isTracking,
            ),
          ),

          // ── Auto-follow FAB ─────────────────────────────────
          Positioned(
            bottom: 24,
            right: 16,
            child: FloatingActionButton.small(
              heroTag: 'autofollow',
              onPressed: () {
                setState(() => _autoFollow = !_autoFollow);
                if (_autoFollow && current != null) {
                  _mapCtrl.move(current, _mapCtrl.camera.zoom);
                }
              },
              backgroundColor:
                  _autoFollow ? Colors.blue : Colors.grey.shade400,
              child: Icon(
                _autoFollow ? Icons.my_location : Icons.location_searching,
                color: Colors.white,
              ),
            ),
          ),

          // ── Start / Stop on map ─────────────────────────────
          Positioned(
            bottom: 24,
            left: 16,
            child: FloatingActionButton.extended(
              heroTag: 'startstop',
              onPressed: () async {
                final t = ref.read(trackingProvider);
                if (t.isTracking) {
                  t.stopTracking();
                } else {
                  await t.startTracking();
                }
              },
              backgroundColor:
                  tracker.isTracking ? Colors.red : Colors.green.shade700,
              icon: Icon(
                tracker.isTracking ? Icons.stop : Icons.play_arrow,
                color: Colors.white,
              ),
              label: Text(
                tracker.isTracking ? 'Stop' : 'Start',
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Map overlay panel ───────────────────────────────────────────────

class _MapOverlay extends StatelessWidget {
  final double speedKmh;
  final double totalDistance;
  final double nextThreshold;
  final bool isTracking;

  const _MapOverlay({
    required this.speedKmh,
    required this.totalDistance,
    required this.nextThreshold,
    required this.isTracking,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      color: Colors.white.withOpacity(0.92),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _item('Speed', '${speedKmh.toStringAsFixed(1)} km/h'),
            _item('Dist', _fmt(totalDistance)),
            _item('Next', _fmt(nextThreshold)),
            Icon(
              isTracking ? Icons.fiber_manual_record : Icons.stop_circle,
              color: isTracking ? Colors.red : Colors.grey,
              size: 16,
            ),
          ],
        ),
      ),
    );
  }

  Widget _item(String label, String value) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value,
              style:
                  const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
          Text(label,
              style: const TextStyle(fontSize: 10, color: Colors.grey)),
        ],
      );

  String _fmt(double m) {
    if (m >= 1000) return '${(m / 1000).toStringAsFixed(2)} km';
    return '${m.toInt()} m';
  }
}
