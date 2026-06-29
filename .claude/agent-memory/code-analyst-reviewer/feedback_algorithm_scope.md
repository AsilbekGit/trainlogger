---
name: train-logger-algorithm-scope
description: For train_logger, the curvature/grade/distance/filtering math is the validated core and is treated as off-limits; scope changes to interval/config, platform wiring, and bug fixes unless explicitly asked.
metadata:
  type: feedback
---

When working in train_logger, treat the core measurement algorithms as off-limits unless the user explicitly says otherwise: Menger curvature (`computeMengerCurvature`), grade (`computeGradePercent`), distance accumulation, and the GPS noise-filtering thresholds (`kMaxAccuracyM`, `kMinMovementM`, `kMinSpeedMs`, `kMaxSpeedMs`, `kMaxJumpM`) in `lib/services/tracking_service.dart`.

**Why:** The user shipped at least one change under an explicit "HARD CONSTRAINT: do NOT change the core logic/algorithms — only the interval value, bug fixes, and platform/background wiring." The math is treated as carefully validated (there is a curvature test suite in `test/tracking_service_test.dart`), so changes are deliberately scoped around it.

**How to apply:** Prefer fixes that touch configuration (e.g. `kLogIntervalMeters`, geolocator `intervalDuration`), platform wiring (manifests, Info.plist, `location_service.dart`), persistence, lifecycle, and emission plumbing. If a correct fix *requires* touching the math or the record-emission logic (e.g. the multi-threshold phantom-record bug), call it out and get explicit sign-off rather than changing it silently.
