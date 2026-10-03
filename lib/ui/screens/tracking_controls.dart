import 'package:flutter/material.dart';
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
  if (started || !context.mounted || !tracker.needsLocationPermission) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Location Access Required'),
      content: const Text(
        'Turn on location services and allow location access in Settings '
        'to use the tracker.',
      ),
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
