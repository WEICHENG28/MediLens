import 'package:flutter_test/flutter_test.dart';
import 'package:medilens/core/care_events.dart';
import 'package:medilens/core/care_reminders.dart';

void main() {
  final now = DateTime(2026, 11, 17, 19, 10);

  test('送往后端只带时间、类型与数值；日记文字不送出；旧版拍餐字段换成新名称', () {
    expect(careEventJson({'id': 'x', 'type': 'note', 'time': '2026-11-17T08:00:00', 'text': '心情不好'}), isNull);
    final g = careEventJson({'id': 'a', 'type': 'glucose', 'time': '2026-11-17T08:00:00', 'glucose': 7.2, 'after': 'meal',
      'glucose_source': 'finger'})!;
    expect(g.keys, unorderedEquals(['type', 'time', 'glucose', 'glucose_source']));
    final old = careEventJson({'type': 'meal', 'time': '2026-11-17T18:00:00', 'meal_food': '米饭', 'meal_grams': 150,
      'meal_carbs_g': 42.0, 'meal_fdc_id': 1})!;
    expect(old['food'], '米饭');
    expect(old['grams'], 150);
    expect(old['carbs_g'], 42.0);
    expect(old['estimate'], 'photo');
    expect(old.containsKey('meal_fdc_id'), isFalse);
    expect(careEventsJson([{'type': 'note', 'time': 't'}, {'type': 'wake', 'time': 't'}]), hasLength(1));
  });

  test('餐次推断与后端一致', () {
    expect(mealSlotFor(DateTime(2026, 1, 1, 7)), 'breakfast');
    expect(mealSlotFor(DateTime(2026, 1, 1, 12)), 'lunch');
    expect(mealSlotFor(DateTime(2026, 1, 1, 19)), 'dinner');
  });

  test('份量修正：碳水按比例换算，第一次的原始估算保留，再修正也不覆盖', () {
    final meal = {'type': 'meal', 'time': '2026-11-11T18:15:00', 'grams': 200.0, 'carbs_g': 64.0, 'sugars_g': 2.0};
    final once = correctPortion(meal, 280, '家属', now);
    expect(once['grams'], 280);
    expect(once['carbs_g'], 89.6);
    expect(once['original_grams'], 200.0);
    expect(once['original_carbs_g'], 64.0);
    expect(once['corrected_by'], '家属');
    final twice = correctPortion(once, 250, '本人', now);
    expect(twice['original_grams'], 200.0);
    expect(twice['carbs_g'], 80.0);
    expect(meal['grams'], 200.0); // 不改动原记录
  });

  group('说一句话记录', () {
    List<String> types(String s) => [for (final r in parseVoiceRecord(s, now)) r.event['type'] as String];

    test('进餐、餐次与甜饮料', () {
      final r = parseVoiceRecord('我刚吃了一碗米饭和红烧肉，还喝了可乐', now).single;
      expect(r.event['type'], 'meal');
      expect(r.event['meal_slot'], 'dinner');
      expect(r.event['sweet_drink'], isTrue);
      expect(r.event['estimate'], 'voice');
      expect(r.event.containsKey('carbs_g'), isFalse); // 不知道份量，不估算
      expect(parseVoiceRecord('早饭吃了包子', now).single.event['meal_slot'], 'breakfast');
    });

    test('血糖、血压、体重、步数、运动', () {
      expect(parseVoiceRecord('血糖7.8', now).single.event, containsPair('glucose', 7.8));
      expect(parseVoiceRecord('监测仪血糖3.6', now).single.event['glucose_source'], 'cgm');
      final bp = parseVoiceRecord('血压135/80', now).single.event;
      expect([bp['systolic'], bp['diastolic']], [135, 80]);
      expect(parseVoiceRecord('体重66.5公斤', now).single.event['weight_kg'], 66.5);
      expect(parseVoiceRecord('今天走了4200步', now).map((r) => r.event['type']), contains('steps'));
      expect(parseVoiceRecord('饭后散步了二十分钟', now).single.event['minutes'], 20);
      expect(parseVoiceRecord('走了半小时', now).single.event['minutes'], 30);
    });

    test('用药与症状；吃药不会被当成进餐', () {
      expect(types('刚吃了药'), ['medication']);
      expect(parseVoiceRecord('忘了吃药', now).single.event['taken'], isFalse);
      expect(parseVoiceRecord('有点心慌出汗', now).single.event['symptoms'], unorderedEquals(['心悸', '出汗']));
    });

    test('听不懂就返回空，不乱记', () {
      expect(parseVoiceRecord('今天天气不错', now), isEmpty);
      expect(parseVoiceRecord('血糖999', now).where((r) => r.event['type'] == 'glucose'), isEmpty);
    });
  });

  test('照护提醒合并：同一提醒不重复，过去的不加入，一天前的清掉', () {
    CareReminder r(String title, DateTime at) => CareReminder(id: '$title$at', at: at, title: title, reason: '');
    final old = [r('测晚餐后 2 小时血糖', now.add(const Duration(hours: 2))), r('旧的', now.subtract(const Duration(days: 2)))];
    final merged = mergeCareReminders(old, [
      r('测晚餐后 2 小时血糖', now.add(const Duration(hours: 2, minutes: 5))), // 重复
      r('睡前测一次血糖', now.add(const Duration(hours: 3))),
      r('已经过去', now.subtract(const Duration(minutes: 1))),
    ], now);
    expect(merged.map((x) => x.title), ['测晚餐后 2 小时血糖', '睡前测一次血糖']);
    expect(CareReminder.fromJson(merged.first.toJson())!.title, merged.first.title);
    expect(CareReminder.fromJson({'bad': 1}), isNull);
  });
}
