// 血糖变化：按一天 / 一周 / 一月显示自己记录的血糖，并画出个人目标范围。
// 只展示已录入的数据（记多少画多少），用中性用语标注「范围内 / 高于 / 低于」，不做任何判断或评分。

import 'package:flutter/material.dart';

(double, double) parseTarget(String? raw) {
  final p = (raw ?? '').split('-').map(double.tryParse).toList();
  return p.length == 2 && p[0] != null && p[1] != null && p[0]! < p[1]! ? (p[0]!, p[1]!) : (3.9, 10.0);
}

String rangeLabel(double v, (double, double) target) =>
    v < target.$1 ? '低于目标范围' : v > target.$2 ? '高于目标范围' : '在目标范围内';

/// 指定时间窗内的血糖记录（按时间排序）。
List<(DateTime, double)> glucosePoints(List<Map<String, dynamic>> events, DateTime from, DateTime to) {
  final out = <(DateTime, double)>[];
  for (final e in events) {
    if (e['type'] != 'glucose' || e['glucose'] is! num) continue;
    final t = DateTime.tryParse(e['time'] as String? ?? '');
    if (t == null || t.isBefore(from) || t.isAfter(to)) continue;
    out.add((t, (e['glucose'] as num).toDouble()));
  }
  out.sort((a, b) => a.$1.compareTo(b.$1));
  return out;
}

class GlucoseTrendSheet extends StatefulWidget {
  final List<Map<String, dynamic>> events;
  final (double, double) target;
  final DateTime now;
  final VoidCallback? onAdd;
  const GlucoseTrendSheet({super.key, required this.events, required this.target, required this.now, this.onAdd});
  @override
  State<GlucoseTrendSheet> createState() => _GlucoseTrendSheetState();
}

class _GlucoseTrendSheetState extends State<GlucoseTrendSheet> {
  int days = 7;

  @override
  Widget build(BuildContext context) {
    final from = widget.now.subtract(Duration(days: days));
    final pts = glucosePoints(widget.events, from, widget.now);
    final inRange = pts.where((p) => p.$2 >= widget.target.$1 && p.$2 <= widget.target.$2).length;
    final small = Theme.of(context).textTheme.bodySmall;
    return SafeArea(child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('血糖变化', style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          if (widget.onAdd != null) TextButton.icon(key: const Key('trend_add'), onPressed: widget.onAdd,
              icon: const Icon(Icons.add, size: 18), label: const Text('记血糖')),
        ]),
        const SizedBox(height: 8),
        SegmentedButton<int>(
          segments: const [ButtonSegment(value: 1, label: Text('一天')), ButtonSegment(value: 7, label: Text('一周')),
            ButtonSegment(value: 30, label: Text('一个月'))],
          selected: {days},
          onSelectionChanged: (s) => setState(() => days = s.first),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 200,
          child: pts.isEmpty
              ? Center(child: Text('这段时间还没有血糖记录', style: small))
              : CustomPaint(key: const Key('trend_chart'), size: Size.infinite,
                  painter: _TrendPainter(pts, widget.target, from, widget.now)),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Container(width: 14, height: 8, color: const Color(0x339DB98A)),
          const SizedBox(width: 4),
          Text('我的目标范围 ${widget.target.$1}–${widget.target.$2} mmol/L', style: small),
        ]),
        const SizedBox(height: 4),
        Text(pts.isEmpty ? '图表只显示已录入的数据。' : '共 ${pts.length} 次记录，其中 $inRange 次在目标范围内。图表只显示已录入的数据，变化的意义请与医生讨论。',
            key: const Key('trend_summary'), style: small),
      ]),
    ));
  }
}

class _TrendPainter extends CustomPainter {
  final List<(DateTime, double)> pts;
  final (double, double) target;
  final DateTime from, to;
  _TrendPainter(this.pts, this.target, this.from, this.to);

  @override
  void paint(Canvas canvas, Size size) {
    const left = 30.0, bottom = 18.0;
    final w = size.width - left, h = size.height - bottom;
    final values = [...pts.map((p) => p.$2), target.$1, target.$2];
    final lo = (values.reduce((a, b) => a < b ? a : b) - 1).floorToDouble().clamp(0, 40).toDouble();
    final hi = (values.reduce((a, b) => a > b ? a : b) + 1).ceilToDouble();
    final span = to.difference(from).inMinutes.toDouble();
    double x(DateTime t) => left + w * (t.difference(from).inMinutes / span).clamp(0, 1);
    double y(double v) => h * (1 - (v - lo) / (hi - lo));

    canvas.drawRect(Rect.fromLTRB(left, y(target.$2), size.width, y(target.$1)), Paint()..color = const Color(0x339DB98A));
    final axis = Paint()..color = const Color(0xFFE0D6CC)..strokeWidth = 1;
    canvas.drawLine(Offset(left, h), Offset(size.width, h), axis);
    for (final v in [lo, target.$1, target.$2, hi]) {
      final tp = TextPainter(text: TextSpan(text: v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1),
          style: const TextStyle(fontSize: 10, color: Colors.black45)), textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, Offset(0, y(v) - tp.height / 2));
    }
    final line = Paint()..color = const Color(0xFFD08B5B)..strokeWidth = 2..style = PaintingStyle.stroke;
    final path = Path();
    for (final (i, p) in pts.indexed) {
      final o = Offset(x(p.$1), y(p.$2));
      i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(path, line);
    for (final p in pts) {
      canvas.drawCircle(Offset(x(p.$1), y(p.$2)), 3.5, Paint()..color = const Color(0xFFD08B5B));
    }
  }

  @override
  bool shouldRepaint(covariant _TrendPainter old) => old.pts != pts || old.target != target || old.from != from;
}
