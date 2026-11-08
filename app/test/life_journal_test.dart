import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medilens/core/api_client.dart';
import 'package:medilens/core/life_journal.dart';
import 'package:medilens/core/task_receipts.dart';
import 'package:medilens/data/local_store.dart';
import 'package:medilens/features/life_page.dart';
import 'package:medilens/features/reminder_page.dart';
import 'package:medilens/core/local_reminders.dart';
import 'package:medilens/core/desktop_pet.dart';
import 'local_reminders_test.dart' show FakePlatform;

class OfflineApi extends ApiClient {
  final bodies = <Map<String, dynamic>>[];
  OfflineApi() : super('https://unused.invalid');
  @override
  Future<Map<String, dynamic>> lifestyle(Map<String, dynamic> body) async {
    bodies.add(body); throw ApiException('合成测试：离线');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2026, 10, 31, 12);
  final manual = {'id': 'manual-one', 'type': 'medication', 'taken': true, 'time': '2026-10-31T08:00:00'};
  DailyTask task(String id) => DailyTask({'id': id, 'task': 'medication', 'time': '08:00'}, now);
  late MemoryStore store;
  late ProviderContainer container;
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(DesktopPet.channel, (_) async => null);
    store = MemoryStore(); container = ProviderContainer(overrides: [localStoreProvider.overrideWithValue(store)]);
  });
  tearDown(() {
    container.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(DesktopPet.channel, null);
  });

  test('明确关联只计算一次；重新读取不重复，撤销保留手动记录', () async {
    await store.putSetting('life_events', jsonEncode([manual]));
    final receipts = container.read(taskReceiptsProvider.notifier);
    expect(await receipts.record(task('one'), now, manualEventId: 'manual-one'), isTrue);
    expect(effectiveLifeEvents([manual], container.read(taskReceiptsProvider), receipts.manualLinks), hasLength(1));
    await receipts.load();
    expect(receipts.manualLinks[task('one').key], 'manual-one');
    expect(effectiveLifeEvents([manual], container.read(taskReceiptsProvider), receipts.manualLinks), hasLength(1));
    expect(await receipts.record(task('one'), now, undo: true), isTrue);
    expect((await loadManualEvents(store)), hasLength(1));
    expect(container.read(taskReceiptsProvider), isEmpty);
  });

  test('时间再接近也不自动合并；重复关联同一打卡和错误类型被拒绝', () async {
    await store.putSetting('life_events', jsonEncode([manual]));
    final receipts = container.read(taskReceiptsProvider.notifier);
    await receipts.record(task('one'), now);
    expect(effectiveLifeEvents([manual], container.read(taskReceiptsProvider), receipts.manualLinks), hasLength(2));
    await receipts.record(task('one'), now, undo: true);
    expect(await receipts.record(task('one'), now, manualEventId: 'manual-one'), isTrue);
    expect(await receipts.record(task('two'), now, manualEventId: 'manual-one'), isFalse);
    final other = DailyTask({'id': 'insulin', 'task': 'insulin', 'time': '08:00'}, now);
    expect(await receipts.record(other, now, manualEventId: 'manual-one'), isFalse);
  });

  test('任务派生记录不会写入手动列表；旧回执兼容，未来记录不奖励', () async {
    await store.putSetting(TaskReceipts.storageKey, jsonEncode({task('one').key: now.toIso8601String()}));
    final receipts = container.read(taskReceiptsProvider.notifier); await receipts.load();
    final events = effectiveLifeEvents([], container.read(taskReceiptsProvider), receipts.manualLinks);
    expect(events, hasLength(1));
    expect(await store.getSetting('life_events'), isNull);
    expect(companionSummary(events, now).records, 1);
    expect(companionSummary(events, now.subtract(const Duration(hours: 1))).records, 0);
    expect(companionSummary([], now).message, contains('也没关系'));
    expect(companionSummary([{...manual, 'taken': false}], now).records, 1);
  });

  testWidgets('离线也显示温和反馈，任务后手动打卡要明确选择是否同一次', (t) async {
    await container.read(taskReceiptsProvider.notifier).record(task('one'), now);
    final api = OfflineApi();
    await store.putSetting('life_onboarded', 'true'); // 已完成首次设置的用户
    t.view.physicalSize = const Size(1080, 2400); t.view.devicePixelRatio = 2.75; addTearDown(t.view.reset);
    await t.pumpWidget(ProviderScope(overrides: [localStoreProvider.overrideWithValue(store),
      apiClientProvider.overrideWithValue(api), taskClockProvider.overrideWithValue(() => now)],
      child: const MaterialApp(home: LifePage())));
    await t.pumpAndSettle();
    expect(find.textContaining('今天已经记下 1 条记录'), findsOneWidget);
    expect(find.text('健康（按时用药）'), findsNothing);
    expect(api.bodies.last['negative_feedback'], isFalse);
    expect(api.bodies.last['events'] as List, hasLength(1));
    await t.ensureVisible(find.byKey(const Key('life_吃了药')));
    await t.tap(find.byKey(const Key('life_吃了药'))); await t.pumpAndSettle();
    await t.tap(find.text('同一次，不重复记录')); await t.pumpAndSettle();
    expect(await store.getSetting('life_events'), isNull);
    await t.tap(find.byKey(const Key('life_吃了药'))); await t.pumpAndSettle();
    await t.tap(find.text('不是同一次，另记一次')); await t.pumpAndSettle();
    expect(find.textContaining('已记录打卡吃药'), findsOneWidget); // 弹窗显示这次打卡的时间
    await t.tap(find.byKey(const Key('glucose_skip'))); await t.pumpAndSettle(); // 打卡后询问血糖：这次没测
    expect(await loadManualEvents(store), hasLength(1));
    expect(api.bodies.last['events'] as List, hasLength(2));
    await t.drag(find.byType(ListView).first, const Offset(0, 3000)); await t.pumpAndSettle(); // 回到顶部看珍珠鸟卡片
    expect(find.textContaining('今天已经记下 2 条记录'), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('已有手动记录时必须明确选择，关联后只计一次，撤销不删原打卡', (t) async {
    await store.putSetting('life_events', jsonEncode([manual]));
    await store.putSetting('life_schedule', '[{"id":"00000000-0000-4000-8000-000000000001","task":"medication","time":"08:00"}]');
    t.view.physicalSize = const Size(1080, 2400); t.view.devicePixelRatio = 2.75; addTearDown(t.view.reset);
    await t.pumpWidget(ProviderScope(overrides: [localStoreProvider.overrideWithValue(store),
      localReminderPlatformProvider.overrideWithValue(FakePlatform()), taskClockProvider.overrideWithValue(() => now)],
      child: const MaterialApp(home: ReminderPage())));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('记录完成'), 200);
    await t.tap(find.text('记录完成')); await t.pumpAndSettle();
    expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, '确认已完成')).onPressed, isNull);
    await t.tap(find.byType(DropdownButton<String>)); await t.pumpAndSettle();
    await t.tap(find.text('同一次：使用 08:00 的打卡').last); await t.pumpAndSettle();
    await t.tap(find.text('确认已完成')); await t.pumpAndSettle();
    await container.read(taskReceiptsProvider.notifier).load();
    expect(effectiveLifeEvents(await loadManualEvents(store), container.read(taskReceiptsProvider),
      container.read(taskReceiptsProvider.notifier).manualLinks), hasLength(1));
    await t.tap(find.text('撤销')); await t.pumpAndSettle();
    await t.tap(find.text('确认撤销')); await t.pumpAndSettle();
    expect(await loadManualEvents(store), hasLength(1));
    await t.pumpWidget(const SizedBox.shrink());
  });

  test('关闭陪伴和演示模式只给桌面通用平静状态；读取最新记录避免撤销后旧奖励', () async {
    final moods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(DesktopPet.channel, (call) async {
      moods.add((call.arguments as Map)['mood'] as String); return null;
    });
    await store.putSetting('life_events', jsonEncode([manual]));
    await store.putSetting('life_companion_enabled', 'false');
    await updateLocalCompanion(store, now);
    expect(moods.last, 'calm');
    await store.putSetting('life_companion_enabled', 'true');
    await updateLocalCompanion(store, now);
    expect(moods.last, 'active');
    await store.putSetting('life_demo_mode', 'true');
    await updateLocalCompanion(store, now);
    expect(moods.last, 'calm');
    await store.putSetting('life_demo_mode', 'false');
    await store.putSetting('life_events', '[]');
    await store.putSetting(TaskReceipts.storageKey, '{}');
    await updateLocalCompanion(store, now);
    expect(moods.last, 'calm');
  });
}
