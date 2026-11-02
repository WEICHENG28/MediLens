import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medilens/core/local_reminders.dart';
import 'package:medilens/data/local_store.dart';
import 'package:medilens/features/reminder_page.dart';

class FakePlatform extends LocalReminderPlatform {
  DateTime now = DateTime.now();
  final postponed = <String, int>{};
  final snoozeRequests = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> snooze(String id, int minutes, String day) async {
    if (fail) throw PlatformException(code: 'test_failure');
    snoozeRequests.add({'id': id, 'minutes': minutes, 'day': day});
    postponed[id] = now.add(Duration(minutes: minutes)).millisecondsSinceEpoch;
    return snapshot();
  }
  @override
  Future<Map<String, dynamic>> cancelSnooze(String id) async {
    if (fail) throw PlatformException(code: 'test_failure');
    postponed.remove(id); return snapshot();
  }
  @override
  Future<void> undoAcknowledge(String id) async {}
  final acknowledged = <String>[];
  @override
  Future<void> acknowledge(String id) async { acknowledged.add(id); postponed.remove(id); }
  bool allowed = true, enabled = false, fail = false;
  int permissionRequests = 0, tests = 0, replacements = 0;
  List<Map<String, dynamic>> plans = [];
  Map<String, dynamic> snapshot() => {'available': true, 'notificationsAllowed': allowed,
    'exactAllowed': false, 'scheduledCount': enabled ? plans.length : 0, 'snoozes': Map<String, int>.from(postponed)};
  @override
  Future<Map<String, dynamic>> status() async => snapshot();
  @override
  Future<Map<String, dynamic>> requestNotifications() async {
    permissionRequests++;
    return snapshot();
  }
  @override
  Future<Map<String, dynamic>> replace(bool value, List<Map<String, dynamic>> input) async {
    if (fail) throw PlatformException(code: 'test_failure');
    replacements++;
    enabled = value;
    plans = input;
    postponed.removeWhere((id, _) => !value || !input.any((p) => p['id'] == id));
    return snapshot();
  }
  @override
  Future<void> test() async { tests++; }
}

void main() {
  late MemoryStore store;
  late FakePlatform platform;
  late ProviderContainer container;
  setUp(() {
    store = MemoryStore(); platform = FakePlatform();
    container = ProviderContainer(overrides: [
      localStoreProvider.overrideWithValue(store),
      localReminderPlatformProvider.overrideWithValue(platform),
    ]);
  });
  tearDown(() => container.dispose());
  Future<void> schedule() => store.putSetting('life_schedule', jsonEncode([
    {'task': 'medication', 'time': '08:30', 'label': '私密药名'},
    {'task': 'insulin', 'time': '19:00', 'label': '个人信息'},
  ]));

  test('默认关闭，加载及新增计划均不请求权限或创建通知', () async {
    await schedule();
    final notifier = container.read(remindersProvider.notifier);
    await notifier.load(); await notifier.syncFromStore();
    expect(platform.permissionRequests, 0);
    expect(platform.replacements, 0);
    expect(container.read(remindersProvider).enabled, isFalse);
  });

  test('开启仅向系统传输不透明 ID 和时分，身份及任务类型留在加密存储', () async {
    await schedule();
    final notifier = container.read(remindersProvider.notifier);
    expect(await notifier.setEnabled(true), isTrue);
    expect(platform.plans, hasLength(2));
    for (final plan in platform.plans) {
      expect(plan.keys.toSet(), {'id', 'hour', 'minute'});
      expect(plan['id'], matches(RegExp(r'^[a-f0-9-]{36}$')));
    }
    expect(platform.plans.first['hour'], 8);
    expect(platform.plans.first['minute'], 30);
    final ids = platform.plans.map((p) => p['id']).toList();
    await notifier.syncFromStore();
    expect(platform.plans.map((p) => p['id']).toList(), ids);
    expect(container.read(remindersProvider).plannedCount, 2);
  });

  test('拒绝通知权限不把提醒标记为开启', () async {
    platform.allowed = false;
    expect(await container.read(remindersProvider.notifier).setEnabled(true), isFalse);
    expect(platform.replacements, 0);
    expect(await store.getSetting(ReminderNotifier.enabledKey), isNot('true'));
    expect(container.read(remindersProvider).notificationsAllowed, isFalse);
  });

  test('删除计划后同步会撤销它；关闭后撤销全部并保存关闭状态', () async {
    await schedule();
    final notifier = container.read(remindersProvider.notifier);
    await notifier.setEnabled(true);
    await store.putSetting('life_schedule', '[]');
    await notifier.syncFromStore();
    expect(platform.plans, isEmpty);
    expect(await notifier.setEnabled(false), isTrue);
    expect(platform.enabled, isFalse);
    expect(await store.getSetting(ReminderNotifier.enabledKey), 'false');
  });

  test('取消失败不能声称已关闭，也不清除开启标记', () async {
    await schedule();
    final notifier = container.read(remindersProvider.notifier);
    await notifier.setEnabled(true);
    platform.fail = true;
    expect(await notifier.setEnabled(false), isFalse);
    expect(await store.getSetting(ReminderNotifier.enabledKey), 'true');
    expect(container.read(remindersProvider).enabled, isTrue);
    expect(container.read(remindersProvider).error, isNotNull);
  });

  test('启动时恢复开启的计划；无效时间拒绝同步且仍可关闭', () async {
    await store.putSetting(ReminderNotifier.enabledKey, 'true');
    await schedule();
    final notifier = container.read(remindersProvider.notifier);
    await notifier.load();
    expect(platform.plans, hasLength(2));
    await store.putSetting('life_schedule', '[{"task":"medication","time":"29:60"}]');
    final previous = platform.replacements;
    await notifier.load();
    expect(platform.replacements, previous);
    expect(container.read(remindersProvider).available, isTrue);
    expect(container.read(remindersProvider).error, isNotNull);
    expect(await notifier.setEnabled(false), isTrue);
  });

  test('测试通知不会开启每日提醒或改动生活记录', () async {
    await schedule();
    final original = await store.getSetting('life_schedule');
    expect(await container.read(remindersProvider.notifier).sendTest(), isTrue);
    expect(platform.tests, 1);
    expect(platform.enabled, isFalse);
    expect(await store.getSetting('life_schedule'), original);
    expect(await store.getSetting(ReminderNotifier.enabledKey), isNull);
  });

  testWidgets('页面展示实际权限及时间，不暗示已经准时送达', (t) async {
    await schedule();
    await t.pumpWidget(UncontrolledProviderScope(container: container,
      child: const MaterialApp(home: ReminderPage())));
    await t.pumpAndSettle();
    expect(find.text('本机任务提醒'), findsOneWidget);
    expect(find.text('精确定时：未允许，提醒可能延后'), findsOneWidget);
    expect(find.text('08:30  吃药'), findsOneWidget);
    expect(platform.permissionRequests, 0);
  });
}
