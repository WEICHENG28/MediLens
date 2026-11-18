import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../core/care_events.dart';
import '../core/meal_nutrition.dart';
import '../core/meal_photo.dart';

/// 记录一餐：选餐次 → 拍照或选食物 → 填克数 → 加入这餐（可加多样）→ 确认。
/// 照片只在本机识别；碳水是参考配方的估算，之后可以修正份量，原始估算会保留。
class MealPhotoPage extends StatefulWidget {
  final DateTime? now;
  const MealPhotoPage({super.key, this.now});

  @override
  State<MealPhotoPage> createState() => _MealPhotoPageState();
}

class _MealPhotoPageState extends State<MealPhotoPage> {
  final grams = TextEditingController();
  late final catalog = FoodReference.load();
  late String slot = mealSlotFor(widget.now ?? DateTime.now());
  Uint8List? photo;
  List<FoodReference> suggestions = [];
  FoodReference? selected;
  final items = <MealNutrition>[];
  bool sweetDrink = false;
  bool usedPhoto = false;
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
      final file = await ImagePicker().pickImage(source: source, maxWidth: 1600, maxHeight: 1600, imageQuality: 90);
      if (file == null || !mounted) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      setState(() {
        photo = bytes;
        usedPhoto = true;
        selected = null;
        suggestions = [];
        message = null;
        grams.clear();
      });
      final matches = await mealPhotoSuggestions(bytes, foods);
      if (!mounted) return;
      setState(() {
        suggestions = matches;
        message = matches.isEmpty ? '照片没有找到可用候选。请选择与实际配方最接近的参考食物。'
            : '照片可能是以下几种（按可能性排列），请点选正确的，也可以从食物库重新选择。';
      });
    } catch (_) {
      if (mounted) setState(() => message = '暂时无法识别照片，可以手动选择参考食物。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  MealNutrition? get _current {
    final weight = double.tryParse(grams.text.trim());
    final food = selected;
    return food != null && weight != null && weight.isFinite && weight > 0 && weight <= 5000 ? MealNutrition(food, weight) : null;
  }

  void _addItem() {
    final c = _current;
    if (c == null) return;
    setState(() {
      items.add(c);
      selected = null;
      suggestions = [];
      grams.clear();
      message = '已加入。还有其他食物可以继续加，或直接确认这餐。';
    });
  }

  @override
  Widget build(BuildContext context) {
    final weight = double.tryParse(grams.text.trim());
    final current = _current;
    final all = [...items, ?current];
    final record = all.isEmpty ? null : MealRecord(all, slot, sweetDrink: sweetDrink, fromPhoto: usedPhoto);
    return Scaffold(
      appBar: AppBar(title: const Text('记录一餐 · 估算碳水')),
      body: FutureBuilder<List<FoodReference>>(
        future: catalog,
        builder: (context, snapshot) {
          final foods = snapshot.data;
          if (foods == null) {
            return Center(child: snapshot.hasError ? const Text('食物参考库读取失败，请重新进入。') : const CircularProgressIndicator());
          }
          return ListView(padding: const EdgeInsets.all(16), children: [
            Text('这是哪一餐？', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Wrap(spacing: 8, children: [
              for (final s in const ['breakfast', 'lunch', 'dinner', 'snack'])
                ChoiceChip(key: Key('meal_slot_$s'), label: Text(mealSlotZh[s]!), selected: slot == s,
                    onSelected: busy ? null : (_) => setState(() => slot = s)),
            ]),
            const SizedBox(height: 12),
            const Text('每次估算一样食物，可以加入多样。照片在设备上处理；请核对食物和克重。确认时记为开餐时间。'),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(onPressed: busy ? null : () => pick(ImageSource.camera, foods),
                  icon: const Icon(Icons.photo_camera), label: const Text('拍照')),
              OutlinedButton.icon(onPressed: busy ? null : () => pick(ImageSource.gallery, foods),
                  icon: const Icon(Icons.photo_library_outlined), label: const Text('从相册选图')),
            ]),
            if (photo != null) Image.memory(photo!, height: 175, fit: BoxFit.contain, errorBuilder: (_, _, _) => const Text('照片预览不可用')),
            if (busy) const LinearProgressIndicator(),
            if (message != null) Text(message!),
            if (suggestions.isNotEmpty)
              Wrap(spacing: 8, children: [
                for (final candidate in suggestions)
                  ChoiceChip(label: Text(candidate.label), selected: selected == candidate,
                      onSelected: busy ? null : (value) => setState(() => selected = value ? candidate : null)),
              ]),
            const SizedBox(height: 12),
            InputDecorator(
              decoration: const InputDecoration(labelText: '确认参考食物'),
              child: DropdownButtonHideUnderline(child: DropdownButton<FoodReference>(
                value: selected, isExpanded: true, hint: const Text('从 USDA 食物库选择'),
                onChanged: busy ? null : (value) => setState(() => selected = value),
                items: [for (final value in foods) DropdownMenuItem(value: value, child: Text(value.label))],
              )),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('meal_grams'), controller: grams, enabled: !busy,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: '吃下的可食重量（克）', helperText: '估一下就好，之后可以修正；家人复秤的结果也可以改上去。',
                errorText: grams.text.isNotEmpty && (weight == null || !weight.isFinite || weight <= 0 || weight > 5000)
                    ? '请输入大于 0、至多 5000 的克重' : null,
              ),
            ),
            Align(alignment: Alignment.centerLeft, child: TextButton.icon(
              key: const Key('meal_add_item'), onPressed: busy || current == null ? null : _addItem,
              icon: const Icon(Icons.add), label: const Text('加入这餐，再加一样'))),
            if (items.isNotEmpty) ...[
              Text('这餐已加入', style: Theme.of(context).textTheme.titleSmall),
              for (final (i, it) in items.indexed)
                ListTile(dense: true, contentPadding: EdgeInsets.zero,
                  title: Text('${it.food.name} · ${it.grams.toStringAsFixed(0)} g'),
                  subtitle: Text('碳水约 ${it.carbs.toStringAsFixed(1)} g'),
                  trailing: IconButton(icon: const Icon(Icons.close), tooltip: '移除',
                      onPressed: busy ? null : () => setState(() => items.removeAt(i)))),
            ],
            SwitchListTile(key: const Key('meal_sweet'), contentPadding: EdgeInsets.zero, value: sweetDrink,
                title: const Text('这餐有甜饮料或甜点'), subtitle: const Text('例如含糖饮料、果汁、奶茶、蛋糕'),
                onChanged: busy ? null : (v) => setState(() => sweetDrink = v)),
            if (record != null) ...[
              const SizedBox(height: 4),
              Text('${mealSlotZh[slot]}总碳水约 ${record.carbs.toStringAsFixed(1)} g', key: const Key('meal_total'),
                  style: Theme.of(context).textTheme.titleMedium),
              Text(record.sugars == null ? '部分食物数据库未提供总糖' : '其中总糖约 ${record.sugars!.toStringAsFixed(1)} g'),
              Text('来源：USDA FNDDS 2021–2023 · ${all.map((i) => i.food.sourceName).toSet().join('、')}'
                '${all.any((i) => i.food.approx) ? '（含近似条目：USDA 没有完全对应的中式菜）' : ''}'),
            ],
            const SizedBox(height: 8),
            const Text('估算基于数据库参考配方。酱料、加糖和份量误差会改变实际结果，只供参考，不当作实测。用药请按医嘱。'),
            const SizedBox(height: 8),
            FilledButton(key: const Key('meal_confirm'), onPressed: busy || record == null ? null : () => Navigator.pop(context, record),
                child: const Text('确认并记录这餐')),
          ]);
        },
      ),
    );
  }
}
