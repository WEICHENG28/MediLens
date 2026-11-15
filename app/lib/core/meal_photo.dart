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
  final labels = (await rootBundle.loadString('assets/nutrition/labels.txt'))
      .trim()
      .split('\n');
  final tensor = await compute(_photoInput, bytes);
  final session = await OnnxRuntime().createSessionFromAsset(
    // The runtime caches by filename; a new model needs a new hash suffix.
    'assets/nutrition/food101-8021c00d.onnx',
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
        final first = labels[order.first].trim();
        // This is a conservative UI threshold, not a calibrated probability
        // of identifying a meal or an out-of-distribution detector.
        if (1 / total < 0.50) return [];
        return references.where((food) => food.labels.contains(first)).toList();
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
