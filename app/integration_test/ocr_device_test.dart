// 端侧 OCR 实机测试：在模拟器/真机上用真实 ONNX 推理识别内置合成报告，检查解析结果。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:medilens/core/models.dart';
import 'package:medilens/ocr/ocr_engine.dart';
import 'package:medilens/ocr/report_parser.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final engine = OnnxOcrEngine();

  Future<ParsedReport> run(String name) async {
    final data = await rootBundle.load('assets/fixtures/$name.synthetic.png');
    final image = decodeImageBytes(data.buffer.asUint8List())!;
    final r = await engine.recognize(image);
    final p = parseReport(r.lines);
    // ignore: avoid_print
    print('[OCR] $name 旋转=${r.rotation} 用时=${r.elapsed.inMilliseconds}ms 类型=${p.reportType}');
    for (final i in p.items) {
      // ignore: avoid_print
      print('[OCR]   ${i.code} 值=${i.value} 单位=${i.unit} 参考=${i.reference} 置信=${i.confidence.toStringAsFixed(3)} 状态=${i.status.name} ${i.reviewReasons.join('|')}');
    }
    return p;
  }

  LabItem item(ParsedReport p, String code) => p.items.firstWhere((i) => i.code == code);

  testWidgets('02 尿糖酮体阳性', (t) async {
    final p = await run('02_glucose_ketone');
    expect(p.reportType, 'urinalysis');
    expect(item(p, 'GLU').value, '3+');
    expect(item(p, 'KET').value, '2+');
  });

  testWidgets('03 尿蛋白被遮挡需确认', (t) async {
    final p = await run('03_protein_ambiguous');
    expect(item(p, 'PRO').status, ReviewStatus.needsConfirmation);
  });

  testWidgets('04 UACR', (t) async {
    final p = await run('04_uacr_infection');
    expect(item(p, 'UACR').value, '86.5');
    expect(item(p, 'UACR').unit, 'mg/g');
  });

  testWidgets('07 非尿检', (t) async {
    final p = await run('07_non_target_liver');
    expect(p.supported, isFalse);
  });

  testWidgets('08 横置报告自动旋转', (t) async {
    final p = await run('08_rotated_glucose_ketone');
    expect(item(p, 'GLU').value, '3+');
  });
}
