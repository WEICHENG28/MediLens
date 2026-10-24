// OCR 前后处理（纯 Dart，可单元测试）：
// - 检测：概率图二值化 → 连通域 → 外扩（近似 PaddleOCR unclip）→ 映射回原图坐标
// - 识别：CTC 贪心解码，置信度取各字符最大概率的平均值
// 预处理参数与 PaddleOCR / tools/ocr_reference.py 保持一致。

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

const detMean = [0.485, 0.456, 0.406];
const detStd = [0.229, 0.224, 0.225];

class PixelBox {
  final double x0, y0, x1, y1, score;
  const PixelBox(this.x0, this.y0, this.x1, this.y1, this.score);
  double get w => x1 - x0;
  double get h => y1 - y0;
}

/// 检测输入：长边缩放到 [limit]，宽高取 32 的倍数；输出 NCHW float32（BGR 通道顺序）。
({Float32List data, int w, int h}) detInput(img.Image src, {int limit = 960}) {
  final scale = limit / math.max(src.width, src.height);
  int r32(double v) => math.max(32, (v / 32).round() * 32);
  final nw = r32(src.width * scale), nh = r32(src.height * scale);
  final im = img.copyResize(src, width: nw, height: nh, interpolation: img.Interpolation.linear);
  final data = Float32List(3 * nw * nh);
  final plane = nw * nh;
  for (var y = 0; y < nh; y++) {
    for (var x = 0; x < nw; x++) {
      final p = im.getPixel(x, y);
      final i = y * nw + x;
      // BGR 顺序
      data[i] = (p.b / 255.0 - detMean[0]) / detStd[0];
      data[plane + i] = (p.g / 255.0 - detMean[1]) / detStd[1];
      data[2 * plane + i] = (p.r / 255.0 - detMean[2]) / detStd[2];
    }
  }
  return (data: data, w: nw, h: nh);
}

/// 概率图 → 文本框（原图像素坐标）。
List<PixelBox> detBoxes(
  List<double> prob,
  int mw,
  int mh,
  int srcW,
  int srcH, {
  double thresh = 0.3,
  double boxThresh = 0.6,
  double unclip = 0.5,
}) {
  final labels = Int32List(mw * mh);
  final boxes = <PixelBox>[];
  var next = 0;
  final stack = <int>[];
  for (var start = 0; start < mw * mh; start++) {
    if (labels[start] != 0 || prob[start] <= thresh) continue;
    next++;
    var minX = mw, minY = mh, maxX = 0, maxY = 0;
    var sum = 0.0;
    var count = 0;
    labels[start] = next;
    stack.add(start);
    while (stack.isNotEmpty) {
      final i = stack.removeLast();
      final x = i % mw, y = i ~/ mw;
      sum += prob[i];
      count++;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
      void visit(int j) {
        if (labels[j] == 0 && prob[j] > thresh) {
          labels[j] = next;
          stack.add(j);
        }
      }

      if (x > 0) visit(i - 1);
      if (x < mw - 1) visit(i + 1);
      if (y > 0) visit(i - mw);
      if (y < mh - 1) visit(i + mw);
    }
    final bw = maxX - minX + 1, bh = maxY - minY + 1;
    final score = sum / count;
    if (score < boxThresh || bw < 3 || bh < 3) continue;
    final pad = bh * unclip;
    final sx = srcW / mw, sy = srcH / mh;
    boxes.add(PixelBox(
      math.max(0, (minX - pad) * sx),
      math.max(0, (minY - pad) * sy),
      math.min(srcW.toDouble(), (maxX + 1 + pad) * sx),
      math.min(srcH.toDouble(), (maxY + 1 + pad) * sy),
      score,
    ));
  }
  return boxes;
}

/// 识别输入：裁剪区域缩放到高 48，输出 NCHW float32（BGR，归一化到 [-1,1]）。
({Float32List data, int w}) recInput(img.Image src, PixelBox b) {
  final crop = img.copyCrop(src, x: b.x0.floor(), y: b.y0.floor(), width: math.max(1, b.w.ceil()), height: math.max(1, b.h.ceil()));
  final nw = math.max(8, (48 * crop.width / crop.height).ceil());
  final im = img.copyResize(crop, width: nw, height: 48, interpolation: img.Interpolation.linear);
  final plane = nw * 48;
  final data = Float32List(3 * plane);
  for (var y = 0; y < 48; y++) {
    for (var x = 0; x < nw; x++) {
      final p = im.getPixel(x, y);
      final i = y * nw + x;
      data[i] = (p.b / 255.0 - 0.5) / 0.5;
      data[plane + i] = (p.g / 255.0 - 0.5) / 0.5;
      data[2 * plane + i] = (p.r / 255.0 - 0.5) / 0.5;
    }
  }
  return (data: data, w: nw);
}

/// CTC 贪心解码。[logits] 形状为 [steps, classes]（已 softmax）；chars[0] 为 blank。
({String text, double confidence}) ctcDecode(List<double> logits, int steps, int classes, List<String> chars) {
  final buf = StringBuffer();
  final confs = <double>[];
  var last = 0;
  for (var t = 0; t < steps; t++) {
    var best = 0;
    var bestP = -1.0;
    final base = t * classes;
    for (var c = 0; c < classes; c++) {
      final p = logits[base + c];
      if (p > bestP) {
        bestP = p;
        best = c;
      }
    }
    if (best != 0 && best != last && best < chars.length) {
      buf.write(chars[best]);
      confs.add(bestP);
    }
    last = best;
  }
  final conf = confs.isEmpty ? 0.0 : confs.reduce((a, b) => a + b) / confs.length;
  return (text: buf.toString(), confidence: conf);
}

/// 字符表：blank + 字典 + 空格（与 PP-OCRv5 rec 输出 18385 类对应）。
/// 注意只去掉文件末尾的空行，中间行不能过滤，否则字符索引会错位。
List<String> buildCharset(String dictText) {
  final lines = dictText.split(RegExp(r'\r?\n'));
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  return ['<blank>', ...lines, ' '];
}
