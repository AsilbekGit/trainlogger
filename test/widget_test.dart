import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:train_logger/services/providers.dart';
import 'package:train_logger/services/storage_service.dart';
import 'package:train_logger/ui/screens/dashboard_screen.dart';

void main() {
  testWidgets('Dashboard shows the empty state when there are no records',
      (tester) async {
    // storageServiceProvider must be overridden (it throws by default).
    // An un-initialised StorageService is fine here: getAll() reads the
    // in-memory list, not the disk.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(StorageService()),
        ],
        child: const MaterialApp(home: DashboardScreen()),
      ),
    );

    expect(find.text('Train Logger'), findsOneWidget);
    expect(find.textContaining('No records yet'), findsOneWidget);
    expect(find.text('Start Tracking'), findsOneWidget);
  });
}
