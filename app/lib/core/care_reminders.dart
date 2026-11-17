// 照护提醒：由即时回馈产生（餐后 2 小时测血糖、睡前测血糖、15 分钟后复测）。
// 提醒内容只保存在本机；开启「本机任务提醒」时才排系统通知，通知只显示通用文字，不含病情。

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../data/local_store.dart';
import 'local_reminders.dart';
import 'task_receipts.dart';

const careRemindersKey = 'care_reminders_v1';

class CareReminder {
  final String id;
  final DateTime at;
  final String title;
  final String reason;
  final bool done;
  const CareReminder({required this.id, required this.at, required this.title, required this.reason, this.done = false});

  Map<String, dynamic> toJson() => {'id': id, 'at': at.toIso8601String(), 'title': title, 'reason': reason, 'done': done};
  static CareReminder? fromJson(Object? j) {
    if (j is! Map) return null;
    final at = DateTime.tryParse('${j['at']}');
    if (at == null || j['id'] is! String || j['title'] is! String) return null;
    return CareReminder(id: j['id'] as String, at: at, title: j['title'] as String, reason: '${j['reason'] ?? ''}',
        done: j['done'] == true);
  }

  CareReminder copyWith({bool? done}) => CareReminder(id: id, at: at, title: title, reason: reason, done: done ?? this.done);
}

/// 合并新提醒：同一标题、时间相差 10 分钟以内的视为同一个；过期超过 1 天的清掉。
List<CareReminder> mergeCareReminders(List<CareReminder> old, Iterable<CareReminder> incoming, DateTime now) {
  final out = [for (final r in old) if (now.difference(r.at) < const Duration(days: 1)) r];
  for (final r in incoming) {
    if (!r.at.isAfter(now)) continue;
    if (out.any((o) => o.title == r.title && o.at.difference(r.at).abs() <= const Duration(minutes: 10))) continue;
    out.add(r);
  }
  out.sort((a, b) => a.at.compareTo(b.at));
  return out;
}

class CareRemindersNotifier extends Notifier<List<CareReminder>> {
  @override
  List<CareReminder> build() => const [];
  LocalStore get _store => ref.read(localStoreProvider);
  LocalReminderPlatform get _platform => ref.read(localReminderPlatformProvider);

  Future<void> load() async {
    try {
      final raw = jsonDecode(await _store.getSetting(careRemindersKey) ?? '[]');
      state = [for (final j in (raw is List ? raw : const [])) ?CareReminder.fromJson(j)];
    } catch (_) {
      state = const [];
    }
  }

  Future<void> _persist() => _store.putSetting(careRemindersKey, jsonEncode([for (final r in state) r.toJson()]));

  /// 加入即时回馈带来的提醒（后端格式：at / title / reason）。开启本机提醒时排系统通知；失败也保留在应用内显示。
  Future<List<CareReminder>> addFromServer(List<dynamic> raw) async {
    final now = ref.read(taskClockProvider)();
    final incoming = <CareReminder>[];
    for (final j in raw) {
      if (j is! Map) continue;
      final at = DateTime.tryParse('${j['at']}');
      if (at == null || j['title'] is! String) continue;
      incoming.add(CareReminder(id: const Uuid().v4(), at: at, title: j['title'] as String, reason: '${j['reason'] ?? ''}'));
    }
    final before = {for (final r in state) r.id};
    state = mergeCareReminders(state, incoming, now);
    await _persist();
    final added = [for (final r in state) if (!before.contains(r.id)) r];
    if (added.isNotEmpty && ref.read(remindersProvider).enabled) {
      for (final r in added) {
        try { await _platform.saveCare(r.id, r.at.millisecondsSinceEpoch); } catch (_) {/* 应用内仍会显示 */}
      }
    }
    return added;
  }

  Future<void> markDone(String id) async {
    state = [for (final r in state) r.id == id ? r.copyWith(done: true) : r];
    await _persist();
    try { await _platform.cancelCare(id); } catch (_) {}
  }

  Future<void> clear() async {
    state = const [];
    await _persist();
    try { await _platform.clearCare(); } catch (_) {}
  }
}

final careRemindersProvider = NotifierProvider<CareRemindersNotifier, List<CareReminder>>(CareRemindersNotifier.new);
