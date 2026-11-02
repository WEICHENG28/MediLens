// Deliberate live test: fixed synthetic report/audio only. Reads connection settings, never prints them.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:medilens/core/api_client.dart';
import 'package:medilens/core/models.dart';
import 'package:medilens/core/session.dart';
import 'package:medilens/core/settings.dart';
import 'package:medilens/core/speech.dart';
import 'package:medilens/core/voice_input.dart';
import 'package:medilens/data/local_store.dart';
import 'package:medilens/features/realtime_voice_page.dart';

import 'offline_voice_device_test.dart' show pcm16k;

class _Settings extends SettingsNotifier {
  final AppSettings value;
  _Settings(this.value);
  @override
  AppSettings build() => value;
}

class _Session extends SessionNotifier {
  final ParsedReport report;
  final Map<String, dynamic> analysis;
  _Session(this.report, this.analysis);
  @override
  ReportSession build() => ReportSession(
    id: 'realtime-device-synthetic',
    report: report,
    analysis: analysis,
  );
}

class _FixtureInput extends VoiceInputPlatform {
  final List<Uint8List> fixtures;
  final pending = Completer<String>();
  int turns = 0;
  _FixtureInput(this.fixtures);
  @override
  Future<VoiceInputStatus> status() async {
    final s = await super.status();
    return VoiceInputStatus(
      available: s.available,
      permission: true,
      ready: s.ready,
      busy: s.busy,
    );
  }

  @override
  Future<String> listenRealtime() {
    final index = turns++;
    if (index < fixtures.length) return recognizeEndpointPcm(fixtures[index]);
    return pending.future;
  }

  @override
  Future<void> cancel() async {
    if (turns > fixtures.length && !pending.isCompleted) pending.complete('');
    await super.cancel();
  }
}

Future<void> waitFor(
  WidgetTester t,
  bool Function() ready, {
  int seconds = 90,
}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 200));
    if (ready()) return;
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
  }
  throw TestFailure('合成实时对话未在时限内完成');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('两轮合成中文识别→真实模型→真实播报完成后继续下一轮', (t) async {
    final privateStore = SqlCipherStore();
    ProviderContainer? c;
    final files = <File>[];
    final synth = SystemSpeech();
    try {
      late AppSettings settings;
      late ApiClient api;
      late Map<String, dynamic> analysis;
      final fixtures = <Uint8List>[];
      final report = ParsedReport(
        reportType: 'urinalysis',
        testDate: '2026-11-02',
        items: [
          LabItem(
            code: 'PRO',
            label: '尿蛋白',
            value: '阴性',
            reference: '阴性',
            confidence: 1,
            status: ReviewStatus.confirmed,
          ),
        ],
      );
      await t.runAsync(() async {
        final raw = await privateStore.getSetting('app_settings');
        expect(raw, isNotNull);
        final saved = AppSettings.fromJson(
          jsonDecode(raw!) as Map<String, dynamic>,
        );
        expect(
          saved.apiToken.isNotEmpty,
          isTrue,
          reason: 'Device connection must already be configured',
        );
        settings = saved.copyWith(
          apiBaseUrl: 'http://101.6.162.67:8000',
          aiConsent: true,
        );
        api = ApiClient(settings.apiBaseUrl, null, settings.apiToken);
        analysis = await api.analyze(ApiClient.analysisBody(report, {}, []));
        final voices = SpeechVoice.offlineChinese(await synth.voices());
        expect(voices, isNotEmpty);
        await synth.useVoice(voices.first);
        await synth.rate(.45);
        await synth.tts.awaitSynthCompletion(true);
        for (final phrase in ['这个指标是什么', '请再解释一下']) {
          final file = File(
            '${(await getTemporaryDirectory()).path}/synthetic-realtime-${files.length}.wav',
          );
          files.add(file);
          expect(await synth.tts.synthesizeToFile(phrase, file.path, true), 1);
          fixtures.add(
            (BytesBuilder()
                  ..add(pcm16k(await file.readAsBytes()))
                  ..add(Uint8List(16000 * 2 * 3)))
                .takeBytes(),
          );
        }
      });
      final input = _FixtureInput(fixtures);
      final container = ProviderContainer(
        overrides: [
          localStoreProvider.overrideWithValue(MemoryStore()),
          settingsProvider.overrideWith(() => _Settings(settings)),
          sessionProvider.overrideWith(() => _Session(report, analysis)),
          apiClientProvider.overrideWithValue(api),
          voiceInputPlatformProvider.overrideWithValue(input),
        ],
      );
      c = container;
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            navigatorObservers: [speechRoutes],
            home: const RealtimeVoicePage(focus: 'PRO'),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('realtime_start')));
      await t.tap(find.byKey(const Key('realtime_start')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('realtime_consent')));
      await t.pump();
      await waitFor(
        t,
        () =>
            input.turns >= 3 &&
            container
                    .read(sessionProvider)
                    .messages
                    .where((m) => m.role == 'assistant')
                    .length >=
                2,
      );
      expect(
        container
            .read(sessionProvider)
            .messages
            .where((m) => m.role == 'user')
            .length,
        2,
      );
      expect(
        container
            .read(sessionProvider)
            .messages
            .where((m) => m.role == 'assistant')
            .every((m) => !m.usedFallback),
        isTrue,
        reason:
            'This live fixture expects actual model replies, not fallback text',
      );
      await t.ensureVisible(find.byKey(const Key('realtime_stop')));
      await t.tap(find.byKey(const Key('realtime_stop')));
      await t.pump();
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await t.pump();
      expect(input.turns, 3);
      // ignore: avoid_print
      print(
        '[REALTIME_FLOW] two_native_asr_real_llm_tts_rounds=passed next_listen_after_completion=passed',
      );
      await t.pumpWidget(const SizedBox.shrink());
      await t.pump();
    } finally {
      if (c != null) {
        final container = c;
        await t.runAsync(() => container.read(speechProvider.notifier).stop());
        container.dispose();
      }
      await t.runAsync(() async {
        await synth.stop();
        for (final f in files) {
          if (await f.exists()) await f.delete();
        }
        await privateStore.close();
      });
    }
  });
}
