// 本地 OCR 引擎（PP-OCRv5 mobile det+rec，ONNX Runtime 端侧推理，不联网，原图不离开设备）。

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;

import '../core/models.dart';
import 'image_tools.dart';
import 'ocr_postprocess.dart';

/// OCR 结果：[image] 为识别所用的正向图像（已按 [rotation] 旋转），所有框均基于它归一化。
class OcrResult {
  final img.Image image;
  final int rotation;
  final List<OcrLine> lines;
  final Duration elapsed;
  const OcrResult({required this.image, required this.rotation, required this.lines, required this.elapsed});
}

abstract class OcrEngine {
  /// [rotation]：用户在预览页手动旋转的角度；[autoOrient] 为 true 时会检测横置报告并自动再转 90°。
  Future<OcrResult> recognize(img.Image source, {int rotation = 0, bool autoOrient = true});
}

class OnnxOcrEngine implements OcrEngine {
  OrtSession? _det, _rec;
  List<String>? _chars;

  Future<void> _ensureLoaded() async {
    if (_det != null) return;
    final ort = OnnxRuntime();
    _det = await ort.createSessionFromAsset('assets/ocr/det.onnx');
    _rec = await ort.createSessionFromAsset('assets/ocr/rec.onnx');
    _chars = buildCharset(await rootBundle.loadString('assets/ocr/ppocrv5_dict.txt'));
  }

  Future<List<PixelBox>> _detect(img.Image im) async {
    final input = detInput(im);
    final x = await OrtValue.fromList(input.data, [1, 3, input.h, input.w]);
    final out = await _det!.run({'x': x});
    final prob = (await out.values.first.asFlattenedList()).cast<num>().map((e) => e.toDouble()).toList();
    await x.dispose();
    for (final v in out.values) {
      await v.dispose();
    }
    return detBoxes(prob, input.w, input.h, im.width, im.height);
  }

  Future<({String text, double confidence})> _recognize(img.Image im, PixelBox b) async {
    final input = recInput(im, b);
    final x = await OrtValue.fromList(input.data, [1, 3, 48, input.w]);
    final out = await _rec!.run({'x': x});
    final v = out.values.first;
    final shape = v.shape; // [1, steps, classes]
    final flat = (await v.asFlattenedList()).cast<num>().map((e) => e.toDouble()).toList();
    await x.dispose();
    for (final o in out.values) {
      await o.dispose();
    }
    return ctcDecode(flat, shape[1], shape[2], _chars!);
  }

  @override
  Future<OcrResult> recognize(img.Image source, {int rotation = 0, bool autoOrient = true}) async {
    final sw = Stopwatch()..start();
    await _ensureLoaded();
    var rot = rotation % 360;
    var im = rotate(source, rot);
    var boxes = await _detect(im);
    if (autoOrient) {
      final norm = boxes.map((b) => NormBox(x: b.x0 / im.width, y: b.y0 / im.height, w: b.w / im.width, h: b.h / im.height)).toList();
      if (looksSideways(norm, im.height / im.width)) {
        // 横置报告：分别尝试 90° 与 270°，取识别置信度更高者
        final candidates = <(int, img.Image, List<PixelBox>, double)>[];
        for (final extra in [90, 270]) {
          final r = (rot + extra) % 360;
          final rim = rotate(source, r);
          final rb = await _detect(rim);
          final sample = rb.take(6);
          var sum = 0.0;
          for (final b in sample) {
            sum += (await _recognize(rim, b)).confidence;
          }
          candidates.add((r, rim, rb, sample.isEmpty ? 0 : sum / sample.length));
        }
        candidates.sort((a, b) => b.$4.compareTo(a.$4));
        rot = candidates.first.$1;
        im = candidates.first.$2;
        boxes = candidates.first.$3;
      }
    }
    final lines = <OcrLine>[];
    for (final b in boxes) {
      final r = await _recognize(im, b);
      if (r.text.trim().isEmpty) continue;
      lines.add(OcrLine(
        text: r.text,
        confidence: r.confidence,
        box: NormBox(x: b.x0 / im.width, y: b.y0 / im.height, w: b.w / im.width, h: b.h / im.height),
      ));
    }
    return OcrResult(image: im, rotation: rot, lines: lines, elapsed: sw.elapsed);
  }
}

/// 从文件字节解码图像（含 EXIF 方向校正）。
img.Image? decodeImageBytes(Uint8List bytes) {
  final im = img.decodeImage(bytes);
  if (im == null) return null;
  final oriented = img.bakeOrientation(im);
  // 过大照片先缩小，长边 2000 足够识别且省内存
  final longSide = math.max(oriented.width, oriented.height);
  return longSide > 2000 ? img.copyResize(oriented, width: (oriented.width * 2000 / longSide).round()) : oriented;
}
