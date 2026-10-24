import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer();
  await container.read(settingsProvider.notifier).load();
  runApp(UncontrolledProviderScope(
    container: container,
    child: MediLensApp(onboarded: container.read(settingsProvider).onboarded),
  ));
}
