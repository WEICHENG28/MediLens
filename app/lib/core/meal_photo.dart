import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;

import '../ocr/ocr_engine.dart' show decodeImageBytes;
import 'meal_nutrition.dart';

Future<List<FoodReference>> mealPhotoSuggestions(
  Uint8List bytes,
  List<FoodReference> references,
) async {
  final labels = (await rootBundle.loadString('assets/nutrition/labels_cn.txt'))
      .trim()
      .split('\n');
  final tensor = await compute(_photoInput, bytes);
  final session = await OnnxRuntime().createSessionFromAsset(
    // The runtime caches by filename; a new model needs a new hash suffix.
    // 中式食物模型：CNFOOD-241 微调（59 类，见 assets/nutrition/SOURCES.md）
    'assets/nutrition/food_cn-c9a5f4f7.onnx',
    options: OrtSessionOptions(intraOpNumThreads: 2),
  );
  try {
    final input = await OrtValue.fromList(tensor, [1, 3, 224, 224]);
    try {
      final output = await session.run({'input': input});
      try {
        final scores = (await output.values.single.asFlattenedList())
            .cast<num>();
        if (scores.length != labels.length ||
            scores.any((score) => !score.isFinite)) {
          throw const FormatException('食物类别数据无效');
        }
        final order = List<int>.generate(scores.length, (index) => index)
          ..sort((a, b) => scores[b].compareTo(scores[a]));
        final peak = scores[order.first];
        final total = scores.fold<double>(
          0,
          (sum, value) => sum + math.exp(value - peak),
        );
        double prob(int i) => math.exp(scores[i] - peak) / total;
        // 最高机率太低时不给候选（不是经过校准的机率，也不是「不是食物」的判断）。
        // 1,986 张测试照片：门槛 0.2 时 94% 会给候选，其中前三名含正确答案 93%；由用户点选确认。
        if (prob(order.first) < 0.20) return [];
        final picked = [
          for (final i in order.take(3))
            if (i == order.first || prob(i) >= 0.05) labels[i].trim(),
        ];
        return [
          for (final label in picked)
            ...references.where((food) => food.labels.contains(label)),
        ];
      } finally {
        for (final value in output.values) {
          await value.dispose();
        }
      }
    } finally {
      await input.dispose();
    }
  } finally {
    await session.close();
  }
}

Float32List _photoInput(Uint8List bytes) {
  final source = decodeImageBytes(bytes);
  if (source == null) throw const FormatException('图片格式不支持');
  final resized = source.width <= source.height
      ? img.copyResize(
          source,
          width: 256,
          interpolation: img.Interpolation.linear,
        )
      : img.copyResize(
          source,
          height: 256,
          interpolation: img.Interpolation.linear,
        );
  const size = 224;
  final crop = img.copyCrop(
    resized,
    x: (resized.width - size) ~/ 2,
    y: (resized.height - size) ~/ 2,
    width: size,
    height: size,
  );
  final values = Float32List(3 * size * size);
  for (final pixel in crop) {
    final index = pixel.y * size + pixel.x;
    values[index] = (pixel.rNormalized - 0.485) / 0.229;
    values[size * size + index] = (pixel.gNormalized - 0.456) / 0.224;
    values[2 * size * size + index] = (pixel.bNormalized - 0.406) / 0.225;
  }
  return values;
}
