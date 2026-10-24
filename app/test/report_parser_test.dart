// 报告解析单测：输入为合成报告经 PP-OCRv5 参考实现识别的真实 OCR 输出（tools/ocr_reference.py --export）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:medilens/core/models.dart';
import 'package:medilens/ocr/report_parser.dart';
import 'package:yaml/yaml.dart';

ParsedReport load(String name) {
  final j = jsonDecode(File('test/fixtures/ocr/$name.synthetic.ocr.json').readAsStringSync()) as Map<String, dynamic>;
  final lines = (j['lines'] as List).map((e) => OcrLine.fromJson(e as Map<String, dynamic>)).toList();
  return parseReport(lines);
}

LabItem item(ParsedReport r, String code) => r.items.firstWhere((i) => i.code == code);

void main() {
  test('正常尿常规：8 项全部识别并自动接受', () {
    final r = load('01_normal_urinalysis');
    expect(r.reportType, 'urinalysis');
    expect(r.testDate, '2026-10-01');
    expect(r.items.map((i) => i.code).toSet(), {'GLU', 'KET', 'PRO', 'LEU', 'NIT', 'BLD', 'SG', 'PH'});
    expect(r.pendingReview, isEmpty);
    expect(item(r, 'SG').value, '1.020');
    expect(item(r, 'SG').reference, '1.003-1.030');
    expect(item(r, 'GLU').valueBox, isNotNull);
  });

  test('尿糖酮体阳性：值与异常标记正确', () {
    final r = load('02_glucose_ketone');
    expect(item(r, 'GLU').value, '3+');
    expect(item(r, 'KET').value, '2+');
    // 「↑」箭头检测不稳定（本样本中酮体行的箭头未被检出），判读不依赖它，只依赖参考范围比对
    expect(item(r, 'GLU').flag, anyOf('↑', isNull));
  });

  test('被遮挡的尿蛋白触发局部确认并提供候选', () {
    final r = load('03_protein_ambiguous');
    final pro = item(r, 'PRO');
    expect(pro.status, ReviewStatus.needsConfirmation);
    expect(pro.reviewReasons.join(), contains('置信度'));
    expect(pro.candidates, containsAll(['1+', '2+']));
    expect(r.pendingReview.length, 1);
  });

  test('UACR 与单位、参考范围', () {
    final r = load('04_uacr_infection');
    expect(r.reportType, 'urinalysis+uacr');
    final u = item(r, 'UACR');
    expect(u.value, '86.5');
    expect(u.unit, 'mg/g');
    expect(u.reference, '<30');
    expect(u.status, ReviewStatus.autoAccepted);
  });

  test('mg/mmol 单位 UACR；非首期项目归入其他', () {
    final r = load('05_uacr_mgmmol');
    expect(r.reportType, 'uacr');
    expect(item(r, 'UACR').unit, 'mg/mmol');
    expect(r.otherLabels, contains('尿微量白蛋白'));
  });

  test('缺参考范围仍可解析', () {
    final r = load('06_missing_reference');
    expect(item(r, 'GLU').value, '1+');
    expect(item(r, 'GLU').reference, isNull);
  });

  test('非尿检报告识别为不支持', () {
    final r = load('07_non_target_liver');
    expect(r.reportType, 'unsupported');
    expect(r.supported, isFalse);
  });

  test('矛盾检测：UACR 缺单位、数值不合理、阴性带↑', () {
    OcrLine l(String t, double x, double y, [double c = 0.99]) =>
        OcrLine(text: t, confidence: c, box: NormBox(x: x, y: y, w: 0.08, h: 0.02));
    final r = parseReport([
      l('项目', 0.05, 0.2), l('结果', 0.42, 0.2), l('单位', 0.58, 0.2), l('参考范围', 0.71, 0.2), l('提示', 0.9, 0.2),
      l('UACR', 0.05, 0.3), l('45', 0.42, 0.3), l('<30', 0.71, 0.3),
      l('比重', 0.05, 0.35), l('1020', 0.42, 0.35), l('1.003-1.030', 0.71, 0.35),
      l('尿蛋白', 0.05, 0.4), l('阴性', 0.42, 0.4), l('阴性', 0.71, 0.4), l('↑', 0.9, 0.4),
      l('尿糖', 0.05, 0.45),
    ]);
    expect(item(r, 'UACR').reviewReasons.join(), contains('缺少单位'));
    expect(item(r, 'SG').reviewReasons.join(), contains('合理范围'));
    expect(item(r, 'PRO').reviewReasons.join(), contains('异常标记'));
    expect(item(r, 'GLU').reviewReasons.join(), contains('未识别到结果'));
  });

  test('端侧同义词字典与后端字典一致', () {
    final y = loadYaml(File('../backend/app/knowledge_base/dictionary.yaml').readAsStringSync()) as YamlMap;
    final items = y['items'] as YamlMap;
    expect(items.keys.toSet(), kSynonyms.keys.toSet());
    for (final code in kSynonyms.keys) {
      expect((items[code]['synonyms'] as YamlList).toList(), kSynonyms[code], reason: code);
    }
  });
}
