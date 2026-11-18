import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/providers.dart';

/// Shared by both tabs so permission failures behave consistently.
Future<void> toggleTracking(
  BuildContext context,
  TrackingNotifier tracker,
) async {
  if (tracker.isBusy) return;
  if (tracker.isTracking) {
    tracker.stopTracking();
    return;
  }
  final started = await tracker.startTracking();
  if (started || !context.mounted) return;
  final String title;
  final String message;
  if (tracker.needsPreciseLocation) {
    title = 'Precise Location Required';
    message =
        'Approximate location is about a kilometre off, so the tracker '
        'cannot measure distance. In Settings, turn on Precise Location for '
        'Train Logger.';
  } else if (tracker.needsLocationPermission) {
    title = 'Location Access Required';
    message =
        'Turn on location services and allow location access in Settings '
        'to use the tracker.';
  } else {
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(dialogContext);
            tracker.openSettings();
          },
          child: const Text('Open Settings'),
        ),
      ],
    ),
  );
}

/// Shared by both tabs: saves the current position as a station and confirms
/// it with a short message and a vibration, so it works without looking.
void markStation(BuildContext context, TrackingNotifier tracker) {
  final station = tracker.markStation();
  if (station != null) HapticFeedback.mediumImpact();
  final String message;
  if (station == null) {
    message = 'Waiting for GPS. No position to mark yet.';
  } else {
    final marked =
        'Station ${station.id} marked at '
        '${formatDistance(station.totalDistanceM)}.';
    final age = station.gpsAgeS ?? 0;
    message = age >= TrackingNotifier.kStaleFix.inSeconds
        ? '$marked Weak GPS: position is from ${formatGpsAge(age)} ago.'
        : marked;
  }
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
        content: Text(message),
      ),
    );
}

/// Shown instead of a stale speed while tracking without a recent GPS fix.
String? gpsStatusText(TrackingNotifier tracker) {
  if (!tracker.isGpsStale) return null;
  final age = tracker.gpsFixAge;
  if (age == null) return 'Waiting for GPS…';
  return 'Weak GPS · last fix ${formatGpsAge(age.inSeconds.toDouble())} ago';
}

/// "45 s" or "3 min" for how old a GPS position is.
String formatGpsAge(double seconds) {
  if (seconds < 120) return '${seconds.round()} s';
  return '${(seconds / 60).round()} min';
}

/// "850 m" below 1 km, "12.35 km" above.
String formatDistance(double m) {
  if (m >= 1000) return '${(m / 1000).toStringAsFixed(2)} km';
  return '${m.toInt()} m';
}

/// Local HH:MM:SS for an ISO 8601 timestamp, or a dash if it cannot be read.
String formatClockTime(String timestamp) {
  final time = DateTime.tryParse(timestamp)?.toLocal();
  if (time == null) return '—';
  return '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}:'
      '${time.second.toString().padLeft(2, '0')}';
}

/// "1:30" for a 90 s dwell, "1:02:05" past an hour.
String formatDwell(Duration d) {
  final minutes = (d.inMinutes % 60).toString();
  final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
  if (d.inHours == 0) return '$minutes:$seconds';
  return '${d.inHours}:${minutes.padLeft(2, '0')}:$seconds';
}

class TrackingErrorBanner extends StatelessWidget {
  final String message;

  const TrackingErrorBanner({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: colors.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: colors.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
