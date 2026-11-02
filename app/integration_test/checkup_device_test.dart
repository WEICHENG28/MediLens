// Empty authorized test emulator only; never schedules real appointments.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:medilens/core/local_reminders.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('复查原生联测：未来时间、修改、独立取消与一次触发', (t) async {
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: Text('合成测试：一次性提醒'))));
    final platform = LocalReminderPlatform();
    final original = await platform.checkupStatus();
    expect(original['checkups'] as Map, isEmpty, reason: 'Empty test device only');
    expect(original['scheduledCount'], 0);
    expect(original['notificationsAllowed'], isTrue);
    const id = '00000000-0000-4000-8000-000000000077';
    const other = '00000000-0000-4000-8000-000000000078';
    final first = DateTime.now().add(const Duration(minutes: 2)).millisecondsSinceEpoch;
    try {
      var state = await platform.saveCheckup(id, first);
      expect((state['checkups'] as Map).length, 1);
      await expectLater(platform.saveCheckup(id, DateTime.now().millisecondsSinceEpoch - 1000), throwsA(isA<PlatformException>()));
      expect(((await platform.checkupStatus())['checkups'] as Map)[id]['at'], first);
      await expectLater(platform.saveCheckup(other, first), throwsA(isA<PlatformException>()));
      final target = DateTime.now().add(const Duration(seconds: 12)).millisecondsSinceEpoch;
      state = await platform.saveCheckup(id, target);
      expect((state['checkups'] as Map).length, 1);
      await platform.replace(false, []);
      expect(((await platform.checkupStatus())['checkups'] as Map)[id]['at'], target);
      final deadline = DateTime.now().add(const Duration(seconds: 35));
      var notificationState = 'scheduled';
      while (DateTime.now().isBefore(deadline)) {
        state = await platform.checkupStatus();
        notificationState = (state['checkups'] as Map)[id]['state'] as String;
        if (notificationState != 'scheduled') break;
        await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
      }
      expect(notificationState, 'sent');
      await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
      expect(((await platform.checkupStatus())['checkups'] as Map)[id]['state'], 'sent');
      state = await platform.cancelCheckup(id);
      expect(state['checkups'] as Map, isEmpty);
      // ignore: avoid_print
      print('[CHECKUP] create_edit_past_rejected_independent_once_trigger_cancel=passed');
    } finally { await platform.clearCheckups(); }
  });
}
