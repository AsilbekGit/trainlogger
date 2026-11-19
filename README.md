# Train Logger

Flutter GPS logger for train journeys, with a live dashboard, route map,
50-metre measurement records, automatic stop detection, manual station marks,
local JSON storage, and CSV sharing.

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

## Build with Xcode (iOS)

A fresh clone does not build in Xcode straight away. Xcode needs files that
Flutter and CocoaPods generate on each machine (`ios/Flutter/Generated.xcconfig`,
`ios/Pods` and the plugin packages), and these are deliberately not in git.
You need Xcode, Flutter 3.38 or newer, and CocoaPods.

1. From the project folder, generate them:

   ```sh
   flutter pub get
   cd ios && pod install
   ```

   Run both again after pulling changes to `pubspec.yaml`.
2. Open `ios/Runner.xcworkspace`, not `Runner.xcodeproj`.
3. Choose a specific simulator, such as iPhone 17, and press Run.

With Flutter 3.38 and Xcode 27.2, the generic "Any iOS Simulator Device"
destination fails with "Flutter.framework does not contain architectures".
Xcode's `lipo` no longer accepts the multi-architecture check Flutter runs for
that destination. A specific simulator or device builds one architecture and
works.

To install on a real iPhone, open Runner > Signing & Capabilities and choose
your own team; the project has the maintainer's team selected. Also change
the bundle identifier from `com.example.trainLogger` to one you own, such as
`com.yourname.trainlogger`. Apple does not register `com.example` identifiers
for signing.

In the Simulator, a custom location or a `simctl location start` route reports
no speed, so the app logs no distance. Use Features > Location > Freeway Drive
instead.

## Data flow

1. `LocationService` requests location permission and supplies GPS fixes.
   Android uses a foreground notification and a one-second requested interval;
   iOS enables background location updates.
2. `TrackingNotifier` owns start/stop, active elapsed time, UI state, and saved
   records. Concurrent start requests share one operation. Stopping cancels a
   pending start and breaks measurement continuity before a later restart.
3. `TrackingService` validates fixes, filters noise, accumulates distance, and
   emits records at cumulative milestones of 50, 100, 150 metres, and so on.
4. `StopDetector` watches the fixes `TrackingService` accepted and reports
   stops; `TrackingNotifier` turns them, and Mark Station taps, into
   `StationEvent`s. It never changes distance, records, grade or curvature.
5. `StorageService` serializes writes to a temporary JSON file and renames it
   over the previous file. `ExportService` makes CSV snapshots for sharing.

## Measurement rules

- Horizontal accuracy must be finite and no worse than 20 metres. Invalid
  coordinates and stale timestamps are ignored.
- Speeds below 1 m/s, including unavailable GPS speed, do not add distance.
  Accepted speed is capped at 83 m/s. Movement under 5 metres accumulates
  relative to the last accepted movement fix.
- A jump over 500 metres is a GPS glitch only if covering it since the last
  accepted fix would need more than 83 m/s; it then breaks continuity and
  needs a new baseline. Otherwise, as after a tunnel or weak GPS under a
  station roof, the gap is bridged with a straight segment so its distance
  and 50 m marks are kept (the true route through a curve is longer).
- While the train stands still, the distance baseline keeps its position but
  takes the latest time, so the first 50 m mark after a stop is timed after
  the stop rather than spread across it.
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

## Stops and stations

50 m records rarely fall exactly on a station, and no record is written while
the train stands still, so stations are captured separately:

- **Automatic stops.** Detection uses GPS speed, not an unchanging position:
  a standing phone's position still wanders by a few metres. A stop begins at
  the first accepted fix slower than 1 m/s (3.6 km/h) and counts once the train
  stays that slow for 5 s (the sixth slow fix at one fix per second). It is
  saved at that moment and shown as "Stopped since…" on the dashboard. A
  pending or confirmed stop ends only after 3 s of continuous movement, so one
  noisy reading neither cancels nor splits it. The departure time is the first
  of those moving fixes; if GPS was lost as the train left (a tunnel, a roof),
  it is estimated from the distance covered by the first fix after the gap.
  The saved position is the average of all stationary fixes. Unavailable speed (-1 on iOS) is
  ignored. A "stationary" fix more than 20 m from where the slowdown began, or
  more than 50 m from a confirmed stop, counts as movement; this guards against
  Android reporting 0 for unknown speed. Stops at signals, and a train
  crawling below 3.6 km/h for 5 s, are recorded too: the app cannot tell why
  the train slowed.
- **Mark Station.** While tracking, the button on either tab saves the latest
  accepted GPS position with the current speed and the tap time. It does
  nothing until the first fix arrives, and a second tap within 2 s is the
  same mark. Under a station roof GPS fixes may be rejected for a while, so
  the mark also stores `gps_age_s`, how old that position is; from 10 s on,
  the confirmation and the Stations tab say GPS was weak.

Both appear in the Stations tab and on the map (orange for stops, purple for
marks). Stopping tracking during a stop keeps its arrival and leaves the
departure empty; if the train is still there when tracking (or the app)
restarts, that same stop is resumed rather than duplicated. Tuning constants
are in `lib/services/stop_detector.dart`.

While tracking, the dashboard shows "Waiting for GPS…" or "Weak GPS" and a
dash for speed whenever no fix has been accepted for 10 s. Tracking needs
precise location: with approximate location (Android 12+, or iOS with Precise
Location off) every fix would be rejected, so the app asks for it instead of
starting. On Android 13+ it also asks to show notifications, so the
"Logging train movement" notification is visible while the screen is locked.

## Storage and sessions

Records live in `train_log_records.jsonl` (one record per line) and stations in
`train_log_stations.json`, both in the application documents directory. Each
new 50 m record is appended to the end of the file, so saving stays fast however
long the trip gets. On relaunch, counters resume from the last saved milestone
(or a station saved after it). Raw GPS history and elapsed time are not
persisted. A `train_log_records.json` file from an older version is converted
automatically on first launch and kept as `train_log_records.json.migrated`.

Malformed or half-written lines (for example after a crash) are skipped while
valid records are recovered; the original is first preserved in a
`.corrupt-<timestamp>` backup, and the next save rewrites the file cleanly.
Read failures prevent overwriting an unreadable existing file. Write failures
are reported in the UI, unsaved records remain available for CSV export, and
the next successful save writes them all. New Session deletes the current
records and stations only after saving the empty files succeeds; export first
if you need to keep the trip.

Export shares one file, `train_log_<time>.csv`, with every 50 m record,
automatic stop and station mark, sorted by time so each station sits between
the records around it. The `type` column is `record`, `auto_stop` or
`manual_mark`; filter on it to separate them. `id` is the record index for
records and the station number otherwise.

Columns: `type`, `id`, `timestamp`, `departure_timestamp`, `dwell_s`,
`latitude`, `longitude`, `speed_kmh`, `altitude_m`, `segment_distance_m`,
`elevation_delta_m`, `grade_percent`, `curvature_percent`, `curve_radius_m`,
`total_distance_m`, `gps_age_s`. Departure and dwell apply to automatic stops
only; `gps_age_s` to manual marks only; the segment, elevation, grade and
curvature columns apply to records only. For a
record, `total_distance_m` is its 50 m milestone; for a station it is the
tracked distance at that moment.

CSV timestamps are UTC ISO 8601: arrival time for a stop, tap time for a mark.
Empty fields mean the column does not apply or no measurement is available.
Exports are separate snapshots in temporary storage.

## Device validation

Automated tests cover the algorithm, persistence, export, and session lifecycle.
Background GPS behavior and the native share sheet still require device tests:
start a journey, lock the screen, resume the app, stop and restart tracking,
reopen the app, and export on both a phone and an iPad. Stop detection
thresholds should also be checked against real station stops and GPS under
station roofs. GPS-derived grade and
curvature remain sensitive to location and altitude noise.
