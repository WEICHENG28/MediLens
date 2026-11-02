import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medilens/core/task_receipts.dart';
import 'package:medilens/data/local_store.dart';
import 'package:medilens/core/local_reminders.dart';
import 'package:medilens/features/reminder_page.dart';
import 'local_reminders_test.dart' show FakePlatform;

class FailingStore extends MemoryStore {
  @override
  Future<void> putSetting(String key, String value) async { throw StateError('failed'); }
}

void main() {
  final now = DateTime(2026, 10, 31, 12);
  Map<String, dynamic> plan(String id, {String time = '08:00'}) => {'id': id, 'task': 'medication', 'time': time};
  late MemoryStore store;
  late ProviderContainer container;
  setUp(() { store = MemoryStore(); container = ProviderContainer(overrides: [localStoreProvider.overrideWithValue(store)]); });
  tearDown(() => container.dispose());

  test('同一天重复点击不会重复记录；重建后保留，次日独立', () async {
    final task = DailyTask(plan('a'), now);
    final notifier = container.read(taskReceiptsProvider.notifier);
    final results = await Future.wait([notifier.record(task, now), notifier.record(task, now)]);
    expect(results.where((v) => v).length, 1);
    expect(container.read(taskReceiptsProvider).length, 1);
    container.invalidate(taskReceiptsProvider);
    await container.read(taskReceiptsProvider.notifier).load();
    expect(container.read(taskReceiptsProvider).containsKey(task.key), isTrue);
    final tomorrow = DailyTask(plan('a'), now.add(const Duration(days: 1)));
    expect(container.read(taskReceiptsProvider).containsKey(tomorrow.key), isFalse);
  });

  test('未到时间、昨天任务和不同计划不串记录；支持撤销', () async {
    final notifier = container.read(taskReceiptsProvider.notifier);
    expect(await notifier.record(DailyTask(plan('a', time: '18:00'), now), now), isFalse);
    expect(await notifier.record(DailyTask(plan('a'), now.subtract(const Duration(days: 1))), now), isFalse);
    final a = DailyTask(plan('a'), now), b = DailyTask(plan('b'), now);
    await notifier.record(a, now);
    expect(container.read(taskReceiptsProvider).containsKey(b.key), isFalse);
    expect(await notifier.record(a, now, undo: true), isTrue);
    expect(container.read(taskReceiptsProvider), isEmpty);
    expect(jsonDecode((await store.getSetting(TaskReceipts.storageKey))!), isEmpty);
    expect(await store.getSetting('life_events'), isNull);
  });

  test('旧时间计划迁移为稳定 ID，不修改任务和时间', () async {
    await store.putSetting('life_schedule', '[{"task":"medication","time":"08:00","label":"私人备注"}]');
    final first = await loadTaskPlans(store), second = await loadTaskPlans(store);
    expect(first.first['id'], second.first['id']);
    expect(second.first['time'], '08:00');
    expect(second.first['label'], '私人备注');
  });

  test('存储失败不显示已完成', () async {
    final failed = ProviderContainer(overrides: [localStoreProvider.overrideWithValue(FailingStore())]);
    addTearDown(failed.dispose);
    await expectLater(failed.read(taskReceiptsProvider.notifier).record(DailyTask(plan('a'), now), now), throwsStateError);
    expect(failed.read(taskReceiptsProvider), isEmpty);
  });

  testWidgets('页面取消不记录，确认后完成，撤销后恢复待记录', (t) async {
    final platform = FakePlatform();
    t.view.physicalSize = const Size(1080, 2400); t.view.devicePixelRatio = 2.75;
    addTearDown(t.view.reset);
    await store.putSetting('life_schedule', '[{"id":"00000000-0000-4000-8000-000000000001","task":"medication","time":"00:00"}]');
    await t.pumpWidget(ProviderScope(overrides: [localStoreProvider.overrideWithValue(store),
      localReminderPlatformProvider.overrideWithValue(platform)], child: const MaterialApp(home: ReminderPage())));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('记录完成'), 250);
    await t.tap(find.text('记录完成')); await t.pumpAndSettle();
    await t.tap(find.text('取消')); await t.pumpAndSettle();
    expect(await store.getSetting(TaskReceipts.storageKey), isNull);
    await t.tap(find.text('记录完成')); await t.pumpAndSettle();
    await t.tap(find.text('确认已完成')); await t.pumpAndSettle();
    expect(find.textContaining('已记录完成'), findsOneWidget);
    expect(platform.acknowledged, ['00000000-0000-4000-8000-000000000001']);
    await t.tap(find.text('撤销')); await t.pumpAndSettle();
    await t.tap(find.text('确认撤销')); await t.pumpAndSettle();
    expect(find.text('待记录'), findsOneWidget);
    expect(await store.getSetting('life_events'), isNull);
    await t.pumpWidget(const SizedBox.shrink());
  });
}
