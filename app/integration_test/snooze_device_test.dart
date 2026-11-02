// Empty test emulator only. Never changes encrypted lifestyle/receipt records.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:medilens/core/local_reminders.dart';
import 'package:medilens/core/task_receipts.dart';
import 'package:medilens/data/local_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('原生稍后提醒：替换、撤销、完成、计划变更及关闭', (t) async {
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: Text('合成测试：本机提醒'))));
    final platform = LocalReminderPlatform();
    final original = await platform.status();
    expect(original['scheduledCount'], 0, reason: 'Only run on an empty test emulator');
    expect(original['snoozes'] as Map, isEmpty);
    expect(await SqlCipherStore().getSetting(ReminderNotifier.enabledKey), isNot('true'));
    expect(original['notificationsAllowed'], isTrue);
    final now = DateTime.now();
    expect(now.hour < 23 || now.minute < 29, isTrue, reason: 'Need enough time remaining in the test day');
    const id = '00000000-0000-4000-8000-000000000099';
    final plan = {'id': id, 'hour': 0, 'minute': 0};
    final day = taskDay(now);
    try {
      await platform.replace(true, [plan]);
      var state = await platform.snooze(id, 5, day);
      expect((state['snoozes'] as Map).length, 1);
      final first = (state['snoozes'] as Map)[id] as int;
      expect(first, greaterThanOrEqualTo(now.add(const Duration(minutes: 5)).millisecondsSinceEpoch));
      state = await platform.snooze(id, 15, day);
      expect((state['snoozes'] as Map).length, 1);
      expect((state['snoozes'] as Map)[id] as int, greaterThan(first));
      state = await platform.replace(true, [plan]);
      expect((state['snoozes'] as Map).length, 1, reason: 'Unchanged sync preserves postponement');
      state = await platform.cancelSnooze(id);
      expect(state['snoozes'] as Map, isEmpty);
      expect(state['scheduledCount'], 1);
      await platform.snooze(id, 5, day);
      await platform.acknowledge(id);
      expect((await platform.status())['snoozes'] as Map, isEmpty);
      await expectLater(platform.snooze(id, 5, day), throwsA(isA<PlatformException>()));
      await platform.undoAcknowledge(id);
      await platform.snooze(id, 5, day);
      state = await platform.replace(true, [{'id': id, 'hour': 0, 'minute': 1}]);
      expect(state['snoozes'] as Map, isEmpty, reason: 'Changing plan clears old postponement');
      await platform.snooze(id, 5, day);
      state = await platform.replace(true, []);
      expect(state['snoozes'] as Map, isEmpty);
      await platform.replace(true, [plan]);
      await platform.snooze(id, 5, day);
      state = await platform.replace(false, []);
      expect(state['snoozes'] as Map, isEmpty);
      expect(state['scheduledCount'], 0);
      // ignore: avoid_print
      print('[SNOOZE] native_replace_cancel_complete_plan_change_disable=passed');
    } finally { await platform.replace(false, []); }
  });
}
