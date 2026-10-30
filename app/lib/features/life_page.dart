// 生活打卡与小兔陪伴（原型）：记录用药/打针、吃饭、运动、睡眠、血糖 → 后端分析个人规律、宠物状态与提醒。
// 记录保存在本机（加密数据库）；分析时只发送打卡记录（时间、类型、数值），不含身份信息。

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../core/life_tasks.dart';
import '../data/local_store.dart';

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
  List<LifeTask> tasks = [];
  bool negative = true;
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
    events = List<Map<String, dynamic>>.from(jsonDecode(await store.getSetting(_kEvents) ?? '[]') as List);
    schedule = List<Map<String, dynamic>>.from(jsonDecode(await store.getSetting(_kSchedule) ?? '[]') as List);
    negative = (await store.getSetting(_kNegative)) != 'false';
    tasks = await loadTasks(store);
    await _analyze();
  }

  Future<void> _save() async {
    await store.putSetting(_kEvents, jsonEncode(events));
    await store.putSetting(_kSchedule, jsonEncode(schedule));
    await store.putSetting(_kNegative, negative ? 'true' : 'false');
  }

  static String _now() => DateTime.now().toIso8601String().substring(0, 19);
  static String _today() => DateTime.now().toIso8601String().substring(0, 10);

  Future<void> _analyze() async {
    if (events.isEmpty && tasks.isEmpty) {
      setState(() => result = null);
      return;
    }
    setState(() => busy = true);
    try {
      final r = await ref.read(apiClientProvider).lifestyle({
        'events': events.length > 3000 ? events.sublist(events.length - 3000) : events,
        'schedule': schedule,
        'tasks': tasks.map((t) => {'id': t.id, 'title': t.title, 'due': t.due, 'done': t.done}).toList(),
        'today': _today(),
        'negative_feedback': negative,
      });
      setState(() {
        result = r;
        error = null;
      });
    } catch (e) {
      setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _add(Map<String, dynamic> e) async {
    events.add({'time': _now(), ...e});
    await _save();
    await _analyze();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已记录'), duration: Duration(seconds: 1)));
  }

  Future<void> _loadDemo() async {
    setState(() => busy = true);
    try {
      final d = await ref.read(apiClientProvider).lifestyleDemo(_today());
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
    events = [];
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
    schedule.add({'task': task, 'time': '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}', 'label': '按医嘱'});
    await _save();
    await _analyze();
  }

  @override
  Widget build(BuildContext context) {
    final r = result;
    return Scaffold(
      appBar: AppBar(title: const Text('生活打卡 · 小兔陪伴'), actions: [
        PopupMenuButton<String>(
          onSelected: (v) => v == 'demo' ? _loadDemo() : _clear(),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'demo', child: Text('载入两周示例记录（演示用）')),
            PopupMenuItem(value: 'clear', child: Text('清空打卡记录')),
          ],
        ),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (busy) const LinearProgressIndicator(),
        if (error != null) Card(child: Padding(padding: const EdgeInsets.all(12), child: Text(error!))),
        if (r != null) _PetCard(pet: r['pet'] as Map<String, dynamic>) else _emptyPet(),
        if (r != null)
          for (final a in (r['alerts'] as List)) _AlertCard(a as Map<String, dynamic>),
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
        SwitchListTile(
          title: const Text('漏用药时小兔会生病'),
          subtitle: const Text('提醒按时用药；按时用药 1–2 天即可恢复，小兔不会死亡。关闭后小兔只会等你'),
          value: negative,
          onChanged: (v) async {
            setState(() => negative = v);
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

  Widget _emptyPet() => const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Column(children: [
            Text('🐰', style: TextStyle(fontSize: 64)),
            Text('还没有打卡记录。先添加用药时间，再开始打卡；也可以在右上角载入示例记录看看效果。', textAlign: TextAlign.center),
          ]),
        ),
      );

  Widget _chip(IconData icon, String label, VoidCallback onTap) =>
      ActionChip(key: Key('life_$label'), avatar: Icon(icon, size: 18), label: Text(label), onPressed: busy ? null : onTap);

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
            _stat('按时用药', pct(m['adherence'])),
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
  final Map<String, dynamic> pet;
  const _PetCard({required this.pet});

  @override
  Widget build(BuildContext context) {
    final health = pet['health_state'] as String;
    final energy = pet['energy_state'] as String;
    final mood = pet['mood'] as String;
    final face = health == '生病了' ? '🤒' : health == '有点不舒服' ? '🤧' : mood == '开心' ? '🥳' : energy == '困倦' ? '😪' : '😊';
    final bg = health == '生病了'
        ? const Color(0xFFFDECEA)
        : mood == '开心'
            ? const Color(0xFFE8F5E9)
            : Theme.of(context).colorScheme.surfaceContainerHighest;
    return Card(
      color: bg,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Stack(children: [
              Text(health == '生病了' ? '🛏️' : '🐰', key: const Key('pet_avatar'), style: const TextStyle(fontSize: 64)),
              Positioned(right: 0, bottom: 0, child: Text(face, style: const TextStyle(fontSize: 28))),
            ]),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('小兔 · $health · $energy', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87)),
                const SizedBox(height: 6),
                _bar('健康（按时用药）', pet['health'] as int, Colors.red.shade400),
                _bar('活力（运动·睡眠·记录）', pet['energy'] as int, Colors.teal),
                if ((pet['streak_days'] as int) > 0)
                  Text('连续按时用药 ${pet['streak_days']} 天', style: const TextStyle(fontSize: 12, color: Colors.black87)),
              ]),
            ),
          ]),
          const SizedBox(height: 8),
          Text(pet['message'] as String, key: const Key('pet_message'), style: const TextStyle(fontSize: 16, color: Colors.black87)),
          if (pet['safety_note'] != null) ...[
            const SizedBox(height: 6),
            Text(pet['safety_note'] as String, style: const TextStyle(color: Color(0xFFB71C1C), fontWeight: FontWeight.bold)),
          ],
        ]),
      ),
    );
  }

  Widget _bar(String label, int v, Color c) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$label  $v', style: const TextStyle(fontSize: 12, color: Colors.black87)),
          LinearProgressIndicator(value: v / 100, color: c, backgroundColor: Colors.white, minHeight: 6),
        ]),
      );
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
