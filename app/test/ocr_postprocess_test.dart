import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:medilens/core/models.dart';
import 'package:medilens/ocr/image_tools.dart';
import 'package:medilens/ocr/ocr_postprocess.dart';

void main() {
  test('CTC 解码：去重、去 blank、置信度为平均值', () {
    final chars = ['<blank>', '1', '+', '阴', '性', ' '];
    // 时间步：1 1 blank + + blank
    List<double> step(int k, double p) => List.generate(6, (i) => i == k ? p : (1 - p) / 5);
    final logits = [...step(1, 0.9), ...step(1, 0.8), ...step(0, 0.99), ...step(2, 0.7), ...step(2, 0.6), ...step(0, 0.9)];
    final r = ctcDecode(logits, 6, 6, chars);
    expect(r.text, '1+');
    expect(r.confidence, closeTo((0.9 + 0.7) / 2, 1e-9));
  });

  test('字典解析：中间行不丢失，只去掉末尾空行', () {
    final c = buildCharset('a\nb\n\nc\n');
    expect(c, ['<blank>', 'a', 'b', '', 'c', ' ']);
  });

  test('检测后处理：连通域成框并映射回原图坐标', () {
    const mw = 20, mh = 10;
    final prob = List<double>.filled(mw * mh, 0);
    for (var y = 3; y <= 5; y++) {
      for (var x = 2; x <= 11; x++) {
        prob[y * mw + x] = 0.9;
      }
    }
    prob[9 * mw + 19] = 0.95; // 孤立噪点，应被过滤
    final boxes = detBoxes(prob, mw, mh, 200, 100, unclip: 0);
    expect(boxes.length, 1);
    expect(boxes.first.x0, closeTo(20, 1e-9));
    expect(boxes.first.x1, closeTo(120, 1e-9));
    expect(boxes.first.y0, closeTo(30, 1e-9));
  });

  test('检测输入尺寸为 32 的倍数', () {
    final r = detInput(img.Image(width: 1240, height: 1754));
    expect(r.w % 32, 0);
    expect(r.h % 32, 0);
    expect(r.data.length, 3 * r.w * r.h);
  });

  test('坐标旋转映射与 image 包旋转方向一致（顺时针 90°）', () {
    final src = img.Image(width: 4, height: 2);
    src.setPixelRgb(0, 0, 255, 0, 0); // 左上角红点
    final rotated = rotate(src, 90);
    expect(rotated.width, 2);
    expect(rotated.height, 4);
    // 顺时针 90° 后，原左上角应位于右上角
    expect(rotated.getPixel(1, 0).r, 255);
    final b = rotateBox(const NormBox(x: 0, y: 0, w: 0.25, h: 0.5), 90);
    expect(b.x, closeTo(0.5, 1e-9));
    expect(b.y, closeTo(0, 1e-9));
    expect(b.w, closeTo(0.5, 1e-9));
    expect(b.h, closeTo(0.25, 1e-9));
    // 四次旋转回到原位
    var bb = const NormBox(x: 0.1, y: 0.2, w: 0.3, h: 0.1);
    for (var i = 0; i < 4; i++) {
      bb = rotateBox(bb, 90);
    }
    expect(bb.x, closeTo(0.1, 1e-9));
    expect(bb.y, closeTo(0.2, 1e-9));
  });

  test('横置判断', () {
    final tall = List.generate(10, (_) => const NormBox(x: 0, y: 0, w: 0.02, h: 0.2));
    final wide = List.generate(10, (_) => const NormBox(x: 0, y: 0, w: 0.2, h: 0.02));
    expect(looksSideways(tall, 1.4), isTrue);
    expect(looksSideways(wide, 1.4), isFalse);
  });
}
