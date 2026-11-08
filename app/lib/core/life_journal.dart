import 'dart:convert';
import 'package:uuid/uuid.dart';
import '../data/local_store.dart';
import 'desktop_pet.dart';
const taskReceiptStorageKey = 'task_receipts_v1';
final _companionGeneration = Expando<int>();

Future<List<Map<String, dynamic>>> loadManualEvents(LocalStore store) async {
  final raw = jsonDecode(await store.getSetting('life_events') ?? '[]');
  if (raw is! List || raw.any((e) => e is! Map<String, dynamic>)) throw const FormatException('记录格式错误');
  final events = raw.cast<Map<String, dynamic>>();
  var changed = false;
  final ids = <String>{};
  for (final event in events) {
    if (event['id'] is! String || !ids.add(event['id'] as String)) {
      event['id'] = const Uuid().v4(); ids.add(event['id'] as String); changed = true;
    }
  }
  if (changed) await store.putSetting('life_events', jsonEncode(events));
  return events;
}

/// Derived task events never get appended to the manual-event storage.
List<Map<String, dynamic>> effectiveLifeEvents(List<Map<String, dynamic>> manual,
    Map<String, String> receipts, Map<String, String> links) {
  final result = manual.map((e) => Map<String, dynamic>.from(e)).toList();
  for (final entry in receipts.entries) {
    final parts = entry.key.split('|');
    if (parts.length != 4 || !{'medication', 'insulin'}.contains(parts[2])) continue;
    final time = DateTime.tryParse(entry.value);
    if (time == null || !entry.value.startsWith(parts[0])) continue;
    if (manual.any((e) => e['id'] == links[entry.key] && e['type'] == parts[2] && e['taken'] == true &&
        (e['time'] as String? ?? '').startsWith(parts[0]))) {
      continue;
    }
    result.add({'id': 'task:${entry.key}', 'type': parts[2], 'time': entry.value, 'taken': true});
  }
  result.sort((a, b) => (a['time'] as String).compareTo(b['time'] as String));
  return result;
}

/// 珍珠鸟的四种状态。只回应「有没有记录」，从不随血糖数值或漏药变化。
enum BirdMood { normal, happy, low, recover }

const birdMoodLabel = {BirdMood.normal: '日常陪伴', BirdMood.happy: '开心加油', BirdMood.low: '有点想你', BirdMood.recover: '正在恢复'};

class CompanionSummary {
  final int records; // 今天的记录数
  final int? daysSinceBefore; // 今天之前，距离最近一次记录的天数；null 表示以前没有记录
  final bool justRecorded; // 刚完成一次打卡（页面内的即时反馈）
  const CompanionSummary(this.records, {this.daysSinceBefore, this.justRecorded = false});

  /// 隔了 2 天以上才回来，或者 2 天以上没有记录，才显示「恢复 / 想你」；关闭陪伴反馈时只显示日常与开心。
  BirdMood mood({bool feedback = true}) {
    if (justRecorded) return BirdMood.happy;
    final away = (daysSinceBefore ?? 0) >= 2;
    if (records > 0) return away && feedback ? BirdMood.recover : BirdMood.normal;
    return away && feedback ? BirdMood.low : BirdMood.normal;
  }

  String messageFor(BirdMood m) => switch (m) {
        BirdMood.happy => '记好啦！今天已经记下 $records 条记录，珍珠鸟为你开心。',
        BirdMood.recover => '你回来啦！今天已经记下 $records 条记录，珍珠鸟又有精神了，我们一步一步来。',
        BirdMood.low => '好一会儿没见到你啦。不用着急，想记的时候我们再慢慢开始。',
        BirdMood.normal => message,
      };

  String get message => records > 0
      ? '今天已经记下 $records 条记录，谢谢你照顾自己。珍珠鸟会陪你一步一步来。'
      : '还没有今天的记录也没关系，珍珠鸟在这里陪着你。想记的时候，我们再慢慢来。';
  String get energy => records > 0 ? '活泼' : '平静';
}

CompanionSummary companionSummary(List<Map<String, dynamic>> events, DateTime now, {bool justRecorded = false}) {
  final day = now.toIso8601String().substring(0, 10);
  final today = DateTime(now.year, now.month, now.day);
  var records = 0;
  DateTime? lastBefore;
  for (final e in events) {
    final time = DateTime.tryParse(e['time'] as String? ?? '');
    if (time == null || time.isAfter(now) || e['type'] == 'reminder') continue;
    if ((e['time'] as String).startsWith(day)) {
      records++;
    } else if (time.isBefore(today) && (lastBefore == null || time.isAfter(lastBefore))) {
      lastBefore = time;
    }
  }
  final gap = lastBefore == null ? null : today.difference(DateTime(lastBefore.year, lastBefore.month, lastBefore.day)).inDays;
  return CompanionSummary(records, daysSinceBefore: gap, justRecorded: justRecorded && records > 0);
}

Future<void> updateLocalCompanion(LocalStore store, DateTime now) async {
  final generation = (_companionGeneration[store] ?? 0) + 1;
  _companionGeneration[store] = generation;
  final enabled = await store.getSetting('life_companion_enabled') != 'false';
  final demo = await store.getSetting('life_demo_mode') == 'true';
  final raw = jsonDecode(await store.getSetting(taskReceiptStorageKey) ?? '{}') as Map;
  final receipts = Map<String, String>.from(raw['version'] == 2 ? raw['receipts'] as Map : raw);
  final links = Map<String, String>.from(raw['version'] == 2 ? raw['manual_links'] as Map : {});
  final events = effectiveLifeEvents(await loadManualEvents(store), receipts, links);
  if (_companionGeneration[store] != generation) return;
  await DesktopPet.update(energyState: enabled && !demo ? companionSummary(events, now).energy : null);
}
