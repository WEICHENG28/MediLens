import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/auth.dart';
import 'core/settings.dart';
import 'core/local_reminders.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    final notice = await rootBundle.loadString('assets/asr/NOTICE.txt');
    final license = await rootBundle.loadString('assets/asr/LICENSE-APACHE-2.0.txt');
    yield LicenseEntryWithLineBreaks(['Vosk offline Chinese', 'JNA'], '$notice\n\n$license');
  });
  final container = ProviderContainer();
  await container.read(settingsProvider.notifier).load();
  await container.read(authProvider.notifier).load();
  await container.read(remindersProvider.notifier).load();
  runApp(UncontrolledProviderScope(
    container: container,
    child: MediLensApp(onboarded: container.read(settingsProvider).onboarded),
  ));
}
