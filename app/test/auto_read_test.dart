import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medilens/core/settings.dart';
import 'package:medilens/core/speech.dart';
import 'package:medilens/widgets/common.dart';

import 'speech_test.dart' show FakeSpeech, container;

import 'package:medilens/data/local_store.dart';

void main() {
  Future<void> host(WidgetTester t, ProviderContainer c, String text) async {
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          navigatorObservers: [speechRoutes],
          home: Scaffold(body: ReadAloudButton(text, autoRead: true)),
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  Future<void> enabled(ProviderContainer c, bool value) => c
      .read(settingsProvider.notifier)
      .update(c.read(settingsProvider).copyWith(autoRead: value));
  test('新版本默认关闭且旧未实现开关不自动开启；新选择可保存', () {
    expect(const AppSettings().autoRead, isFalse);
    expect(AppSettings.fromJson({'autoRead': true}).autoRead, isFalse);
    expect(
      AppSettings.fromJson(const AppSettings(autoRead: true).toJson()).autoRead,
      isTrue,
    );
  });
  test('朗读摘要优先保留紧急行动，再解释不确定性', () {
    final text = overviewSpeechText({
      'urgent_alert': {'show': true, 'message': '合成紧急行动'},
      'overall': {'label': '无法判断', 'explanation': '缺少确认信息不等于正常'},
      'hits': [
        {'summary': '合成提示'},
      ],
    });
    expect(text.startsWith('合成紧急行动'), isTrue);
    expect(text, contains('不能代替医生诊断'));
    expect(text, contains('不等于正常'));
  });
  testWidgets('默认静默，主动开启后只读一次；重建和播放完成不重复', (t) async {
    final p = FakeSpeech();
    final scope = container(p, MemoryStore());
    addTearDown(scope.dispose);
    await host(t, scope, '合成摘要');
    expect(p.spoken, isEmpty);
    await enabled(scope, true);
    await t.pumpAndSettle();
    expect(p.spoken, ['合成摘要']);
    p.completed();
    await t.pumpAndSettle();
    await host(t, scope, '合成摘要');
    expect(p.spoken, ['合成摘要']);
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump();
  });
  testWidgets('手动停止不重复启动，内容更新只朗读新摘要，关闭设置立即停止', (t) async {
    final p = FakeSpeech();
    final scope = container(p, MemoryStore());
    addTearDown(scope.dispose);
    await enabled(scope, true);
    await host(t, scope, '旧摘要');
    await t.tap(find.byTooltip('停止朗读'));
    await t.pumpAndSettle();
    expect(p.spoken, ['旧摘要']);
    await host(t, scope, '新摘要');
    expect(p.spoken, ['旧摘要', '新摘要']);
    await enabled(scope, false);
    await t.pumpAndSettle();
    expect(scope.read(speechProvider).speaking, isFalse);
    expect(p.spoken.length, 2);
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump();
  });
  testWidgets('切页停止，返回相同内容不重播；后台停止且恢复不重播', (t) async {
    final p = FakeSpeech();
    final c = container(p, MemoryStore());
    addTearDown(c.dispose);
    await enabled(c, true);
    await host(t, c, '合成摘要');
    final context = t.element(find.byType(ReadAloudButton));
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('下一页')),
      ),
    );
    await t.pumpAndSettle();
    expect(c.read(speechProvider).speaking, isFalse);
    Navigator.of(context).pop();
    await t.pumpAndSettle();
    expect(p.spoken.length, 1);
    await t.tap(find.byTooltip('朗读'));
    await t.pumpAndSettle();
    expect(p.spoken.length, 2);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await t.pumpAndSettle();
    expect(c.read(speechProvider).speaking, isFalse);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpAndSettle();
    expect(p.spoken.length, 2);
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump();
  });
  testWidgets('缺少离线中文音色提示错误，不自动循环重试', (t) async {
    final p = FakeSpeech()..available = [];
    final c = container(p, MemoryStore());
    addTearDown(c.dispose);
    await enabled(c, true);
    await host(t, c, '合成摘要');
    expect(p.spoken, isEmpty);
    expect(find.textContaining('无法朗读'), findsOneWidget);
    await t.pump(const Duration(seconds: 5));
    expect(p.spoken, isEmpty);
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump();
  });
  testWidgets('其他朗读按钮不因全局开关自动播放', (t) async {
    final p = FakeSpeech();
    final c = container(p, MemoryStore());
    addTearDown(c.dispose);
    await enabled(c, true);
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: Scaffold(body: ReadAloudButton('其他内容'))),
      ),
    );
    await t.pumpAndSettle();
    expect(p.spoken, isEmpty);
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump();
  });
  testWidgets('音色检测尚未完成时退后台，迟到结果不能播放', (t) async {
    final p = FakeSpeech()..gate = Completer<dynamic>();
    final c = container(p, MemoryStore());
    addTearDown(c.dispose);
    await enabled(c, true);
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(
          home: Scaffold(body: ReadAloudButton('合成摘要', autoRead: true)),
        ),
      ),
    );
    await t.pump();
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await t.pump();
    p.gate!.complete(p.available);
    await t.pumpAndSettle();
    expect(p.spoken, isEmpty);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpAndSettle();
    expect(p.spoken, isEmpty);
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump();
  });
}
