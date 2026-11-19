// 血糖变化：按一天 / 一周 / 一月显示自己记录的血糖，并画出个人目标范围。
// 只展示已录入的数据（记多少画多少），用中性用语标注「范围内 / 高于 / 低于」，不做任何判断或评分。

import 'dart:async';

import 'package:flutter/material.dart';
import '../core/care_events.dart';
import 'glucose_context_card.dart';

(double, double) parseTarget(String? raw) {
  final p = (raw ?? '').split('-').map(double.tryParse).toList();
  return p.length == 2 && p[0] != null && p[1] != null && p[0]! < p[1]! ? (p[0]!, p[1]!) : (3.9, 10.0);
}

String rangeLabel(double v, (double, double) target) =>
    v < target.$1 ? '低于目标范围' : v > target.$2 ? '高于目标范围' : '在目标范围内';

/// 指定时间窗内的血糖记录（按时间排序）。
List<(DateTime, double)> glucosePoints(List<Map<String, dynamic>> events, DateTime from, DateTime to) =>
    [for (final r in glucoseRecords(events, from, to)) (r.time, r.value)];

const _afterName = {'meal': '吃饭后', 'medication': '吃药后', 'insulin': '打针后', 'setup': '初始血糖'};

class GlucoseRecord {
  final DateTime time;
  final double value;
  final String label; // 吃饭后 / 吃药后 / 打针后 / 初始血糖 / 血糖
  const GlucoseRecord(this.time, this.value, this.label);
}

List<GlucoseRecord> glucoseRecords(List<Map<String, dynamic>> events, DateTime from, DateTime to) {
  final out = <GlucoseRecord>[];
  for (final e in events) {
    final v = e['type'] == 'glucose' ? glucoseMmol(e) : null;
    if (v == null) continue;
    final t = DateTime.tryParse(e['time'] as String? ?? '');
    if (t == null || t.isBefore(from) || t.isAfter(to)) continue;
    out.add(GlucoseRecord(t, v, _afterName[e['after']] ?? '血糖'));
  }
  out.sort((a, b) => a.time.compareTo(b.time));
  return out;
}

/// 最高 / 平均 / 最低（只用已记录的数值，保留一位小数）。
(double, double, double)? glucoseStats(List<GlucoseRecord> rs) {
  if (rs.isEmpty) return null;
  final v = rs.map((r) => r.value).toList();
  double r1(double x) => (x * 10).roundToDouble() / 10;
  return (r1(v.reduce((a, b) => a > b ? a : b)), r1(v.reduce((a, b) => a + b) / v.length), r1(v.reduce((a, b) => a < b ? a : b)));
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
  final elapsed = Stopwatch();
  Timer? timer;

  @override
  void initState() {
    super.initState();
    elapsed.start();
    timer = Timer.periodic(const Duration(minutes: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final from = widget.now.subtract(Duration(days: days));
    final records = glucoseRecords(widget.events, from, widget.now);
    final pts = [for (final r in records) (r.time, r.value)];
    final stats = glucoseStats(records);
    final markers = <(DateTime, String)>[];
    for (final event in widget.events) {
      final type = event['type'];
      final time = DateTime.tryParse(event['time']?.toString() ?? '');
      if (type is String && _markerTypes.containsKey(type) && time != null &&
          !time.isBefore(from) && !time.isAfter(widget.now)) {
        markers.add((time, type));
      }
    }
    final inRange = pts.where((p) => p.$2 >= widget.target.$1 && p.$2 <= widget.target.$2).length;
    final small = Theme.of(context).textTheme.bodySmall;
    return SafeArea(child: SingleChildScrollView(
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
          child: pts.isEmpty && markers.isEmpty
              ? Center(child: Text('这段时间还没有血糖记录', style: small))
              : CustomPaint(key: const Key('trend_chart'), size: Size.infinite,
                  painter: _TrendPainter(pts, markers, widget.target, from, widget.now)),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Container(width: 14, height: 8, color: const Color(0x339DB98A)),
          const SizedBox(width: 4),
          Text('我的目标范围 ${widget.target.$1}–${widget.target.$2} mmol/L', style: small),
        ]),
        if (markers.isNotEmpty)
          Wrap(spacing: 12, children: [
            for (final (name, color) in _markerTypes.values.toSet())
              Text('● $name', style: small?.copyWith(color: color)),
          ]),
        const SizedBox(height: 4),
        Text(pts.isEmpty ? '这段时间无实测血糖，时间轴仅显示打卡。' : '共 ${pts.length} 次记录，其中 $inRange 次在目标范围内。图表只显示已录入的数据，变化的意义请与医生讨论。',
            key: const Key('trend_summary'), style: small),
        GlucoseContextCard(events: widget.events, now: widget.now.add(elapsed.elapsed)),
        if (stats != null) ...[
          const SizedBox(height: 12),
          Row(children: [
            for (final (label, v) in [('最高', stats.$1), ('平均', stats.$2), ('最低', stats.$3)])
              Expanded(child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 3),
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(color: const Color(0xFFFFF8F2), borderRadius: BorderRadius.circular(12)),
                child: Column(children: [
                  Text('$v', key: Key('stat_$label'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  Text('$label · mmol/L', style: small),
                ]),
              )),
          ]),
          const SizedBox(height: 12),
          Text('本期间记录', style: Theme.of(context).textTheme.titleSmall),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: ListView(shrinkWrap: true, children: [
              for (final r in records.reversed)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(switch (r.label) { '吃饭后' => Icons.restaurant, '吃药后' => Icons.medication,
                      '打针后' => Icons.vaccines, _ => Icons.bloodtype_outlined }, color: Colors.black45),
                  title: Text(r.label),
                  subtitle: Text('${r.time.month}月${r.time.day}日 ${r.time.hour.toString().padLeft(2, '0')}:${r.time.minute.toString().padLeft(2, '0')}'),
                  trailing: Text('${r.value} mmol/L', style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
            ]),
          ),
        ],
      ]),
    ));
  }
}

const _markerTypes = {
  'meal': ('餐饮', Color(0xFF9D4A18)),
  'medication': ('用药 / 打针', Color(0xFF175B9B)),
  'insulin': ('用药 / 打针', Color(0xFF175B9B)),
  'sleep': ('入睡 / 起床', Color(0xFF6C428C)),
  'wake': ('入睡 / 起床', Color(0xFF6C428C)),
  'exercise': ('运动', Color(0xFF22714B)),
};

class _TrendPainter extends CustomPainter {
  final List<(DateTime, double)> pts;
  final List<(DateTime, String)> markers;
  final (double, double) target;
  final DateTime from, to;
  _TrendPainter(this.pts, this.markers, this.target, this.from, this.to);

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
    final lanes = _markerTypes.values.toSet().toList();
    for (final (time, type) in markers) {
      final marker = _markerTypes[type]!;
      canvas.drawCircle(Offset(x(time), h + 3.5 + lanes.indexOf(marker) * 4), 2.3,
          Paint()..color = marker.$2);
    }
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
  bool shouldRepaint(covariant _TrendPainter old) => old.pts != pts || old.markers != markers || old.target != target || old.from != from || old.to != to;
}
