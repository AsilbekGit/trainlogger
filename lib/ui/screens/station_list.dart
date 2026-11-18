import 'package:flutter/material.dart';
import '../../models/station_event.dart';
import '../../services/providers.dart';
import '../../services/stop_detector.dart';
import 'tracking_controls.dart';

/// Marker colour shared by the list and the map.
Color stationColor(StationEventType type) => switch (type) {
  StationEventType.autoStop => Colors.orange.shade800,
  StationEventType.manualMark => Colors.deepPurple,
};

IconData stationIcon(StationEventType type) => switch (type) {
  StationEventType.autoStop => Icons.pause,
  StationEventType.manualMark => Icons.place,
};

/// Stops and station marks, newest at the bottom like the records list.
class StationList extends StatelessWidget {
  final List<StationEvent> stations;

  /// Id of the stop the train is standing at now, if any.
  final int? currentStopId;

  const StationList({super.key, required this.stations, this.currentStopId});

  @override
  Widget build(BuildContext context) {
    if (stations.isEmpty) {
      final seconds = StopDetector.kMinStopDuration.inSeconds;
      return Center(
        child: Text(
          'No stations yet.\nStops of $seconds s or longer are added '
          'automatically.\nTap Mark Station to add one yourself.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.grey),
        ),
      );
    }
    return ListView.builder(
      reverse: true,
      itemCount: stations.length,
      itemBuilder: (context, i) {
        final s = stations[stations.length - 1 - i];
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: stationColor(s.type),
            child: Icon(stationIcon(s.type), color: Colors.white, size: 20),
          ),
          title: Text(
            '${s.type.label}  •  ${formatDistance(s.totalDistanceM)}',
          ),
          subtitle: Text(
            '${_timing(s)}\n'
            '${s.latitude.toStringAsFixed(6)}, '
            '${s.longitude.toStringAsFixed(6)}',
          ),
          isThreeLine: true,
          trailing: Text(
            '#${s.id}',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        );
      },
    );
  }

  String _timing(StationEvent s) {
    final at = formatClockTime(s.timestamp);
    if (s.type == StationEventType.manualMark) {
      final marked = 'Marked $at  •  ${s.speedKmh.toStringAsFixed(1)} km/h';
      final age = s.gpsAgeS ?? 0;
      if (age < TrackingNotifier.kStaleFix.inSeconds) return marked;
      return '$marked  •  GPS ${formatGpsAge(age)} old';
    }
    final dwell = s.dwell;
    if (dwell != null) {
      return '$at – ${formatClockTime(s.departureTimestamp!)}  •  '
          'stood ${formatDwell(dwell)}';
    }
    if (s.id == currentStopId) return 'Arrived $at  •  standing now';
    return 'Arrived $at  •  left: unknown';
  }
}
