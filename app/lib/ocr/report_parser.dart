// 报告解析：OCR 文本行 → 结构化检验项目（含原图坐标、置信度、是否需要局部确认、候选值）。
// 纯 Dart，无平台依赖，可单元测试。项目字典须与后端 backend/app/knowledge_base/dictionary.yaml 保持一致（有测试校验）。

import '../core/models.dart';

/// 关键数值字段低于此置信度时需要用户确认（依据合成样本实测：被遮挡的「2+」置信度约 0.92）。
const double kValueReviewThreshold = 0.95;

const Map<String, List<String>> kSynonyms = {
  'GLU': ['GLU', 'U-GLU', '葡萄糖', '尿糖', '尿葡萄糖', 'GLUCOSE'],
  'KET': ['KET', 'U-KET', '酮体', '尿酮体', '尿酮', 'KETONE'],
  'PRO': ['PRO', 'U-PRO', '蛋白', '尿蛋白', '蛋白质', 'PROTEIN'],
  'LEU': ['LEU', 'U-LEU', 'WBC', '白细胞', '尿白细胞', '白细胞酯酶'],
  'NIT': ['NIT', 'U-NIT', '亚硝酸盐', '尿亚硝酸盐'],
  'BLD': ['BLD', 'U-BLD', 'ERY', '隐血', '尿隐血', '潜血', '红细胞'],
  'SG': ['SG', 'U-SG', '比重', '尿比重'],
  'PH': ['PH', 'U-PH', '酸碱度', '尿酸碱度'],
  'UACR': ['UACR', 'ACR', 'MALB/CR', '尿白蛋白/肌酐', '尿白蛋白肌酐比', '尿白蛋白/肌酐比', '尿微量白蛋白/肌酐', '尿微量白蛋白肌酐比值', '白蛋白/肌酐比值'],
};

const Map<String, String> kItemNames = {
  'GLU': '尿葡萄糖', 'KET': '尿酮体', 'PRO': '尿蛋白', 'LEU': '白细胞', 'NIT': '亚硝酸盐',
  'BLD': '隐血', 'SG': '比重', 'PH': '酸碱度', 'UACR': '尿白蛋白/肌酐比',
};

const _qualitative = {'GLU', 'KET', 'PRO', 'LEU', 'NIT', 'BLD'};
const _plausible = {'SG': [1.000, 1.050], 'PH': [4.0, 9.5], 'UACR': [0.0, 10000.0]};
const _uacrUnits = {'mg/g', 'mg/gcr', 'μg/mg', 'ug/mg', 'mg/mmol'};

/// 易混淆的定性结果候选（用于局部确认时供用户点选）。
const Map<String, List<String>> kConfusable = {
  '1+': ['1+', '2+'],
  '2+': ['2+', '1+', '3+'],
  '3+': ['3+', '2+'],
  '4+': ['4+', '3+'],
  '+': ['1+', '±'],
  '±': ['±', '1+', '阴性'],
  '-': ['阴性', '±'],
  '阴性': ['阴性', '±'],
  '阳性': ['阳性', '阴性'],
};

String _canon(String s) {
  var t = s.trim().toUpperCase().replaceAll(' ', '').replaceAll('（', '(').replaceAll('）', ')');
  t = t.replaceAll(RegExp(r'\(.*?\)'), '');
  return t;
}

final Map<String, String> _index = {
  for (final e in kSynonyms.entries)
    for (final s in e.value) _canon(s): e.key,
};

/// 项目名 → 统一代码；无法映射返回 null。
String? mapCode(String label) {
  final c = _canon(label);
  if (_index.containsKey(c)) return _index[c];
  final m = RegExp(r'[(（]\s*([A-Za-z\-/]+)\s*[)）]').firstMatch(label);
  if (m != null && _index.containsKey(_canon(m.group(1)!))) return _index[_canon(m.group(1)!)];
  for (final p in ['U-', '尿']) {
    if (c.startsWith(p) && _index.containsKey(c.substring(p.length))) return _index[c.substring(p.length)];
  }
  return null;
}

bool isQualitativeValue(String v) {
  final t = v.replaceAll(' ', '').replaceAll('＋', '+').replaceAll('－', '-');
  return RegExp(r'^([1-4]\+|\+{1,4}|±|\+-|-|阴性|阳性|弱阳性)').hasMatch(t);
}

double? parseNumber(String? v) {
  if (v == null) return null;
  final m = RegExp(r'^[<>≤≥]?\s*(-?\d+(?:\.\d+)?)$').firstMatch(v.trim());
  return m == null ? null : double.tryParse(m.group(1)!);
}

/// 提示列常见 OCR 误读（「↑」被读成「1」「个」等）规范化。
String? normalizeFlag(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  final t = raw.trim();
  if (const {'↑', '1', '个', 'T', 't', 'H', '+'}.contains(t)) return '↑';
  if (const {'↓', 'L', 'l'}.contains(t)) return '↓';
  if (t == '*') return '*';
  return t;
}

class _Row {
  final List<OcrLine> cells = [];
  double get cy => cells.map((c) => c.box.cy).reduce((a, b) => a + b) / cells.length;
  double get h => cells.map((c) => c.box.h).reduce((a, b) => a + b) / cells.length;
  NormBox get box => cells.map((c) => c.box).reduce((a, b) => a.union(b));
}

List<_Row> _groupRows(List<OcrLine> lines) {
  final sorted = [...lines]..sort((a, b) => a.box.cy.compareTo(b.box.cy));
  final rows = <_Row>[];
  for (final l in sorted) {
    final last = rows.isEmpty ? null : rows.last;
    if (last != null && (l.box.cy - last.cy).abs() < last.h * 0.6) {
      last.cells.add(l);
    } else {
      rows.add(_Row()..cells.add(l));
    }
  }
  for (final r in rows) {
    r.cells.sort((a, b) => a.box.x.compareTo(b.box.x));
  }
  return rows;
}

class _Columns {
  final double result, unit, reference, flag;
  const _Columns(this.result, this.unit, this.reference, this.flag);
}

_Columns? _findHeader(List<_Row> rows) {
  for (final r in rows) {
    double? find(List<String> keys) {
      for (final c in r.cells) {
        if (keys.any((k) => c.text.contains(k))) return c.box.x;
      }
      return null;
    }

    final result = find(['结果']);
    final ref = find(['参考', '范围']);
    if (result != null && ref != null) {
      return _Columns(result, find(['单位']) ?? (result + ref) / 2, ref, find(['提示', '标志']) ?? ref + 0.15);
    }
  }
  return null;
}

/// 解析 OCR 结果为结构化报告。
ParsedReport parseReport(List<OcrLine> lines) {
  final rows = _groupRows(lines.where((l) => l.text.trim().isNotEmpty).toList());
  final cols = _findHeader(rows);
  final date = _findDate(lines);
  final items = <LabItem>[];
  final others = <String>[];

  for (final r in rows) {
    final labelCell = r.cells.first;
    final code = mapCode(labelCell.text);
    if (code == null) {
      if (r.cells.length < 2) continue;
      if (cols != null && r.cells.length >= 2 && labelCell.box.x < cols.result - 0.05 && !_isHeaderOrMeta(labelCell.text)) {
        others.add(labelCell.text);
      }
      continue;
    }
    OcrLine? value, unit, ref, flag;
    final cells = cols == null ? r.cells.skip(1) : r.cells.skip(1).expand(_splitTokens);
    for (final c in cells) {
      final x = c.box.x;
      if (cols == null) {
        value ??= c;
        continue;
      }
      // 选择距离最近的列起点
      final d = {
        'v': (x - cols.result).abs(),
        'u': (x - cols.unit).abs(),
        'r': (x - cols.reference).abs(),
        'f': (x - cols.flag).abs(),
      };
      final best = d.entries.reduce((a, b) => a.value <= b.value ? a : b).key;
      switch (best) {
        case 'v':
          value ??= c;
        case 'u':
          unit ??= c;
        case 'r':
          ref ??= c;
        case 'f':
          flag ??= c;
      }
    }
    items.add(_buildItem(code, labelCell, value, unit, ref, flag, r.box));
  }

  final codes = items.map((i) => i.code).toSet();
  String type;
  if (codes.isEmpty) {
    type = 'unsupported';
  } else if (codes.length == 1 && codes.contains('UACR')) {
    type = 'uacr';
  } else if (codes.contains('UACR')) {
    type = 'urinalysis+uacr';
  } else {
    type = 'urinalysis';
  }
  return ParsedReport(reportType: type, testDate: date, items: items, otherLabels: others);
}

/// 检测器可能把相邻两列（如「mg/mmol <3.4」）合成一个框：按空格拆分，并按字符位置估算每段的横坐标。
Iterable<OcrLine> _splitTokens(OcrLine c) {
  final text = c.text.trim();
  final parts = text.split(RegExp(r'\s+'));
  if (parts.length < 2) return [c];
  final out = <OcrLine>[];
  var offset = 0;
  for (final part in parts) {
    final start = text.indexOf(part, offset);
    offset = start + part.length;
    final x = c.box.x + c.box.w * start / text.length;
    final w = c.box.w * part.length / text.length;
    out.add(OcrLine(text: part, confidence: c.confidence, box: NormBox(page: c.box.page, x: x, y: c.box.y, w: w, h: c.box.h)));
  }
  return out;
}

bool _isHeaderOrMeta(String t) =>
    RegExp(r'项目|结果|单位|参考|提示|姓名|样本|检验|审核|报告|医院|科室|日期').hasMatch(t);

String? _findDate(List<OcrLine> lines) {
  for (final l in lines) {
    final m = RegExp(r'(20\d{2})[-/.年](\d{1,2})[-/.月](\d{1,2})').firstMatch(l.text);
    if (m != null) {
      return '${m.group(1)}-${m.group(2)!.padLeft(2, '0')}-${m.group(3)!.padLeft(2, '0')}';
    }
  }
  return null;
}

LabItem _buildItem(String code, OcrLine label, OcrLine? value, OcrLine? unit, OcrLine? ref, OcrLine? flag, NormBox rowBox) {
  final reasons = <String>[];
  final v = value?.text.trim().replaceAll('＋', '+').replaceAll(' ', '');
  final conf = value?.confidence ?? 0;
  final f = normalizeFlag(flag?.text);

  if (v == null || v.isEmpty) {
    reasons.add('未识别到结果');
  } else {
    if (conf < kValueReviewThreshold) reasons.add('识别置信度较低（${(conf * 100).toStringAsFixed(0)}%）');
    if (_qualitative.contains(code)) {
      if (!isQualitativeValue(v)) reasons.add('结果「$v」不是常见的定性写法');
      final negative = v == '阴性' || v == '-';
      if (negative && f == '↑') reasons.add('结果为阴性但带有异常标记');
    } else {
      final n = parseNumber(v);
      if (n == null) {
        reasons.add('结果「$v」不是有效数值');
      } else {
        final p = _plausible[code];
        if (p != null && (n < p[0] || n > p[1])) reasons.add('数值超出合理范围，可能识别错误');
      }
      if (code == 'UACR') {
        final u = unit?.text.trim().toLowerCase().replaceAll(' ', '').replaceAll('µ', 'μ');
        if (u == null || u.isEmpty) {
          reasons.add('缺少单位');
        } else if (!_uacrUnits.contains(u)) {
          reasons.add('单位「${unit!.text}」无法识别');
        }
      }
    }
  }
  final candidates = <String>[
    if (v != null && v.isNotEmpty) ...(kConfusable[v] ?? [v]),
  ];
  return LabItem(
    code: code,
    label: label.text,
    value: v,
    unit: unit?.text.trim(),
    reference: ref?.text.trim(),
    flag: f,
    confidence: conf,
    status: reasons.isEmpty ? ReviewStatus.autoAccepted : ReviewStatus.needsConfirmation,
    valueBox: value?.box,
    rowBox: rowBox,
    candidates: candidates.toSet().toList(),
    reviewReasons: reasons,
  );
}
