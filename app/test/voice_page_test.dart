import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medilens/core/api_client.dart';
import 'package:medilens/core/models.dart';
import 'package:medilens/core/session.dart';
import 'package:medilens/core/settings.dart';
import 'package:medilens/core/speech.dart';
import 'package:medilens/core/voice_input.dart';
import 'package:medilens/data/local_store.dart';
import 'package:medilens/features/voice_page.dart';
import 'package:medilens/features/chat_page.dart';

import 'speech_test.dart' show FakeSpeech;

class ReadySession extends SessionNotifier {
  @override
  ReportSession build() => const ReportSession(
    id: 'voice-synthetic',
    report: ParsedReport(reportType: 'urinalysis', items: []),
    analysis: {},
  );
}

class ConsentSettings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(aiConsent: true);
}

class Input extends VoiceInputPlatform {
  bool allowed = true, grant = false;
  int starts = 0, cancels = 0, stops = 0;
  Completer<String> gate = Completer<String>();
  @override
  Future<VoiceInputStatus> status() async =>
      VoiceInputStatus(available: true, permission: allowed);
  @override
  Future<bool> permission() async => grant;
  @override
  Future<String> listen() {
    starts++;
    return gate.future;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> cancel() async {
    cancels++;
  }
}

class Api extends ApiClient {
  final sent = <String>[];
  Completer<Map<String, dynamic>>? gate;
  Api() : super('http://synthetic.test');
  @override
  Future<Map<String, dynamic>> chat(
    Map<String, dynamic> body,
    String message, {
    String? focus,
    String? quick,
    List<Map<String, String>> history = const [],
  }) async {
    sent.add(message);
    return gate == null
        ? {
            'answer': '合成回答，仅供测试',
            'citations': [],
            'safety_category': 'medication',
          }
        : await gate!.future;
  }
}

ProviderContainer scope(
  Input input,
  Api api,
  FakeSpeech speech, {
  bool report = true,
}) => ProviderContainer(
  overrides: [
    localStoreProvider.overrideWithValue(MemoryStore()),
    voiceInputPlatformProvider.overrideWithValue(input),
    apiClientProvider.overrideWithValue(api),
    speechPlatformProvider.overrideWithValue(speech),
    settingsProvider.overrideWith(ConsentSettings.new),
    if (report) sessionProvider.overrideWith(ReadySession.new),
  ],
);
Future<void> host(
  WidgetTester t,
  ProviderContainer c, {
  bool chat = false,
}) async {
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        navigatorObservers: [speechRoutes],
        home: chat ? const ChatPage() : const VoicePage(),
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

Future<void> cleanup(WidgetTester t) async {
  await t.pumpWidget(const SizedBox.shrink());
  await t.pump();
}

void main() {
  testWidgets('没有报告时明确导入入口，不启动麦克风或模型', (t) async {
    final p = Input(), a = Api(), s = FakeSpeech();
    final container = scope(p, a, s, report: false);
    addTearDown(container.dispose);
    await host(t, container);
    expect(find.text('去导入报告'), findsOneWidget);
    expect(find.byKey(const Key('voice_start')), findsNothing);
    expect(p.starts, 0);
    expect(a.sent, isEmpty);
    await cleanup(t);
  });
  testWidgets('拒绝麦克风不阻塞文字，也不在授权后自动录音', (t) async {
    final p = Input()..allowed = false;
    final a = Api(), s = FakeSpeech();
    final container = scope(p, a, s);
    addTearDown(container.dispose);
    await host(t, container);
    await tap(t, 'voice_start');
    expect(find.textContaining('未允许麦克风'), findsOneWidget);
    expect(p.starts, 0);
    p.grant = true;
    await tap(t, 'voice_start');
    expect(find.textContaining('请再次点击'), findsOneWidget);
    expect(p.starts, 0);
    expect(a.sent, isEmpty);
    await cleanup(t);
  });
  testWidgets('识别只进入可编辑草稿，确认才发送，回答显示安全提示并朗读', (t) async {
    final p = Input(), a = Api(), s = FakeSpeech();
    final c = scope(p, a, s);
    addTearDown(c.dispose);
    await host(t, c);
    await tap(t, 'voice_start');
    expect(find.byKey(const Key('voice_listening')), findsOneWidget);
    p.gate.complete('合成识别有误');
    await t.pumpAndSettle();
    expect(a.sent, isEmpty);
    expect(
      t
          .widget<TextField>(find.byKey(const Key('voice_draft')))
          .controller!
          .text,
      '合成识别有误',
    );
    await t.enterText(find.byKey(const Key('voice_draft')), '修改后的合成问题');
    await tap(t, 'voice_send');
    expect(a.sent, ['修改后的合成问题']);
    expect(find.text('安全提示'), findsOneWidget);
    expect(find.text('合成回答，仅供测试'), findsOneWidget);
    expect(s.spoken, ['合成回答，仅供测试']);
    await cleanup(t);
  });
  testWidgets('取消后迟到识别不能覆盖草稿，退后台不能继续播放或发送', (t) async {
    final p = Input(), a = Api(), s = FakeSpeech();
    final c = scope(p, a, s);
    addTearDown(c.dispose);
    await host(t, c);
    await t.enterText(find.byKey(const Key('voice_draft')), '保留的草稿');
    await tap(t, 'voice_start');
    await tap(t, 'voice_cancel');
    p.gate.complete('迟到识别');
    await t.pumpAndSettle();
    expect(
      t
          .widget<TextField>(find.byKey(const Key('voice_draft')))
          .controller!
          .text,
      '保留的草稿',
    );
    expect(a.sent, isEmpty);
    await cleanup(t);
  });
  testWidgets('后台期间返回的模型结果只留文字，不自动朗读', (t) async {
    final p = Input(),
        a = Api()..gate = Completer<Map<String, dynamic>>(),
        s = FakeSpeech();
    final c = scope(p, a, s);
    addTearDown(c.dispose);
    await host(t, c);
    await t.enterText(find.byKey(const Key('voice_draft')), '合成问题');
    await t.tap(find.byKey(const Key('voice_send')));
    await t.pump();
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await t.pump();
    a.gate!.complete({'answer': '合成迟到回答', 'citations': []});
    await t.pump();
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpAndSettle();
    expect(s.spoken, isEmpty);
    expect(c.read(sessionProvider).messages.last.content, '合成迟到回答');
    await cleanup(t);
  });
  testWidgets('识别失败保留文字，不展示底层异常；缺音色仍显示模型回答', (t) async {
    final p = Input(), a = Api(), s = FakeSpeech()..available = [];
    final c = scope(p, a, s);
    addTearDown(c.dispose);
    await host(t, c);
    await t.enterText(find.byKey(const Key('voice_draft')), '保留的草稿');
    await tap(t, 'voice_start');
    p.gate.completeError(StateError('sensitive_error'));
    await t.pumpAndSettle();
    expect(find.textContaining('原来的文字仍保留'), findsOneWidget);
    expect(find.textContaining('sensitive_error'), findsNothing);
    expect(
      t
          .widget<TextField>(find.byKey(const Key('voice_draft')))
          .controller!
          .text,
      '保留的草稿',
    );
    await tap(t, 'voice_send');
    expect(find.text('合成回答，仅供测试'), findsOneWidget);
    expect(s.spoken, isEmpty);
    await cleanup(t);
  });
  testWidgets('重新说话可打断回答朗读，切换文字保留同一会话', (t) async {
    final p = Input(), a = Api(), s = FakeSpeech();
    final c = scope(p, a, s);
    addTearDown(c.dispose);
    await host(t, c);
    await t.enterText(find.byKey(const Key('voice_draft')), '合成问题');
    await tap(t, 'voice_send');
    expect(c.read(speechProvider).speaking, isTrue);
    await tap(t, 'voice_start');
    expect(c.read(speechProvider).speaking, isFalse);
    await tap(t, 'voice_cancel');
    p.gate.complete('');
    await t.pumpAndSettle();
    await host(t, c, chat: true);
    expect(find.text('合成问题'), findsOneWidget);
    expect(find.text('合成回答，仅供测试'), findsOneWidget);
    await cleanup(t);
  });
  testWidgets('撤回云端指标授权后不发送问题', (t) async {
    final p = Input(), a = Api(), s = FakeSpeech();
    final c = scope(p, a, s);
    addTearDown(c.dispose);
    await c
        .read(settingsProvider.notifier)
        .update(c.read(settingsProvider).copyWith(aiConsent: false));
    await host(t, c);
    await t.enterText(find.byKey(const Key('voice_draft')), '合成问题');
    await tap(t, 'voice_send');
    expect(a.sent, isEmpty);
    expect(find.textContaining('请先在设置中允许'), findsOneWidget);
    await cleanup(t);
  });
  testWidgets('大字和键盘出现时仍可输入确认，不发生布局溢出', (t) async {
    t.view.physicalSize = const Size(1080,2400);t.view.devicePixelRatio=2.625;
    addTearDown(t.view.resetPhysicalSize);addTearDown(t.view.resetDevicePixelRatio);
    final c=scope(Input(),Api(),FakeSpeech());addTearDown(c.dispose);
    await t.pumpWidget(UncontrolledProviderScope(container:c,child:MaterialApp(
      builder:(context,child)=>MediaQuery(data:MediaQuery.of(context).copyWith(textScaler:const TextScaler.linear(1.5),viewInsets:const EdgeInsets.only(bottom:280)),child:child!),home:const VoicePage())));
    await t.pumpAndSettle();expect(t.takeException(),isNull);await cleanup(t);
  });

}
