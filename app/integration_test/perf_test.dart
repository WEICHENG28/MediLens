// 端到端耗时（模拟器实测）：图片解码 → 本机 OCR → 报告解析 → 后端判读（/analyze）→ 总览数据就绪。
// 不含用户操作时间（确认、点击）。需后端运行：python scripts/run_backend.py
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:medilens/core/api_client.dart';
import 'package:medilens/core/settings.dart';
import 'package:medilens/ocr/ocr_engine.dart';
import 'package:medilens/ocr/report_parser.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('端到端耗时', (t) async {
    final engine = OnnxOcrEngine();
    final api = ApiClient(AppSettings.defaultApiBaseUrl);
    final names = ['02_glucose_ketone', '01_normal_urinalysis', '03_protein_ambiguous', '04_uacr_infection',
      '05_uacr_mgmmol', '06_missing_reference', '07_non_target_liver', '08_rotated_glucose_ketone'];
    final rows = <Map<String, Object>>[];
    for (final n in names) {
      final total = Stopwatch()..start();
      final data = await rootBundle.load('assets/fixtures/$n.synthetic.png');
      final img = decodeImageBytes(data.buffer.asUint8List())!;
      final decodeMs = total.elapsedMilliseconds;
      final ocr = await engine.recognize(img);
      final ocrMs = total.elapsedMilliseconds - decodeMs;
      final report = parseReport(ocr.lines);
      var apiMs = 0;
      if (report.supported) {
        final s = Stopwatch()..start();
        await api.analyze(ApiClient.analysisBody(report, const {}, const []));
        apiMs = s.elapsedMilliseconds;
      }
      rows.add({'name': n, 'decode_ms': decodeMs, 'ocr_ms': ocrMs, 'analyze_ms': apiMs, 'total_ms': total.elapsedMilliseconds});
    }
    // ignore: avoid_print
    print('[PERF] ${jsonEncode(rows)}');
    expect(rows.every((r) => (r['total_ms'] as int) < 15000), isTrue, reason: '企划书目标：端到端 ≤15 秒');
  });
}
