// Fixed synthetic phrase only; never reads actual app settings, reports or credentials.
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:medilens/core/speech.dart';
import 'package:medilens/core/settings.dart';
import 'package:medilens/widgets/common.dart';
import 'package:medilens/data/local_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('已安装的离线中文音色真实播报完成并生成音频', (t) async {
    final c = ProviderContainer(overrides: [localStoreProvider.overrideWithValue(MemoryStore())]);
    File? output;
    try {
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: Text('合成测试：离线中文朗读'))));
      final n = c.read(speechProvider.notifier);
      await t.runAsync(n.refresh);
      expect(c.read(speechProvider).voices, isNotEmpty);
      await t.runAsync(() => n.select(c.read(speechProvider).voices.first.id));
      var started = false;
      final subscription = c.listen(speechProvider, (_, next) { if (next.speaking) started = true; });
      await t.runAsync(() => n.speak('您好，这是本机离线中文朗读测试。', 'synthetic_device'));
      final deadline = DateTime.now().add(const Duration(seconds: 25));
      while (c.read(speechProvider).speaking && DateTime.now().isBefore(deadline)) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
      }
      expect(started, isTrue); expect(c.read(speechProvider).speaking, isFalse); expect(c.read(speechProvider).message, isNull);
      subscription.close();
      final platform = c.read(speechPlatformProvider) as SystemSpeech;
      await t.runAsync(() async {
        output = File('${(await getTemporaryDirectory()).path}/medilens-chinese-synthetic-check.wav');
        await platform.tts.awaitSynthCompletion(true);
        final result = await platform.tts.synthesizeToFile('您好，这是中文语音合成测试。', output!.path, true).timeout(const Duration(seconds: 25));
        expect(result, 1); expect(await output!.exists(), isTrue); expect(await output!.length(), greaterThan(44));
        // ignore: avoid_print
        print('[CHINESE_SPEECH] native_completion=passed wav_bytes=${await output!.length()}');
      });
    } finally {
      await t.runAsync(() async { await c.read(speechProvider.notifier).stop(); if (output != null && await output!.exists()) { await output!.delete(); } });
      c.dispose();
    }
  });
  testWidgets('主动开启自动朗读后由页面触发真实中文播放', (t) async {
    final c = ProviderContainer(overrides: [localStoreProvider.overrideWithValue(MemoryStore())]);
    var started = false;
    final subscription = c.listen(speechProvider, (_, next) { if (next.speaking) started = true; });
    try {
      await t.runAsync(() => c.read(settingsProvider.notifier).update(c.read(settingsProvider).copyWith(autoRead: true)));
      await t.pumpWidget(UncontrolledProviderScope(container: c, child: MaterialApp(navigatorObservers: [speechRoutes],
        home: const Scaffold(body: ReadAloudButton('您好，这是自动朗读摘要的合成测试。', autoRead: true)))));
      final deadline = DateTime.now().add(const Duration(seconds: 25));
      while (DateTime.now().isBefore(deadline)) {
        await t.pump();
        if (started && !c.read(speechProvider).speaking && !c.read(speechProvider).loading) break;
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      }
      expect(started, isTrue); expect(c.read(speechProvider).speaking, isFalse); expect(c.read(speechProvider).message, isNull);
      // ignore: avoid_print
      print('[AUTO_READ] widget_triggered_native_chinese_completed=passed');
      await t.pumpWidget(const SizedBox.shrink()); await t.pump();
    } finally {
      subscription.close(); await t.runAsync(() => c.read(speechProvider.notifier).stop()); c.dispose();
    }
  });

}
