import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/providers.dart';
import 'station_list.dart';
import 'tracking_controls.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracker = ref.watch(trackingProvider);
    final records = tracker.records;
    final stations = tracker.stations;
    final currentStop = tracker.currentStop;
    final isTracking = tracker.isTracking;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Train Logger'),
        actions: [
          Builder(
            builder: (buttonContext) => IconButton(
              icon: const Icon(Icons.share),
              tooltip: 'Export CSV',
              onPressed: records.isEmpty && stations.isEmpty
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
      body: DefaultTabController(
        length: 2,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final header = SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (tracker.errorMessage != null)
                    TrackingErrorBanner(message: tracker.errorMessage!),
                  _StatsPanel(
                    speedKmh: tracker.isGpsStale ? null : tracker.speedKmh,
                    gpsStatus: gpsStatusText(tracker),
                    totalDistance: tracker.totalDistanceM,
                    nextThreshold: tracker.nextThresholdM,
                    altitude: tracker.altitudeM,
                    recordCount: records.length,
                    isTracking: isTracking,
                    elapsed: tracker.elapsed,
                    stoppedSince: currentStop?.timestamp,
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: tracker.isBusy
                                ? null
                                : () => toggleTracking(context, tracker),
                            icon: Icon(
                              isTracking ? Icons.stop : Icons.play_arrow,
                            ),
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
                              minimumSize: const Size.fromHeight(48),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: isTracking && !tracker.isBusy
                                ? () => markStation(context, tracker)
                                : null,
                            icon: const Icon(Icons.add_location_alt),
                            label: const Text('Mark Station'),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(48),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
            final lists = Column(
              children: [
                TabBar(
                  tabs: [
                    Tab(text: 'Records (${records.length})'),
                    Tab(text: 'Stations (${stations.length})'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      records.isEmpty
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
                                  curveStr =
                                      '${pct.toStringAsFixed(3)}% ($radiusStr)';
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
                                    formatClockTime(r.timestamp),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey,
                                    ),
                                  ),
                                );
                              },
                            ),
                      StationList(
                        stations: stations,
                        currentStopId: currentStop?.id,
                      ),
                    ],
                  ),
                ),
              ],
            );
            // A phone in landscape: controls on the left, lists on the right,
            // so Start/Stop and Mark Station always stay on screen.
            if (constraints.maxWidth > constraints.maxHeight &&
                constraints.maxHeight < 500) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: header),
                  const VerticalDivider(width: 1),
                  Expanded(child: lists),
                ],
              );
            }
            // Portrait: header on top. If it is ever taller than 60% of the
            // screen it scrolls instead of squeezing the lists to nothing.
            return Column(
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: constraints.maxHeight * 0.6,
                  ),
                  child: header,
                ),
                Expanded(child: lists),
              ],
            );
          },
        ),
      ),
    );
  }

  void _confirmNewSession(BuildContext context, TrackingNotifier tracker) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('New Session?'),
        content: const Text(
          'This will stop tracking and delete all current records '
          'and stations. '
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
  /// Null while GPS is weak or lost: the last speed is no longer current.
  final double? speedKmh;

  /// "Waiting for GPS…" or "Weak GPS…" while tracking without a recent fix.
  final String? gpsStatus;
  final double totalDistance;
  final double nextThreshold;
  final double altitude;
  final int recordCount;
  final bool isTracking;
  final Duration elapsed;

  /// Arrival time of the stop in progress, if the train is standing.
  final String? stoppedSince;

  const _StatsPanel({
    required this.speedKmh,
    this.gpsStatus,
    required this.totalDistance,
    required this.nextThreshold,
    required this.altitude,
    required this.recordCount,
    required this.isTracking,
    required this.elapsed,
    this.stoppedSince,
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
            speedKmh == null
                ? '— km/h'
                : '${speedKmh!.toStringAsFixed(1)} km/h',
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
          if (gpsStatus != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                gpsStatus!,
                style: TextStyle(
                  color: Colors.amber.shade900,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          if (stoppedSince != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Stopped since ${formatClockTime(stoppedSince!)}',
                style: TextStyle(
                  color: Colors.orange.shade800,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _StatChip(
                label: 'Distance',
                value: formatDistance(totalDistance),
              ),
              _StatChip(
                label: 'Next Log',
                value: formatDistance(nextThreshold),
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
