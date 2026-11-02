import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'local_reminders.dart';
import 'task_receipts.dart';

class CheckupEntry {
  final String id, status;
  final int at;
  const CheckupEntry(this.id, this.at, this.status);
  DateTime get when => DateTime.fromMillisecondsSinceEpoch(at);
}

class CheckupState {
  final bool available, allowed, exact;
  final List<CheckupEntry> entries;
  final String? error;
  const CheckupState({this.available = false, this.allowed = false, this.exact = false, this.entries = const [], this.error});
}

class CheckupNotifier extends Notifier<CheckupState> {
  bool _saving = false;
  @override
  CheckupState build() => const CheckupState();
  LocalReminderPlatform get _platform => ref.read(localReminderPlatformProvider);
  void _received(Map<String, dynamic> data) {
    final entries = [for (final e in ((data['checkups'] as Map?) ?? {}).entries)
      CheckupEntry(e.key as String, (e.value['at'] as num).toInt(), e.value['state'] as String)]
      ..sort((a, b) => a.at.compareTo(b.at));
    state = CheckupState(available: data['available'] == true, allowed: data['notificationsAllowed'] == true,
      exact: data['exactAllowed'] == true, entries: entries);
  }
  void _failed(String message) {
    state = CheckupState(available: state.available, allowed: state.allowed, exact: state.exact,
      entries: state.entries, error: message);
  }
  Future<void> load() async {
    if (_saving) return;
    try { _received(await _platform.checkupStatus()); }
    catch (_) { _failed('复查提醒暂未读取成功，请重试。原提醒没有被删除。'); }
  }
  Future<bool> save(DateTime when, {String? id}) async {
    final now = ref.read(taskClockProvider)();
    if (_saving) return false;
    if (!when.isAfter(now)) { _failed('请选择未来的日期和时间。'); return false; }
    if (state.entries.any((e) => e.id != id && e.status == 'scheduled' && e.at == when.millisecondsSinceEpoch)) {
      _failed('已经有相同时间的复查提醒。'); return false;
    }
    _saving = true;
    try {
      final permission = await _platform.requestNotifications();
      if (permission['notificationsAllowed'] != true) {
        _received(await _platform.checkupStatus());
        _failed('未允许系统通知，提醒没有保存。请在系统设置中允许后重试。');
        return false;
      }
      _received(await _platform.saveCheckup(id ?? const Uuid().v4(), when.millisecondsSinceEpoch));
      return true;
    } catch (_) {
      _failed('保存未成功，请重试并核对原提醒。'); return false;
    } finally { _saving = false; }
  }
  Future<bool> cancel(String id) async {
    if (_saving) return false;
    _saving = true;
    try { _received(await _platform.cancelCheckup(id)); return true; }
    catch (_) { _failed('取消未成功，原提醒可能仍生效，请重试。'); return false; }
    finally { _saving = false; }
  }
  Future<bool> clearAll() async {
    if (_saving) return false;
    _saving = true;
    try { _received(await _platform.clearCheckups()); return true; }
    catch (_) { _failed('复查提醒尚未撤销，请重试后再删除记录。'); return false; }
    finally { _saving = false; }
  }
}

final checkupProvider = NotifierProvider<CheckupNotifier, CheckupState>(CheckupNotifier.new);
