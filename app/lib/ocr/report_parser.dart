// 报告解析：OCR 文本行 → 结构化检验项目（含原图坐标、置信度、是否需要局部确认、候选值）。
// 纯 Dart，无平台依赖，可单元测试。项目字典须与后端 backend/app/knowledge_base/dictionary.yaml 保持一致（有测试校验）。

import '../core/models.dart';

/// 关键数值字段低于此置信度时需要用户确认。
/// 依据合成开发集（tests/eval，130 份）统计：置信度 0.85 以上的识别错误均已被「写法不合法 / 数值不合理 /
/// 单独的 +」规则拦截，因此门槛由 0.95 调整为 0.85，以降低用户确认负担；最终效果以独立测试集为准。
const double kValueReviewThreshold = 0.85;

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
  '+': ['±', '1+', '2+'],
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
/// 先精确匹配；再按 OCR 常见形近混淆匹配英文缩写（0↔O、1↔I/L、5↔S、6↔G、8↔B）；
/// 四个字及以上的中文名允许一个字识别错误（如「肌酥」→「肌酐」）。只剩单个字母等过短的名称不做猜测。
String? mapCode(String label) {
  final exact = _mapExact(label);
  if (exact != null) return exact;
  for (final variant in _asciiLookAlikes(label)) {
    final v = _mapExact(variant);
    if (v != null) return v;
  }
  return _mapByOneCharDiff(_canon(label));
}

String? _mapExact(String label) {
  final c = _canon(label);
  if (_index.containsKey(c)) return _index[c];
  final m = RegExp(r'[(（]\s*([A-Za-z0-9\-/]+)\s*[)）]').firstMatch(label);
  if (m != null && _index.containsKey(_canon(m.group(1)!))) return _index[_canon(m.group(1)!)];
  for (final p in ['U-', '尿']) {
    if (c.startsWith(p) && _index.containsKey(c.substring(p.length))) return _index[c.substring(p.length)];
  }
  return null;
}

/// 英文缩写中的数字按形近字母替换（只处理含数字的片段，最少 2 个字符）。
List<String> _asciiLookAlikes(String label) {
  if (!RegExp(r'[0-9]').hasMatch(label) || !RegExp(r'[A-Za-z]').hasMatch(label)) return const [];
  String sub(Map<String, String> m) => label.split('').map((ch) => m[ch] ?? ch).join();
  const base = {'0': 'O', '5': 'S', '6': 'G', '8': 'B'};
  return [sub({...base, '1': 'I'}), sub({...base, '1': 'L'})];
}

String? _mapByOneCharDiff(String c) {
  if (c.length < 4 || RegExp(r'^[A-Z0-9\-/]+$').hasMatch(c)) return null;
  String? found;
  for (final e in _index.entries) {
    if (e.key.length != c.length || e.key.length < 4) continue;
    var diff = 0;
    for (var i = 0; i < c.length && diff <= 1; i++) {
      if (c[i] != e.key[i]) diff++;
    }
    if (diff == 1) {
      if (found != null && found != e.value) return null; // 有歧义时不猜
      found = e.value;
    }
  }
  return found;
}

/// 单位中的 OCR 形近错误（如 mg/mmo1 → mg/mmol）。
String? normalizeUnit(String? u) {
  if (u == null) return null;
  return u.trim().replaceAll(RegExp(r'mmo[1I|]', caseSensitive: false), 'mmol').replaceAll('µ', 'μ');
}

const _grades = ['阴性', '±', '1+', '2+', '3+'];

/// 生成局部确认时的候选值：常见混淆 + 按 OCR 规律修复（丢失的「+」、I/l→1、逗号→小数点、丢失的小数点）。
List<String> candidatesFor(String code, String v) {
  final out = <String>[];
  if (_qualitative.contains(code)) {
    out.addAll(kConfusable[v] ?? const []);
    final digitPlus = RegExp(r'^[Il|]\+$').hasMatch(v) ? '1+' : null;
    final m = RegExp(r'^([1-4])[4+]?$').firstMatch(v);
    if (digitPlus != null) out.add(digitPlus);
    if (m != null) out.add('${m.group(1)}+');
    if (!isQualitativeValue(v) || out.isEmpty) {
      out.addAll(code == 'NIT' ? const ['阴性', '阳性'] : _grades);
    }
    if (isQualitativeValue(v) && !out.contains(v)) out.insert(0, v);
  } else {
    out.add(v);
    if (v.contains(',')) out.add(v.replaceAll(',', '.'));
    final n = parseNumber(v);
    final p = _plausible[code];
    if (n != null && p != null && (n < p[0] || n > p[1]) && !v.contains('.')) {
      for (var i = 1; i < v.length; i++) {
        final c = '${v.substring(0, i)}.${v.substring(i)}';
        final cn = double.tryParse(c);
        if (cn != null && cn >= p[0] && cn <= p[1]) out.add(c);
      }
    }
    // UACR：即使数值看似合理，也给出小数点位置不同的候选（811 → 81.1、8.11；81.1 → 811、8.11）
    if (code == 'UACR' && n != null) {
      final digits = v.replaceAll('.', '');
      if (RegExp(r'^\d{2,}$').hasMatch(digits)) {
        for (var i = 1; i <= digits.length; i++) {
          final c = i == digits.length ? digits : '${digits.substring(0, i)}.${digits.substring(i)}';
          if (!c.endsWith('.') && double.tryParse(c) != null) out.add(c);
        }
      }
    }
  }
  return out.toSet().toList();
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
      if (v == '+') reasons.add('单独的「+」可能是「±」或「1+」，需要确认');
    } else {
      final n = parseNumber(v);
      if (n == null) {
        reasons.add('结果「$v」不是有效数值');
      } else {
        final p = _plausible[code];
        if (p != null && (n < p[0] || n > p[1])) reasons.add('数值超出合理范围，可能识别错误');
      }
      if (code == 'UACR') {
        final u = normalizeUnit(unit?.text)?.toLowerCase().replaceAll(' ', '');
        if (u == null || u.isEmpty) {
          reasons.add('缺少单位');
        } else if (!_uacrUnits.contains(u)) {
          reasons.add('单位「${unit!.text}」无法识别');
        }
        // 关键定量指标一律请用户核对：测试集中的静默错误均为小数点丢失（如 81.1 → 811），
        // 错误值仍在合理范围且置信度高，无法由其他规则发现；UACR 分级（30/300 mg/g）对小数点敏感
        if (n != null && reasons.isEmpty) reasons.add('关键数值，请对照原图核对小数点');
      }
    }
  }
  final candidates = (v == null || v.isEmpty)
      ? (_qualitative.contains(code) ? (code == 'NIT' ? const ['阴性', '阳性'] : _grades) : const <String>[])
      : candidatesFor(code, v);
  return LabItem(
    code: code,
    label: label.text,
    value: v,
    unit: normalizeUnit(unit?.text),
    reference: ref?.text.trim(),
    flag: f,
    confidence: conf,
    status: reasons.isEmpty ? ReviewStatus.autoAccepted : ReviewStatus.needsConfirmation,
    valueBox: value?.box,
    rowBox: rowBox,
    candidates: candidates,
    reviewReasons: reasons,
  );
}
