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

/// 珍珠鸟的四种状态（组员绘制：图3 日常、图4 开心跳跃、图2 低落、图1 恢复精神）。
enum BirdMood { normal, happy, low, recover }

const birdMoodLabel = {BirdMood.normal: '日常陪伴', BirdMood.happy: '开心加油', BirdMood.low: '有点想你', BirdMood.recover: '打起精神'};

/// 多久没打开生活打卡，再进来时小鸟显示「有点想你」（组员设计：3 小时）。
const birdIdle = Duration(hours: 3);

enum BirdEvent { enterRecent, enterAfterIdle, checkIn, glucoseInRange, glucoseOutOfRange }

/// 小鸟对用户行为的反应（组员设计，两处调整见 assets/pet/SOURCE.md）：
/// - 超过 3 小时再进来 → 有点想你；开始打卡后 → 打起精神。
/// - 打卡、记录的血糖在自己设定的范围内 → 开心跳跃。
/// - 血糖超出范围 → 打起精神并给予关心，而不是低落：不让患者因数值自责，也避免为了让小鸟开心而少记高值。
/// - 关闭「陪伴反馈」时，不显示「有点想你」。
class BirdState {
  final BirdMood mood;
  final String message;
  const BirdState(this.mood, this.message);
}

BirdState birdReact(BirdMood current, BirdEvent event, {bool feedback = true}) => switch (event) {
      BirdEvent.enterAfterIdle when feedback =>
        const BirdState(BirdMood.low, '好一会儿没见到你啦，珍珠鸟有点想你。不用着急，我们慢慢开始。'),
      BirdEvent.enterAfterIdle || BirdEvent.enterRecent =>
        const BirdState(BirdMood.normal, '珍珠鸟在这里陪着你。想记的时候，点下面的按钮就好。'),
      BirdEvent.checkIn when current == BirdMood.low =>
        const BirdState(BirdMood.recover, '你回来啦！珍珠鸟又有精神了，我们一步一步来。'),
      BirdEvent.checkIn => const BirdState(BirdMood.happy, '记好啦！谢谢你照顾自己，珍珠鸟为你开心。'),
      BirdEvent.glucoseInRange => const BirdState(BirdMood.happy, '耶！这次记录在你的目标范围内，珍珠鸟为你开心～'),
      BirdEvent.glucoseOutOfRange => const BirdState(BirdMood.recover,
          '这次在目标范围外。愿意记下来就很重要，珍珠鸟陪你继续按计划来；如果身体不舒服，请及时联系医生。'),
    };

class CompanionSummary {
  final int records; // 今天的记录数
  const CompanionSummary(this.records);
  String get message => records > 0
      ? '今天已经记下 $records 条记录，谢谢你照顾自己。珍珠鸟会陪你一步一步来。'
      : '还没有今天的记录也没关系，珍珠鸟在这里陪着你。想记的时候，我们再慢慢来。';
  String get energy => records > 0 ? '活泼' : '平静';
}

CompanionSummary companionSummary(List<Map<String, dynamic>> events, DateTime now) {
  final day = now.toIso8601String().substring(0, 10);
  return CompanionSummary(events.where((e) {
    final time = DateTime.tryParse(e['time'] as String? ?? '');
    return time != null && !time.isAfter(now) && (e['time'] as String).startsWith(day) && e['type'] != 'reminder';
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
