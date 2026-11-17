import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

class FoodReference {
  final int fdcId;
  final String name;
  final String sourceName;
  final double carbs;
  final double? sugars;
  final List<String> labels;

  const FoodReference({
    required this.fdcId,
    required this.name,
    required this.sourceName,
    required this.carbs,
    required this.sugars,
    required this.labels,
  });

  factory FoodReference.fromJson(Map<String, dynamic> data) => FoodReference(
    fdcId: data['fdc_id'] as int,
    name: data['name'] as String,
    sourceName: data['source_name'] as String,
    carbs: (data['carbs_per_100g'] as num).toDouble(),
    sugars: (data['sugars_per_100g'] as num?)?.toDouble(),
    labels: (data['labels'] as List<dynamic>).cast<String>(),
  );

  String get source => 'https://fdc.nal.usda.gov/food-details/$fdcId/nutrients';

  static Future<List<FoodReference>> load() async {
    final raw = await rootBundle.loadString(
      'assets/nutrition/food_reference.json',
    );
    return (jsonDecode(raw) as List<dynamic>)
        .map((row) => FoodReference.fromJson(row as Map<String, dynamic>))
        .toList(growable: false);
  }
}

class MealNutrition {
  final FoodReference food;
  final double grams;
  const MealNutrition(this.food, this.grams);

  double get carbs => food.carbs * grams / 100;
  double? get sugars => food.sugars == null ? null : food.sugars! * grams / 100;

  Map<String, dynamic> toEvent() => {
    'type': 'meal',
    'meal_size': 'normal',
    'meal_food': food.name,
    'meal_grams': grams,
    'meal_carbs_g': carbs,
    'meal_sugars_g': ?sugars,
    'meal_fdc_id': food.fdcId,
  };
}

/// 一餐（可含多样食物）：餐次、是否有甜饮料、是否用照片估算。碳水是参考配方的估算，不当作实测。
class MealRecord {
  final List<MealNutrition> items;
  final String slot; // breakfast / lunch / dinner / snack
  final bool sweetDrink;
  final bool fromPhoto;
  const MealRecord(this.items, this.slot, {this.sweetDrink = false, this.fromPhoto = false});

  double get carbs => items.fold(0, (s, i) => s + i.carbs);
  double? get sugars => items.any((i) => i.sugars == null) ? null : items.fold<double>(0, (s, i) => s + i.sugars!);

  Map<String, dynamic> toEvent() => {
    'type': 'meal',
    'meal_slot': slot,
    'food': items.map((i) => i.food.name).join('＋'),
    'carbs_g': double.parse(carbs.toStringAsFixed(1)),
    if (sugars != null) 'sugars_g': double.parse(sugars!.toStringAsFixed(1)),
    'grams': items.first.grams, // 第一样（通常是主食）的份量，修正份量时以它为准
    'sweet_drink': sweetDrink,
    'estimate': fromPhoto ? 'photo' : 'manual',
    'meal_size': carbs >= 80 || sweetDrink ? 'large' : 'normal',
    'meal_fdc_id': items.first.food.fdcId,
  };
}
