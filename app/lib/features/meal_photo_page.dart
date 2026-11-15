import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../core/meal_nutrition.dart';
import '../core/meal_photo.dart';

class MealPhotoPage extends StatefulWidget {
  const MealPhotoPage({super.key});

  @override
  State<MealPhotoPage> createState() => _MealPhotoPageState();
}

class _MealPhotoPageState extends State<MealPhotoPage> {
  final grams = TextEditingController();
  late final catalog = FoodReference.load();
  Uint8List? photo;
  List<FoodReference> suggestions = [];
  FoodReference? selected;
  bool busy = false;
  String? message;

  @override
  void dispose() {
    grams.dispose();
    super.dispose();
  }

  Future<void> pick(ImageSource source, List<FoodReference> foods) async {
    setState(() => busy = true);
    try {
      final file = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 90,
      );
      if (file == null || !mounted) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      setState(() {
        photo = bytes;
        selected = null;
        suggestions = [];
        message = null;
        grams.clear();
      });
      final matches = await mealPhotoSuggestions(bytes, foods);
      if (!mounted) return;
      setState(() {
        suggestions = matches;
        message = matches.isEmpty
            ? '照片没有找到可用候选。请选择与实际配方最接近的参考食物。'
            : '请核对照片候选，也可以从食物库重新选择。';
      });
    } catch (_) {
      if (mounted) setState(() => message = '暂时无法识别照片，可以手动选择参考食物。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final weight = double.tryParse(grams.text.trim());
    final food = selected;
    final estimate =
        food != null &&
            weight != null &&
            weight.isFinite &&
            weight > 0 &&
            weight <= 5000
        ? MealNutrition(food, weight)
        : null;
    return Scaffold(
      appBar: AppBar(title: const Text('拍餐饮估算糖与碳水')),
      body: FutureBuilder<List<FoodReference>>(
        future: catalog,
        builder: (context, snapshot) {
          final foods = snapshot.data;
          if (foods == null) {
            return Center(
              child: snapshot.hasError
                  ? const Text('食物参考库读取失败，请重新进入。')
                  : const CircularProgressIndicator(),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text('每次估算一种食物或饮品。照片在设备上处理；请核对食物和可食用克重。确认时记为开餐时间。'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: busy
                        ? null
                        : () => pick(ImageSource.camera, foods),
                    icon: const Icon(Icons.photo_camera),
                    label: const Text('拍照'),
                  ),
                  OutlinedButton.icon(
                    onPressed: busy
                        ? null
                        : () => pick(ImageSource.gallery, foods),
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('从相册选图'),
                  ),
                ],
              ),
              if (photo != null)
                Image.memory(
                  photo!,
                  height: 175,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Text('照片预览不可用'),
                ),
              if (busy) const LinearProgressIndicator(),
              if (message != null) Text(message!),
              if (suggestions.isNotEmpty)
                Wrap(
                  spacing: 8,
                  children: [
                    for (final candidate in suggestions)
                      ChoiceChip(
                        label: Text(candidate.name),
                        selected: selected == candidate,
                        onSelected: busy
                            ? null
                            : (value) => setState(
                                () => selected = value ? candidate : null,
                              ),
                      ),
                  ],
                ),
              const SizedBox(height: 12),
              InputDecorator(
                decoration: const InputDecoration(labelText: '确认参考食物'),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<FoodReference>(
                    value: selected,
                    isExpanded: true,
                    hint: const Text('从 USDA 食物库选择'),
                    onChanged: busy
                        ? null
                        : (value) => setState(() => selected = value),
                    items: [
                      for (final value in foods)
                        DropdownMenuItem(value: value, child: Text(value.name)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('meal_grams'),
                controller: grams,
                enabled: !busy,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: '实际吃下的可食重量（克）',
                  helperText: '可按称重或包装净含量填写。',
                  errorText:
                      grams.text.isNotEmpty &&
                          (weight == null ||
                              !weight.isFinite ||
                              weight <= 0 ||
                              weight > 5000)
                      ? '请输入大于 0、至多 5000 的克重'
                      : null,
                ),
              ),
              if (estimate != null) ...[
                const SizedBox(height: 12),
                Text(
                  '总碳水约 ${estimate.carbs.toStringAsFixed(1)} g',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  estimate.sugars == null
                      ? '数据库未提供总糖'
                      : '总糖约 ${estimate.sugars!.toStringAsFixed(1)} g（总碳水的一部分）',
                ),
                Text('来源：USDA FNDDS 2021–2023 · ${estimate.food.sourceName}'),
                SelectableText(estimate.food.source),
              ],
              const SizedBox(height: 8),
              const Text('估算基于数据库参考配方。酱料、加糖和份量误差会改变实际结果。用药请按医嘱。'),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: busy || estimate == null
                    ? null
                    : () => Navigator.pop(context, estimate),
                child: const Text('确认并记录这餐'),
              ),
            ],
          );
        },
      ),
    );
  }
}
