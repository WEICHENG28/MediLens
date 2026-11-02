import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medilens/core/local_reminders.dart';
import 'package:medilens/core/task_receipts.dart';
import 'package:medilens/data/local_store.dart';
import 'package:medilens/features/reminder_page.dart';
import 'local_reminders_test.dart' show FakePlatform;

void main() {
  const id = '00000000-0000-4000-8000-000000000001';
  final now = DateTime(2026, 10, 31, 12);
  final plan = {'id': id, 'task': 'medication', 'time': '08:00', 'label': '私人备注'};
  late MemoryStore store;
  late FakePlatform platform;
  late ProviderContainer container;
  setUp(() async {
    store = MemoryStore(); platform = FakePlatform()..now = now;
    await store.putSetting('life_schedule', jsonEncode([plan]));
    container = ProviderContainer(overrides: [localStoreProvider.overrideWithValue(store),
      localReminderPlatformProvider.overrideWithValue(platform), taskClockProvider.overrideWithValue(() => now)]);
    await container.read(remindersProvider.notifier).setEnabled(true);
  });
  tearDown(() => container.dispose());

  test('跨日、未来任务及不支持的分钟数不允许延后', () {
    final task = DailyTask(plan, now);
    expect(snoozeTarget(task, 5, now), now.add(const Duration(minutes: 5)));
    expect(snoozeTarget(task, 5, DateTime(2026, 10, 31, 23, 58)), isNull);
    expect(snoozeTarget(task, 5, now.add(const Duration(days: 1))), isNull);
    expect(snoozeTarget(DailyTask({...plan, 'time': '18:00'}, now), 5, now), isNull);
    expect(snoozeTarget(task, 2, now), isNull);
  });

  test('并发点击只请求一次；再次选择替换时间，不改原计划或完成记录', () async {
    final notifier = container.read(remindersProvider.notifier), task = DailyTask(plan, now);
    final original = await store.getSetting('life_schedule');
    final result = await Future.wait([notifier.snoozeTask(task, 5), notifier.snoozeTask(task, 5)]);
    expect(result.where((v) => v), hasLength(1));
    expect(platform.snoozeRequests, [{'id': id, 'minutes': 5, 'day': '2026-10-31'}]);
    expect(await notifier.snoozeTask(task, 15), isTrue);
    expect(container.read(remindersProvider).snoozes, {id: now.add(const Duration(minutes: 15)).millisecondsSinceEpoch});
    expect(await store.getSetting('life_schedule'), original);
    expect(await store.getSetting(TaskReceipts.storageKey), isNull);
  });

  test('关闭、未授权或已经完成时不发送延后请求', () async {
    final notifier = container.read(remindersProvider.notifier), task = DailyTask(plan, now);
    await container.read(taskReceiptsProvider.notifier).record(task, now);
    expect(await notifier.snoozeTask(task, 5), isFalse);
    await container.read(taskReceiptsProvider.notifier).record(task, now, undo: true);
    platform.allowed = false; await notifier.load();
    expect(await notifier.snoozeTask(task, 5), isFalse);
    platform.allowed = true; await notifier.setEnabled(false);
    expect(await notifier.snoozeTask(task, 5), isFalse);
    expect(platform.snoozeRequests, isEmpty);
  });

  test('取消及关闭清理延后；失败不会误报已取消', () async {
    final notifier = container.read(remindersProvider.notifier), task = DailyTask(plan, now);
    await notifier.snoozeTask(task, 5);
    platform.fail = true;
    expect(await notifier.cancelPostponement(id), isFalse);
    expect(container.read(remindersProvider).snoozes.containsKey(id), isTrue);
    platform.fail = false;
    expect(await notifier.cancelPostponement(id), isTrue);
    expect(container.read(remindersProvider).snoozes, isEmpty);
    await notifier.snoozeTask(task, 5); await notifier.setEnabled(false);
    expect(platform.postponed, isEmpty);
  });

  testWidgets('取消对话框不安排；选择后显示时间；完成会清理延后', (t) async {
    t.view.physicalSize = const Size(1080, 2400); t.view.devicePixelRatio = 2.75;
    addTearDown(t.view.reset);
    await t.pumpWidget(UncontrolledProviderScope(container: container, child: const MaterialApp(home: ReminderPage())));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('稍后提醒'), 200);
    await t.tap(find.text('稍后提醒')); await t.pumpAndSettle();
    await t.tap(find.text('取消')); await t.pumpAndSettle();
    expect(platform.snoozeRequests, isEmpty);
    await t.tap(find.text('稍后提醒')); await t.pumpAndSettle();
    await t.tap(find.text('5 分钟后')); await t.pumpAndSettle();
    expect(find.text('已安排稍后提醒：12:05'), findsOneWidget);
    await t.tap(find.text('记录完成')); await t.pumpAndSettle();
    await t.tap(find.text('确认已完成')); await t.pumpAndSettle();
    expect(platform.postponed, isEmpty);
    expect(find.textContaining('已记录完成'), findsOneWidget);
    expect(find.text('稍后提醒'), findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
  });
}
