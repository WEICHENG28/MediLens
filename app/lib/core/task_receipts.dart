import 'dart:convert';
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../data/local_store.dart';
import 'life_journal.dart';

String taskDay(DateTime time) => time.toIso8601String().substring(0, 10);
final taskClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

class DailyTask {
  final String id, kind, time, day;
  DailyTask(Map plan, DateTime date)
      : id = plan['id'] as String, kind = plan['task'] as String,
        time = plan['time'] as String, day = taskDay(date);
  String get key => '$day|$id|$kind|$time';
  DateTime get scheduled => DateTime.parse('${day}T$time:00');
  bool canRecord(DateTime now) => taskDay(now) == day && !now.isBefore(scheduled);
}

Future<List<Map<String, dynamic>>> loadTaskPlans(LocalStore store) async {
  final raw = jsonDecode(await store.getSetting('life_schedule') ?? '[]');
  if (raw is! List) throw const FormatException('计划格式错误');
  final plans = <Map<String, dynamic>>[];
  final ids = <String>{};
  var changed = false;
  for (final value in raw) {
    if (value is! Map<String, dynamic> || !{'medication', 'insulin'}.contains(value['task']) ||
        value['time'] is! String || !RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d$').hasMatch(value['time'])) {
      throw const FormatException('计划格式错误');
    }
    if (value['id'] is! String || !RegExp(r'^[a-f0-9-]{36}$').hasMatch(value['id']) || ids.contains(value['id'])) {
      value['id'] = const Uuid().v4(); changed = true;
    }
    ids.add(value['id'] as String);
    plans.add(value);
  }
  if (changed) await store.putSetting('life_schedule', jsonEncode(plans));
  return plans;
}

class TaskReceipts extends Notifier<Map<String, String>> {
  static const storageKey = taskReceiptStorageKey;
  bool _saving = false;
  Future<void> _companionUpdate = Future.value();
  Map<String, String> _links = {};
  Map<String, String> get manualLinks => Map.unmodifiable(_links);
  Future<void> clear() async {
    if (_saving) throw StateError('正在保存');
    await _store.putSetting(storageKey, '{}');
    _links = {}; state = {};
  }
  @override
  Map<String, String> build() => {};
  LocalStore get _store => ref.read(localStoreProvider);
  Future<void> load() async {
    if (_saving) return;
    final saved = jsonDecode(await _store.getSetting(storageKey) ?? '{}');
    final raw = saved is Map && saved['version'] == 2 ? saved['receipts'] : saved;
    if (raw is! Map || raw.values.any((v) => v is! String || v.length < 16 || DateTime.tryParse(v) == null)) throw const FormatException('记录格式错误');
    final links = saved is Map && saved['version'] == 2 ? saved['manual_links'] : <String, String>{};
    if (links is! Map || links.values.any((v) => v is! String)) throw const FormatException('关联格式错误');
    _links = Map<String, String>.from(links);
    state = Map<String, String>.from(raw);
  }
  Future<bool> record(DailyTask task, DateTime now, {bool undo = false, String? manualEventId}) async {
    if (_saving || taskDay(now) != task.day || (!undo && !task.canRecord(now))) return false;
    if (undo ? !state.containsKey(task.key) : state.containsKey(task.key)) return false;
    _saving = true;
    try {
      if (!undo && manualEventId != null) {
        final manual = await loadManualEvents(_store);
        if (_links.containsValue(manualEventId) || !manual.any((e) => e['id'] == manualEventId &&
            e['type'] == task.kind && e['taken'] == true && (e['time'] as String).startsWith(task.day))) {
          return false;
        }
      }
      final next = Map<String, String>.from(state);
      final links = Map<String, String>.from(_links);
      if (undo) { next.remove(task.key); } else { next[task.key] = now.toIso8601String(); }
      if (undo) { links.remove(task.key); } else if (manualEventId != null) { links[task.key] = manualEventId; }
      // One encrypted settings write: no partial completion/event updates.
      await _store.putSetting(storageKey, jsonEncode(links.isEmpty ? next : {'version': 2, 'receipts': next, 'manual_links': links}));
      _links = links;
      state = next;
      final store = _store;
      _companionUpdate = _companionUpdate.then((_) => updateLocalCompanion(store, now)).catchError((Object _) {});
      unawaited(_companionUpdate);
      return true;
    } finally { _saving = false; }
  }
}

final taskReceiptsProvider = NotifierProvider<TaskReceipts, Map<String, String>>(TaskReceipts.new);
