// 解析器对 OCR 常见错误的处理（规律来自合成开发集 tests/eval 的错误分析）。
import 'package:flutter_test/flutter_test.dart';
import 'package:medilens/ocr/report_parser.dart';

void main() {
  test('英文缩写形近字修正：PR0 / G1U / N1T', () {
    expect(mapCode('PR0'), 'PRO');
    expect(mapCode('G1U'), 'GLU');
    expect(mapCode('N1T'), 'NIT');
    expect(mapCode('U-PR0'), 'PRO');
  });

  test('中文名允许一个字识别错误，过短或有歧义时不猜', () {
    expect(mapCode('尿白蛋白/肌酥比'), 'UACR');
    expect(mapCode('H'), isNull); // 只剩一个字母：不猜
    expect(mapCode('S'), isNull);
    expect(mapCode('谷丙转氨酶'), isNull);
  });

  test('候选：丢失的 +、I/l→1、单独 + 的歧义', () {
    expect(candidatesFor('GLU', '2'), contains('2+'));
    expect(candidatesFor('KET', '14'), contains('1+'));
    expect(candidatesFor('BLD', 'l+'), contains('1+'));
    expect(candidatesFor('PRO', '+'), containsAll(['±', '1+', '2+']));
  });

  test('候选：无法识别的定性结果给出完整等级', () {
    expect(candidatesFor('KET', '什'), containsAll(['阴性', '±', '1+', '2+', '3+']));
    expect(candidatesFor('NIT', '閉性'), containsAll(['阴性', '阳性']));
  });

  test('候选：逗号→小数点、补回丢失的小数点', () {
    expect(candidatesFor('SG', '1,009'), contains('1.009'));
    expect(candidatesFor('PH', '77'), contains('7.7'));
    expect(candidatesFor('SG', '1009'), contains('1.009'));
  });

  test('单位形近字修正', () {
    expect(normalizeUnit('mg/mmo1'), 'mg/mmol');
  });
}
