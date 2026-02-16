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
///   appended when ≥ 10 m from the previous vertex).
/// - A green marker shows the **start** of the route.
/// - A red train icon marker shows the **current** GPS position.
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

    // Start point = first point in polyline (if any).
    final LatLng? startPoint =
        polyline.isNotEmpty ? polyline.first : null;

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

              // ── Route polyline (blue, thick, semi-transparent) ──
              if (polyline.length >= 2)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: polyline,
                      color: Colors.blue.shade700,
                      strokeWidth: 5.0,
                      borderColor: Colors.blue.shade900.withOpacity(0.4),
                      borderStrokeWidth: 1.5,
                    ),
                  ],
                ),

              // ── Markers: start + current position ───────────────
              MarkerLayer(
                markers: [
                  // Green circle at start of route.
                  if (startPoint != null)
                    Marker(
                      point: startPoint,
                      width: 28,
                      height: 28,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.green,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2.5),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black26,
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: const Center(
                          child: Icon(Icons.flag, color: Colors.white, size: 14),
                        ),
                      ),
                    ),

                  // Red train icon at current position.
                  if (current != null)
                    Marker(
                      point: current,
                      width: 44,
                      height: 44,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.red,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2.5),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black38,
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: const Center(
                          child:
                              Icon(Icons.train, color: Colors.white, size: 22),
                        ),
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
              recordCount: tracker.records.length,
            ),
          ),

          // ── Legend ───────────────────────────────────────────
          if (polyline.isNotEmpty)
            Positioned(
              bottom: 80,
              left: 16,
              child: Card(
                elevation: 3,
                color: Colors.white.withOpacity(0.92),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _legendItem(Colors.green, 'Start'),
                      const SizedBox(height: 4),
                      _legendItem(Colors.blue.shade700, 'Path'),
                      const SizedBox(height: 4),
                      _legendItem(Colors.red, 'Current'),
                    ],
                  ),
                ),
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

          // ── Fit-route FAB (zoom to show entire path) ────────
          if (polyline.length >= 2)
            Positioned(
              bottom: 72,
              right: 16,
              child: FloatingActionButton.small(
                heroTag: 'fitroute',
                tooltip: 'Fit entire route',
                onPressed: () {
                  _fitRoute(polyline);
                },
                backgroundColor: Colors.blueGrey,
                child: const Icon(Icons.zoom_out_map, color: Colors.white),
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

  /// Zoom the map to fit the entire route polyline with padding.
  void _fitRoute(List<LatLng> points) {
    if (points.length < 2) return;

    double minLat = points.first.latitude;
    double maxLat = points.first.latitude;
    double minLng = points.first.longitude;
    double maxLng = points.first.longitude;

    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }

    final bounds = LatLngBounds(
      LatLng(minLat, minLng),
      LatLng(maxLat, maxLng),
    );

    _mapCtrl.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: const EdgeInsets.all(60),
      ),
    );

    setState(() => _autoFollow = false);
  }

  Widget _legendItem(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    );
  }
}

// ── Map overlay panel ───────────────────────────────────────────────

class _MapOverlay extends StatelessWidget {
  final double speedKmh;
  final double totalDistance;
  final double nextThreshold;
  final bool isTracking;
  final int recordCount;

  const _MapOverlay({
    required this.speedKmh,
    required this.totalDistance,
    required this.nextThreshold,
    required this.isTracking,
    required this.recordCount,
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
            _item('Logs', '$recordCount'),
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