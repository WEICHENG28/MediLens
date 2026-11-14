import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/settings.dart';
import 'core/speech.dart';
import 'core/pet_interaction.dart';
import 'core/theme.dart';
import 'features/life_page.dart';
import 'features/reminder_page.dart';
import 'features/auth_page.dart';
import 'features/checkup_page.dart';
import 'features/desktop_pet_page.dart';
import 'features/chat_page.dart';
import 'features/voice_page.dart';
import 'features/realtime_voice_page.dart';
import 'features/doctor_page.dart';
import 'features/followup_page.dart';
import 'features/history_page.dart';
import 'features/history_trends_page.dart';
import 'features/home_page.dart';
import 'features/import_page.dart';
import 'features/overview_page.dart';
import 'features/review_page.dart';
import 'features/save_page.dart';
import 'features/settings_page.dart';
import 'features/speech_page.dart';
import 'features/medication_page.dart';
import 'features/medication_records_page.dart';
import 'features/welcome_page.dart';

GoRouter buildRouter(bool onboarded) => GoRouter(
      initialLocation: onboarded ? '/home' : '/welcome',
      observers: [speechRoutes, petRoutes],
      routes: [
        GoRoute(path: '/welcome', builder: (_, _) => const WelcomePage()),
        GoRoute(path: '/home', builder: (_, _) => const HomePage()),
        GoRoute(path: '/import', builder: (_, _) => const ImportPage()),
        GoRoute(path: '/review', builder: (_, _) => const ReviewPage()),
        GoRoute(path: '/overview', builder: (_, _) => const OverviewPage()),
        GoRoute(path: '/followup', builder: (_, _) => const FollowupPage()),
        GoRoute(path: '/chat', builder: (_, s) => ChatPage(focus: s.uri.queryParameters['focus'])),
        GoRoute(path: '/save', builder: (_, _) => const SavePage()),
        GoRoute(path: '/history', builder: (_, _) => const HistoryPage()),
        GoRoute(path: '/trends', builder: (_, _) => const HistoryTrendsPage()),
        GoRoute(path: '/doctor', builder: (_, _) => const DoctorPage()),
        GoRoute(path: '/checkup-reminders', builder: (_, _) => const CheckupPage()),
        GoRoute(path: '/speech-settings', builder: (_, _) => const SpeechPage()),
        GoRoute(path: '/settings', builder: (_, _) => const SettingsPage()),
        GoRoute(path: '/life', builder: (_, _) => const LifePage()),
        GoRoute(path: '/desktop-pet', builder: (_, _) => const DesktopPetPage()),
        GoRoute(path: '/unsupported', builder: (_, _) => const UnsupportedPage()),
        GoRoute(path: '/realtime-voice', builder: (_, s) => RealtimeVoicePage(focus: s.uri.queryParameters['focus'], initialDraft: s.extra is String ? s.extra as String : null)),
        GoRoute(path: '/voice', builder: (_, s) => VoicePage(focus: s.uri.queryParameters['focus'], initialDraft: s.extra is String ? s.extra as String : null)),
        GoRoute(path: '/medications-saved', builder: (_, _) => const MedicationRecordsPage()),
        GoRoute(path: '/medication', builder: (_, _) => const MedicationPage()),
        GoRoute(path: '/auth', builder: (_, _) => const AuthPage()),
        GoRoute(
          path: '/reminder',
          builder: (_, _) => const ReminderPage(),
        ),
      ],
    );

class MediLensApp extends ConsumerStatefulWidget {
  final bool onboarded;
  const MediLensApp({super.key, required this.onboarded});
  @override
  ConsumerState<MediLensApp> createState() => _MediLensAppState();
}

class _MediLensAppState extends ConsumerState<MediLensApp> {
  late final GoRouter router = buildRouter(widget.onboarded);

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(settingsProvider.select((s) => s.displayMode));
    return MaterialApp.router(
      title: 'MediLens',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(mode),
      routerConfig: router,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
    );
  }
}

class UnsupportedPage extends StatelessWidget {
  const UnsupportedPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('暂不支持该报告')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Icon(Icons.description_outlined, size: 64, color: Colors.blueGrey),
            const SizedBox(height: 16),
            const Text('没有识别到尿常规或尿白蛋白/肌酐比（UACR）项目。', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 8),
            const Text('当前版本只支持这两类报告，无法解读这份报告。如果这确实是尿检报告，请尝试重新拍摄（保持报告平整、光线充足）。'),
            const SizedBox(height: 24),
            FilledButton(onPressed: () => context.go('/home'), child: const Text('返回首页')),
          ]),
        ),
      );
}
