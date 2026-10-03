import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/providers.dart';
import 'tracking_controls.dart';

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
          Builder(
            builder: (buttonContext) => IconButton(
              icon: const Icon(Icons.share),
              tooltip: 'Export CSV',
              onPressed: records.isEmpty
                  ? null
                  : () {
                      final box = buttonContext.findRenderObject() as RenderBox;
                      tracker.exportCsv(
                        sharePositionOrigin:
                            box.localToGlobal(Offset.zero) & box.size,
                      );
                    },
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'new') _confirmNewSession(context, tracker);
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'new',
                enabled: !tracker.isClearing,
                child: const Text('New Session'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (tracker.errorMessage != null)
            TrackingErrorBanner(message: tracker.errorMessage!),
          _StatsPanel(
            speedKmh: tracker.speedKmh,
            totalDistance: tracker.totalDistanceM,
            nextThreshold: tracker.nextThresholdM,
            altitude: tracker.altitudeM,
            recordCount: records.length,
            isTracking: isTracking,
            elapsed: tracker.elapsed,
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: FilledButton.icon(
              onPressed: tracker.isBusy
                  ? null
                  : () => toggleTracking(context, tracker),
              icon: Icon(isTracking ? Icons.stop : Icons.play_arrow),
              label: Text(
                tracker.isStarting
                    ? 'Starting…'
                    : tracker.isClearing
                    ? 'Clearing…'
                    : isTracking
                    ? 'Stop Tracking'
                    : 'Start Tracking',
              ),
              style: FilledButton.styleFrom(
                backgroundColor: isTracking
                    ? Colors.red
                    : Colors.green.shade700,
                minimumSize: const Size(220, 48),
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: records.isEmpty
                ? const Center(
                    child: Text(
                      'No records yet.\nStart tracking and travel 50 m.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    reverse: true,
                    itemCount: records.length,
                    itemBuilder: (ctx, i) {
                      final r = records[records.length - 1 - i];

                      // Curvature display: percent + radius.
                      String curveStr;
                      if (r.curvaturePercent == null) {
                        curveStr = '—';
                      } else {
                        final pct = r.curvaturePercent!;
                        final radiusStr = r.curveRadiusM != null
                            ? 'R=${r.curveRadiusM!.toInt()}m'
                            : 'R=∞';
                        curveStr = '${pct.toStringAsFixed(3)}% ($radiusStr)';
                      }

                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Colors.blueGrey,
                          child: Text(
                            '${r.index}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        title: Text(
                          '${r.totalDistanceM.toInt()} m  •  '
                          '${r.speedKmh.toStringAsFixed(1)} km/h',
                        ),
                        subtitle: Text(
                          'Grade: ${r.gradePercent?.toStringAsFixed(2) ?? "N/A"}%  •  '
                          'Curve: $curveStr',
                        ),
                        trailing: Text(
                          _formatTimestamp(r.timestamp),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  String _formatTimestamp(String timestamp) {
    final time = DateTime.tryParse(timestamp)?.toLocal();
    if (time == null) return '—';
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}';
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
            child: const Text('Clear Session'),
          ),
        ],
      ),
    );
  }
}

class _StatsPanel extends StatelessWidget {
  final double speedKmh;
  final double totalDistance;
  final double nextThreshold;
  final double altitude;
  final int recordCount;
  final bool isTracking;
  final Duration elapsed;

  const _StatsPanel({
    required this.speedKmh,
    required this.totalDistance,
    required this.nextThreshold,
    required this.altitude,
    required this.recordCount,
    required this.isTracking,
    required this.elapsed,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      color: isTracking
          ? Colors.green.withValues(alpha: 0.08)
          : Colors.grey.withValues(alpha: 0.06),
      child: Column(
        children: [
          Text(
            '${speedKmh.toStringAsFixed(1)} km/h',
            style: Theme.of(
              context,
            ).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          // ── Elapsed time ──────────────────────────────────
          Text(
            _formatDuration(elapsed),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: isTracking ? Colors.green.shade700 : Colors.grey,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
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
              _StatChip(label: 'Records', value: '$recordCount'),
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

  /// Format a [Duration] as HH:MM:SS.
  String _formatDuration(Duration d) {
    final hours = d.inHours.toString().padLeft(2, '0');
    final minutes = (d.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
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
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }
}
