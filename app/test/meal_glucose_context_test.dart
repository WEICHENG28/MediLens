import 'package:flutter_test/flutter_test.dart';
import 'package:medilens/core/glucose_context.dart';
import 'package:medilens/core/meal_nutrition.dart';

final now = DateTime(2026, 11, 10, 12, 10);

Map<String, dynamic> event(
  String type,
  DateTime time, [
  Map<String, dynamic> data = const {},
]) => {'type': type, 'time': time.toIso8601String(), ...data};

List<Map<String, dynamic>> day(
  int daysAgo, {
  double? followup,
  double carbs = 45,
  int sleep = 8,
  bool takesMedicine = false,
  bool takesInsulin = false,
}) {
  final date = DateTime(now.year, now.month, now.day - daysAgo, 12);
  final wake = date.subtract(const Duration(hours: 5));
  return [
    event('sleep', wake.subtract(Duration(hours: sleep))),
    event('wake', wake),
    if (takesMedicine)
      event('medication', date.subtract(const Duration(hours: 3)), {
        'taken': true,
      }),
    if (takesInsulin)
      event('insulin', date.subtract(const Duration(minutes: 10)), {
        'taken': true,
      }),
    event('meal', date, {'meal_carbs_g': carbs, 'meal_fdc_id': 2708408}),
    event('glucose', date.add(const Duration(minutes: 5)), {'glucose': 6.4}),
    if (followup != null)
      event('glucose', date.add(const Duration(hours: 2)), {
        'glucose': followup,
      }),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('USDA grams scale total carbohydrate and sugar independently', () async {
    final foods = await FoodReference.load();
    final rice = foods.singleWhere((food) => food.fdcId == 2708408);
    final meal = MealNutrition(rice, 150);
    expect(meal.carbs, 42);
    expect(meal.sugars, closeTo(0.075, 0.0001));
    expect(meal.toEvent()['meal_fdc_id'], rice.fdcId);
    expect(foods, hasLength(24));
  });

  test('one current measurement alone is never a direction', () {
    final context = describeGlucose(day(0), now);
    expect(context.latest?.glucose, 6.4);
    expect(context.comparableDays, 0);
    expect(context.direction, isNull);
  });

  test('five distinct comparable days can show an observed direction', () {
    final history = [
      ...day(0),
      for (int i = 1; i <= 5; i++) ...day(i, followup: 8.1),
    ];
    final context = describeGlucose(history, now);
    expect(context.comparableDays, 5);
    expect(context.direction, HistoricalDirection.higher);
    expect(
      describeGlucose(history, now.add(const Duration(minutes: 30))).direction,
      isNull,
    );
  });

  test('disagreement stays visible and low readings suppress a direction', () {
    final history = [
      ...day(0),
      for (int i = 1; i <= 5; i++) ...day(i, followup: i < 4 ? 8 : 5.2),
    ];
    expect(describeGlucose(history, now).direction, HistoricalDirection.mixed);
    history.add(event('glucose', now, {'glucose': 3.4}));
    expect(describeGlucose(history, now).direction, isNull);
  });

  test('meal, sleep, medication, and intervening activity affect matching', () {
    final history = [
      ...day(0, takesMedicine: true),
      ...day(1, followup: 8.1, takesMedicine: true),
      ...day(2, followup: 8.1, takesMedicine: true, sleep: 5),
      ...day(3, followup: 8.1, takesMedicine: true, carbs: 80),
      ...day(4, followup: 8.1),
      ...day(5, followup: 8.1, takesMedicine: true, takesInsulin: true),
      ...day(6, followup: 8.1, takesMedicine: true),
      event('exercise', DateTime(2026, 11, 4, 13), {'minutes': 20}),
    ];
    final context = describeGlucose(history, now);
    expect(context.comparableDays, 1);
    expect(context.direction, isNull);
    expect(context.context?.sleepHours, 8);
    expect(context.context?.medication, hasLength(1));
  });
}
