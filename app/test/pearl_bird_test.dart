import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medilens/core/api_client.dart';
import 'package:medilens/core/task_receipts.dart';
import 'package:medilens/data/local_store.dart';
import 'package:medilens/features/life_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medilens/core/life_journal.dart';
import 'package:medilens/widgets/glucose_trend.dart';

Map<String, dynamic> ev(String time, [String type = 'meal', Map<String, dynamic> extra = const {}]) =>
    {'id': time, 'time': time, 'type': type, ...extra};

class OfflineApi extends ApiClient {
  OfflineApi() : super('https://unused.invalid');
  @override
  Future<Map<String, dynamic>> lifestyle(Map<String, dynamic> body) async => throw ApiException('合成测试：离线');
}

void main() {
  final now = DateTime(2026, 11, 8, 20, 0);

  test('珍珠鸟反应：超过 3 小时进来想你，打卡后打起精神；之后打卡开心', () {
    var b = birdReact(BirdMood.normal, BirdEvent.enterAfterIdle);
    expect(b.mood, BirdMood.low);
    b = birdReact(b.mood, BirdEvent.checkIn);
    expect(b.mood, BirdMood.recover);
    expect(birdReact(BirdMood.normal, BirdEvent.checkIn).mood, BirdMood.happy);
    expect(birdReact(BirdMood.normal, BirdEvent.enterRecent).mood, BirdMood.normal);
    expect(birdReact(BirdMood.normal, BirdEvent.enterAfterIdle, feedback: false).mood, BirdMood.normal);
  });

  test('血糖在目标范围内开心跳跃；超出范围给予关心，不显示低落', () {
    expect(birdReact(BirdMood.normal, BirdEvent.glucoseInRange).mood, BirdMood.happy);
    final out = birdReact(BirdMood.normal, BirdEvent.glucoseOutOfRange);
    expect(out.mood, isNot(BirdMood.low));
    expect(out.message, contains('记下来就很重要'));
    expect(out.message, isNot(contains('不好')));
  });

  test('今日记录数', () {
    expect(companionSummary([ev('2026-11-08T08:00:00'), ev('2026-11-07T08:00:00')], now).records, 1);
  });

  test('目标范围解析与中性标注', () {
    expect(parseTarget(null), (3.9, 10.0));
    expect(parseTarget('4.4-7.0'), (4.4, 7.0));
    expect(parseTarget('8-5'), (3.9, 10.0));
    expect(rangeLabel(3.5, (3.9, 10.0)), '低于目标范围');
    expect(rangeLabel(6.0, (3.9, 10.0)), '在目标范围内');
    expect(rangeLabel(12.0, (3.9, 10.0)), '高于目标范围');
  });

  test('趋势只取时间窗内的血糖记录并按时间排序', () {
    final events = [
      ev('2026-11-08T07:00:00', 'glucose', {'glucose': 6.1}),
      ev('2026-11-02T07:00:00', 'glucose', {'glucose': 7.2}),
      ev('2026-10-01T07:00:00', 'glucose', {'glucose': 9.0}),
      ev('2026-11-08T06:00:00', 'meal'),
    ];
    final week = glucosePoints(events, now.subtract(const Duration(days: 7)), now);
    expect(week.map((p) => p.$2), [7.2, 6.1]);
    expect(glucosePoints(events, now.subtract(const Duration(days: 1)), now), hasLength(1));
  });

  testWidgets('血糖变化面板：可切换一天/一周/一月，没有记录时说明', (t) async {
    final events = [ev('2026-11-08T07:00:00', 'glucose', {'glucose': 12.0}), ev('2026-11-06T07:00:00', 'glucose', {'glucose': 6.0})];
    await t.pumpWidget(MaterialApp(home: Scaffold(body: GlucoseTrendSheet(events: events, target: (3.9, 10.0), now: now))));
    expect(find.byKey(const Key('trend_chart')), findsOneWidget);
    expect(find.textContaining('共 2 次记录，其中 1 次在目标范围内'), findsOneWidget);
    await t.tap(find.text('一天')); await t.pumpAndSettle();
    expect(find.textContaining('共 1 次记录'), findsOneWidget);
    await t.pumpWidget(MaterialApp(home: Scaffold(body: GlucoseTrendSheet(events: const [], target: (3.9, 10.0), now: now))));
    expect(find.text('这段时间还没有血糖记录'), findsOneWidget);
  });

  testWidgets('首次进入：欢迎与初始血糖 → 设置目标 → 小鸟按目标范围反应，资料保存在本机', (t) async {
    final store = MemoryStore();
    t.view.physicalSize = const Size(1080, 2400); t.view.devicePixelRatio = 2.75; addTearDown(t.view.reset);
    await t.pumpWidget(ProviderScope(overrides: [localStoreProvider.overrideWithValue(store),
      apiClientProvider.overrideWithValue(OfflineApi()), taskClockProvider.overrideWithValue(() => now)],
      child: const MaterialApp(home: LifePage())));
    await t.pumpAndSettle();
    expect(find.text('欢迎来到生活打卡！'), findsOneWidget);
    await t.enterText(find.byKey(const Key('setup_glucose')), '6.5');
    await t.tap(find.byKey(const Key('setup_next'))); await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('setup_low')), '4.4');
    await t.enterText(find.byKey(const Key('setup_high')), '7');
    await t.ensureVisible(find.byKey(const Key('setup_done')));
    await t.tap(find.byKey(const Key('setup_done'))); await t.pumpAndSettle();
    expect(find.text('开心加油'), findsOneWidget); // 6.5 在 4.4–7 内
    expect(await store.getSetting('life_onboarded'), 'true');
    expect(await store.getSetting('life_glucose_target'), '4.4-7.0');
    expect(jsonDecode(await store.getSetting('life_meal_times') ?? '[]'), ['07:30', '12:00', '18:00']);
    final events = jsonDecode(await store.getSetting('life_events') ?? '[]') as List;
    expect(events.single['glucose'], 6.5);
    await t.pumpWidget(const SizedBox.shrink());
  });
}
