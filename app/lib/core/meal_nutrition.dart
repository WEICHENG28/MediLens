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
