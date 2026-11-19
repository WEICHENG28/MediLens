// 照护图表：一日时间轴（血糖线＋吃饭、用药、活动、睡眠、症状标记）、三餐后比较、目标范围比例条。
// 只画已记录的资料，记多少画多少；颜色只表示「范围内 / 高于 / 低于」，不做评分。

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/care_events.dart';

/// 某一天（00:00–24:00）的血糖与生活记录。
class DayTimeline extends StatelessWidget {
  final List<Map<String, dynamic>> events;
  final DateTime day;
  final (double, double) target;
  final double height;
  const DayTimeline({super.key, required this.events, required this.day, required this.target, this.height = 190});

  @override
  Widget build(BuildContext context) {
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    final todays = [
      for (final e in events)
        if (DateTime.tryParse(e['time'] as String? ?? '') case final t? when !t.isBefore(start) && t.isBefore(end)) (t, e),
    ];
    final readings = todays.where((x) => x.$2['type'] == 'glucose' && x.$2['glucose'] is num).length;
    return Semantics(
      label: '今天的血糖与生活记录时间轴，共 $readings 笔血糖',
      child: SizedBox(height: height, width: double.infinity,
          child: CustomPaint(key: const Key('day_timeline'), painter: _TimelinePainter(todays, start, target))),
    );
  }
}

const _marks = {'meal': '🍚', 'medication': '💊', 'insulin': '💉', 'exercise': '🚶', 'sleep': '🌙', 'symptom': '⚠️', 'lab': '🏥'};

class _TimelinePainter extends CustomPainter {
  final List<(DateTime, Map<String, dynamic>)> items;
  final DateTime start;
  final (double, double) target;
  _TimelinePainter(this.items, this.start, this.target);

  TextPainter _t(String s, double size, [Color c = Colors.black54]) =>
      TextPainter(text: TextSpan(text: s, style: TextStyle(fontSize: size, color: c)), textDirection: TextDirection.ltr)..layout();

  @override
  void paint(Canvas canvas, Size size) {
    const lo = 2.0;
    final pts = [for (final (t, e) in items) if (e['type'] == 'glucose' && glucoseMmol(e) != null) (t, glucoseMmol(e)!, e)];
    final hi = math.max(16.0, pts.isEmpty ? 0.0 : pts.map((p) => p.$2).reduce(math.max) + 1);
    final plot = Rect.fromLTRB(26, 8, size.width - 6, size.height - 46);
    double x(DateTime t) => plot.left + t.difference(start).inMinutes / 1440 * plot.width;
    double y(double v) => plot.bottom - (v.clamp(lo, hi) - lo) / (hi - lo) * plot.height;
    // 目标范围底色
    canvas.drawRect(Rect.fromLTRB(plot.left, y(target.$2), plot.right, y(target.$1)), Paint()..color = const Color(0xFFE8F5E9));
    final grid = Paint()..color = Colors.grey.shade300..strokeWidth = 1;
    for (final v in [target.$1, target.$2]) {
      canvas.drawLine(Offset(plot.left, y(v)), Offset(plot.right, y(v)), grid);
      final l = _t(v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1), 9);
      l.paint(canvas, Offset(plot.left - l.width - 3, y(v) - l.height / 2));
    }
    for (final h in [0, 6, 12, 18, 24]) {
      final xx = plot.left + h / 24 * plot.width;
      canvas.drawLine(Offset(xx, plot.bottom), Offset(xx, plot.bottom + 3), grid);
      final l = _t('$h时', 9);
      l.paint(canvas, Offset((xx - l.width / 2).clamp(0, size.width - l.width), plot.bottom + 4));
    }
    Color colorOf(double v) => v < target.$1 ? const Color(0xFFC62828) : v > target.$2 ? const Color(0xFFEF6C00) : const Color(0xFF2E7D32);
    // 监测仪读数连线（间隔超过 1 小时断开）；指血画成空心点
    final cgm = [for (final p in pts) if (p.$3['glucose_source'] == 'cgm') p];
    final line = Paint()..color = const Color(0xFF5C7C99)..strokeWidth = 1.6;
    for (var i = 1; i < cgm.length; i++) {
      if (cgm[i].$1.difference(cgm[i - 1].$1) <= const Duration(hours: 1)) {
        canvas.drawLine(Offset(x(cgm[i - 1].$1), y(cgm[i - 1].$2)), Offset(x(cgm[i].$1), y(cgm[i].$2)), line);
      }
    }
    for (final p in pts) {
      final finger = p.$3['glucose_source'] != 'cgm';
      if (!finger && cgm.length > 24) {
        if (p.$2 < target.$1) canvas.drawCircle(Offset(x(p.$1), y(p.$2)), 2.5, Paint()..color = colorOf(p.$2));
        continue;
      }
      canvas.drawCircle(Offset(x(p.$1), y(p.$2)), finger ? 4.5 : 3, Paint()..color = finger ? Colors.white : colorOf(p.$2));
      canvas.drawCircle(Offset(x(p.$1), y(p.$2)), finger ? 4.5 : 3,
          Paint()..color = colorOf(p.$2)..style = PaintingStyle.stroke..strokeWidth = 2);
    }
    // 生活记录标记（同一刻多个时错开）
    final used = <int, int>{};
    for (final (t, e) in items) {
      final m = _marks[e['type']];
      if (m == null) continue;
      final slot = (x(t) / 14).round();
      final row = used.update(slot, (v) => v + 1, ifAbsent: () => 0);
      final l = _t(m, 12, Colors.black);
      l.paint(canvas, Offset((x(t) - l.width / 2).clamp(0, size.width - l.width), plot.bottom + 16 + (row % 2) * 13.0));
    }
  }

  @override
  bool shouldRepaint(covariant _TimelinePainter old) => old.items != items || old.target != target;
}

/// 三餐后 2 小时血糖中位数的比较；最高的一餐加深颜色。
class MealCompareBars extends StatelessWidget {
  final Map<String, dynamic> postMeal; // breakfast/lunch/dinner → {median, n, high_count}
  final double high;
  const MealCompareBars({super.key, required this.postMeal, this.high = 10.0});

  @override
  Widget build(BuildContext context) {
    const names = {'breakfast': '早餐后', 'lunch': '午餐后', 'dinner': '晚餐后'};
    final data = [for (final k in names.keys) if (postMeal[k] is Map) (k, (postMeal[k]['median'] as num).toDouble(), (postMeal[k]['n'] as num? ?? 0).toInt())];
    if (data.isEmpty) return const SizedBox.shrink();
    final top = data.map((d) => d.$2).reduce(math.max);
    final scale = math.max(top, high) + 2;
    return Column(key: const Key('meal_compare'), children: [
      for (final (k, v, n) in data)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            SizedBox(width: 52, child: Text(names[k]!, style: const TextStyle(fontSize: 13))),
            Expanded(child: LayoutBuilder(builder: (_, c) => Stack(children: [
              Container(height: 22, decoration: BoxDecoration(color: const Color(0xFFF3ECE6), borderRadius: BorderRadius.circular(6))),
              Container(height: 22, width: c.maxWidth * v / scale,
                  decoration: BoxDecoration(
                      color: v == top && data.length > 1 ? const Color(0xFFEF6C00) : const Color(0xFFFFB74D),
                      borderRadius: BorderRadius.circular(6))),
              Positioned(left: c.maxWidth * high / scale, top: 0, bottom: 0,
                  child: Container(width: 2, color: Colors.black26)),
            ]))),
            SizedBox(width: 74, child: Text(' ${v.toStringAsFixed(1)}${n > 0 ? '（$n 次）' : ''}', style: const TextStyle(fontSize: 12))),
          ]),
        ),
      Align(alignment: Alignment.centerLeft, child: Text('竖线为目标上限 ${high.toStringAsFixed(0)}；数字为餐后 2 小时中位数（mmol/L）',
          style: Theme.of(context).textTheme.bodySmall)),
    ]);
  }
}

/// 读数在目标范围内 / 高于 / 低于的比例条。
class RangeBar extends StatelessWidget {
  final double? tbr, tir, tar;
  final String source;
  const RangeBar({super.key, required this.tbr, required this.tir, required this.tar, required this.source});

  @override
  Widget build(BuildContext context) {
    if (tir == null) return const SizedBox.shrink();
    final parts = [(tbr ?? 0, const Color(0xFFC62828), '偏低'), (tir!, const Color(0xFF66BB6A), '范围内'), (tar ?? 0, const Color(0xFFFFA726), '偏高')];
    return Column(key: const Key('range_bar'), crossAxisAlignment: CrossAxisAlignment.start, children: [
      ClipRRect(borderRadius: BorderRadius.circular(8), child: Row(children: [
        for (final (v, c, _) in parts)
          if (v > 0) Expanded(flex: math.max(1, (v * 1000).round()), child: Container(height: 18, color: c)),
      ])),
      const SizedBox(height: 4),
      Wrap(spacing: 14, children: [
        for (final (v, c, label) in parts)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 4),
            Text('$label ${(v * 100).round()}%', style: const TextStyle(fontSize: 12)),
          ]),
      ]),
      Text(source == 'cgm' ? '依据：监测仪读数' : '依据：指血记录（多在餐后测，比例只作参考）', style: Theme.of(context).textTheme.bodySmall),
    ]);
  }
}
