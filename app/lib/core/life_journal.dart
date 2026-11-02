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

class CompanionSummary {
  final int records;
  const CompanionSummary(this.records);
  String get message => records > 0
      ? '今天已经记下 $records 条记录，谢谢你照顾自己。小兔会陪你一步一步来。'
      : '还没有今天的记录也没关系，小兔在这里陪着你。想记的时候，我们再慢慢来。';
  String get energy => records > 0 ? '活泼' : '平静';
}

CompanionSummary companionSummary(List<Map<String, dynamic>> events, DateTime now) {
  final day = now.toIso8601String().substring(0, 10);
  return CompanionSummary(events.where((e) {
    final time = DateTime.tryParse(e['time'] as String? ?? '');
    return time != null && !time.isAfter(now) && (e['time'] as String).startsWith(day) &&
        e['type'] != 'reminder';
  }).length);
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
