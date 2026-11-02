import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../data/local_store.dart';
import 'task_receipts.dart';

DateTime? snoozeTarget(DailyTask task, int minutes, DateTime now) {
  if (!const {5, 10, 15, 30}.contains(minutes) || !task.canRecord(now)) return null;
  final target = now.add(Duration(minutes: minutes));
  return taskDay(target) == task.day ? target : null;
}

class LocalReminderPlatform {
  static const channel = MethodChannel('cn.medilens.medilens/local_reminders');
  Future<Map<String, dynamic>> status() async =>
      await channel.invokeMapMethod<String, dynamic>('status') ?? {};
  Future<Map<String, dynamic>> requestNotifications() async =>
      await channel.invokeMapMethod<String, dynamic>('requestNotifications') ?? {};
  Future<Map<String, dynamic>> replace(bool enabled, List<Map<String, dynamic>> plans) async =>
      await channel.invokeMapMethod<String, dynamic>('replaceDaily', {'enabled': enabled, 'plans': plans}) ?? {};
  Future<void> openNotifications() => channel.invokeMethod('openNotificationSettings');
  Future<void> openExact() => channel.invokeMethod('openExactSettings');
  Future<void> test() => channel.invokeMethod('test');
  Future<void> acknowledge(String id) => channel.invokeMethod('acknowledge', {'id': id});
  Future<void> undoAcknowledge(String id) => channel.invokeMethod('undoAcknowledge', {'id': id});
  Future<Map<String, dynamic>> checkupStatus() async => await channel.invokeMapMethod<String, dynamic>('checkupStatus') ?? {};
  Future<Map<String, dynamic>> saveCheckup(String id, int at) async =>
      await channel.invokeMapMethod<String, dynamic>('saveCheckup', {'id': id, 'at': at}) ?? {};
  Future<Map<String, dynamic>> cancelCheckup(String id) async =>
      await channel.invokeMapMethod<String, dynamic>('cancelCheckup', {'id': id}) ?? {};
  Future<Map<String, dynamic>> clearCheckups() async => await channel.invokeMapMethod<String, dynamic>('clearCheckups') ?? {};
  Future<Map<String, dynamic>> snooze(String id, int minutes, String day) async =>
      await channel.invokeMapMethod<String, dynamic>('snooze', {'id': id, 'minutes': minutes, 'day': day}) ?? {};
  Future<Map<String, dynamic>> cancelSnooze(String id) async =>
      await channel.invokeMapMethod<String, dynamic>('cancelSnooze', {'id': id}) ?? {};
}

final localReminderPlatformProvider = Provider((ref) => LocalReminderPlatform());

class ReminderState {
  final bool enabled, available, notificationsAllowed, exactAllowed;
  final int plannedCount;
  final String? error;
  final Map<String, int> snoozes;
  const ReminderState({this.enabled = false, this.available = false,
    this.notificationsAllowed = false, this.exactAllowed = false,
    this.plannedCount = 0, this.error, this.snoozes = const {}});
}

class ReminderNotifier extends Notifier<ReminderState> {
  bool _postponing = false;
  static const enabledKey = 'local_reminders_enabled';
  @override
  ReminderState build() => const ReminderState();
  LocalStore get _store => ref.read(localStoreProvider);
  LocalReminderPlatform get _platform => ref.read(localReminderPlatformProvider);

  void _received(Map<String, dynamic> data, bool enabled) {
    state = ReminderState(enabled: enabled, available: data['available'] == true,
      notificationsAllowed: data['notificationsAllowed'] == true,
      exactAllowed: data['exactAllowed'] == true,
      plannedCount: (data['scheduledCount'] as num?)?.toInt() ?? 0,
      snoozes: {for (final entry in ((data['snoozes'] as Map?) ?? {}).entries)
        if (entry.key is String && entry.value is num) entry.key as String: (entry.value as num).toInt()});
  }

  void _failed([String message = '未能同步本机提醒。原有计划可能仍生效，请检查系统权限后重试。']) {
    state = ReminderState(enabled: state.enabled, available: state.available,
      notificationsAllowed: state.notificationsAllowed, exactAllowed: state.exactAllowed,
      plannedCount: state.plannedCount,
      snoozes: state.snoozes, error: message);
  }

  Future<void> load() async {
    final enabled = await _store.getSetting(enabledKey) == 'true';
    try {
      _received(await _platform.status(), enabled);
      if (enabled) _received(await _platform.replace(true, await _plans()), enabled);
    } on MissingPluginException {
      state = const ReminderState();
    } on PlatformException {
      _failed();
    } on FormatException {
      _failed();
    }
  }

  /// Only opaque IDs and clock times enter Android's scheduling storage.
  Future<List<Map<String, dynamic>>> _plans() async {
    final decoded = jsonDecode(await _store.getSetting('life_schedule') ?? '[]');
    if (decoded is! List) throw const FormatException('计划格式不正确');
    final raw = decoded;
    if (raw.length > 32) throw const FormatException('最多 32 项');
    final plans = <Map<String, dynamic>>[];
    var changed = false;
    final seen = <String>{};
    for (final value in raw) {
      if (value is! Map<String, dynamic>) throw const FormatException('计划格式不正确');
      final plan = value;
      final time = plan['time'];
      if (!{'insulin', 'medication'}.contains(plan['task']) || time is! String ||
          !RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d$').hasMatch(time)) {
        throw const FormatException('时间格式不正确');
      }
      if (!seen.add('${plan['task']}:$time')) continue;
      if (plan['id'] is! String || !RegExp(r'^[a-f0-9-]{36}$').hasMatch(plan['id'] as String)) {
        plan['id'] = const Uuid().v4();
        changed = true;
      }
      plans.add({'id': plan['id'], 'hour': int.parse(time.substring(0, 2)),
        'minute': int.parse(time.substring(3))});
    }
    if (changed) await _store.putSetting('life_schedule', jsonEncode(raw));
    return plans;
  }

  Future<bool> setEnabled(bool enabled) async {
    try {
      if (enabled) {
        final permission = await _platform.requestNotifications();
        if (permission['notificationsAllowed'] != true) {
          _received(permission, state.enabled);
          return false;
        }
      }
      final data = await _platform.replace(enabled, enabled ? await _plans() : []);
      await _store.putSetting(enabledKey, enabled ? 'true' : 'false');
      _received(data, enabled);
      return true;
    } on MissingPluginException {
      state = const ReminderState(error: '当前平台暂不支持本机提醒。');
      return false;
    } on PlatformException {
      _failed();
      return false;
    } on FormatException {
      _failed();
      return false;
    }
  }

  Future<void> syncFromStore() async {
    if (await _store.getSetting(enabledKey) != 'true') return;
    await load();
  }

  Future<bool> snoozeTask(DailyTask task, int minutes, {DateTime? now}) async {
    if (_postponing || !state.enabled || !state.notificationsAllowed ||
        snoozeTarget(task, minutes, now ?? ref.read(taskClockProvider)()) == null ||
        ref.read(taskReceiptsProvider).containsKey(task.key)) {
      return false;
    }
    _postponing = true;
    try {
      _received(await _platform.snooze(task.id, minutes, task.day), state.enabled);
      return true;
    } catch (_) {
      _failed('稍后提醒未能安排，原来的时间计划没有改变。请检查通知权限后重试。');
      return false;
    } finally { _postponing = false; }
  }

  Future<bool> cancelPostponement(String id) async {
    if (_postponing) return false;
    _postponing = true;
    try {
      _received(await _platform.cancelSnooze(id), state.enabled);
      return true;
    } catch (_) {
      _failed('未能取消稍后提醒，原提醒可能仍生效，请重试。');
      return false;
    } finally { _postponing = false; }
  }

  Future<bool> sendTest() async {
    try {
      final permission = await _platform.requestNotifications();
      _received(permission, state.enabled);
      if (!state.notificationsAllowed) return false;
      await _platform.test();
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      _failed();
      return false;
    }
  }
}

final remindersProvider = NotifierProvider<ReminderNotifier, ReminderState>(ReminderNotifier.new);
