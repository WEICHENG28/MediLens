// 生活打卡的首次设置（组员设计）：欢迎 → 填写当前时间与初始血糖 → 设置吃饭/吃药/打针目标时间与个人目标血糖。
// 用药与打针时间写入「用药时间（按医嘱）」，可用于本机提醒；吃饭时间只显示在打卡按钮上。

import 'package:flutter/material.dart';

import '../core/life_journal.dart';
import '../widgets/pearl_bird.dart';

class SetupResult {
  final DateTime time;
  final double? glucose;
  final List<String> mealTimes, medTimes, insulinTimes;
  final (double, double) target;
  const SetupResult({required this.time, this.glucose, required this.mealTimes, required this.medTimes,
      required this.insulinTimes, required this.target});
}

class LifeSetupPage extends StatefulWidget {
  final DateTime now;
  final (double, double) target;
  final List<String> mealTimes, medTimes, insulinTimes;
  final Future<void> Function(SetupResult) onDone;
  const LifeSetupPage({super.key, required this.now, required this.target, required this.mealTimes,
      required this.medTimes, required this.insulinTimes, required this.onDone});
  @override
  State<LifeSetupPage> createState() => _LifeSetupPageState();
}

class _LifeSetupPageState extends State<LifeSetupPage> {
  int step = 0;
  late DateTime time = widget.now;
  final glucose = TextEditingController();
  late final low = TextEditingController(text: widget.target.$1.toString());
  late final high = TextEditingController(text: widget.target.$2.toString());
  late List<String> meals = widget.mealTimes.isEmpty ? ['07:30', '12:00', '18:00'] : [...widget.mealTimes];
  late List<String> meds = [...widget.medTimes];
  late List<String> insulin = [...widget.insulinTimes];
  String? error;
  bool saving = false;

  String _hm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _pickTime() async {
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(time));
    if (t != null) setState(() => time = DateTime(time.year, time.month, time.day, t.hour, t.minute));
  }

  Future<void> _addTime(List<String> list) async {
    final t = await showTimePicker(context: context, initialTime: const TimeOfDay(hour: 8, minute: 0));
    if (t != null && !list.contains(_hm(t))) setState(() => list..add(_hm(t))..sort());
  }

  void _next() {
    final g = glucose.text.trim();
    if (g.isNotEmpty) {
      final v = double.tryParse(g);
      if (v == null || v <= 0 || v >= 40) {
        setState(() => error = '请填写 0–40 之间的数字，例如 6.5；没有测可以留空');
        return;
      }
    }
    setState(() { error = null; step = 1; });
  }

  Future<void> _done() async {
    final l = double.tryParse(low.text.trim()), h = double.tryParse(high.text.trim());
    if (l == null || h == null || l < 2 || h > 30 || l >= h) {
      setState(() => error = '请检查目标范围：下限要小于上限，范围在 2–30 mmol/L 之间');
      return;
    }
    setState(() { error = null; saving = true; });
    await widget.onDone(SetupResult(time: time, glucose: double.tryParse(glucose.text.trim()), mealTimes: meals,
        medTimes: meds, insulinTimes: insulin, target: (l, h)));
  }

  Widget _times(String title, String hint, List<String> list, String key) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 16),
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        Text(hint, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final t in list) InputChip(label: Text(t), onDeleted: () => setState(() => list.remove(t))),
          ActionChip(key: Key('setup_add_$key'), avatar: const Icon(Icons.add, size: 18), label: const Text('添加时间'), onPressed: () => _addTime(list)),
        ]),
      ]);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hm = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    return Scaffold(
      appBar: AppBar(title: Text(step == 0 ? '欢迎来到生活打卡' : '设置我的目标')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        if (step == 0) ...[
          const Center(child: PearlBird(mood: BirdMood.normal, size: 170)),
          const SizedBox(height: 12),
          Text('欢迎来到生活打卡！', textAlign: TextAlign.center, style: t.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          const Text('珍珠鸟会陪你一起记录吃饭、用药和血糖，一起把糖尿病管理好。', textAlign: TextAlign.center),
          const SizedBox(height: 24),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.schedule),
            title: const Text('现在的时间'),
            subtitle: Text('${time.month}月${time.day}日 $hm'),
            trailing: TextButton(onPressed: _pickTime, child: const Text('修改')),
          ),
          TextField(
            key: const Key('setup_glucose'),
            controller: glucose,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: '今天的初始血糖（mmol/L）', helperText: '没有测可以留空，之后再记'),
          ),
          if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: const TextStyle(color: Colors.red))),
          const SizedBox(height: 24),
          FilledButton(key: const Key('setup_next'), onPressed: _next, child: const Text('下一步：设置目标')),
        ] else ...[
          Text('设置后，打卡按钮会显示下一次的目标时间。请以医生的医嘱为准。', style: t.bodyMedium),
          _times('吃饭时间', '只显示在「打卡吃饭」上，不会发送通知', meals, 'meal'),
          _times('吃药时间（按医嘱）', '可在「本机任务提醒」中开启通知', meds, 'med'),
          _times('打针时间（按医嘱）', '没有用胰岛素可以不填', insulin, 'insulin'),
          const SizedBox(height: 16),
          Text('我的目标血糖（mmol/L）', style: t.titleMedium),
          Text('请填写医生给您的个人目标；不确定时可先用常用的 3.9–10.0，之后可修改。', style: t.bodySmall),
          Row(children: [
            Expanded(child: TextField(key: const Key('setup_low'), controller: low, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: '下限'))),
            const SizedBox(width: 12),
            Expanded(child: TextField(key: const Key('setup_high'), controller: high, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: '上限'))),
          ]),
          if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: const TextStyle(color: Colors.red))),
          const SizedBox(height: 24),
          Row(children: [
            TextButton(onPressed: saving ? null : () => setState(() => step = 0), child: const Text('上一步')),
            const Spacer(),
            FilledButton(key: const Key('setup_done'), onPressed: saving ? null : _done, child: const Text('完成，开始打卡')),
          ]),
        ],
      ]),
    );
  }
}
