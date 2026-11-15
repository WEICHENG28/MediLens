/// Local, descriptive matching of paired readings around meals.
/// A direction describes comparable historical pairs, never a glucose forecast.
class LifeObservation {
  final String type;
  final DateTime time;
  final Map<String, dynamic> data;
  LifeObservation(this.type, this.time, this.data);

  double? get glucose {
    final value = _number(data['glucose']);
    return type == 'glucose' && value != null && value > 0 && value < 40
        ? value
        : null;
  }

  double? get carbs => _number(data['meal_carbs_g']);

  static double? _number(Object? value) =>
      value is num && value.isFinite && value >= 0 ? value.toDouble() : null;
}

class ReadingContext {
  final LifeObservation? meal;
  final List<LifeObservation> medication;
  final List<LifeObservation> activity;
  final double? sleepHours;
  const ReadingContext(
    this.meal,
    this.medication,
    this.activity,
    this.sleepHours,
  );

  String get medicationPattern {
    final entries = medication.map((event) {
      final status = event.data['taken'];
      final timing = meal == null || event.time.isBefore(meal!.time)
          ? 'before'
          : 'after';
      return '${event.type}:$status:$timing';
    }).toList()..sort();
    return entries.join('|');
  }

  bool get requiresCaution => medication.any(
    (event) => event.type == 'insulin' || event.data['taken'] != true,
  );
}

enum HistoricalDirection { higher, lower, similar, mixed }

class GlucoseContext {
  static const minimumPairs = 5;
  final List<LifeObservation> timeline;
  final LifeObservation? latest;
  final ReadingContext? context;
  final int comparableDays;
  final HistoricalDirection? direction;
  final String status;
  const GlucoseContext({
    required this.timeline,
    required this.latest,
    required this.context,
    required this.comparableDays,
    required this.direction,
    required this.status,
  });
}

GlucoseContext describeGlucose(
  List<Map<String, dynamic>> records,
  DateTime now,
) {
  final history = <LifeObservation>[];
  for (final record in records) {
    final type = record['type'];
    final rawTime = record['time'];
    if (type is! String || rawTime is! String) continue;
    final time = DateTime.tryParse(rawTime)?.toLocal();
    if (time == null || time.isAfter(now)) continue;
    history.add(LifeObservation(type, time, record));
  }
  history.sort((a, b) => a.time.compareTo(b.time));
  final readings = history.where((event) => event.glucose != null).toList();
  final latest = readings.lastOrNull;
  final anchorContext = latest == null ? null : _context(history, latest.time);
  final timeline = history
      .where(
        (event) =>
            !event.time.isBefore(now.subtract(const Duration(hours: 24))) &&
            (event.glucose != null || _contextTypes.contains(event.type)),
      )
      .toList();

  GlucoseContext result(
    String status, {
    int days = 0,
    HistoricalDirection? direction,
  }) => GlucoseContext(
    timeline: timeline,
    latest: latest,
    context: anchorContext,
    comparableDays: days,
    direction: direction,
    status: status,
  );

  if (latest == null || anchorContext == null) {
    return result('记下一次实测血糖后，可以查看当时的生活记录。');
  }
  if (latest.glucose! < 3.9) {
    return result('这次实测低于 3.9 mmol/L。请按医护人员给你的低血糖处理方案行动。');
  }
  if (now.difference(latest.time) > const Duration(minutes: 30)) {
    return result('最近一次读数已超过 30 分钟。更新实测后可重新比较。');
  }
  final meal = anchorContext.meal;
  final carbs = meal?.carbs;
  if (meal == null ||
      carbs == null ||
      meal.data['meal_fdc_id'] is! int ||
      !_nearMealStart(latest, meal)) {
    return result('要比较餐后方向，请先记录并确认这餐的碳水，并在开餐后 15 分钟内记录实测。');
  }
  if (anchorContext.sleepHours == null) {
    return result('缺少最近一段完整的睡眠记录，暂时无法匹配可比历史。');
  }
  if (anchorContext.requiresCaution ||
      _additionalFactors(history, latest.time, now)) {
    return result('有胰岛素、用药异常或测量后新增生活事件，暂不提供方向线索。');
  }

  final deltas = <DateTime, double>{};
  final currentDay = _day(latest.time);
  for (final pastMeal in history.where((event) => event.type == 'meal')) {
    final day = _day(pastMeal.time);
    final pastCarbs = pastMeal.carbs;
    if (!day.isBefore(currentDay) ||
        deltas.containsKey(day) ||
        pastCarbs == null ||
        pastMeal.data['meal_fdc_id'] != meal.data['meal_fdc_id'] ||
        (pastCarbs - carbs).abs() > 10 ||
        latest.time.difference(pastMeal.time) > const Duration(days: 90)) {
      continue;
    }
    final baseline = readings
        .where((reading) => _nearMealStart(reading, pastMeal))
        .firstOrNull;
    if (baseline == null || (baseline.glucose! - latest.glucose!).abs() > 1) {
      continue;
    }
    final past = _context(history, baseline.time);
    if (!identical(past.meal, pastMeal) ||
        past.requiresCaution ||
        past.sleepHours == null ||
        (past.sleepHours! - anchorContext.sleepHours!).abs() > 1 ||
        past.medicationPattern != anchorContext.medicationPattern ||
        past.activity.isEmpty != anchorContext.activity.isEmpty) {
      continue;
    }
    final after = readings
        .where((reading) {
          final elapsed = reading.time.difference(pastMeal.time);
          return elapsed >= const Duration(minutes: 90) &&
              elapsed <= const Duration(minutes: 150);
        })
        .reduceOrNull(
          (a, b) =>
              (a.time.difference(pastMeal.time).inSeconds - 7200).abs() <=
                  (b.time.difference(pastMeal.time).inSeconds - 7200).abs()
              ? a
              : b,
        );
    if (after == null || _additionalFactors(history, baseline.time, after.time)) {
      continue;
    }
    deltas[day] = after.glucose! - baseline.glucose!;
  }

  final days = deltas.length;
  if (days < GlucoseContext.minimumPairs) {
    return result('找到 $days 天可比历史。至少需要 5 天各有一次餐初及餐后约 2 小时的配对实测。', days: days);
  }
  final changes = deltas.values;
  // A 0.6 mmol/L comparison band and 80% agreement are prototype heuristics,
  // not clinical cutoffs or confidence intervals.
  final higher = changes.where((value) => value >= 0.6).length;
  final lower = changes.where((value) => value <= -0.6).length;
  final similar = days - higher - lower;
  final required = (days * 0.8).ceil();
  final direction = higher >= required
      ? HistoricalDirection.higher
      : lower >= required
      ? HistoricalDirection.lower
      : similar >= required
      ? HistoricalDirection.similar
      : HistoricalDirection.mixed;
  return result(
    '依据过去 $days 天的相似记录。实际变化仍以本次复测为准。',
    days: days,
    direction: direction,
  );
}

const _contextTypes = {
  'meal',
  'medication',
  'insulin',
  'sleep',
  'wake',
  'exercise',
};

DateTime _day(DateTime time) => DateTime(time.year, time.month, time.day);

bool _nearMealStart(LifeObservation reading, LifeObservation meal) {
  final elapsed = reading.time.difference(meal.time);
  return !elapsed.isNegative && elapsed <= const Duration(minutes: 15);
}

bool _additionalFactors(
  List<LifeObservation> events,
  DateTime from,
  DateTime until,
) => events.any(
  (event) =>
      _contextTypes.contains(event.type) &&
      event.time.isAfter(from) &&
      !event.time.isAfter(until),
);

ReadingContext _context(List<LifeObservation> events, DateTime time) {
  final before = events.where((event) => !event.time.isAfter(time)).toList();
  bool within(LifeObservation event, Duration duration) =>
      time.difference(event.time) <= duration;

  final meal = before
      .where(
        (event) =>
            event.type == 'meal' && within(event, const Duration(hours: 3)),
      )
      .lastOrNull;
  final medication = before
      .where(
        (event) =>
            (event.type == 'medication' || event.type == 'insulin') &&
            within(event, const Duration(hours: 6)),
      )
      .toList();
  final activity = before
      .where(
        (event) =>
            event.type == 'exercise' && within(event, const Duration(hours: 3)),
      )
      .toList();

  final wake = before
      .where(
        (event) =>
            event.type == 'wake' && within(event, const Duration(hours: 24)),
      )
      .lastOrNull;
  double? sleepHours;
  if (wake != null) {
    final sleep = before
        .where(
          (event) =>
              (event.type == 'sleep' || event.type == 'wake') &&
              event.time.isBefore(wake.time),
        )
        .lastOrNull;
    if (sleep?.type == 'sleep') {
      final minutes = wake.time.difference(sleep!.time).inMinutes;
      if (minutes > 0 && minutes <= 24 * 60) sleepHours = minutes / 60;
    }
  }
  return ReadingContext(meal, medication, activity, sleepHours);
}

extension _ReduceOrNull<T> on Iterable<T> {
  T? reduceOrNull(T Function(T, T) combine) {
    final values = iterator;
    if (!values.moveNext()) return null;
    var value = values.current;
    while (values.moveNext()) {
      value = combine(value, values.current);
    }
    return value;
  }
}
