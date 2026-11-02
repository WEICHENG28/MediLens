// 生活打卡与小兔陪伴（原型）：记录用药/打针、吃饭、运动、睡眠、血糖 → 后端分析个人规律、宠物状态与提醒。
// 记录保存在本机（加密数据库）；分析时只发送打卡记录（时间、类型、数值），不含身份信息。

import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../core/api_client.dart';
import '../core/local_reminders.dart';
import '../core/task_receipts.dart';
import '../core/life_journal.dart';
import '../data/local_store.dart';
import '../widgets/interactive_bunny.dart';

const _kEvents = 'life_events';
const _kSchedule = 'life_schedule';
const _kNegative = 'life_negative_feedback';

class LifePage extends ConsumerStatefulWidget {
  const LifePage({super.key});
  @override
  ConsumerState<LifePage> createState() => _LifePageState();
}

class _LifePageState extends ConsumerState<LifePage> {
  List<Map<String, dynamic>> events = [];
  List<Map<String, dynamic>> schedule = [];
  bool companion = true;
  bool demo = false;
  bool adding = false;
  List<Map<String, dynamic>> projected = [];
  Map<String, dynamic>? result;
  String? error;
  bool busy = false;

  LocalStore get store => ref.read(localStoreProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
    events = await loadManualEvents(store);
    schedule = List<Map<String, dynamic>>.from(jsonDecode(await store.getSetting(_kSchedule) ?? '[]') as List);
    companion = await store.getSetting('life_companion_enabled') != 'false';
    demo = await store.getSetting('life_demo_mode') == 'true';
    if (mounted) await _analyze();
    } catch (_) {
      if (mounted) setState(() => error = '本机记录暂时无法读取，请重试；原记录没有删除。');
    }
  }

  Future<void> _save() async {
    for (final plan in schedule) {
      if (plan['id'] is! String || !RegExp(r'^[a-f0-9-]{36}$').hasMatch(plan['id'] as String)) plan['id'] = const Uuid().v4();
    }
    await store.putSetting(_kEvents, jsonEncode(events));
    await store.putSetting(_kSchedule, jsonEncode(schedule));
    await store.putSetting(_kNegative, 'false');
    await store.putSetting('life_companion_enabled', companion ? 'true' : 'false');
    await store.putSetting('life_demo_mode', demo ? 'true' : 'false');
    await ref.read(remindersProvider.notifier).syncFromStore();
  }

  String _now() => ref.read(taskClockProvider)().toIso8601String().substring(0, 19);
  String _today() => taskDay(ref.read(taskClockProvider)());

  Future<void> _analyze() async {
    setState(() => busy = true);
    try {
      final receipts = ref.read(taskReceiptsProvider.notifier);
      await receipts.load();
      projected = effectiveLifeEvents(events, demo ? {} : ref.read(taskReceiptsProvider), demo ? {} : receipts.manualLinks);
      unawaited(updateLocalCompanion(store, ref.read(taskClockProvider)()).catchError((Object _) {}));
      if (!mounted) return;
      if (projected.isEmpty) { setState(() { result = null; error = null; }); return; }
      final r = await ref.read(apiClientProvider).lifestyle({
        'events': (projected.length > 3000 ? projected.sublist(projected.length - 3000) : projected).map((e) => {
          for (final key in ['type', 'time', 'taken', 'insulin_kind', 'meal_size', 'minutes', 'glucose', 'task', 'slot'])
            if (e.containsKey(key)) key: e[key],
        }).toList(),
        'schedule': schedule,
        'today': _today(),
        'negative_feedback': false,
      });
      if (!mounted) return;
      setState(() {
        result = r;
        error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _add(Map<String, dynamic> e) async {
    if (adding || demo) return;
    adding = true;
    try {
      if ({'medication', 'insulin'}.contains(e['type']) && e['taken'] == true) {
        await ref.read(taskReceiptsProvider.notifier).load();
        if (!mounted) return;
        final matches = ref.read(taskReceiptsProvider).entries.where((r) => r.key.startsWith('${_today()}|') && r.key.split('|')[2] == e['type']).toList();
        if (matches.isNotEmpty) {
          final choice = await showDialog<String>(context: context, builder: (c) => AlertDialog(
            title: const Text('今天已有同类任务完成记录'),
            content: Text('已记录的计划时间：${matches.map((r) => r.key.split('|').last).join('、')}。\n本次是否是同一次？不会仅按时间自动合并。'),
            actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
              TextButton(onPressed: () => Navigator.pop(c, 'same'), child: const Text('同一次，不重复记录')),
              FilledButton(onPressed: () => Navigator.pop(c, 'new'), child: const Text('不是同一次，另记一次'))]));
          if (choice != 'new' || !mounted) {
            if (mounted && choice == 'same') ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已保留原任务记录，没有重复添加')));
            return;
          }
        }
      }
      final next = [...events, {'id': const Uuid().v4(), 'time': _now(), ...e}];
      await store.putSetting(_kEvents, jsonEncode(next));
      events = next;
      await _analyze();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已记录'), duration: Duration(seconds: 1)));
    } catch (_) {
      if (mounted) setState(() => error = '记录未能完成，请检查后重试。');
    } finally { adding = false; }
  }

  Future<void> _loadDemo() async {
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('载入合成演示记录？'),
      content: const Text('这会替换当前生活打卡和用药时间，并关闭本机提醒。任务完成记录会保留，但不合并到演示分析。请不要用演示数据代替自己的记录。'),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('继续载入'))]));
    if (ok != true || !mounted) return;
    setState(() => busy = true);
    try {
      if (ref.read(remindersProvider).available && !await ref.read(remindersProvider.notifier).setEnabled(false)) {
        if (mounted) setState(() => error = '请先在本机提醒中关闭通知，再载入演示记录。');
        return;
      }
      final d = await ref.read(apiClientProvider).lifestyleDemo(_today());
      demo = true;
      events = List<Map<String, dynamic>>.from(d['events'] as List);
      schedule = List<Map<String, dynamic>>.from(d['schedule'] as List);
      await _save();
      await _analyze();
    } catch (e) {
      setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      content: const Text('清空生活打卡与任务完成记录，并关闭本机提醒？用药时间计划保留。此操作不可恢复。'),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('清空'))]));
    if (ok != true || !mounted) return;
    if (ref.read(remindersProvider).available && !await ref.read(remindersProvider.notifier).setEnabled(false)) return;
    await ref.read(taskReceiptsProvider.notifier).clear();
    events = [];
    demo = false;
    await _save();
    await _analyze();
  }

  Future<void> _askExercise() async {
    final m = await showDialog<int>(
      context: context,
      builder: (c) => SimpleDialog(title: const Text('运动了多久？'), children: [
        for (final v in [10, 20, 30, 45, 60]) SimpleDialogOption(onPressed: () => Navigator.pop(c, v), child: Text('$v 分钟')),
      ]),
    );
    if (m != null) await _add({'type': 'exercise', 'minutes': m});
  }

  Future<void> _askGlucose() async {
    final c = TextEditingController();
    final v = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('血糖（mmol/L）'),
        content: TextField(controller: c, keyboardType: const TextInputType.numberWithOptions(decimal: true), autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, double.tryParse(c.text.trim())), child: const Text('记录')),
        ],
      ),
    );
    if (v != null && v > 0 && v < 40) await _add({'type': 'glucose', 'glucose': v});
  }

  Future<void> _addSchedule() async {
    if (demo) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先清空演示，再添加自己的用药时间。')));
      return;
    }
    if (schedule.length >= 32) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('最多添加 32 个用药时间，请先删除不再使用的时间。')));
      return;
    }
    final t = await showTimePicker(context: context, initialTime: const TimeOfDay(hour: 8, minute: 0));
    if (t == null || !mounted) return;
    final task = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(title: const Text('这个时间要做什么？'), children: [
        SimpleDialogOption(onPressed: () => Navigator.pop(c, 'insulin'), child: const Text('打胰岛素')),
        SimpleDialogOption(onPressed: () => Navigator.pop(c, 'medication'), child: const Text('吃药')),
      ]),
    );
    if (task == null) return;
    final time = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    if (schedule.any((s) => s['task'] == task && s['time'] == time)) return;
    schedule.add({'id': const Uuid().v4(), 'task': task, 'time': time, 'label': '按医嘱'});
    await _save();
    await _analyze();
  }

  @override
  Widget build(BuildContext context) {
    final r = result;
    final reminders = ref.watch(remindersProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('生活打卡 · 小兔陪伴'), actions: [
        PopupMenuButton<String>(
          onSelected: (v) => v == 'demo' ? _loadDemo() : _clear(),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'demo', child: Text('载入两周示例记录（演示用）')),
            PopupMenuItem(value: 'clear', child: Text('清空生活与任务记录')),
          ],
        ),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (busy) const LinearProgressIndicator(),
        if (error != null) Card(child: Padding(padding: const EdgeInsets.all(12), child: Text(error!))),
        if (reminders.error != null) Card(child: Padding(padding: const EdgeInsets.all(12), child: Text(reminders.error!))),
        if (demo) const Text('合成演示数据：不合并个人任务记录。请先清空演示，再记录自己的生活。', style: TextStyle(color: Colors.deepOrange)),
        if (companion) _PetCard(summary: companionSummary(projected, ref.read(taskClockProvider)())),
        if (r != null)
          for (final a in (r['alerts'] as List)) _AlertCard(a as Map<String, dynamic>),
        if (r?['pet']?['safety_note'] != null) _AlertCard({'level': 'yellow', 'title': '已记录的用药疑问', 'text': r!['pet']['safety_note']}),
        const SizedBox(height: 12),
        Text('打卡', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [
          _chip(Icons.vaccines, '打了胰岛素', () => _add({'type': 'insulin', 'insulin_kind': 'rapid', 'taken': true})),
          _chip(Icons.warning_amber, '忘了打针', () => _add({'type': 'insulin', 'insulin_kind': 'rapid', 'taken': false})),
          _chip(Icons.medication, '吃了药', () => _add({'type': 'medication', 'taken': true})),
          _chip(Icons.warning_amber, '忘了吃药', () => _add({'type': 'medication', 'taken': false})),
          _chip(Icons.restaurant, '吃饭', () => _add({'type': 'meal', 'meal_size': 'normal'})),
          _chip(Icons.directions_walk, '运动', _askExercise),
          _chip(Icons.bedtime, '睡觉', () => _add({'type': 'sleep'})),
          _chip(Icons.wb_sunny_outlined, '起床', () => _add({'type': 'wake'})),
          _chip(Icons.bloodtype_outlined, '记血糖', _askGlucose),
        ]),
        if (r != null) ..._results(context, r),
        const SizedBox(height: 16),
        Text('用药时间（按医嘱）', style: Theme.of(context).textTheme.titleMedium),
        for (final (i, s) in schedule.indexed)
          ListTile(
            dense: true,
            leading: Icon(s['task'] == 'insulin' ? Icons.vaccines : Icons.medication),
            title: Text('${s['time']}  ${s['task'] == 'insulin' ? '打胰岛素' : '吃药'}'),
            subtitle: Text('${s['label'] ?? ''}'),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除',
              onPressed: () async {
                schedule.removeAt(i);
                await _save();
                await _analyze();
              },
            ),
          ),
        TextButton.icon(onPressed: _addSchedule, icon: const Icon(Icons.add), label: const Text('添加用药时间')),
        ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.notifications_none),
          title: const Text('本机任务提醒'),
          subtitle: Text(reminders.enabled ? '已开启；点击检查权限和测试送达' : '默认关闭；添加时间不会自动发送通知'),
          onTap: () async { await context.push('/reminder'); if (mounted) _load(); }),
        SwitchListTile(
          title: const Text('小兔陪伴反馈'),
          subtitle: const Text('只鼓励确认过的记录，不扣健康分，也不把未记录当作漏药。小兔状态不代表真实病情。'),
          value: companion,
          onChanged: (v) async {
            setState(() => companion = v);
            await _save();
            await _analyze();
          },
        ),
        const SizedBox(height: 8),
        Text('打卡记录保存在本机；分析时只发送记录的时间、类型与数值，不含姓名等身份信息。原型功能，规律分析与提醒未经医学审核。',
            style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }

  Widget _chip(IconData icon, String label, VoidCallback onTap) =>
      ActionChip(key: Key('life_$label'), avatar: Icon(icon, size: 18), label: Text(label), onPressed: busy || demo ? null : onTap);

  List<Widget> _results(BuildContext context, Map<String, dynamic> r) {
    final m = r['metrics'] as Map<String, dynamic>;
    String pct(Object? v) => v == null ? '—' : '${((v as num) * 100).round()}%';
    final insights = r['insights'] as List;
    final reminders = r['reminders'] as List;
    return [
      const SizedBox(height: 16),
      Text('最近的情况', style: Theme.of(context).textTheme.titleMedium),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(spacing: 24, runSpacing: 8, children: [
            _stat('血糖在 3.9–10 的比例', pct(m['tir'])),
            _stat('偏低次数', '${m['low_events']}'),
            _stat('用药记录覆盖（原型）', pct(m['adherence'])),
            _stat('血糖记录', '${m['readings']} 次'),
          ]),
        ),
      ),
      const SizedBox(height: 12),
      Text('我的规律', style: Theme.of(context).textTheme.titleMedium),
      if (insights.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('记录还不够多，暂时没有发现明显规律（建议连续记录 2–4 周）。')),
      for (final i in insights.cast<Map<String, dynamic>>())
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(i['title'] as String, style: const TextStyle(fontWeight: FontWeight.bold))),
                Text(i['confidence'] == '较明确' ? '较明确' : '初步', style: Theme.of(context).textTheme.bodySmall),
              ]),
              const SizedBox(height: 4),
              Text(i['finding'] as String),
              for (final g in (i['groups'] as List).cast<Map<String, dynamic>>())
                Text('· ${g['label']}：${g['n']} 次，中位数 ${g['median']} mmol/L', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 4),
              Text('复诊可以问：${i['doctor_question']}', style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
        ),
      Text(r['disclaimer'] as String, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 12),
      Text('提醒', style: Theme.of(context).textTheme.titleMedium),
      for (final x in reminders.cast<Map<String, dynamic>>())
        ListTile(
          dense: true,
          leading: Icon(x['adaptive'] != null ? Icons.auto_awesome : Icons.alarm),
          title: Text('${x['when']}  ${x['task']}'),
          subtitle: Text(x['reason'] as String),
        ),
      Text('带星光图标的提醒会根据您过去完成提醒的情况，自动选择最容易做到的时段。', style: Theme.of(context).textTheme.bodySmall),
    ];
  }

  Widget _stat(String label, String value) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ]);
}

class _PetCard extends StatelessWidget {
  final CompanionSummary summary;
  const _PetCard({required this.summary});
  @override
  Widget build(BuildContext context) => Card(child: Padding(
    padding: const EdgeInsets.all(16), child: Column(children: [
      const InteractiveBunny(),
      const SizedBox(height: 8),
      Text(summary.message, key: const Key('pet_message'), textAlign: TextAlign.center),
      const SizedBox(height: 8),
      const Text('未记录不代表未完成；小兔的样子不代表您的健康状况。'),
    ])));
}

class _AlertCard extends StatelessWidget {
  final Map<String, dynamic> a;
  const _AlertCard(this.a);
  @override
  Widget build(BuildContext context) => Card(
        color: a['level'] == 'red' ? const Color(0xFFFDECEA) : const Color(0xFFFFF4E5),
        child: ListTile(
          leading: Icon(Icons.warning_amber, color: a['level'] == 'red' ? const Color(0xFFB71C1C) : const Color(0xFFE65100)),
          title: Text(a['title'] as String, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87)),
          subtitle: Text(a['text'] as String, style: const TextStyle(color: Colors.black87)),
        ),
      );
}
