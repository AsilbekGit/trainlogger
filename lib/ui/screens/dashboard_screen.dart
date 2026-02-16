import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/providers.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracker = ref.watch(trackingProvider);
    final records = tracker.records;
    final isTracking = tracker.isTracking;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Train Logger'),
        actions: [
          // Export CSV
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'Export CSV',
            onPressed: records.isEmpty
                ? null
                : () => tracker.exportCsv(),
          ),
          // New session
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'new') {
                _confirmNewSession(context, tracker);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'new', child: Text('New Session')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Live stats panel ──────────────────────────────────
          _StatsPanel(
            speedKmh: tracker.speedKmh,
            totalDistance: tracker.totalDistanceM,
            nextThreshold: tracker.nextThresholdM,
            altitude: tracker.altitudeM,
            recordCount: records.length,
            isTracking: isTracking,
          ),

          const Divider(height: 1),

          // ── Start / Stop button ───────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: FilledButton.icon(
              onPressed: () => _toggleTracking(context, ref),
              icon: Icon(isTracking ? Icons.stop : Icons.play_arrow),
              label: Text(isTracking ? 'Stop Tracking' : 'Start Tracking'),
              style: FilledButton.styleFrom(
                backgroundColor:
                    isTracking ? Colors.red : Colors.green.shade700,
                minimumSize: const Size(220, 48),
              ),
            ),
          ),

          const Divider(height: 1),

          // ── Record list ───────────────────────────────────────
          Expanded(
            child: records.isEmpty
                ? const Center(
                    child: Text(
                      'No records yet.\nStart tracking and travel 100 m.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    reverse: true, // newest at top
                    itemCount: records.length,
                    itemBuilder: (ctx, i) {
                      final r = records[records.length - 1 - i];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Colors.blueGrey,
                          child: Text(
                            '${r.index}',
                            style: const TextStyle(
                                color: Colors.white, fontSize: 13),
                          ),
                        ),
                        title: Text(
                          '${r.totalDistanceM.toInt()} m  •  '
                          '${r.speedKmh.toStringAsFixed(1)} km/h',
                        ),
                        subtitle: Text(
                          'Grade: ${r.gradePercent?.toStringAsFixed(2) ?? "N/A"} %  •  '
                          'Alt: ${r.altitudeM.toStringAsFixed(1)} m',
                        ),
                        trailing: Text(
                          r.timestamp.substring(11, 19), // HH:mm:ss
                          style: const TextStyle(
                              fontSize: 12, color: Colors.grey),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleTracking(BuildContext context, WidgetRef ref) async {
    final tracker = ref.read(trackingProvider);
    if (tracker.isTracking) {
      tracker.stopTracking();
    } else {
      final ok = await tracker.startTracking();
      if (!ok && context.mounted) {
        _showPermissionDialog(context, tracker);
      }
    }
  }

  void _showPermissionDialog(
      BuildContext context, TrackingNotifier tracker) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Location Permission Required'),
        content: const Text(
          'Please enable location access in Settings to use the tracker.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              tracker.openSettings();
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  void _confirmNewSession(BuildContext context, TrackingNotifier tracker) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('New Session?'),
        content: const Text(
          'This will stop tracking and delete all current records. '
          'Export first if you need the data.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              tracker.newSession();
            },
            child: const Text('Clear & Start New'),
          ),
        ],
      ),
    );
  }
}

// ── Stats panel widget ──────────────────────────────────────────────

class _StatsPanel extends StatelessWidget {
  final double speedKmh;
  final double totalDistance;
  final double nextThreshold;
  final double altitude;
  final int recordCount;
  final bool isTracking;

  const _StatsPanel({
    required this.speedKmh,
    required this.totalDistance,
    required this.nextThreshold,
    required this.altitude,
    required this.recordCount,
    required this.isTracking,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      color: isTracking
          ? Colors.green.withOpacity(0.08)
          : Colors.grey.withOpacity(0.06),
      child: Column(
        children: [
          // Big speed display
          Text(
            '${speedKmh.toStringAsFixed(1)} km/h',
            style: Theme.of(context)
                .textTheme
                .displaySmall
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _StatChip(
                label: 'Distance',
                value: _formatDistance(totalDistance),
              ),
              _StatChip(
                label: 'Next Log',
                value: _formatDistance(nextThreshold),
              ),
              _StatChip(
                label: 'Altitude',
                value: '${altitude.toStringAsFixed(1)} m',
              ),
              _StatChip(
                label: 'Records',
                value: '$recordCount',
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatDistance(double m) {
    if (m >= 1000) return '${(m / 1000).toStringAsFixed(2)} km';
    return '${m.toInt()} m';
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  const _StatChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
        const SizedBox(height: 2),
        Text(label,
            style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }
}
