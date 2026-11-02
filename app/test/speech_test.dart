import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medilens/core/speech.dart';
import 'package:medilens/data/local_store.dart';
import 'package:medilens/features/speech_page.dart';
import 'package:medilens/widgets/common.dart';

Map<String, String> voice(String name, {String locale = 'zh-CN', String network = '0', String features = ''}) =>
  {'name': name, 'locale': locale, 'network_required': network, 'features': features};
class FakeSpeech implements SpeechPlatform {
  dynamic available = [voice('中文甲'), voice('中文乙')];
  final spoken = <String>[];
  int stops = 0, speakResult = 1;
  bool fail = false;
  SpeechVoice? chosen;
  Completer<dynamic>? gate;
  late void Function() completed, cancelled, failed;
  @override Future<dynamic> voices() async { if (fail) throw StateError('private_native_error'); return gate == null ? available : await gate!.future; }
  @override Future<dynamic> useVoice(SpeechVoice v) async { chosen = v; return 1; }
  @override Future<dynamic> rate(double rate) async => 1;
  @override Future<dynamic> speak(String text) async { spoken.add(text); return speakResult; }
  @override Future<bool> openSettings() async => false;
  @override Future<dynamic> stop() async { stops++; return 1; }
  @override void handlers(void Function() done, void Function() cancel, void Function() error) { completed = done; cancelled = cancel; failed = error; }
}
ProviderContainer container(FakeSpeech p, MemoryStore store) => ProviderContainer(overrides: [
  speechPlatformProvider.overrideWithValue(p), localStoreProvider.overrideWithValue(store)]);
void main() {
  test('释放语音状态后延迟停止不会再次读取状态', () async {
    final scope = container(FakeSpeech(), MemoryStore());
    final n = scope.read(speechProvider.notifier); scope.dispose();
    await n.stop(owner: 'preview');
  });
  test('系统设置无法打开时显示手动路径', () async {
    final scope = container(FakeSpeech(), MemoryStore()); addTearDown(scope.dispose);
    await scope.read(speechProvider.notifier).openSettings();
    expect(scope.read(speechProvider).message, contains('手机设置'));
  });
  test('仅允许明确离线且已安装的普通话；缺元数据不猜测', () {
    final data = SpeechVoice.offlineChinese([voice('ok'), voice('online', network: '1'), voice('missing', features: 'notInstalled'),
      voice('en', locale: 'en-US'), voice('cantonese', locale: 'zh-HK'), {'name': 'unknown', 'locale': 'zh-CN'}, voice('ok')]);
    expect(data.map((v) => v.name), ['ok']);
  });
  test('音色持久化、重读、完成与异步错误状态', () async {
    final p = FakeSpeech(), store = MemoryStore();
    final scope = container(p, store); addTearDown(scope.dispose);
    final n = scope.read(speechProvider.notifier);
    await n.refresh(); await n.select(scope.read(speechProvider).voices.firstWhere((v) => v.name == '中文乙').id);
    await n.speak('仅用于合成测试', 'a'); expect(p.chosen!.name, '中文乙');
    expect(scope.read(speechProvider).speaking, isTrue); p.completed(); expect(scope.read(speechProvider).speaking, isFalse);
    await n.speak('第二段', 'b'); p.failed(); expect(scope.read(speechProvider).message, contains('朗读失败'));
    await n.refresh(); expect(scope.read(speechProvider).selected, isNotNull);
  });
  test('无音色、检测异常、音色被移除均不发送文本', () async {
    final p = FakeSpeech(), store = MemoryStore(); final scope = container(p, store); addTearDown(scope.dispose);
    final n = scope.read(speechProvider.notifier);
    p.available = []; await n.refresh(); expect(scope.read(speechProvider).message, contains('未检测到'));
    await n.speak('private text', 'a'); expect(p.spoken, isEmpty);
    p.fail = true; await n.refresh(); expect(scope.read(speechProvider).message, isNot(contains('private_native_error')));
    p.fail = false; p.available = [voice('中文甲')];
    await store.putSetting(SpeechNotifier.storageKey, 'removed'); await n.speak('private text', 'a'); expect(p.spoken, isEmpty);
  });
  test('检测期间停止会阻止后续播放，旧按钮不能停止新会话', () async {
    final p = FakeSpeech(); final scope = container(p, MemoryStore()); addTearDown(scope.dispose);
    final n = scope.read(speechProvider.notifier); p.gate = Completer<dynamic>();
    final speaking = n.speak('不应播放', 'a'); await Future<void>.delayed(Duration.zero);
    final stopping = n.stop(owner: 'a'); p.gate!.complete([voice('中文甲')]);
    await speaking; await stopping; expect(p.spoken, isEmpty);
    p.gate = null; await n.speak('甲', 'a'); await n.speak('乙', 'b');
    await n.stop(owner: 'a'); expect(scope.read(speechProvider).owner, 'b'); expect(scope.read(speechProvider).speaking, isTrue);
    await n.stop(owner: 'b'); expect(scope.read(speechProvider).speaking, isFalse);
  });
  testWidgets('缺中文音色时说明与重新检测可见，不展示试听', (t) async {
    final p = FakeSpeech()..available = []; final scope = container(p, MemoryStore()); addTearDown(scope.dispose);
    await t.pumpWidget(UncontrolledProviderScope(container: scope, child: const MaterialApp(home: SpeechPage()))); await t.pumpAndSettle();
    expect(find.text('重新检测中文语音'), findsOneWidget); expect(find.text('试听中文音色'), findsNothing);
    expect(find.byKey(const Key('speech_message')), findsOneWidget); expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox.shrink()); await t.pump();
  });
  testWidgets('选择和试听；大字显示；离开试听页会停止', (t) async {
    final p = FakeSpeech(); final scope = container(p, MemoryStore()); addTearDown(scope.dispose);
    await t.pumpWidget(UncontrolledProviderScope(container: scope, child: MaterialApp(builder: (context, child) =>
      MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.5)), child: child!), home: const SpeechPage())));
    await t.pumpAndSettle(); await t.tap(find.text('中文乙')); await t.pumpAndSettle();
    await t.ensureVisible(find.text('试听中文音色')); await t.pumpAndSettle();
    await Scrollable.ensureVisible(t.element(find.text('试听中文音色')), alignment: .5); await t.pumpAndSettle(); await t.tap(find.text('试听中文音色')); await t.pumpAndSettle();
    expect(p.chosen!.name, '中文乙'); expect(p.spoken, hasLength(1)); expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox.shrink()); await t.pump(); expect(scope.read(speechProvider).speaking, isFalse);
  });
  testWidgets('朗读按钮切换与异步错误提示，不残留播放状态', (t) async {
    final p = FakeSpeech(); final scope = container(p, MemoryStore()); addTearDown(scope.dispose);
    await t.pumpWidget(UncontrolledProviderScope(container: scope, child: const MaterialApp(home: Scaffold(body: Row(children: [ReadAloudButton('甲'), ReadAloudButton('乙')])))));
    await t.tap(find.byTooltip('朗读').first); await t.pumpAndSettle(); expect(find.byTooltip('停止朗读'), findsOneWidget);
    await t.tap(find.byTooltip('朗读').last); await t.pumpAndSettle(); expect(p.spoken, ['甲', '乙']);
    p.failed(); await t.pump(); expect(find.textContaining('朗读失败'), findsOneWidget); expect(find.byTooltip('停止朗读'), findsNothing);
    await t.pumpWidget(const SizedBox.shrink()); await t.pump();
  });
  test('系统拒绝播放时恢复按钮并报告错误', () async {
    final p = FakeSpeech()..speakResult = 0;
    final scope = container(p, MemoryStore()); addTearDown(scope.dispose);
    await scope.read(speechProvider.notifier).speak('合成测试', 'a');
    expect(scope.read(speechProvider).speaking, isFalse);
    expect(scope.read(speechProvider).message, contains('无法朗读'));
    expect(p.stops, greaterThanOrEqualTo(2));
  });
  testWidgets('跳转下一页和进入后台均停止当前报告朗读', (t) async {
    final p = FakeSpeech(); final scope = container(p, MemoryStore()); addTearDown(scope.dispose);
    await t.pumpWidget(UncontrolledProviderScope(container: scope, child: MaterialApp(navigatorObservers: [speechRoutes],
      home: Scaffold(body: Builder(builder: (context) => Column(children: [const ReadAloudButton('合成报告'),
        TextButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('下一页')))), child: const Text('前往下一页'))]))))));
    await t.tap(find.byTooltip('朗读')); await t.pumpAndSettle();
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive); await t.pump();
    expect(scope.read(speechProvider).speaking, isFalse);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.tap(find.byTooltip('朗读')); await t.pumpAndSettle();
    await t.tap(find.text('前往下一页')); await t.pumpAndSettle();
    expect(scope.read(speechProvider).speaking, isFalse); expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox.shrink()); await t.pump();
  });

}
