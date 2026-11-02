import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/checkup_reminders.dart';
import '../core/local_reminders.dart';
import '../core/task_receipts.dart';

class CheckupPage extends ConsumerStatefulWidget {
  const CheckupPage({super.key});
  @override
  ConsumerState<CheckupPage> createState() => _CheckupPageState();
}

class _CheckupPageState extends ConsumerState<CheckupPage> with WidgetsBindingObserver {
  bool busy = false;
  @override
  void initState() {
    super.initState(); WidgetsBinding.instance.addObserver(this);
    Future.microtask(() { if (mounted) ref.read(checkupProvider.notifier).load(); });
  }
  @override
  void dispose() { WidgetsBinding.instance.removeObserver(this); super.dispose(); }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !busy) ref.read(checkupProvider.notifier).load();
  }
  String _label(CheckupEntry entry) {
    switch (entry.status) {
      case 'sent': return '已请求发送通知，不代表已复查';
      case 'expired': return '已过期，未自动补发';
      case 'blocked': return '通知未发出，请检查系统权限';
      case 'sending': return '发送状态待核对，请查看系统通知';
      default: return entry.when.isAfter(ref.read(taskClockProvider)()) ? '已安排一次性提醒' : '时间已到，实际送达请查看系统通知';
    }
  }
  Future<void> _edit([CheckupEntry? entry]) async {
    final now = ref.read(taskClockProvider)();
    final today = DateTime(now.year, now.month, now.day);
    final last = DateTime(now.year + 5, now.month, now.day);
    final previous = entry?.when ?? now.add(const Duration(days: 1));
    final date = await showDatePicker(context: context, initialDate: previous.isBefore(today) || previous.isAfter(last) ? today : previous,
      firstDate: today, lastDate: last, helpText: '按医嘱选择复查提醒日期');
    if (date == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: entry == null ? const TimeOfDay(hour: 9, minute: 0) : TimeOfDay.fromDateTime(entry.when),
      helpText: '选择通知时间');
    if (time == null || !mounted) return;
    final target = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    final confirmed = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('确认复查提醒时间'),
      content: Text('${target.toString().substring(0, 16)}\n\n请确认这是您按医生交代设置的时间。APP 不会判断何时需要复查，只发送这一次通知。'),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('返回修改')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('确认并保存'))]));
    if (confirmed != true || !mounted) return;
    setState(() => busy = true);
    final ok = await ref.read(checkupProvider.notifier).save(target, id: entry?.id);
    if (!mounted) return;
    setState(() => busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? '已保存复查提醒' : ref.read(checkupProvider).error ?? '保存未完成')));
  }
  Future<void> _cancel(CheckupEntry entry) async {
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      content: Text('取消 ${entry.when.toString().substring(0, 16)} 的提醒？这不会更改医生安排。'),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('保留')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('取消提醒'))]));
    if (ok != true || !mounted) return;
    setState(() => busy = true);
    final changed = await ref.read(checkupProvider.notifier).cancel(entry.id);
    if (mounted) {
      setState(() => busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(changed ? '已取消提醒' : '取消未成功，请重试')));
    }
  }
  Future<void> _settings(bool exact) async {
    try {
      final platform = ref.read(localReminderPlatformProvider);
      if (exact) { await platform.openExact(); } else { await platform.openNotifications(); }
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请到手机设置中查看 MediLens 的通知与闹钟权限。')));
    }
  }
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(checkupProvider);
    return Scaffold(appBar: AppBar(title: const Text('复查日期提醒')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('按医生交代的日期手动设置，每条只提醒一次。AI 不会决定或修改复查日期。'),
        if (state.error != null) Text(state.error!, style: const TextStyle(color: Colors.deepOrange)),
        TextButton(onPressed: busy ? null : () => ref.read(checkupProvider.notifier).load(), child: const Text('刷新提醒状态')),
        ListTile(contentPadding: EdgeInsets.zero, title: Text(state.allowed ? '系统通知：已允许' : '系统通知：未允许或已关闭'),
          trailing: TextButton(onPressed: state.available ? () => _settings(false) : null, child: const Text('通知设置'))),
        ListTile(contentPadding: EdgeInsets.zero, title: Text(state.exact ? '精确定时：已允许' : '未允许精确定时，可能延后'),
          trailing: TextButton(onPressed: state.available ? () => _settings(true) : null, child: const Text('定时设置'))),
        if (state.entries.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('还没有复查提醒。请先向医生确认日期。')),
        for (final entry in state.entries) Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(entry.when.toString().substring(0, 16), style: Theme.of(context).textTheme.titleMedium),
          Text(_label(entry)),
          Wrap(spacing: 12, children: [TextButton(onPressed: busy ? null : () => _edit(entry), child: const Text('修改时间')),
            TextButton(onPressed: busy ? null : () => _cancel(entry), child: const Text('取消提醒'))]),
        ]))),
        FilledButton.icon(key: const Key('add_checkup'), onPressed: busy || !state.available || state.entries.length >= 32 ? null : () => _edit(),
          icon: const Icon(Icons.event_available), label: const Text('添加复查提醒')),
        const SizedBox(height: 16),
        const Text('本机提醒无需联网，通知只显示通用文字，不含报告或医院。按设置时手机时区保存；旅行或更改时区后请核对时间。重启只恢复未来提醒，过去时间不自动补发。省电限制、关机和系统强制停止可能影响送达。关闭每日用药通知不会取消这里的提醒。'),
      ]));
  }
}
