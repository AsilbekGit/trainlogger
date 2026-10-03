# Train Logger

Flutter GPS logger for train journeys, with a live dashboard, route map,
50-metre measurement records, local JSON storage, and CSV sharing.

## Run and check

Use Flutter 3.38 or newer with Dart 3.10 or newer. These minimums match the
committed dependencies and the iOS host's scene lifecycle integration.

```sh
flutter pub get
flutter analyze
flutter test
flutter run
```

The app is primarily configured for Android and iOS. Location and network
permissions are also declared for macOS. The other generated platform folders
are not a guarantee of support: file storage uses `dart:io`, so the current
implementation is not web compatible, and Linux location support is not wired.

## Data flow

1. `LocationService` requests location permission and supplies GPS fixes.
   Android uses a foreground notification and a one-second requested interval;
   iOS enables background location updates.
2. `TrackingNotifier` owns start/stop, active elapsed time, UI state, and saved
   records. Concurrent start requests share one operation. Stopping cancels a
   pending start and breaks measurement continuity before a later restart.
3. `TrackingService` validates fixes, filters noise, accumulates distance, and
   emits records at cumulative milestones of 50, 100, 150 metres, and so on.
4. `StorageService` serializes writes to a temporary JSON file and renames it
   over the previous file. `ExportService` makes a CSV snapshot for sharing.

## Measurement rules

- Horizontal accuracy must be finite and no worse than 20 metres. Invalid
  coordinates and stale timestamps are ignored.
- Speeds below 1 m/s, including unavailable GPS speed, do not add distance.
  Accepted speed is capped at 83 m/s. Movement under 5 metres accumulates
  relative to the last accepted movement fix; jumps over 500 metres break
  continuity and require a new baseline.
- Each crossed 50-metre milestone is interpolated between accepted fixes,
  including its position, timestamp, speed, and smoothed altitude. Several
  milestones crossed in one update therefore have distinct positions. These
  are estimates: sparse GPS fixes cannot reveal the exact intervening route.
- Altitude uses a rolling median of five samples. Grade compares the smoothed
  altitudes of consecutive logged points and uses their geodesic separation:
  `grade_percent = elevation_delta_m / segment_distance_m * 100`.
- Menger curvature uses three consecutive points, `kappa = 4 * area / (a*b*c)`.
  `curvature_percent` retains the project's convention of `kappa * 100`;
  `curve_radius_m` is `1 / kappa`. The value stored in the newest record
  describes curvature at the previous point. A straight line has zero
  curvature and a null radius. The initial accepted fix counts as an origin.
- Stopping preserves counters and records but resets GPS/altitude history;
  movement while stopped is excluded. The first segment after a restart can
  be shorter than 50 metres because the cumulative remainder is preserved.

## Storage and sessions

Records live in `train_log_records.json` in the application documents directory.
On relaunch, counters resume from the last saved milestone. Raw GPS history,
the sub-50-metre distance remainder, and elapsed time are not persisted.

Malformed rows are skipped while valid records are recovered. Before replacing
damaged JSON, the original is preserved in a `.corrupt-<timestamp>` backup.
Read failures prevent overwriting an unreadable existing file. Write failures
are reported in the UI, and unsaved records remain available for CSV export.
New Session deletes the current log only after saving the empty file succeeds;
export first if you need to keep the trip.

CSV timestamps are UTC ISO 8601. Export includes distance, speed, altitude,
elevation change, grade, curvature, and radius. Empty numeric fields mean no
measurement is available. Exports are separate snapshots in temporary storage.

## Device validation

Automated tests cover the algorithm, persistence, export, and session lifecycle.
Background GPS behavior and the native share sheet still require device tests:
start a journey, lock the screen, resume the app, stop and restart tracking,
reopen the app, and export on both a phone and an iPad. GPS-derived grade and
curvature remain sensitive to location and altitude noise.
