import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/local_reminders.dart';
import '../core/task_receipts.dart';
import '../core/life_journal.dart';
import '../data/local_store.dart';

class ReminderPage extends ConsumerStatefulWidget {
  const ReminderPage({super.key});
  @override
  ConsumerState<ReminderPage> createState() => _ReminderPageState();
}

class _ReminderPageState extends ConsumerState<ReminderPage> with WidgetsBindingObserver {
  bool busy = false;
  List plans = [];
  Timer? clock;
  String? receiptError;
  bool demoMode = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    clock = Timer.periodic(const Duration(seconds: 30), (_) { if (mounted) setState(() {}); });
  }
  @override
  void dispose() {
    clock?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !busy) _refresh();
  }
  Future<void> _refresh() async {
    await ref.read(remindersProvider.notifier).load();
    if (!mounted) return;
    try {
      final loaded = await loadTaskPlans(ref.read(localStoreProvider));
      final demo = await ref.read(localStoreProvider).getSetting('life_demo_mode') == 'true';
      if (!mounted) return;
      await ref.read(taskReceiptsProvider.notifier).load();
      if (mounted) setState(() { plans = loaded; receiptError = null; demoMode = demo; });
    } catch (_) {
      if (mounted) setState(() { plans = []; receiptError = '任务记录暂时未能读取，请重试；不会据此判断是否已用药。'; });
    }
  }

  Future<void> _record(DailyTask task, bool undo) async {
    List<Map<String, dynamic>> manual = [];
    if (!undo) {
      try {
        final linked = ref.read(taskReceiptsProvider.notifier).manualLinks.values.toSet();
        manual = (await loadManualEvents(ref.read(localStoreProvider))).where((e) => e['type'] == task.kind &&
            e['taken'] == true && (e['time'] as String).startsWith(task.day) && !linked.contains(e['id'])).toList();
      } catch (_) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先检查生活打卡记录，再确认任务。')));
        return;
      }
    }
    if (!mounted) return;
    String? selection;
    final ok = await showDialog<bool>(context: context, builder: (c) => StatefulBuilder(builder: (c, update) => AlertDialog(
      title: Text(undo ? '撤销今天的完成记录？' : '确认这项任务已经完成？'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(undo ? '只撤销任务完成记录，已关联的手动打卡会保留，不改变用药时间。' : '${task.time} ${task.kind == 'insulin' ? '打胰岛素' : '吃药'}\n\n只有您确认已经完成后才记录。这不是现在用药的建议，请以医嘱为准。'),
        if (manual.isNotEmpty) DropdownButton<String>(isExpanded: true, value: selection,
          hint: const Text('请确认是否已经打过卡'),
          items: [for (final e in manual) DropdownMenuItem(value: e['id'] as String,
              child: Text('同一次：使用 ${(e['time'] as String).substring(11, 16)} 的打卡')),
            const DropdownMenuItem(value: '__new__', child: Text('不是同一次，另记一次完成'))],
          onChanged: (v) => update(() => selection = v)),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
        FilledButton(onPressed: manual.isNotEmpty && selection == null ? null : () => Navigator.pop(c, true), child: Text(undo ? '确认撤销' : '确认已完成'))],
    )));
    if (ok != true || !mounted) return;
    setState(() => busy = true);
    try {
      final changed = await ref.read(taskReceiptsProvider.notifier).record(task, ref.read(taskClockProvider)(), undo: undo,
          manualEventId: selection == '__new__' ? null : selection);
      if (!mounted) return;
      var notificationCleared = true;
      if (changed) {
        try {
          final platform = ref.read(localReminderPlatformProvider);
          if (undo) { await platform.undoAcknowledge(task.id); } else { await platform.acknowledge(task.id); }
          if (mounted) await ref.read(remindersProvider.notifier).load();
        }
        catch (_) { notificationCleared = false; }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(changed
          ? (undo ? '已撤销完成记录；不会重新发送过去的通知' : notificationCleared ? '已记录，谢谢你照顾自己' : '完成记录已保存；通知清理未完成，请关闭本条通知') : '记录未改变，请查看今天的任务状态。')));
      }
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('保存未成功，请重试；尚未标记完成。')));
    } finally { if (mounted) setState(() => busy = false); }
  }

  Future<void> _snooze(DailyTask task) async {
    final now = ref.read(taskClockProvider)();
    final minutes = await showDialog<int>(context: context, builder: (c) => AlertDialog(
      title: const Text('稍后再提醒一次'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('只延后这一次通知，不改变医嘱时间，也不会标记任务完成。不能延后到第二天。'),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [for (final value in [5, 10, 15, 30])
          OutlinedButton(onPressed: snoozeTarget(task, value, now) == null ? null : () => Navigator.pop(c, value), child: Text('$value 分钟后'))]),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消'))],
    ));
    if (minutes == null || !mounted) return;
    setState(() => busy = true);
    final ok = await ref.read(remindersProvider.notifier).snoozeTask(task, minutes);
    if (!mounted) return;
    setState(() => busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? '已安排稍后提醒；系统省电或权限限制可能影响送达。' : '稍后提醒未安排，请检查任务时间、完成状态及通知权限。')));
  }

  Future<void> _cancelSnooze(String id) async {
    setState(() => busy = true);
    final ok = await ref.read(remindersProvider.notifier).cancelPostponement(id);
    if (!mounted) return;
    setState(() => busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? '已取消这一次稍后提醒，每日计划不变' : '取消未成功，提醒可能仍生效，请重试')));
  }

  Future<void> _toggle(bool value) async {
    setState(() => busy = true);
    final ok = await ref.read(remindersProvider.notifier).setEnabled(value);
    if (!mounted) return;
    setState(() => busy = false);
    if (!ok) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('提醒未能开启或更新，请查看下方系统权限状态。')));
  }

  Future<void> _settings(bool exact) async {
    try {
      final platform = ref.read(localReminderPlatformProvider);
      if (exact) { await platform.openExact(); } else { await platform.openNotifications(); }
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('未能打开系统设置，请在手机设置中找到 MediLens 的通知和闹钟权限。')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(remindersProvider);
    final receipts = ref.watch(taskReceiptsProvider);
    final now = ref.watch(taskClockProvider)();
    return Scaffold(appBar: AppBar(title: const Text('本机任务提醒')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('按您在“生活打卡”中确认的用药时间，每天发送一次通用通知。时间请以医嘱为准，AI 不会修改它。'),
        SwitchListTile(key: const Key('reminders_enabled'),
          contentPadding: EdgeInsets.zero, title: const Text('开启用药时间通知'),
          subtitle: Text(state.enabled ? '已同步 ${state.plannedCount} 个时间' : '默认关闭，由您主动开启'),
          value: state.enabled, onChanged: busy || !state.available || demoMode ? null : _toggle),
        if (demoMode) const Text('当前为演示计划，不能开启真实任务通知或记录个人完成状态；请在生活打卡中先清空演示。'),
        if (!state.available) const Text('当前平台尚不能使用本机提醒。'),
        if (state.error != null) Text(state.error!, style: const TextStyle(color: Colors.deepOrange)),
        ListTile(contentPadding: EdgeInsets.zero,
          title: Text(state.notificationsAllowed ? '系统通知：已允许' : '系统通知：未允许或已关闭'),
          subtitle: const Text('通知和锁屏仅显示通用提醒，不显示药名、血糖或报告内容。'),
          trailing: TextButton(onPressed: state.available ? () => _settings(false) : null, child: const Text('系统设置'))),
        ListTile(contentPadding: EdgeInsets.zero,
          title: Text(state.exactAllowed ? '精确定时：已允许' : '精确定时：未允许，提醒可能延后'),
          subtitle: const Text('省电限制、关机或系统强制停止应用也可能影响送达。请在自己的手机上测试。'),
          trailing: TextButton(onPressed: state.available ? () => _settings(true) : null, child: const Text('设置'))),
        const Divider(),
        Text('今天的任务 · ${taskDay(now)}', style: Theme.of(context).textTheme.titleMedium),
        const Text('仅由您确认完成；收到通知不会自动算作完成。未记录也不代表未用药。'),
        if (receiptError != null) Text(receiptError!),
        for (final plan in plans) ...[
          Builder(builder: (_) {
            final task = DailyTask(plan, now);
            final completed = receipts[task.key];
            final postponed = state.snoozes[task.id];
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [ListTile(contentPadding: EdgeInsets.zero,
              title: Text('${task.time}  ${task.kind == 'insulin' ? '打胰岛素' : '吃药'}'),
              subtitle: Text(completed != null ? '已记录完成 ${completed.substring(11, 16)}'
                  : task.canRecord(now) ? '待记录' : '尚未到计划时间'),
              trailing: completed != null
                ? TextButton(onPressed: busy || demoMode ? null : () => _record(task, true), child: const Text('撤销'))
                : FilledButton.tonal(onPressed: busy || demoMode || !task.canRecord(now) ? null : () => _record(task, false), child: const Text('记录完成'))),
              if (completed == null) ...[
                if (postponed != null) Text(DateTime.fromMillisecondsSinceEpoch(postponed).isAfter(now)
                    ? '已安排稍后提醒：${DateTime.fromMillisecondsSinceEpoch(postponed).toString().substring(11, 16)}'
                    : '稍后时间已到，实际送达请查看系统通知'),
                Wrap(spacing: 12, children: [
                  TextButton(onPressed: busy || demoMode || !state.enabled || !state.notificationsAllowed || !task.canRecord(now) ? null : () => _snooze(task), child: const Text('稍后提醒')),
                  if (postponed != null) TextButton(onPressed: busy ? null : () => _cancelSnooze(task.id), child: const Text('取消稍后提醒')),
                ]),
              ],
            ]);
          }),
        ],
        const Divider(),
        Text('时间管理', style: Theme.of(context).textTheme.titleMedium),
        if (plans.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('还没有时间计划。先在生活打卡中添加按医嘱安排的时间。')),
        OutlinedButton.icon(icon: const Icon(Icons.edit_calendar), label: const Text('去生活打卡管理时间'),
          onPressed: () async { await context.push('/life'); if (mounted) _refresh(); }),
        TextButton.icon(onPressed: () => context.push('/checkup-reminders'), icon: const Icon(Icons.event), label: const Text('管理复查日期提醒')),
        const SizedBox(height: 12),
        OutlinedButton.icon(key: const Key('reminder_test'), icon: const Icon(Icons.notifications_outlined),
          label: const Text('发送一条测试通知'), onPressed: !state.available || busy ? null : () async {
            setState(() => busy = true);
            final ok = await ref.read(remindersProvider.notifier).sendTest();
            if (!context.mounted) return;
            setState(() => busy = false);
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok
                ? '已安排测试通知，约 10 秒后发送；未允许精确定时时可能延后。可以回到手机桌面等待。'
                : '测试未安排，请先允许系统通知。')));
          }),
        const SizedBox(height: 16),
        const Text('任务完成会用于生活记录和珍珠鸟陪伴。已有同类打卡时请明确选择是否是同一次，不会仅凭时间接近自动合并。稍后提醒只延后通知，不改变医嘱时间。完成、删除计划或关闭提醒会撤销它；重启后不补发过期通知。'),
      ]));
  }
}
