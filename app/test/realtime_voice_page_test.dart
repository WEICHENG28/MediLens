
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medilens/core/speech.dart';
import 'package:medilens/core/voice_input.dart';
import 'package:medilens/features/realtime_voice_page.dart';

import 'voice_page_test.dart' as base;
import 'realtime_voice_test.dart' show RealtimeInputFake;
import 'speech_test.dart' show FakeSpeech;

void main() {
  Future<void> host(WidgetTester t, ProviderContainer c) async {
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          navigatorObservers: [speechRoutes],
          home: const RealtimeVoicePage(),
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  Future<void> tap(WidgetTester t, String key) async {
    final f = find.byKey(Key(key));
    await t.ensureVisible(f);
    await t.tap(f);
    await t.pumpAndSettle();
  }

  Future<void> open(WidgetTester t) async {
    await tap(t, 'realtime_start');
    await tap(t, 'realtime_consent');
  }

  testWidgets('默认不录音；取消同意不启动；明确开启后才聆听', (t) async {
    final p = RealtimeInputFake(), api = base.Api(), speech = FakeSpeech();
    final c = base.scope(base.Input(), api, speech);
    addTearDown(c.dispose);
    final scope = ProviderContainer(
      parent: c,
      overrides: [voiceInputPlatformProvider.overrideWithValue(p)],
    );
    addTearDown(scope.dispose);
    await host(t, scope);
    expect(p.results, isEmpty);
    await tap(t, 'realtime_start');
    await t.tap(find.text('取消'));
    await t.pumpAndSettle();
    expect(p.results, isEmpty);
    await open(t);
    expect(p.results.length, 1);
    await tap(t, 'realtime_stop');
    p.results[0].complete('不应发送');
    await t.pumpAndSettle();
    expect(api.sent, isEmpty);
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump();
    await p.events.close();
  });
  testWidgets('真实语音状态完成回调后才继续，退后台后不自动恢复', (t) async {
    final p = RealtimeInputFake(), api = base.Api(), speech = FakeSpeech();
    final c = base.scope(base.Input(), api, speech);
    addTearDown(c.dispose);
    final scope = ProviderContainer(
      parent: c,
      overrides: [voiceInputPlatformProvider.overrideWithValue(p)],
    );
    addTearDown(scope.dispose);
    await host(t, scope);
    await open(t);
    p.results[0].complete('尿蛋白是什么');
    await t.pump();
    await t.pump(const Duration(seconds: 2));
    await t.pumpAndSettle();
    expect(api.sent, ['尿蛋白是什么']);
    expect(speech.spoken.length, 1);
    expect(p.results.length, 1);
    speech.completed();
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpAndSettle();
    expect(p.results.length, 2);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await t.pumpAndSettle();
    p.results[1].complete('后台迟到问题');
    await t.pumpAndSettle();
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpAndSettle();
    expect(p.results.length, 2);
    expect(api.sent.length, 1);
    expect(find.text('开启实时对话'), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump();
    await p.events.close();
  });
  testWidgets('数值句显示核对框，不自动发；确认后发送修改的句子', (t) async {
    final p = RealtimeInputFake(), api = base.Api(), speech = FakeSpeech();
    final c = base.scope(base.Input(), api, speech);
    addTearDown(c.dispose);
    final scope = ProviderContainer(
      parent: c,
      overrides: [voiceInputPlatformProvider.overrideWithValue(p)],
    );
    addTearDown(scope.dispose);
    await host(t, scope);
    await open(t);
    p.results[0].complete('尿蛋白2+');
    await t.pumpAndSettle();
    expect(api.sent, isEmpty);
    await t.enterText(find.byKey(const Key('realtime_editor')), '请解释尿蛋白');
    await tap(t, 'realtime_confirm');
    expect(api.sent, ['请解释尿蛋白']);
    await tap(t, 'realtime_stop');
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump();
    await p.events.close();
  });
}
