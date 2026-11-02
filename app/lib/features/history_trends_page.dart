import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/history_trends.dart';
import '../core/task_receipts.dart';
import '../data/local_store.dart';
import '../ocr/report_parser.dart';

class HistoryTrendsPage extends ConsumerStatefulWidget {
  const HistoryTrendsPage({super.key});
  @override
  ConsumerState<HistoryTrendsPage> createState() => _HistoryTrendsPageState();
}

class _HistoryTrendsPageState extends ConsumerState<HistoryTrendsPage> {
  String? selectedCode;
  final confirmed = <String, String>{};
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('历史指标对照')),
    body: ref.watch(historyProvider).when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => const Center(child: Text('历史记录读取失败，请返回重试。')),
      data: (reports) {
        final codes = historyCodes(reports);
        if (codes.isEmpty) return Center(child: Text(reports.isEmpty ? '本机还没有保存的报告' : '没有可识别的指标代码，请返回历史页查看原始结果'));
        final code = codes.contains(selectedCode) ? selectedCode! : codes.first;
        final trend = historyTrend(reports, code, now: ref.read(taskClockProvider)());
        return ListView(padding: const EdgeInsets.all(16), children: [
          const Text('仅整理本机保存的数据，不判断病情或疗效。历史记录未保存医院与检测方法，不能自动认定不同报告可直接比较。'),
          const SizedBox(height: 12),
          DropdownButton<String>(key: const Key('trend_code'), isExpanded: true, value: code,
            items: [for (final value in codes) DropdownMenuItem(value: value, child: Text(kItemNames[value] ?? value))],
            onChanged: (value) => setState(() { selectedCode = value; confirmed.clear(); })),
          const Text('按原单位和参考范围分组，不自动换算。实心点为人工确认，空心点为自动识别。不同组不可直接比较；待确认/无法确认值不绘制。'),
          if (trend.groups.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Text('当前没有可绘制的数值，原始结果及原因见下方。')),
          for (final group in trend.groups) Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${kItemNames[code] ?? code} · ${group.unit}', style: Theme.of(context).textTheme.titleMedium),
              Text('原报告参考范围：${group.reference.isEmpty ? '未提供' : group.reference}'),
              Text('${group.points.length} 个数值点 · 纵轴自动缩放，请查看刻度'),
              LayoutBuilder(builder: (context, size) => SingleChildScrollView(scrollDirection: Axis.horizontal,
                child: Semantics(label: '${group.points.length} 个按检验日期排列的数值点，单位 ${group.unit}；下方逐条列出原始结果',
                  child: SizedBox(width: math.max(320, size.maxWidth), height: 240 * MediaQuery.textScalerOf(context).scale(1).clamp(1, 1.5),
                    child: CustomPaint(key: ValueKey('trend_plot_${group.key}'), painter: _TrendPainter(group.points,
                      connect: group.canConnect && confirmed[group.key] == group.fingerprint,
                      color: Theme.of(context).colorScheme.primary, fontSize: MediaQuery.textScalerOf(context).scale(12))))))),
              for (final reason in group.lineRestrictions) Text('· $reason'),
              if (group.canConnect) CheckboxListTile(key: ValueKey('trend_confirm_${group.key}'), contentPadding: EdgeInsets.zero,
                title: const Text('我已核对原报告，确认检测方法等比较条件一致'),
                subtitle: const Text('仅在这次查看中允许连线，不修改报告，也不生成医学结论；数据变化后需重新核对。'),
                value: confirmed[group.key] == group.fingerprint,
                onChanged: (value) => setState(() { if (value == true) { confirmed[group.key] = group.fingerprint; } else { confirmed.remove(group.key); } })),
              for (final point in group.points) ListTile(contentPadding: EdgeInsets.zero,
                title: Text('${point.report.testDate} · ${point.raw} ${point.unit}'),
                subtitle: Text('${point.confirmed ? '人工确认' : '自动识别，尚未人工确认'}\n保存于 ${point.report.savedAt.toString().substring(0, 16)}（不是检验时间）')),
            ],
          ))),
          if (trend.omissions.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('仅原文对照的记录', style: Theme.of(context).textTheme.titleMedium),
            for (final item in trend.omissions) ListTile(contentPadding: EdgeInsets.zero,
              title: Text('${item.date} · ${item.raw}'), subtitle: Text(item.reason)),
          ],
        ]);
      },
    ),
  );
}

class _TrendPainter extends CustomPainter {
  final List<TrendPoint> points;
  final bool connect;
  final Color color;
  final double fontSize;
  _TrendPainter(this.points, {required this.connect, required this.color, required this.fontSize});
  TextPainter text(String value) => TextPainter(text: TextSpan(text: value, style: TextStyle(color: Colors.black87, fontSize: fontSize)),
    textDirection: TextDirection.ltr)..layout();
  String number(double value) => value.toStringAsPrecision(4);
  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    var low = points.map((p) => p.value).reduce(math.min), high = points.map((p) => p.value).reduce(math.max);
    final padding = high == low ? math.max(low.abs() * .05, .001) : (high - low) * .1;
    low -= padding; high += padding;
    final ticks = [low, (low + high) / 2, high];
    final left = ticks.map((v) => text(number(v)).width).reduce(math.max) + 10;
    final plot = Rect.fromLTRB(left, 16, size.width - 12, size.height - fontSize * 2.8);
    if (plot.width < 20 || plot.height < 20) return;
    final grid = Paint()..color = Colors.grey.shade300..strokeWidth = 1;
    for (final value in ticks) {
      final y = plot.bottom - (value - low) / (high - low) * plot.height;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      final label = text(number(value)); label.paint(canvas, Offset(plot.left - label.width - 6, y - label.height / 2));
    }
    int day(DateTime date) => DateTime.utc(date.year, date.month, date.day).millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;
    final first = day(points.first.date), last = day(points.last.date);
    Offset position(TrendPoint point) => Offset(first == last ? plot.center.dx : plot.left + (day(point.date) - first) / (last - first) * plot.width,
      plot.bottom - (point.value - low) / (high - low) * plot.height);
    final ink = Paint()..color = color..strokeWidth = 2;
    if (connect) {
      for (var i = 1; i < points.length; i++) { canvas.drawLine(position(points[i - 1]), position(points[i]), ink); }
    }
    for (final point in points) {
      canvas.drawCircle(position(point), 5, Paint()..color = point.confirmed ? color : Colors.white);
      canvas.drawCircle(position(point), 5, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 2);
    }
    final firstLabel = text(points.first.report.testDate!), lastLabel = text(points.last.report.testDate!);
    firstLabel.paint(canvas, Offset(first == last ? plot.center.dx - firstLabel.width / 2 : plot.left, plot.bottom + 8));
    if (first != last) lastLabel.paint(canvas, Offset(plot.right - lastLabel.width, plot.bottom + 8));
  }
  @override
  bool shouldRepaint(covariant _TrendPainter old) => old.points != points || old.connect != connect || old.color != color || old.fontSize != fontSize;
}
