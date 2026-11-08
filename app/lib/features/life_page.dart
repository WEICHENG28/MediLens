// 生活打卡与珍珠鸟陪伴（原型）：记录用药/打针、吃饭、运动、睡眠、血糖 → 后端分析个人规律、宠物状态与提醒。
// 记录保存在本机（加密数据库）；分析时只发送打卡记录（时间、类型、数值），不含身份信息。

import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../core/api_client.dart';
import '../core/life_tasks.dart';
import '../core/local_reminders.dart';
import '../core/task_receipts.dart';
import '../core/life_journal.dart';
import '../data/local_store.dart';
import '../widgets/glucose_trend.dart';
import 'life_setup_page.dart';
import '../widgets/interactive_bunny.dart';
import '../widgets/voice_note_field.dart';

const _kEvents = 'life_events';
const _kSchedule = 'life_schedule';
const _kNegative = 'life_negative_feedback';
const _kTarget = 'life_glucose_target';
const _kMeals = 'life_meal_times';
const _kLastVisit = 'life_last_visit';
const _kOnboarded = 'life_onboarded';

class LifePage extends ConsumerStatefulWidget {
  const LifePage({super.key});
  @override
  ConsumerState<LifePage> createState() => _LifePageState();
}

class _LifePageState extends ConsumerState<LifePage> {
  List<Map<String, dynamic>> events = [];
  List<Map<String, dynamic>> schedule = [];
  List<LifeTask> tasks = [];
  bool companion = true;
  bool demo = false;
  bool adding = false;
  List<Map<String, dynamic>> projected = [];
  Map<String, dynamic>? result;
  String? error;
  bool busy = false;
  BirdState bird = birdReact(BirdMood.normal, BirdEvent.enterRecent); // 珍珠鸟当前的状态与话语
  bool? onboarded; // 是否已完成首次设置；null 表示还在读取
  List<String> mealTimes = []; // 吃饭目标时间（只用于显示，不发送通知）
  (double, double) target = (3.9, 10.0); // 个人血糖目标，默认 3.9–10.0 mmol/L，可改为医生给的目标

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
    tasks = await loadTasks(store);
    target = parseTarget(await store.getSetting(_kTarget));
    mealTimes = List<String>.from(jsonDecode(await store.getSetting(_kMeals) ?? '[]') as List);
    onboarded = await store.getSetting(_kOnboarded) == 'true' || events.isNotEmpty || schedule.isNotEmpty;
    final now = ref.read(taskClockProvider)();
    final last = DateTime.tryParse(await store.getSetting(_kLastVisit) ?? '');
    bird = birdReact(bird.mood, last != null && now.difference(last) > birdIdle ? BirdEvent.enterAfterIdle : BirdEvent.enterRecent, feedback: companion);
    await store.putSetting(_kLastVisit, now.toIso8601String());
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
      if (projected.isEmpty && tasks.isEmpty) { setState(() { result = null; error = null; }); return; }
      final r = await ref.read(apiClientProvider).lifestyle({
        'events': [for (final e in projected) if (e['type'] != 'note') e].reversed.take(3000).toList().reversed.map((e) => {
          for (final key in ['type', 'time', 'taken', 'insulin_kind', 'meal_size', 'minutes', 'glucose', 'task', 'slot'])
            if (e.containsKey(key)) key: e[key],
        }).toList(),
        'schedule': schedule,
        'tasks': tasks.map((t) => {'id': t.id, 'title': t.title, 'due': t.due, 'done': t.done}).toList(),
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
      final g = e['glucose'];
      bird = birdReact(bird.mood, g is num ? (g >= target.$1 && g <= target.$2 ? BirdEvent.glucoseInRange : BirdEvent.glucoseOutOfRange) : BirdEvent.checkIn, feedback: companion);
      await store.putSetting(_kLastVisit, ref.read(taskClockProvider)().toIso8601String());
      await _analyze();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已记录'), duration: Duration(seconds: 1)));
      // 组员设计：打卡吃饭/吃药/打针后，接着询问这次的血糖（没测可以跳过）
      if ({'meal', 'medication', 'insulin'}.contains(e['type']) && e['taken'] != false) {
        adding = false;
        await _askGlucose(after: e['type'] as String);
      }
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

  static const _checkInName = {'meal': '打卡吃饭', 'medication': '打卡吃药', 'insulin': '打卡打针'};

  /// after：刚完成的打卡类型（吃饭/吃药/打针），血糖会标注「X 后」，并在弹窗上显示打卡时间。
  Future<void> _askGlucose({String? after}) async {
    final afterCheckIn = after != null;
    final c = TextEditingController();
    final at = ref.read(taskClockProvider)();
    final hm = '${at.month}月${at.day}日 ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    final v = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(afterCheckIn ? '这次测了血糖吗？' : '记录血糖'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (afterCheckIn) Container(
            key: const Key('checkin_time'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(color: const Color(0xFFE3F4EA), borderRadius: BorderRadius.circular(8)),
            child: Text('已记录${_checkInName[after]} · $hm'),
          ),
          TextField(key: const Key('glucose_input'), controller: c, keyboardType: const TextInputType.numberWithOptions(decimal: true), autofocus: true,
              decoration: InputDecoration(labelText: '本次血糖', suffixText: 'mmol/L', helperText: '会和你设定的目标 ${target.$1}–${target.$2} 对照')),
        ]),
        actions: [
          TextButton(key: const Key('glucose_skip'), onPressed: () => Navigator.pop(ctx), child: Text(afterCheckIn ? '没测，跳过' : '取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, double.tryParse(c.text.trim())), child: const Text('记录')),
        ],
      ),
    );
    if (v != null && v > 0 && v < 40) await _add({'type': 'glucose', 'glucose': v, 'after': ?after});
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
    if (onboarded == false) {
      return LifeSetupPage(now: ref.read(taskClockProvider)(), target: target, mealTimes: mealTimes,
          medTimes: [for (final s in schedule) if (s['task'] == 'medication') s['time'] as String],
          insulinTimes: [for (final s in schedule) if (s['task'] == 'insulin') s['time'] as String],
          onDone: _finishSetup);
    }
    final r = result;
    final reminders = ref.watch(remindersProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('生活打卡 · 珍珠鸟陪伴'), actions: [
        PopupMenuButton<String>(
          onSelected: (v) => v == 'demo' ? _loadDemo() : v == 'setup' ? setState(() => onboarded = false) : _clear(),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'setup', child: Text('重新设置目标时间与血糖')),
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
        _Greeting(now: ref.read(taskClockProvider)()),
        if (companion) _BirdCard(state: bird, summary: companionSummary(projected, ref.read(taskClockProvider)())),
        if (r != null)
          for (final a in (r['alerts'] as List)) _AlertCard(a as Map<String, dynamic>),
        if (r?['pet']?['safety_note'] != null) _AlertCard({'level': 'yellow', 'title': '已记录的用药疑问', 'text': r!['pet']['safety_note']}),
        const SizedBox(height: 12),
        _GlucoseOverview(events: projected, schedule: schedule, target: target, now: ref.read(taskClockProvider)(),
            onTrend: _openTrend, onEditTarget: _editTarget),
        const SizedBox(height: 16),
        Row(children: [
          Text('今天想记录什么？', style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          Text('点击后自动记录当前时间', style: Theme.of(context).textTheme.bodySmall),
        ]),
        const SizedBox(height: 8),
        GridView.count(
          crossAxisCount: 2, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 2.3,
          children: [
            _tile('吃饭', Icons.restaurant, '打卡吃饭', _nextTime(mealTimes, '记录吃饭时间', '目标'), const Color(0xFFFFE4E1), () => _add({'type': 'meal', 'meal_size': 'normal'})),
            _tile('吃了药', Icons.medication, '打卡吃药', _planText('medication'), const Color(0xFFE3F4EA), () => _add({'type': 'medication', 'taken': true})),
            _tile('打了胰岛素', Icons.vaccines, '打卡打针', _planText('insulin'), const Color(0xFFECE8FB), () => _add({'type': 'insulin', 'insulin_kind': 'rapid', 'taken': true})),
            _tile('日常记录', Icons.edit_note, '日常记录', '运动、睡眠、补记', const Color(0xFFFFF1D6), _openDaily),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(height: 64, child: _tile('血糖变化', Icons.show_chart, '血糖变化', '记血糖、看一天 / 一周 / 一个月的变化', const Color(0xFFE2F0FB), _openTrend)),
        if (r != null) ..._results(context, r),
        if (tasks.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('复查与咨询事项（来自报告解读）', style: Theme.of(context).textTheme.titleMedium),
          for (final t in tasks)
            CheckboxListTile(
              key: Key('task_${t.id}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: t.done,
              title: Text(t.title, style: TextStyle(decoration: t.done ? TextDecoration.lineThrough : null)),
              subtitle: Text(t.due == null ? '下次复诊时，以医生安排为准' : '最早 ${t.due} 起（以医生安排为准）'),
              onChanged: (v) async {
                tasks = [for (final x in tasks) x.id == t.id ? x.copyWith(done: v ?? false) : x];
                await saveTasks(store, tasks);
                await _analyze();
              },
            ),
        ],
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
          title: const Text('珍珠鸟陪伴反馈'),
          subtitle: const Text('只鼓励确认过的记录，不扣健康分，也不把未记录当作漏药。珍珠鸟状态不代表真实病情。'),
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

  Widget _tile(String key, IconData icon, String title, String subtitle, Color tint, VoidCallback onTap) => Material(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: Key('life_$key'),
          borderRadius: BorderRadius.circular(16),
          onTap: busy || demo ? null : onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFF0E6DD))),
            child: Row(children: [
              Container(width: 40, height: 40, decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(12)),
                  child: Icon(icon, size: 22, color: Colors.black54)),
              const SizedBox(width: 10),
              Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(subtitle, style: Theme.of(context).textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
              ])),
            ]),
          ),
        ),
      );

  /// 打卡瓷砖上显示今天下一次按医嘱的时间。
  String _planText(String task) =>
      _nextTime([for (final s in schedule) if (s['task'] == task) s['time'] as String], '记录当前时间', '医嘱时间');

  String _nextTime(List<String> raw, String empty, String prefix) {
    final times = [...raw]..sort();
    if (times.isEmpty) return empty;
    final now = ref.read(taskClockProvider)();
    final hm = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    return '$prefix ${times.firstWhere((t) => t.compareTo(hm) >= 0, orElse: () => times.first)}';
  }

  /// 首次设置完成：保存初始血糖、目标时间与目标血糖范围。
  Future<void> _finishSetup(SetupResult r) async {
    if (r.glucose != null) {
      events = [...events, {'id': const Uuid().v4(), 'time': r.time.toIso8601String().substring(0, 19), 'type': 'glucose', 'glucose': r.glucose, 'after': 'setup'}];
      await store.putSetting(_kEvents, jsonEncode(events));
    }
    for (final (task, times) in [('medication', r.medTimes), ('insulin', r.insulinTimes)]) {
      for (final t in times) {
        if (!schedule.any((s) => s['task'] == task && s['time'] == t)) {
          schedule.add({'id': const Uuid().v4(), 'task': task, 'time': t, 'label': '按医嘱'});
        }
      }
    }
    mealTimes = r.mealTimes;
    target = r.target;
    await store.putSetting(_kMeals, jsonEncode(mealTimes));
    await store.putSetting(_kTarget, '${target.$1}-${target.$2}');
    await store.putSetting(_kOnboarded, 'true');
    await _save();
    final g = r.glucose;
    bird = g == null ? birdReact(bird.mood, BirdEvent.enterRecent)
        : birdReact(bird.mood, g >= target.$1 && g <= target.$2 ? BirdEvent.glucoseInRange : BirdEvent.glucoseOutOfRange, feedback: companion);
    setState(() => onboarded = true);
    await _analyze();
  }

  Future<void> _openDaily() {
    final note = TextEditingController();
    final recent = [for (final e in events.reversed) if (e['type'] == 'note') e].take(3).toList();
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
        child: SafeArea(child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('日常记录', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('可以打字，也可以点麦克风用说的。日记只保存在这台手机上，不会上传。', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 10),
            VoiceNoteField(controller: note),
            Align(alignment: Alignment.centerRight, child: FilledButton.icon(
              key: const Key('note_save'),
              icon: const Icon(Icons.check, size: 18),
              label: const Text('保存日记'),
              onPressed: busy || demo ? null : () {
                final text = note.text.trim();
                if (text.isEmpty) return;
                Navigator.pop(c);
                _add({'type': 'note', 'text': text});
              },
            )),
            if (recent.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('最近的日记', style: Theme.of(context).textTheme.titleSmall),
              for (final e in recent)
                Padding(padding: const EdgeInsets.only(top: 4), child: Text(
                    '${(e['time'] as String).substring(5, 16).replaceFirst('T', ' ')}  ${e['text']}',
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall)),
            ],
            const Divider(height: 24),
            Text('其他记录', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              _chip(Icons.directions_walk, '运动', () { Navigator.pop(c); _askExercise(); }),
              _chip(Icons.bedtime, '睡觉', () { Navigator.pop(c); _add({'type': 'sleep'}); }),
              _chip(Icons.wb_sunny_outlined, '起床', () { Navigator.pop(c); _add({'type': 'wake'}); }),
              _chip(Icons.bloodtype_outlined, '记血糖', () { Navigator.pop(c); _askGlucose(); }),
              _chip(Icons.warning_amber, '忘了吃药', () { Navigator.pop(c); _add({'type': 'medication', 'taken': false}); }),
              _chip(Icons.warning_amber, '忘了打针', () { Navigator.pop(c); _add({'type': 'insulin', 'insulin_kind': 'rapid', 'taken': false}); }),
            ]),
          ]),
        )),
      ),
    );
  }

  Future<void> _openTrend() => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (c) => GlucoseTrendSheet(
          events: projected, target: target, now: ref.read(taskClockProvider)(),
          onAdd: busy || demo ? null : () { Navigator.pop(c); _askGlucose(); },
        ),
      );

  Future<void> _editTarget() async {
    final lo = TextEditingController(text: target.$1.toString()), hi = TextEditingController(text: target.$2.toString());
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('我的血糖目标范围'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('请填写医生给您的个人目标（mmol/L）。只用于把记录标成「范围内 / 高于 / 低于」，珍珠鸟不会因此变化。'),
        Row(children: [
          Expanded(child: TextField(key: const Key('target_low'), controller: lo, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: '下限'))),
          const SizedBox(width: 12),
          Expanded(child: TextField(key: const Key('target_high'), controller: hi, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: '上限'))),
        ]),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('保存'))],
    ));
    if (ok != true) return;
    final l = double.tryParse(lo.text.trim()), h = double.tryParse(hi.text.trim());
    if (l == null || h == null || l < 2 || h > 30 || l >= h) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请检查：下限要小于上限，范围在 2–30 mmol/L 之间')));
      return;
    }
    await store.putSetting(_kTarget, '$l-$h');
    if (mounted) setState(() => target = (l, h));
  }


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
      for (final i in insights.cast<Map<String, dynamic>>()) _InsightCard(i),
      Text('这些是从你的记录看出的规律，不是用药建议；要怎么调整，请问医生。', key: const Key('insight_note'),
          style: Theme.of(context).textTheme.bodySmall),
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

class _Greeting extends StatelessWidget {
  final DateTime now;
  const _Greeting({required this.now});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${now.year} · ${now.month}月${now.day}日 · 生活打卡',
              style: const TextStyle(color: Color(0xFFB07A55), fontWeight: FontWeight.w600, fontSize: 13)),
          const SizedBox(height: 4),
          Text('今天也一起加油！', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          Text('慢慢记录每一步，珍珠鸟会一直陪着你。', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.black54)),
        ]),
      );
}

class _BirdCard extends StatelessWidget {
  final BirdState state;
  final CompanionSummary summary;
  const _BirdCard({required this.state, required this.summary});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: const LinearGradient(colors: [Color(0xFFFFE6D6), Color(0xFFFFF4EA), Color(0xFFEFF3E6)],
              begin: Alignment.topLeft, end: Alignment.bottomRight),
        ),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.75), borderRadius: BorderRadius.circular(20)),
              child: Text(state.label, key: const Key('bird_mood_label'),
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF5E7D4F))),
            ),
            const SizedBox(height: 10),
            Text(state.message, key: const Key('pet_message'),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, height: 1.4, color: Color(0xFF4A3A30))),
            const SizedBox(height: 8),
            Text(summary.records > 0 ? '今天已经记下 ${summary.records} 条记录' : '还没有今天的记录也没关系',
                key: const Key('today_records'), style: const TextStyle(fontSize: 12, color: Colors.black54)),
          ])),
          InteractiveBunny(size: 78, mood: state.mood),
        ]),
      );
}

class _GlucoseOverview extends StatelessWidget {
  final List<Map<String, dynamic>> events;
  final List<Map<String, dynamic>> schedule;
  final (double, double) target;
  final DateTime now;
  final VoidCallback onTrend;
  final VoidCallback onEditTarget;
  const _GlucoseOverview({required this.events, required this.schedule, required this.target, required this.now,
      required this.onTrend, required this.onEditTarget});

  @override
  Widget build(BuildContext context) {
    final day = now.toIso8601String().substring(0, 10);
    final glucose = [for (final e in events) if (e['type'] == 'glucose' && e['glucose'] is num) e];
    final last = glucose.isEmpty ? null : glucose.last;
    final todayRecords = events.where((e) => (e['time'] as String? ?? '').startsWith(day) && e['type'] != 'reminder').length;
    final planned = schedule.length;
    final done = events.where((e) => (e['time'] as String? ?? '').startsWith(day) &&
        {'medication', 'insulin'}.contains(e['type']) && e['taken'] == true).length.clamp(0, planned);
    final small = Theme.of(context).textTheme.bodySmall;
    Widget box(String label, Widget value, String hint, {VoidCallback? onTap}) => Expanded(child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: const Color(0xFFFFF8F2), borderRadius: BorderRadius.circular(14)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: small),
              const SizedBox(height: 4),
              value,
              const SizedBox(height: 2),
              Text(hint, style: small, maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
        ));
    String fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: Color(0xFFF0E6DD))),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.bar_chart, size: 20, color: Color(0xFF8C6A55)),
            const SizedBox(width: 6),
            Text('今日血糖概览', style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            TextButton(key: const Key('open_trend'), onPressed: onTrend, child: const Text('查看变化 ›')),
          ]),
          Row(children: [
            box('最近一次记录',
                Text.rich(TextSpan(children: [
                  TextSpan(text: last == null ? '—' : fmt((last['glucose'] as num).toDouble()),
                      style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
                  const TextSpan(text: ' mmol/L', style: TextStyle(fontSize: 12, color: Colors.black54)),
                ]), key: const Key('last_glucose')),
                last == null ? '还没有血糖记录' : '${(last['time'] as String).substring(11, 16)} · ${rangeLabel((last['glucose'] as num).toDouble(), target).replaceAll('目标', '').replaceAll('在', '')}'),
            const SizedBox(width: 10),
            box('我的目标范围',
                Text('${fmt(target.$1)}–${fmt(target.$2)}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                'mmol/L · 点这里修改', onTap: onEditTarget),
          ]),
          const SizedBox(height: 12),
          if (planned > 0) ...[
            ClipRRect(borderRadius: BorderRadius.circular(6), child: LinearProgressIndicator(
              value: done / planned, minHeight: 6, backgroundColor: const Color(0xFFF3ECE6), color: const Color(0xFF9DB98A))),
            const SizedBox(height: 6),
            Text('今天已完成 $done/$planned 项用药打卡 · 共 $todayRecords 条记录', style: small),
          ] else
            Text('今天共 $todayRecords 条记录。在下方添加医嘱的用药时间后，可以看到完成进度。', style: small),
        ]),
      ),
    );
  }
}

/// 我的规律：第一层只说一句白话（不放数字），点「看详细」才显示次数、中位数和复诊可以问的问题。
class _InsightCard extends StatelessWidget {
  final Map<String, dynamic> i;
  const _InsightCard(this.i);
  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    final sure = i['confidence'] == '较明确';
    final headline = (i['headline'] as String?)?.isNotEmpty == true ? i['headline'] as String : i['finding'] as String;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: Key('insight_${i['id']}'),
          tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          title: Text(headline, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, height: 1.35)),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: sure ? const Color(0xFFE3F4EA) : const Color(0xFFFFF1D6), borderRadius: BorderRadius.circular(10)),
                child: Text(sure ? '比较明显' : '还要多观察', style: small),
              ),
              const SizedBox(width: 8),
              Text(i['title'] as String, style: small),
            ]),
          ),
          trailing: Text('看详细', style: small?.copyWith(color: Theme.of(context).colorScheme.primary)),
          children: [
            Text(i['finding'] as String),
            for (final g in (i['groups'] as List).cast<Map<String, dynamic>>())
              Text('· ${g['label']}：${g['n']} 次，中位数 ${g['median']} mmol/L', style: small),
            const SizedBox(height: 6),
            Text('复诊可以问：${i['doctor_question']}', style: small),
          ],
        ),
      ),
    );
  }
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
