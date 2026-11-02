import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medilens/core/history_trends.dart';
import 'package:medilens/core/task_receipts.dart';
import 'package:medilens/data/local_store.dart';
import 'package:medilens/features/history_trends_page.dart';

SavedReport report(String id, String? date, {String code = 'UACR', String value = '30',
  String? unit = 'mg/g', String? reference = '<30', String status = 'confirmed', bool duplicate = false}) {
  final item = {'code': code, 'original_label': code, 'raw_value': value, 'unit': unit,
    'reference_text': reference, 'review_status': status};
  return SavedReport(id: id, testDate: date, savedAt: DateTime(2026, 10, 31, 12),
    reportType: 'urinalysis+uacr', items: [item, if (duplicate) Map<String, dynamic>.from(item)], answers: {});
}

void main() {
  final now = DateTime(2026, 10, 31);
  test('严格检验日期，不用保存日期补缺，不绘制未来检验', () {
    expect(strictReportDate('2026-02-30'), isNull);
    expect(strictReportDate('2026-2-3'), isNull);
    expect(strictReportDate('0000-01-01'), isNull);
    expect(strictReportDate('2024-02-29'), DateTime(2024, 2, 29));
    final data = historyTrend([report('a', null), report('b', '2026-11-01')], 'UACR', now: now);
    expect(data.groups, isEmpty); expect(data.omissions, hasLength(2));
  });
  test('原单位和参考范围分别分组，不换算、不修改原始记录', () {
    final reports = [report('a', '2026-10-01'), report('b', '2026-10-02', value: '5', unit: 'mg/mmol'),
      report('c', '2026-10-03', reference: '<20')];
    final data = historyTrend(reports, 'UACR', now: now);
    expect(data.groups, hasLength(3));
    expect(data.groups.map((g) => g.points.single.value).toList(), [30, 5, 30]);
    expect(reports[1].items.single['raw_value'], '5');
  });
  test('待确认、未知、已排除、不等号、重复行及未知单位不绘制', () {
    final reports = [
      for (final status in ['needs_confirmation', 'unknown', 'excluded']) report(status, '2026-10-01', status: status),
      report('bound', '2026-10-02', value: '<30'), report('duplicate', '2026-10-03', duplicate: true),
      report('unit', '2026-10-04', unit: null), report('huge', '2026-10-05', value: '99999999999'),
    ];
    final data = historyTrend(reports, 'UACR', now: now);
    expect(data.groups, isEmpty); expect(data.omissions, hasLength(7));
  });
  test('自动识别点不可连线；同日多记录不猜顺序；无范围不连线', () {
    expect(historyTrend([report('a', '2026-10-01'), report('b', '2026-10-02', status: 'auto_accepted')], 'UACR', now: now).groups.single.canConnect, isFalse);
    expect(historyTrend([report('a', '2026-10-01'), report('b', '2026-10-01')], 'UACR', now: now).groups.single.canConnect, isFalse);
    expect(historyTrend([report('a', '2026-10-01', reference: null), report('b', '2026-10-02', reference: null)], 'UACR', now: now).groups.single.canConnect, isFalse);
  });
  test('按检验日期排序，保留原写法；定性等级不转数字', () {
    final data = historyTrend([report('late', '2026-10-20', code: 'SG', value: '1.020', unit: null, reference: '1.003-1.030'),
      report('early', '2026-10-01', code: 'SG', value: '1.010', unit: null, reference: '1.003-1.030')], 'SG', now: now);
    expect(data.groups.single.points.first.report.id, 'early');
    expect(data.groups.single.points.last.raw, '1.020');
    expect(data.groups.single.canConnect, isTrue);
    final qualitative = historyTrend([report('glu', '2026-10-01', code: 'GLU', value: '2+', unit: null)], 'GLU', now: now);
    expect(qualitative.groups, isEmpty); expect(qualitative.omissions.single.raw, '2+');
  });
  testWidgets('连线需主动核对，数据增加后原勾选失效', (t) async {
    final store = MemoryStore();
    await store.saveReport(report('a', '2026-10-01')); await store.saveReport(report('b', '2026-10-10', value: '40'));
    final container = ProviderContainer(overrides: [localStoreProvider.overrideWithValue(store), taskClockProvider.overrideWithValue(() => now)]);
    addTearDown(container.dispose);
    t.view.physicalSize = const Size(1080, 2400); t.view.devicePixelRatio = 2.75; addTearDown(t.view.reset);
    await t.pumpWidget(UncontrolledProviderScope(container: container, child: const MaterialApp(home: HistoryTrendsPage())));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.byType(CheckboxListTile), 200,
      scrollable: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down));
    expect(t.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value, isFalse);
    await t.tap(find.byType(CheckboxListTile)); await t.pumpAndSettle();
    expect(t.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value, isTrue);
    await store.saveReport(report('c', '2026-10-20', value: '35')); container.invalidate(historyProvider);
    await t.pumpAndSettle();
    expect(t.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value, isFalse);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('大字显示及空记录正常；自动识别不给可连线开关', (t) async {
    final store = MemoryStore(); await store.saveReport(report('a', '2026-10-01', status: 'auto_accepted'));
    final container = ProviderContainer(overrides: [localStoreProvider.overrideWithValue(store), taskClockProvider.overrideWithValue(() => now)]);
    addTearDown(container.dispose);
    await t.pumpWidget(UncontrolledProviderScope(container: container, child: MaterialApp(builder: (context, child) =>
      MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.5)), child: child!), home: const HistoryTrendsPage())));
    await t.pumpAndSettle();
    expect(find.byType(CheckboxListTile), findsNothing); expect(t.takeException(), isNull);
    await store.deleteAll(); container.invalidate(historyProvider); await t.pumpAndSettle();
    expect(find.text('本机还没有保存的报告'), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
  });
}
