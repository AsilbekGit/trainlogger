import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'services/storage_service.dart';
import 'services/providers.dart';
import 'ui/screens/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialise Hive storage before the app starts.
  // Wrapped in try-catch so the app always launches, even if storage
  // is temporarily broken.
  final storage = StorageService();
  try {
    await storage.init();
  } catch (e) {
    debugPrint('[main] Storage init failed, continuing with empty state: $e');
  }

  runApp(
    ProviderScope(
      overrides: [
        storageServiceProvider.overrideWithValue(storage),
      ],
      child: const TrainLoggerApp(),
    ),
  );
}

class TrainLoggerApp extends StatelessWidget {
  const TrainLoggerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Train Logger',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.blueGrey,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      home: const HomeScreen(),
    );
  }
}