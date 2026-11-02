import '../data/local_store.dart';

class TrendPoint {
  final SavedReport report;
  final DateTime date;
  final String raw, unit, reference;
  final double value;
  final bool confirmed;
  const TrendPoint(this.report, this.date, this.raw, this.unit, this.reference, this.value, this.confirmed);
}

class TrendOmission {
  final String date, raw, reason;
  const TrendOmission(this.date, this.raw, this.reason);
}

class TrendGroup {
  final String code, unit, reference;
  final List<TrendPoint> points;
  const TrendGroup(this.code, this.unit, this.reference, this.points);
  String get key => '$code|$unit|$reference';
  String get fingerprint => points.map((p) => '${p.report.id}:${p.report.savedAt.toIso8601String()}:${p.date}:${p.raw}:${p.confirmed}').join('|');
  List<String> get lineRestrictions => [
    if (points.length < 2) '至少需要两条数值记录',
    if (reference.isEmpty) '缺少参考范围，不能直接比较',
    if (points.any((p) => !p.confirmed)) '有自动识别值尚未人工确认，只显示数值点',
    if (points.map((p) => p.report.testDate).toSet().length != points.length) '同日有多份记录，无法确认检验先后，不连线',
  ];
  bool get canConnect => lineRestrictions.isEmpty;
}

class HistoryTrend {
  final List<TrendGroup> groups;
  final List<TrendOmission> omissions;
  const HistoryTrend(this.groups, this.omissions);
}

DateTime? strictReportDate(String? raw) {
  if (raw == null || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(raw)) return null;
  final year = int.parse(raw.substring(0, 4)), month = int.parse(raw.substring(5, 7)), day = int.parse(raw.substring(8));
  if (year < 1) return null;
  final date = DateTime(year, month, day);
  return date.year == year && date.month == month && date.day == day ? date : null;
}

List<String> historyCodes(List<SavedReport> reports) {
  final codes = <String>{for (final report in reports) for (final item in report.items)
    if (item['code'] is String && (item['code'] as String).isNotEmpty) item['code'] as String};
  const preferred = ['UACR', 'SG', 'PH', 'GLU', 'KET', 'PRO', 'LEU', 'NIT', 'BLD'];
  final rest = codes.difference(preferred.toSet()).toList()..sort();
  return [...preferred.where(codes.contains), ...rest];
}

HistoryTrend historyTrend(List<SavedReport> reports, String code, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final lastDate = DateTime(today.year, today.month, today.day);
  final groups = <String, List<TrendPoint>>{};
  final omissions = <TrendOmission>[];
  for (final report in reports) {
    final items = report.items.where((i) => i['code'] == code).toList();
    if (items.isEmpty) continue;
    final item = items.first;
    final raw = item['raw_value']?.toString() ?? '未识别';
    final unit = item['unit']?.toString().trim() ?? '';
    final reference = (item['reference_text']?.toString() ?? '').replaceAll(RegExp(r'\s+'), '');
    final date = strictReportDate(report.testDate);
    String? reason;
    double? value;
    if (items.length != 1) {
      reason = '同一报告该指标出现多次，请先核对原报告';
    } else if (date == null) {
      reason = '缺少或无效的检验日期，不使用保存日期代替';
    } else if (date.isAfter(lastDate)) {
      reason = '检验日期在未来，请核对原报告';
    } else if (!{'confirmed', 'auto_accepted'}.contains(item['review_status'])) {
      reason = '待确认、无法确认或已排除，不绘制';
    } else if (!{'UACR', 'SG', 'PH'}.contains(code)) {
      reason = '首版仅原文对照，不把定性等级当作数值曲线';
    } else if ((code == 'UACR' && !{'mg/g', 'mg/mmol'}.contains(unit)) ||
        (code != 'UACR' && unit.isNotEmpty && !(code == 'PH' && unit == 'pH'))) {
      reason = '单位缺失或本版不支持，不能直接比较';
    } else if (!RegExp(r'^[+-]?(?:\d+(?:\.\d+)?|\.\d+)$').hasMatch(raw.trim())) {
      reason = '本版仅绘制普通十进制数值；不等号、定性或其他写法保留原文';
    } else {
      value = double.tryParse(raw.trim());
      if (value == null || !value.isFinite || value.abs() > 1e9) reason = '超出本版图表支持的数值范围，请核对原报告';
    }
    if (reason != null) {
      omissions.add(TrendOmission(report.testDate ?? '日期未知', '$raw${unit.isEmpty ? '' : ' $unit'}', reason));
      continue;
    }
    final displayUnit = code == 'UACR' ? unit : '无量纲';
    final key = '$displayUnit|$reference';
    groups.putIfAbsent(key, () => []).add(TrendPoint(report, date!, raw, displayUnit, reference, value!, item['review_status'] == 'confirmed'));
  }
  return HistoryTrend([for (final points in groups.values)
    TrendGroup(code, points.first.unit, points.first.reference,
      points..sort((a, b) { final day = a.date.compareTo(b.date); return day != 0 ? day : a.report.id.compareTo(b.report.id); }))], omissions);
}
