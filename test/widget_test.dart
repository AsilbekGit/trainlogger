import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:train_logger/models/station_event.dart';
import 'package:train_logger/services/location_service.dart';
import 'package:train_logger/services/providers.dart';
import 'package:train_logger/services/storage_service.dart';
import 'package:train_logger/ui/screens/dashboard_screen.dart';

class _TestLocation extends LocationService {
  final permission = Completer<bool>();
  final positions = StreamController<Position>.broadcast();
  int permissionCalls = 0;

  @override
  Future<bool> requestPermission() {
    permissionCalls++;
    return permission.future;
  }

  @override
  Future<bool> hasPreciseLocation() async => true;

  @override
  Stream<Position> get positionStream => positions.stream;

  @override
  Future<void> startListening({int distanceFilter = 0}) async {}

  @override
  void stopListening() {}

  @override
  void dispose() {
    positions.close();
    super.dispose();
  }
}

class _NoDiskStorage extends StorageService {
  @override
  Future<void> saveStation(StationEvent station) async {}
}

void main() {
  testWidgets('Dashboard shows the empty state when there are no records', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [storageServiceProvider.overrideWithValue(StorageService())],
        child: const MaterialApp(home: DashboardScreen()),
      ),
    );

    expect(find.text('Train Logger'), findsOneWidget);
    expect(find.textContaining('No records yet'), findsOneWidget);
    expect(find.text('Start Tracking'), findsOneWidget);
  });

  testWidgets('Starting disables repeated taps and explains denied access', (
    tester,
  ) async {
    final location = _TestLocation();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(StorageService()),
          locationServiceProvider.overrideWithValue(location),
        ],
        child: const MaterialApp(home: DashboardScreen()),
      ),
    );
    await tester.tap(find.text('Start Tracking'));
    await tester.pump();
    expect(find.text('Starting…'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Starting…'),
        matching: find.byWidgetPredicate((widget) => widget is FilledButton),
      ),
    );
    expect(button.onPressed, isNull);
    expect(location.permissionCalls, 1);
    location.permission.complete(false);
    await tester.pumpAndSettle();
    expect(find.text('Location Access Required'), findsOneWidget);
    expect(find.text('Open Settings'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Start Tracking'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    location.dispose();
  });

  testWidgets('GPS failures are visible and restore the Start control', (
    tester,
  ) async {
    final location = _TestLocation();
    location.permission.complete(true);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(StorageService()),
          locationServiceProvider.overrideWithValue(location),
        ],
        child: const MaterialApp(home: DashboardScreen()),
      ),
    );
    await tester.tap(find.text('Start Tracking'));
    await tester.pump();
    expect(find.text('Stop Tracking'), findsOneWidget);
    location.positions.addError(StateError('GPS disconnected'));
    await tester.pump();
    expect(find.textContaining('Location updates stopped'), findsOneWidget);
    expect(find.text('Start Tracking'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    location.dispose();
  });

  testWidgets('Mark Station works only while tracking', (tester) async {
    final location = _TestLocation();
    location.permission.complete(true);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(_NoDiskStorage()),
          locationServiceProvider.overrideWithValue(location),
        ],
        child: const MaterialApp(home: DashboardScreen()),
      ),
    );
    OutlinedButton markButton() => tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.text('Mark Station'),
        matching: find.byWidgetPredicate((widget) => widget is OutlinedButton),
      ),
    );
    expect(markButton().onPressed, isNull);

    await tester.tap(find.text('Start Tracking'));
    await tester.pump();
    expect(markButton().onPressed, isNotNull);
    await tester.tap(find.text('Mark Station'));
    await tester.pump();
    expect(
      find.text('Waiting for GPS. No position to mark yet.'),
      findsOneWidget,
    );
    expect(find.text('Waiting for GPS…'), findsOneWidget);

    location.positions.add(
      Position(
        latitude: 41,
        longitude: 69,
        timestamp: DateTime.utc(2026),
        accuracy: 5,
        altitude: 100,
        altitudeAccuracy: 5,
        heading: 0,
        headingAccuracy: 0,
        speed: 10,
        speedAccuracy: 1,
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Mark Station'));
    await tester.pump();
    expect(find.text('Station 1 marked at 0 m.'), findsOneWidget);

    await tester.tap(find.text('Stations (1)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('Marked station'), findsOneWidget);

    await tester.tap(find.text('Stop Tracking'));
    await tester.pump();
    expect(markButton().onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
    location.dispose();
  });
}
