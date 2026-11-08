import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medilens/core/life_journal.dart';
import 'package:medilens/widgets/glucose_trend.dart';

Map<String, dynamic> ev(String time, [String type = 'meal', Map<String, dynamic> extra = const {}]) =>
    {'id': time, 'time': time, 'type': type, ...extra};

void main() {
  final now = DateTime(2026, 11, 8, 20, 0);

  test('珍珠鸟只回应有没有记录：刚打卡开心、隔两天以上想你/恢复，关闭反馈只显示日常', () {
    expect(companionSummary([], now).mood(), BirdMood.normal); // 从没记录过：日常
    expect(companionSummary([ev('2026-11-07T09:00:00')], now).mood(), BirdMood.normal); // 昨天记过
    expect(companionSummary([ev('2026-11-05T09:00:00')], now).mood(), BirdMood.low); // 隔了 3 天
    expect(companionSummary([ev('2026-11-05T09:00:00')], now).mood(feedback: false), BirdMood.normal);
    final back = [ev('2026-11-05T09:00:00'), ev('2026-11-08T08:00:00')];
    expect(companionSummary(back, now).mood(), BirdMood.recover);
    expect(companionSummary(back, now, justRecorded: true).mood(), BirdMood.happy);
    expect(companionSummary([], now, justRecorded: true).mood(), BirdMood.normal); // 没有今天的记录不会开心
  });

  test('血糖数值高低不影响珍珠鸟', () {
    final high = [ev('2026-11-08T08:00:00', 'glucose', {'glucose': 18.0})];
    final normal = [ev('2026-11-08T08:00:00', 'glucose', {'glucose': 6.0})];
    expect(companionSummary(high, now).mood(), companionSummary(normal, now).mood());
    expect(companionSummary(high, now).messageFor(BirdMood.normal), companionSummary(normal, now).messageFor(BirdMood.normal));
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
}
