// 图像质量检查与方向处理（纯 Dart）。
// 坐标约定：所有 OCR 框都基于「旋转后的正向图像」归一化，界面显示的也是同一张正向图像，保证高亮框不偏行。

import 'dart:math' as math;

import 'package:image/image.dart' as img;

import '../core/models.dart';

class QualityReport {
  final double sharpness; // 拉普拉斯方差（缩放到短边 600 后计算）
  final double brightness; // 平均亮度 0~255
  final double glareRatio; // 过曝像素比例
  final int width, height;
  const QualityReport(this.sharpness, this.brightness, this.glareRatio, this.width, this.height);

  /// 阈值依据合成样本初步设定（清晰样本约 >300，模糊样本 <60），需在真实照片上再校准。
  bool get blurry => sharpness < 120;
  bool get tooDark => brightness < 60;
  bool get glare => glareRatio > 0.05;
  bool get tooSmall => math.min(width, height) < 500;

  List<String> get warnings => [
        if (blurry) '图片可能模糊，建议对焦后重拍',
        if (tooDark) '图片偏暗，建议在光线充足处重拍',
        if (glare) '可能有反光，建议调整角度避免反光',
        if (tooSmall) '图片分辨率较低，可能影响识别',
      ];
}

QualityReport checkQuality(img.Image src) {
  final scale = 600 / math.min(src.width, src.height);
  final g = img.grayscale(scale < 1 ? img.copyResize(src, width: (src.width * scale).round()) : img.Image.from(src));
  final w = g.width, h = g.height;
  double sum = 0, sumSq = 0, bright = 0;
  var glare = 0, n = 0;
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final c = g.getPixel(x, y).r.toDouble();
      final lap = 4 * c - g.getPixel(x - 1, y).r - g.getPixel(x + 1, y).r - g.getPixel(x, y - 1).r - g.getPixel(x, y + 1).r;
      sum += lap;
      sumSq += lap * lap;
      bright += c;
      if (c >= 250) glare++;
      n++;
    }
  }
  final mean = sum / n;
  final avg = bright / n;
  // 扫描件/截图纸面本身接近纯白（平均亮度 >= 230）时不判反光；拍照时纸面偏灰，出现成片饱和像素才提示反光
  final glareRatio = avg >= 230 ? 0.0 : glare / n;
  return QualityReport(sumSq / n - mean * mean, avg, glareRatio, src.width, src.height);
}

/// 按顺时针角度旋转（0/90/180/270）。
img.Image rotate(img.Image src, int degrees) => degrees % 360 == 0 ? src : img.copyRotate(src, angle: degrees);

/// 根据检测框形状判断是否需要旋转 90°：横排文字的框应「宽大于高」。
bool looksSideways(List<NormBox> boxes, double imageAspect) {
  if (boxes.length < 5) return false;
  // 换算成像素比例后比较
  final tall = boxes.where((b) => b.h / imageAspect > b.w * 1.5).length;
  return tall > boxes.length * 0.6;
}

/// 将「旋转前」图像上的归一化框映射到「顺时针旋转 [degrees] 后」图像上的归一化框。
NormBox rotateBox(NormBox b, int degrees) {
  switch (degrees % 360) {
    case 90:
      return NormBox(page: b.page, x: 1 - b.y - b.h, y: b.x, w: b.h, h: b.w);
    case 180:
      return NormBox(page: b.page, x: 1 - b.x - b.w, y: 1 - b.y - b.h, w: b.w, h: b.h);
    case 270:
      return NormBox(page: b.page, x: b.y, y: 1 - b.x - b.w, w: b.h, h: b.w);
    default:
      return b;
  }
}
