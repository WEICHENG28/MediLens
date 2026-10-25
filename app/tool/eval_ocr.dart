// OCR 结构化评测：用 APP 实际使用的报告解析器（lib/ocr/report_parser.dart）处理评测集的 OCR 结果，
// 与标准答案逐字段比对。数据为合成报告，结果不代表真实报告准确率。
// 用法（在 app 目录）：dart run tool/eval_ocr.dart [dev|test]

import 'dart:convert';
import 'dart:io';

import 'package:medilens/core/models.dart';
import 'package:medilens/ocr/report_parser.dart';

String norm(String? s) => (s ?? '').replaceAll(' ', '').replaceAll('＋', '+').replaceAll('－', '-').trim();

bool sameValue(String? a, String? b) {
  final x = norm(a), y = norm(b);
  if (x == y) return true;
  final nx = double.tryParse(x), ny = double.tryParse(y);
  return nx != null && ny != null && (nx - ny).abs() < 1e-9;
}

class Tally {
  int fields = 0, correctAuto = 0, correctFlagged = 0, wrongFlagged = 0, wrongAuto = 0, missing = 0, candidateFix = 0;
  int unitTotal = 0, unitOk = 0, refTotal = 0, refOk = 0;
  int reports = 0;
  final ms = <int>[];

  int get recognizedCorrect => correctAuto + correctFlagged;
  int get wrong => wrongFlagged + wrongAuto;
  Map<String, dynamic> toJson() => {
        'reports': reports,
        'fields': fields,
        'field_accuracy_before_confirm': ratio(recognizedCorrect, fields),
        'auto_accepted_correct': correctAuto,
        'flagged_but_correct': correctFlagged,
        'wrong_caught_by_review': wrongFlagged,
        'wrong_silently_accepted': wrongAuto,
        'missing_items': missing,
        'error_catch_rate': ratio(wrongFlagged, wrong),
        'silent_error_rate': ratio(wrongAuto, fields),
        'review_burden': ratio(correctFlagged + wrongFlagged, fields),
        'candidate_fix_rate': ratio(candidateFix, wrongFlagged),
        'accuracy_after_confirm_assuming_candidate': ratio(recognizedCorrect + candidateFix, fields),
        'unit_accuracy': ratio(unitOk, unitTotal),
        'reference_accuracy': ratio(refOk, refTotal),
        'ocr_ms_median': ms.isEmpty ? null : (ms..sort())[ms.length ~/ 2],
      };
}

double? ratio(int a, int b) => b == 0 ? null : double.parse((a / b).toStringAsFixed(4));

final debugFilter = Platform.environment['EVAL_DEBUG'];
final confidences = <Map<String, dynamic>>[];

void main(List<String> args) {
  final root = Directory.current.parent.path;
  final evalSet = args.isEmpty ? 'dev' : args.first;
  final truthDir = Directory('$root/tests/eval/$evalSet/truth');
  final total = Tally();
  final byPerturb = <String, Tally>{};
  final byLayout = <String, Tally>{};
  var typeOk = 0, typeTotal = 0, nonTargetRejected = 0, nonTargetTotal = 0;
  final silentExamples = <String>[];

  for (final f in truthDir.listSync().whereType<File>().toList()..sort((a, b) => a.path.compareTo(b.path))) {
    final name = f.uri.pathSegments.last.replaceAll('.json', '');
    final truth = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final ocr = jsonDecode(File('$root/tests/eval/$evalSet/ocr/$name.json').readAsStringSync()) as Map<String, dynamic>;
    final lines = (ocr['lines'] as List).map((e) => OcrLine.fromJson(e as Map<String, dynamic>)).toList();
    final parsed = parseReport(lines);
    typeTotal++;
    if (truth['supported'] == false) {
      nonTargetTotal++;
      if (!parsed.supported) {
        nonTargetRejected++;
        typeOk++;
      }
      continue;
    }
    if (parsed.supported) typeOk++;
    final tallies = [total, byPerturb.putIfAbsent(truth['perturbation'] as String, Tally.new), byLayout.putIfAbsent(truth['layout'] as String, Tally.new)];
    for (final t in tallies) {
      t.reports++;
      t.ms.add(ocr['ocr_ms'] as int);
    }
    for (final g in (truth['items'] as List).cast<Map<String, dynamic>>()) {
      final p = parsed.items.where((i) => i.code == g['code']).firstOrNull;
      for (final t in tallies) {
        t.fields++;
        if (p == null || p.value == null || p.value!.isEmpty) {
          t.missing++;
          if (identical(t, total) && debugFilter != null && name.contains(debugFilter!)) {
            stdout.writeln('[漏项] $name ${g['code']}（${g['label']}）: ${p == null ? '未识别到该项目' : '结果为空'}');
          }
          // 缺失不会被当作正常：APP 会提示「未识别到」，并要求确认（若该行被识别为项目）
          continue;
        }
        final ok = sameValue(p.value, g['value'] as String);
        if (identical(t, total)) confidences.add({'ok': ok, 'conf': p.confidence, 'code': p.code, 'value': g['value'], 'got': p.value, 'reasons': p.reviewReasons, 'name': name});
        final flagged = p.status == ReviewStatus.needsConfirmation;
        if (ok && !flagged) t.correctAuto++;
        if (ok && flagged) t.correctFlagged++;
        if (!ok && flagged) {
          t.wrongFlagged++;
          if (p.candidates.any((c) => sameValue(c, g['value'] as String))) t.candidateFix++;
        }
        if (!ok && !flagged) {
          t.wrongAuto++;
          if (identical(t, total) && silentExamples.length < 20) {
            silentExamples.add('$name ${g['code']}: 识别为「${p.value}」，应为「${g['value']}」（置信度 ${p.confidence.toStringAsFixed(3)}）');
          }
        }
        if (g['unit'] != null) {
          t.unitTotal++;
          if (norm(p.unit).toLowerCase() == norm(g['unit'] as String).toLowerCase()) t.unitOk++;
        }
        if (g['reference'] != null) {
          t.refTotal++;
          if (norm(p.reference) == norm(g['reference'] as String)) {
            t.refOk++;
          } else if (identical(t, total) && debugFilter != null && name.contains(debugFilter!)) {
            stdout.writeln('[参考] $name ${g['code']}: 识别「${p.reference}」应为「${g['reference']}」');
          }
        }
        if (identical(t, total) && debugFilter != null && name.contains(debugFilter!) && flagged) {
          stdout.writeln('[确认] $name ${g['code']}: 值「${p.value}」(${ok ? '对' : '错，应为${g['value']}'}) 原因：${p.reviewReasons.join('|')}');
        }
      }
    }
  }

  final result = {
    'set': evalSet,
    'note': '合成报告评测（虚构数据，固定随机种子）；不代表真实报告准确率',
    'report_type_accuracy': ratio(typeOk, typeTotal),
    'non_target_rejected': '$nonTargetRejected/$nonTargetTotal',
    'overall': total.toJson(),
    'by_perturbation': {for (final e in byPerturb.entries) e.key: e.value.toJson()},
    'by_layout': {for (final e in byLayout.entries) e.key: e.value.toJson()},
    'silent_error_examples': silentExamples,
  };
  File('$root/tests/eval/$evalSet/results/field_confidences.json')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(jsonEncode(confidences));
  final out = File('$root/tests/eval/$evalSet/results/ocr_eval.json');
  out.parent.createSync(recursive: true);
  out.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(result));
  stdout.writeln(const JsonEncoder.withIndent('  ').convert({'overall': result['overall'], 'report_type_accuracy': result['report_type_accuracy'], 'non_target_rejected': result['non_target_rejected']}));
}
