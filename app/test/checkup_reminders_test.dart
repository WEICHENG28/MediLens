import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medilens/core/checkup_reminders.dart';
import 'package:medilens/core/local_reminders.dart';
import 'package:medilens/core/task_receipts.dart';
import 'package:medilens/features/checkup_page.dart';
import 'local_reminders_test.dart' show FakePlatform;

class CheckupFake extends FakePlatform {
  final entries = <String, Map<String, dynamic>>{};
  int saves = 0;
  @override
  Future<Map<String, dynamic>> checkupStatus() async => {...snapshot(), 'checkups': {
    for (final e in entries.entries) e.key: Map<String, dynamic>.from(e.value)}};
  @override
  Future<Map<String, dynamic>> saveCheckup(String id, int at) async {
    if (this.fail) throw PlatformException(code: 'failed');
    saves++; entries[id] = {'at': at, 'state': 'scheduled'}; return checkupStatus();
  }
  @override
  Future<Map<String, dynamic>> cancelCheckup(String id) async {
    if (this.fail) throw PlatformException(code: 'failed');
    entries.remove(id); return checkupStatus();
  }
  @override
  Future<Map<String, dynamic>> clearCheckups() async {
    if (this.fail) throw PlatformException(code: 'failed');
    entries.clear(); return checkupStatus();
  }
}

void main() {
  final now = DateTime(2026, 10, 31, 12), future = DateTime(2026, 11, 1, 9);
  late CheckupFake platform;
  late ProviderContainer container;
  setUp(() {
    platform = CheckupFake();
    container = ProviderContainer(overrides: [localReminderPlatformProvider.overrideWithValue(platform),
      taskClockProvider.overrideWithValue(() => now)]);
  });
  tearDown(() => container.dispose());

  test('拒绝过去时间、拒绝权限和双击不会创建重复提醒', () async {
    final notifier = container.read(checkupProvider.notifier);
    expect(await notifier.save(now), isFalse); expect(platform.saves, 0);
    platform.allowed = false;
    expect(await notifier.save(future), isFalse); expect(platform.entries, isEmpty);
    expect(container.read(checkupProvider).allowed, isFalse);
    platform.allowed = true;
    final result = await Future.wait([notifier.save(future), notifier.save(future)]);
    expect(result.where((v) => v), hasLength(1)); expect(platform.entries, hasLength(1));
    expect(await notifier.save(future), isFalse);
  });

  test('修改保留同一个 ID，重新读取保留提醒；关闭每日通知不影响复查', () async {
    final notifier = container.read(checkupProvider.notifier);
    await notifier.save(future);
    final id = platform.entries.keys.single;
    expect(await notifier.save(future.add(const Duration(days: 1)), id: id), isTrue);
    expect(platform.entries, hasLength(1));
    container.invalidate(checkupProvider); await container.read(checkupProvider.notifier).load();
    expect(container.read(checkupProvider).entries.single.id, id);
    await platform.replace(false, []);
    expect(platform.entries, hasLength(1));
  });

  test('保存和取消失败保留旧状态；删除全部撤销复查', () async {
    final notifier = container.read(checkupProvider.notifier);
    await notifier.save(future); final before = container.read(checkupProvider).entries.single;
    platform.fail = true;
    expect(await notifier.save(future.add(const Duration(days: 1)), id: before.id), isFalse);
    expect(await notifier.cancel(before.id), isFalse);
    expect(container.read(checkupProvider).entries.single.at, before.at);
    expect(await notifier.clearAll(), isFalse);
    platform.fail = false; expect(await notifier.clearAll(), isTrue);
    expect(container.read(checkupProvider).entries, isEmpty);
  });

  testWidgets('手选日期和时间后再次确认才保存；取消提醒需确认', (t) async {
    t.view.physicalSize = const Size(1080, 2400); t.view.devicePixelRatio = 2.75; addTearDown(t.view.reset);
    await t.pumpWidget(UncontrolledProviderScope(container: container, child: const MaterialApp(home: CheckupPage())));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('add_checkup'))); await t.pumpAndSettle();
    await t.tap(find.text('OK')); await t.pumpAndSettle();
    await t.tap(find.text('OK')); await t.pumpAndSettle();
    expect(platform.saves, 0);
    expect(find.textContaining('2026-11-01 09:00'), findsOneWidget);
    await t.tap(find.text('确认并保存')); await t.pumpAndSettle();
    expect(platform.saves, 1);
    expect(find.text('已安排一次性提醒'), findsOneWidget);
    await t.tap(find.text('取消提醒')); await t.pumpAndSettle();
    await t.tap(find.text('保留')); await t.pumpAndSettle();
    expect(platform.entries, hasLength(1));
    await t.tap(find.text('取消提醒')); await t.pumpAndSettle();
    await t.tap(find.widgetWithText(FilledButton, '取消提醒')); await t.pumpAndSettle();
    expect(platform.entries, isEmpty);
    await t.pumpWidget(const SizedBox.shrink());
  });
}
