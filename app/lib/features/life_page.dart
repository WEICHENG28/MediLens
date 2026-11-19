// 生活打卡与珍珠鸟陪伴（原型）：记录用药/打针、吃饭、运动、睡眠、血糖 → 后端分析个人规律、宠物状态与提醒。
// 记录保存在本机（加密数据库）；分析时只发送打卡记录（时间、类型、数值），不含身份信息。

import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../core/api_client.dart';
import '../core/care_events.dart';
import '../core/care_reminders.dart';
import 'care_pages.dart';
import 'care_sections.dart';
import '../core/life_tasks.dart';
import '../core/meal_nutrition.dart';
import '../core/local_reminders.dart';
import '../core/task_receipts.dart';
import '../core/life_journal.dart';
import '../data/local_store.dart';
import '../widgets/glucose_trend.dart';
import 'life_setup_page.dart';
import 'meal_photo_page.dart';
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
  int analysisGeneration = 0;
  BirdState bird = birdReact(BirdMood.normal, BirdEvent.enterRecent); // 珍珠鸟当前的状态与话语
  bool? onboarded; // 是否已完成首次设置；null 表示还在读取
  List<String> mealTimes = []; // 吃饭目标时间（只用于显示，不发送通知）
  (double, double) target = (3.9, 10.0); // 个人血糖目标，默认 3.9–10.0 mmol/L，可改为医生给的目标
  Map<String, dynamic>? careReply; // 最近一笔记录的即时回馈（照护核心）
  Map<String, dynamic>? careProfile, careDaily, careGoal; // 照护档案、今日小结、小目标（旧版服务器没有时为 null）
  Map<String, dynamic>? goalState; // 进行中的小目标 {id, started}
  // 示范模式（陈女士虚构病例，合成资料）：完整 14 天的记录依日期逐日放入
  List<Map<String, dynamic>> demoQueue = [];
  DateTime? demoDay; // 已放到哪一天
  bool demoCgm = true;
  DateTime? scenarioDay; // 情境按钮发生的那一天（连按几个情境都在同一天）

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
    await ref.read(careRemindersProvider.notifier).load();
    goalState = _decodeMap(await store.getSetting('care_goal'));
    final dq = await store.getSetting('care_demo_queue');
    demoQueue = dq == null ? [] : List<Map<String, dynamic>>.from(jsonDecode(dq) as List);
    demoDay = DateTime.tryParse(await store.getSetting('care_demo_day') ?? '');
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

  String _now() => ref.read(taskClockProvider)().toIso8601String();
  String _today() => taskDay(ref.read(taskClockProvider)());

  Future<void> _analyze({bool background = false}) async {
    final generation = ++analysisGeneration;
    setState(() => busy = !background);
    try {
      final receipts = ref.read(taskReceiptsProvider.notifier);
      await receipts.load();
      if (!mounted || generation != analysisGeneration) return;
      setState(() {
        projected = effectiveLifeEvents(events, demo ? {} : ref.read(taskReceiptsProvider), demo ? {} : receipts.manualLinks);
      });
      unawaited(updateLocalCompanion(store, ref.read(taskClockProvider)()).catchError((Object _) {}));
      if (!mounted) return;
      if (projected.isEmpty && tasks.isEmpty) { setState(() { result = null; error = null; careProfile = careDaily = careGoal = null; }); return; }
      unawaited(_loadCare(generation)); // 照护核心与原有分析各自进行，任一边失败不影响另一边
      final r = await ref.read(apiClientProvider).lifestyle({
        'events': careEventsJson(projected).reversed.take(3000).toList().reversed.toList(),
        'schedule': schedule,
        'tasks': tasks.map((t) => {'id': t.id, 'title': t.title, 'due': t.due, 'done': t.done}).toList(),
        'today': _today(),
        'negative_feedback': false,
      });
      if (!mounted || generation != analysisGeneration) return;
      setState(() {
        result = r;
        error = null;
      });
    } catch (e) {
      if (!mounted || generation != analysisGeneration) return;
      setState(() => error = e.toString());
    } finally {
      if (mounted && generation == analysisGeneration) setState(() => busy = false);
    }
  }

  static Map<String, dynamic>? _decodeMap(String? raw) {
    try { final v = raw == null ? null : jsonDecode(raw); return v is Map<String, dynamic> ? v : null; } catch (_) { return null; }
  }

  /// 照护核心请求的共同内容：记录（只含时间、类型与数值）、用药时间、目标范围。
  Map<String, dynamic> careBody() => {
        'events': careEventsJson(projected).reversed.take(6000).toList().reversed.toList(),
        'schedule': schedule,
        'target_low': target.$1,
        'target_high': target.$2,
      };

  /// 今天（示范模式时是示范进行到的那一天）。
  DateTime get viewDay {
    final homeTimes = [for (final e in projected) if (e['type'] != 'lab') e['time'] as String]..sort();
    final d = demo && homeTimes.isNotEmpty ? DateTime.parse(homeTimes.last) : demo && demoDay != null ? demoDay! : ref.read(taskClockProvider)();
    return DateTime(d.year, d.month, d.day);
  }

  String _ymd(DateTime d) => d.toIso8601String().substring(0, 10);

  /// 照护档案、今日小结、小目标：三个请求同时进行；服务器较旧或连不上时保留原来的显示。
  Future<void> _loadCare(int generation) async {
    if (projected.isEmpty) { if (mounted) setState(() { careProfile = null; careDaily = null; careGoal = null; }); return; }
    final api = ref.read(apiClientProvider);
    final body = careBody();
    Future<Map<String, dynamic>?> safe(Future<Map<String, dynamic>> f) => f.then<Map<String, dynamic>?>((v) => v).catchError((Object _) => null);
    final res = await Future.wait([
      safe(api.careProfile(body)),
      safe(api.careDaily({...body, 'day': _ymd(viewDay)})),
      safe(api.careGoal({...body, if (goalState != null) 'goal_id': goalState!['id'], if (goalState != null) 'started': goalState!['started']})),
    ]);
    if (!mounted || generation != analysisGeneration) return;
    setState(() { careProfile = res[0]; careDaily = res[1]; careGoal = res[2]; });
  }

  Future<void> _startGoal(String id) async {
    goalState = {'id': id, 'started': _ymd(viewDay)};
    await store.putSetting('care_goal', jsonEncode(goalState));
    await _analyze(background: true);
  }

  Future<void> _stopGoal() async {
    goalState = null;
    await store.putSetting('care_goal', 'null');
    await _analyze(background: true);
  }

  void _openPage(Widget page) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));

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
      final record = {'id': const Uuid().v4(), 'time': _now(), 'recorded_at': _now(), 'schema_version': 2, 'timezone_name': DateTime.now().timeZoneName, 'source': 'manual', 'is_simulated': false, if (e['type'] == 'glucose') 'unit': 'mmol/L', ...e};
      final history = projected;
      final next = [...events, record];
      await store.putSetting(_kEvents, jsonEncode(next));
      events = next;
      unawaited(_careFeedback(history, [record]));
      final g = e['glucose'];
      bird = birdReact(bird.mood, g is num ? (g >= target.$1 && g <= target.$2 ? BirdEvent.glucoseInRange : BirdEvent.glucoseOutOfRange) : BirdEvent.checkIn, feedback: companion);
      await store.putSetting(_kLastVisit, ref.read(taskClockProvider)().toIso8601String());
      if (!mounted) return;
      unawaited(_analyze(background: true));
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
    await ref.read(careRemindersProvider.notifier).clear();
    events = [];
    careReply = null;
    careProfile = careDaily = careGoal = null;
    demoQueue = [];
    demoDay = null;
    scenarioDay = null;
    await store.putSetting('care_demo_queue', '[]');
    await store.putSetting('care_demo_day', '');
    demo = false;
    await _save();
    await _analyze();
  }

  Future<void> _openMealPhoto() async {
    final meal = await Navigator.of(context).push<MealRecord>(
      MaterialPageRoute(builder: (_) => MealPhotoPage(now: ref.read(taskClockProvider)())),
    );
    if (meal != null && mounted) await _add(meal.toEvent());
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
    var source = 'finger';
    var confirm = false;
    final v = await showDialog<double>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
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
          const SizedBox(height: 10),
          Wrap(spacing: 8, children: [
            ChoiceChip(key: const Key('glucose_src_finger'), label: const Text('指血'), selected: source == 'finger',
                onSelected: (_) => setD(() => source = 'finger')),
            ChoiceChip(key: const Key('glucose_src_cgm'), label: const Text('监测仪'), selected: source == 'cgm',
                onSelected: (_) => setD(() => source = 'cgm')),
          ]),
          CheckboxListTile(key: const Key('glucose_confirm'), dense: true, contentPadding: EdgeInsets.zero, value: confirm,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('这是复核测量'), subtitle: const Text('监测仪读数偏低或和身体感觉不一致时，用指血再测一次'),
              onChanged: (x) => setD(() { confirm = x ?? false; if (confirm) source = 'finger'; })),
        ]),
        actions: [
          TextButton(key: const Key('glucose_skip'), onPressed: () => Navigator.pop(ctx), child: Text(afterCheckIn ? '没测，跳过' : '取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, double.tryParse(c.text.trim())), child: const Text('记录')),
        ],
      )),
    );
    if (v != null && v > 0 && v < 40) {
      await _add({'type': 'glucose', 'glucose': v, 'glucose_source': source, if (confirm) 'confirmatory': true, 'after': ?after});
    }
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
          onSelected: (v) => v == 'demo' ? _startCareDemo() : v == 'old_demo' ? _loadDemo() : v == 'setup' ? setState(() => onboarded = false) : _clear(),
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'setup', child: Text('重新设置目标时间与血糖')),
            const PopupMenuItem(value: 'demo', child: Text('示范模式：陈女士（虚构病例）')),
            PopupMenuItem(value: 'clear', child: Text(demo ? '结束示范并清空' : '清空生活与任务记录')),
          ],
        ),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (busy) const LinearProgressIndicator(),
        if (error != null) Card(child: Padding(padding: const EdgeInsets.all(12), child: Text(error!))),
        if (reminders.error != null) Card(child: Padding(padding: const EdgeInsets.all(12), child: Text(reminders.error!))),
        if (demo) _demoBar(context),
        _Greeting(now: ref.read(taskClockProvider)()),
        if (companion) _BirdCard(state: bird, summary: companionSummary(projected, ref.read(taskClockProvider)())),
        if (r != null)
          for (final a in (r['alerts'] as List)) _AlertCard(a as Map<String, dynamic>),
        if (r?['pet']?['safety_note'] != null) _AlertCard({'level': 'yellow', 'title': '已记录的用药疑问', 'text': r!['pet']['safety_note']}),
        if (careReply != null) _CareReplyCard(reply: careReply!, onClose: () => setState(() => careReply = null)),
        _CareReminderList(reminders: ref.watch(careRemindersProvider), now: ref.read(taskClockProvider)(),
            onDone: (id) => ref.read(careRemindersProvider.notifier).markDone(id)),
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
            _tile('吃饭', Icons.restaurant, '打卡吃饭', _nextTime(mealTimes, '记录吃饭时间', '目标'), const Color(0xFFFFE4E1), () => _add({'type': 'meal', 'meal_size': 'normal', 'meal_slot': mealSlotFor(ref.read(taskClockProvider)())})),
            _tile('吃了药', Icons.medication, '打卡吃药', _planText('medication'), const Color(0xFFE3F4EA), () => _add({'type': 'medication', 'taken': true})),
            _tile('打了胰岛素', Icons.vaccines, '打卡打针', _planText('insulin'), const Color(0xFFECE8FB), () => _add({'type': 'insulin', 'insulin_kind': 'rapid', 'taken': true})),
            _tile('日常记录', Icons.edit_note, '日常记录', '运动、睡眠、补记', const Color(0xFFFFF1D6), _openDaily),
          ],
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          key: const Key('life_meal_photo'),
          onPressed: busy || demo ? null : _openMealPhoto,
          icon: const Icon(Icons.add_a_photo_outlined),
          label: const Text('拍餐饮 · 估算糖与碳水'),
        ),
        const SizedBox(height: 10),
        SizedBox(height: 64, child: _tile('血糖变化', Icons.show_chart, '血糖变化', '记血糖、看一天 / 一周 / 一个月的变化', const Color(0xFFE2F0FB), _openTrend)),
        ..._todayMeals(context),
        if (careProfile != null)
          CareSections(
            profile: careProfile!, daily: careDaily, goal: careGoal, events: projected, day: viewDay, target: target,
            onStartGoal: demo && demoQueue.isEmpty ? null : _startGoal, onStopGoal: _stopGoal,
            onWeekly: () => _openPage(WeeklyPage(body: careBody())),
            onVisit: () => _openPage(VisitSummaryPage(body: careBody())),
            onChat: () => _openPage(CareChatPage(body: careBody())),
          )
        else if (r != null) ..._results(context, r),
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

  Widget _demoBar(BuildContext context) {
    final last = _demoLastDay;
    final first = demoQueue.isEmpty ? null : DateTime.parse(demoQueue.first['time'] as String);
    final dayNo = first == null || demoDay == null ? null : demoDay!.difference(DateTime(first.year, first.month, first.day)).inDays + 1;
    final canNext = demoDay != null && last != null && !demoDay!.add(const Duration(days: 1)).isAfter(last);
    return Card(
      key: const Key('demo_bar'),
      color: const Color(0xFFFFF4E5),
      child: Padding(padding: const EdgeInsets.all(10), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(demoQueue.isEmpty ? '合成演示数据：请先清空演示，再记录自己的生活。'
            : '示范模式 · 陈女士（虚构病例，合成资料）${dayNo == null ? '' : ' · 已到第 ${dayNo.clamp(0, 14)}/14 天'}',
            style: const TextStyle(color: Colors.deepOrange, fontWeight: FontWeight.w600)),
        if (demoQueue.isNotEmpty) ...[
          const SizedBox(height: 6),
          Row(children: [
            FilledButton.icon(key: const Key('demo_next'), onPressed: busy || !canNext ? null : _demoNextDay,
                icon: const Icon(Icons.skip_next), label: Text(canNext ? '下一天' : '14 天已播完')),
          ]),
          const SizedBox(height: 6),
          const Text('情境（模拟刚刚发生的一件事）：', style: TextStyle(fontSize: 12)),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final e in scenarioName.entries)
              ActionChip(key: Key('scenario_${e.key}'), label: Text(e.value, style: const TextStyle(fontSize: 12)),
                  onPressed: busy ? null : () => _demoScenario(e.key)),
          ]),
        ],
      ])),
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


  /// 即时回馈：把刚记下的记录连同之前的记录送去照护核心；连不上服务器时安静略过，不影响记录本身。
  Future<void> _careFeedback(List<Map<String, dynamic>> history, List<Map<String, dynamic>> added, {bool important = false}) async {
    final body = careEventsJson(added);
    if (body.isEmpty) return;
    try {
      final r = await ref.read(apiClientProvider).careRecord({
        'events': careEventsJson(history).reversed.take(6000).toList().reversed.toList(),
        'new': body,
        'schedule': schedule,
        'target_low': target.$1,
        'target_high': target.$2,
      });
      if (!mounted) return;
      final reminders = (r['reminders'] as List?) ?? const [];
      if (reminders.isNotEmpty && !demo) await ref.read(careRemindersProvider.notifier).addFromServer(reminders);
      if (important) { // 逐日播放：一天有几十笔，只留需要注意的回应
        final fb = ((r['feedback'] as List?) ?? const []).cast<Map<String, dynamic>>();
        r['feedback'] = [for (final f in fb) if (f['tone'] == 'alert' || f['tone'] == 'caution' || '${f['title']}'.startsWith('已同步')) f].take(4).toList();
      }
      if (mounted) setState(() => careReply = r);
    } catch (_) {/* 离线或旧版服务器：只保存记录 */}
  }

  // ---------- 示范模式（陈女士虚构病例，合成资料） ----------

  Future<void> _startCareDemo() async {
    final choice = await showDialog<(String, bool)>(context: context, builder: (c) {
      var cgm = true;
      return StatefulBuilder(builder: (c, setD) => AlertDialog(
        title: const Text('示范模式：陈女士（虚构病例）'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('依老师建议文件的数值生成的 14 天合成资料。会暂时替换生活记录与用药时间，并关闭本机提醒；结束示范后清空。',
              style: TextStyle(fontSize: 13)),
          SwitchListTile(contentPadding: EdgeInsets.zero, value: cgm, onChanged: (v) => setD(() => cgm = v),
              title: const Text('戴连续血糖监测仪'), subtitle: Text(cgm ? '每 15 分钟一笔' : '只有指血，每天约 5 笔')),
          for (final (k, t, d) in const [('new', '从空白开始，逐日播放', '按「下一天」看资料慢慢累积、结论慢慢出现'),
            ('day3', '已记录 3 天', '资料还少，多数规律在「观察中」'), ('chen14', '完整 14 天', '照护档案已完整，可直接看结论与复诊摘要')])
            ListTile(key: Key('demo_$k'), contentPadding: EdgeInsets.zero, title: Text(t), subtitle: Text(d),
                trailing: const Icon(Icons.chevron_right), onTap: () => Navigator.pop(c, (k, cgm))),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消'))],
      ));
    });
    if (choice == null || !mounted) return;
    setState(() => busy = true);
    try {
      if (ref.read(remindersProvider).available && !await ref.read(remindersProvider.notifier).setEnabled(false)) {
        if (mounted) setState(() => error = '请先在本机提醒中关闭通知，再开始示范。');
        return;
      }
      final now = ref.read(taskClockProvider)();
      final yesterday = DateTime(now.year, now.month, now.day).subtract(const Duration(days: 1));
      final d = await ref.read(apiClientProvider).careDemo('chen14', _ymd(yesterday), cgm: choice.$2);
      final all = [for (final (i, e) in (d['events'] as List).cast<Map<String, dynamic>>().indexed) {'id': 'demo-$i', ...e}];
      final first = yesterday.subtract(const Duration(days: 13));
      final shown = choice.$1 == 'new' ? 0 : choice.$1 == 'day3' ? 3 : 14;
      final cut = first.add(Duration(days: shown));
      demo = true;
      demoCgm = choice.$2;
      scenarioDay = null;
      demoQueue = all;
      demoDay = first.add(Duration(days: shown - 1));
      events = [for (final e in all) if (DateTime.parse(e['time'] as String).isBefore(cut)) e];
      schedule = List<Map<String, dynamic>>.from(d['schedule'] as List);
      careReply = null;
      await store.putSetting('care_demo_queue', jsonEncode(demoQueue));
      await store.putSetting('care_demo_day', demoDay!.toIso8601String());
      await _save();
      await _analyze();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  DateTime? get _demoLastDay => demoQueue.isEmpty ? null : DateTime.parse(demoQueue.last['time'] as String);

  Future<void> _demoNextDay() async {
    final last = _demoLastDay;
    if (demoDay == null || last == null) return;
    final next = demoDay!.add(const Duration(days: 1));
    if (next.isAfter(last)) return;
    final from = DateTime(next.year, next.month, next.day), to = from.add(const Duration(days: 1));
    final added = [for (final e in demoQueue) if (DateTime.parse(e['time'] as String) case final t when !t.isBefore(from) && t.isBefore(to)) e];
    final history = projected;
    demoDay = from;
    scenarioDay = null;
    events = [...events, ...added];
    await store.putSetting('care_demo_day', demoDay!.toIso8601String());
    await store.putSetting(_kEvents, jsonEncode(events));
    await _analyze();
    await _careFeedback(history, added, important: true);
  }

  static const _scenarioTime = {'normal_dinner': (18, 0), 'late_high_carb_dinner': (19, 15), 'post_meal_high': (21, 15),
    'night_low': (23, 40), 'missed_med': (18, 0), 'post_meal_walk': (18, 40), 'new_lab': (9, 0)};
  static const scenarioName = {'normal_dinner': '一般晚餐', 'late_high_carb_dinner': '晚吃＋高碳水晚餐', 'post_meal_high': '餐后血糖偏高',
    'night_low': '半夜低血糖', 'missed_med': '漏吃药', 'post_meal_walk': '饭后散步', 'new_lab': '新的医院检验'};

  /// 情境按钮：在示范的「下一天」模拟刚刚发生的一件事。
  Future<void> _demoScenario(String name) async {
    final base = scenarioDay ??= viewDay.add(const Duration(days: 1)); // 情境发生在目前最后一天的隔天，之后的情境同一天
    final (h, m) = _scenarioTime[name]!;
    final at = DateTime(base.year, base.month, base.day, h, m);
    try {
      final r = await ref.read(apiClientProvider).careScenario(name, at.toIso8601String().substring(0, 19), cgm: demoCgm);
      final added = [for (final (i, e) in (r['events'] as List).cast<Map<String, dynamic>>().indexed)
        {'id': 'demo-s-${at.millisecondsSinceEpoch}-$i', ...e}];
      final history = projected;
      events = [...events, ...added];
      await store.putSetting(_kEvents, jsonEncode(events));
      await _analyze(background: true);
      await _careFeedback(history, added);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> _askSymptoms() async {
    const options = ['出汗', '心悸', '手抖', '头晕', '饥饿', '乏力', '恶心', '口渴'];
    final chosen = <String>{};
    final ok = await showDialog<bool>(context: context, builder: (c) => StatefulBuilder(builder: (c, setD) => AlertDialog(
      title: const Text('哪里不舒服？'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final o in options)
            FilterChip(key: Key('symptom_$o'), label: Text(o), selected: chosen.contains(o),
                onSelected: (v) => setD(() => v ? chosen.add(o) : chosen.remove(o))),
        ]),
        const SizedBox(height: 8),
        const Text('如果意识不清、胸痛或呼吸困难，请立即就医或拨打 120。', style: TextStyle(fontSize: 12, color: Colors.black54)),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
        FilledButton(onPressed: chosen.isEmpty ? null : () => Navigator.pop(c, true), child: const Text('记录'))],
    )));
    if (ok == true) await _add({'type': 'symptom', 'symptoms': chosen.toList()});
  }

  Future<void> _askBp() async {
    final s = TextEditingController(), d = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('记录血压'),
      content: Row(children: [
        Expanded(child: TextField(key: const Key('bp_sys'), controller: s, keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '高压（收缩压）'))),
        const SizedBox(width: 12),
        Expanded(child: TextField(key: const Key('bp_dia'), controller: d, keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '低压（舒张压）'))),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('记录'))],
    ));
    final sv = int.tryParse(s.text.trim()), dv = int.tryParse(d.text.trim());
    if (ok != true) return;
    if (sv == null || dv == null || sv <= dv || sv > 260 || dv < 30) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请检查血压数值：高压要大于低压')));
      return;
    }
    await _add({'type': 'bp', 'systolic': sv, 'diastolic': dv});
  }

  Future<void> _askNumber(String label, String unit, double min, double max, Map<String, dynamic> Function(double) build,
      {bool decimal = true}) async {
    final c = TextEditingController();
    final v = await showDialog<double>(context: context, builder: (ctx) => AlertDialog(
      title: Text('记录$label'),
      content: TextField(key: Key('num_$label'), controller: c, autofocus: true,
          keyboardType: TextInputType.numberWithOptions(decimal: decimal),
          decoration: InputDecoration(labelText: label, suffixText: unit)),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(ctx, double.tryParse(c.text.trim())), child: const Text('记录'))],
    ));
    if (v == null) return;
    if (v < min || v > max) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label请填 ${min.toStringAsFixed(0)}–${max.toStringAsFixed(0)} 之间')));
      return;
    }
    await _add(build(v));
  }

  /// 医院检验：手动输入最近一次的糖化血红蛋白、空腹血糖与诊间血压（之后再加拍照识别）。
  Future<void> _askLab() async {
    final a1c = TextEditingController(), fpg = TextEditingController(), sbp = TextEditingController(), dbp = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('医院检验结果'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('填最近一次的结果，没有的可以空着。', style: TextStyle(fontSize: 12, color: Colors.black54)),
        TextField(key: const Key('lab_hba1c'), controller: a1c, keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: '糖化血红蛋白 HbA1c', suffixText: '%')),
        TextField(key: const Key('lab_fpg'), controller: fpg, keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: '空腹血糖（静脉）', suffixText: 'mmol/L')),
        Row(children: [
          Expanded(child: TextField(controller: sbp, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '诊间高压'))),
          const SizedBox(width: 12),
          Expanded(child: TextField(controller: dbp, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '诊间低压'))),
        ]),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('保存'))],
    ));
    if (ok != true) return;
    double? n(TextEditingController t) => double.tryParse(t.text.trim());
    final lab = <String, double>{
      if (n(a1c) case final v? when v >= 3 && v <= 20) 'hba1c': v,
      if (n(fpg) case final v? when v > 1 && v < 40) 'fpg': v,
      if (n(sbp) case final v? when v >= 60 && v <= 260) 'clinic_sbp': v,
      if (n(dbp) case final v? when v >= 30 && v <= 160) 'clinic_dbp': v,
    };
    if (lab.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('没有可保存的数值，请检查后再填')));
      return;
    }
    await _add({'type': 'lab', 'lab': lab});
  }

  /// 说一句话记录：语音转文字（或手打）→ 本机解析 → 请用户确认后才保存。
  Future<void> _voiceRecord() async {
    final text = TextEditingController();
    final said = await showModalBottomSheet<String>(context: context, isScrollControlled: true, showDragHandle: true,
      builder: (c) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
        child: SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), child: Column(
          mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('说一句话记录', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text('例如：「我刚吃了一碗米饭和红烧肉」「饭后散步了 20 分钟」「血糖 7.8」「血压 135/80」。'
                '说完会先请你确认。', style: TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 8),
            VoiceNoteField(controller: text),
            Align(alignment: Alignment.centerRight, child: FilledButton(key: const Key('voice_record_parse'),
                onPressed: () => Navigator.pop(c, text.text.trim()), child: const Text('下一步'))),
          ]))),
      ));
    if (said == null || said.isEmpty || !mounted) return;
    final parsed = parseVoiceRecord(said, ref.read(taskClockProvider)());
    if (parsed.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('没有听懂要记录什么，可以换个说法，或用下面的按钮记录。')));
      return;
    }
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('要记录这些吗？'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final p in parsed) Text('· ${p.summary}', key: Key('voice_item_${p.event['type']}')),
        if (parsed.any((p) => p.event['type'] == 'meal'))
          const Padding(padding: EdgeInsets.only(top: 8), child: Text('说的餐点不会估算碳水；想估算可以改用「拍餐饮」。',
              style: TextStyle(fontSize: 12, color: Colors.black54))),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('不对，取消')),
        FilledButton(key: const Key('voice_record_ok'), onPressed: () => Navigator.pop(c, true), child: const Text('确认记录'))],
    ));
    if (ok != true || !mounted) return;
    final now = _now();
    final history = projected;
    final added = [for (final p in parsed) {'id': const Uuid().v4(), ...p.event, 'time': now}];
    events = [...events, ...added];
    await store.putSetting(_kEvents, jsonEncode(events));
    unawaited(_analyze(background: true));
    unawaited(_careFeedback(history, added));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已记录 ${added.length} 项'), duration: const Duration(seconds: 1)));
  }

  /// 今天的饮食：可以修正份量（家人复秤），原始估算会保留。
  List<Widget> _todayMeals(BuildContext context) {
    final day = _today();
    final meals = [for (final e in events) if (e['type'] == 'meal' && (e['time'] as String? ?? '').startsWith(day)) e];
    if (meals.isEmpty) return const [];
    final small = Theme.of(context).textTheme.bodySmall;
    return [
      const SizedBox(height: 12),
      Text('今天的饮食', style: Theme.of(context).textTheme.titleMedium),
      for (final m in meals)
        ListTile(
          key: Key('meal_row_${m['id']}'),
          dense: true, contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.restaurant),
          title: Text('${(m['time'] as String).substring(11, 16)} ${mealSlotZh[m['meal_slot'] ?? mealSlotFor(DateTime.parse(m['time'] as String))]}'
              '${(m['food'] ?? m['meal_food']) != null ? ' · ${m['food'] ?? m['meal_food']}' : ''}'),
          subtitle: Text([
            if ((m['carbs_g'] ?? m['meal_carbs_g']) is num) '碳水约 ${((m['carbs_g'] ?? m['meal_carbs_g']) as num).toStringAsFixed(0)} g',
            if (m['corrected_by'] != null) '已由${m['corrected_by']}修正（原 ${(m['original_grams'] as num?)?.toStringAsFixed(0) ?? '—'} g）',
            if (m['sweet_drink'] == true) '有甜饮料',
          ].join(' · '), style: small),
          trailing: (m['grams'] ?? m['meal_grams']) is num && !demo
              ? TextButton(key: Key('meal_fix_${m['id']}'), onPressed: () => _fixPortion(m), child: const Text('修正份量'))
              : null,
        ),
    ];
  }

  Future<void> _fixPortion(Map<String, dynamic> meal) async {
    final normalized = {...meal, 'grams': meal['grams'] ?? meal['meal_grams'], 'carbs_g': meal['carbs_g'] ?? meal['meal_carbs_g'],
      'sugars_g': meal['sugars_g'] ?? meal['meal_sugars_g'], 'food': meal['food'] ?? meal['meal_food']};
    final c = TextEditingController(text: (normalized['grams'] as num).toStringAsFixed(0));
    var by = '家属';
    final grams = await showDialog<double>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
      title: const Text('修正份量'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('原估算 ${(normalized['original_grams'] ?? normalized['grams'] as num).toString()} g（主食）。修正后碳水按比例换算，原始估算会保留。',
            style: const TextStyle(fontSize: 13)),
        TextField(key: const Key('fix_grams'), controller: c, keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: '实际克数', suffixText: 'g')),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          for (final who in const ['家属', '本人'])
            ChoiceChip(label: Text('$who复秤'), selected: by == who, onSelected: (_) => setD(() => by = who)),
        ]),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(ctx, double.tryParse(c.text.trim())), child: const Text('保存修正'))],
    )));
    if (grams == null || grams <= 0 || grams > 5000 || !mounted) return;
    final fixed = correctPortion(normalized, grams, by, ref.read(taskClockProvider)());
    final history = [for (final e in projected) if (e['id'] != meal['id']) e];
    events = [for (final e in events) e['id'] == meal['id'] ? fixed : e];
    await store.putSetting(_kEvents, jsonEncode(events));
    setState(() {});
    unawaited(_analyze(background: true));
    unawaited(_careFeedback(history, [fixed]));
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
              _chip(Icons.sick_outlined, '身体不舒服', () { Navigator.pop(c); _askSymptoms(); }),
              _chip(Icons.favorite_border, '血压', () { Navigator.pop(c); _askBp(); }),
              _chip(Icons.monitor_weight_outlined, '体重', () { Navigator.pop(c); _askNumber('体重', 'kg', 20, 300, (v) => {'type': 'weight', 'weight_kg': v}); }),
              _chip(Icons.directions_run, '今天步数', () { Navigator.pop(c); _askNumber('今天步数', '步', 0, 100000, (v) => {'type': 'steps', 'steps': v.round()}, decimal: false); }),
              _chip(Icons.local_hospital_outlined, '医院检验', () { Navigator.pop(c); _askLab(); }),
              _chip(Icons.record_voice_over_outlined, '说一句话记录', () { Navigator.pop(c); _voiceRecord(); }),
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
                  TextSpan(text: last == null ? '—' : fmt(double.parse(glucoseMmol(last)!.toStringAsFixed(1))),
                      style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
                  const TextSpan(text: ' mmol/L', style: TextStyle(fontSize: 12, color: Colors.black54)),
                ]), key: const Key('last_glucose')),
                last == null ? '还没有血糖记录' : '${(last['time'] as String).substring(11, 16)} · ${rangeLabel(glucoseMmol(last)!, target).replaceAll('目标', '').replaceAll('在', '')}'),
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
    final headline = (i['headline'] as String?)?.isNotEmpty == true ? i['headline'] as String : i['title'] as String; // 旧版服务器没有白话句时，先显示简短标题
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


/// 即时回馈卡：这笔记录在整体状况里的意义、依据，以及照护档案的变化。
class _CareReplyCard extends StatelessWidget {
  final Map<String, dynamic> reply;
  final VoidCallback onClose;
  const _CareReplyCard({required this.reply, required this.onClose});
  static const _bg = {'alert': Color(0xFFFDECEA), 'caution': Color(0xFFFFF4E5), 'good': Color(0xFFE8F5E9), 'info': Color(0xFFEFF4FB)};
  static const _fg = {'alert': Color(0xFFB71C1C), 'caution': Color(0xFFE65100), 'good': Color(0xFF2E7D32), 'info': Color(0xFF1F5F99)};
  @override
  Widget build(BuildContext context) {
    final fb = ((reply['feedback'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final changes = ((reply['changes'] as List?) ?? const []).cast<Map<String, dynamic>>();
    if (fb.isEmpty && changes.isEmpty) return const SizedBox.shrink();
    final small = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(key: const Key('care_reply'), crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('刚才的记录', style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          IconButton(icon: const Icon(Icons.close, size: 18), tooltip: '收起', onPressed: onClose),
        ]),
        for (final f in fb)
          Card(
            color: _bg[f['tone']] ?? _bg['info'],
            margin: const EdgeInsets.only(bottom: 8),
            child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${f['title']}', style: TextStyle(fontWeight: FontWeight.bold, color: _fg[f['tone']] ?? Colors.black87)),
              const SizedBox(height: 4),
              Text('${f['text']}', style: const TextStyle(height: 1.45, color: Colors.black87)),
              if ((f['based_on'] as List?)?.isNotEmpty == true) ...[
                const SizedBox(height: 4),
                Text('依据：${(f['based_on'] as List).join('、')}', style: small),
              ],
            ])),
          ),
        for (final c in changes)
          Padding(padding: const EdgeInsets.only(bottom: 6), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.auto_awesome, size: 16, color: Color(0xFF8C6A55)),
            const SizedBox(width: 6),
            Expanded(child: Text('${c['text']}', key: const Key('care_change'), style: const TextStyle(fontSize: 13))),
          ])),
      ]),
    );
  }
}

/// 接下来的照护提醒（由即时回馈产生）。
class _CareReminderList extends StatelessWidget {
  final List<CareReminder> reminders;
  final DateTime now;
  final void Function(String id) onDone;
  const _CareReminderList({required this.reminders, required this.now, required this.onDone});
  @override
  Widget build(BuildContext context) {
    final upcoming = [for (final r in reminders) if (!r.done && r.at.isAfter(now.subtract(const Duration(hours: 2)))) r];
    if (upcoming.isEmpty) return const SizedBox.shrink();
    String hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('接下来的提醒', style: Theme.of(context).textTheme.titleMedium),
        for (final r in upcoming)
          ListTile(
            key: Key('care_reminder_${r.id}'),
            dense: true, contentPadding: EdgeInsets.zero,
            leading: Icon(r.at.isBefore(now) ? Icons.alarm_on : Icons.alarm, color: r.at.isBefore(now) ? const Color(0xFFE65100) : null),
            title: Text('${hm(r.at)}  ${r.title}'),
            subtitle: Text(r.reason),
            trailing: TextButton(onPressed: () => onDone(r.id), child: const Text('完成')),
          ),
      ]),
    );
  }
}
