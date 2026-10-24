import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:medilens/ocr/image_tools.dart';

void main() {
  img.Image load(String n) => img.decodePng(File('../tests/fixtures/$n.synthetic.png').readAsBytesSync())!;

  test('清晰合成报告无质量警告', () {
    final q = checkQuality(load('01_normal_urinalysis'));
    expect(q.warnings, isEmpty, reason: 'sharpness=${q.sharpness}');
  });

  test('模糊合成报告提示重拍', () {
    final q = checkQuality(load('09_blurry'));
    expect(q.blurry, isTrue, reason: 'sharpness=${q.sharpness}');
  });

  test('暗图提示', () {
    final dark = img.Image(width: 800, height: 800);
    img.fill(dark, color: img.ColorRgb8(20, 20, 20));
    expect(checkQuality(dark).tooDark, isTrue);
  });
}
