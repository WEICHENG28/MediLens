// 生活页的照护区块：今天（时间轴＋每日小结）、我的状况（分级结论）、观察中、图表、改善小目标、周报/复诊摘要/问照护助理入口。
// 资料都来自照护核心（后端规则与统计）；第一层只放一句白话，点开才看依据与数字。

import 'package:flutter/material.dart';

import '../widgets/care_charts.dart';

const careLevelTitle = {
  'fact': '从记录看到的事实',
  'association': '多次出现的关联（只代表相关，不是原因）',
  'ask_doctor': '建议带去问医生',
  'unknown': '目前还不能判断',
};

class CareSections extends StatelessWidget {
  final Map<String, dynamic> profile;
  final Map<String, dynamic>? daily;
  final Map<String, dynamic>? goal; // {suggested, progress}
  final List<Map<String, dynamic>> events;
  final DateTime day;
  final (double, double) target;
  final void Function(String goalId)? onStartGoal;
  final VoidCallback? onStopGoal;
  final VoidCallback onWeekly, onVisit, onChat;
  const CareSections({super.key, required this.profile, required this.daily, required this.goal, required this.events,
      required this.day, required this.target, this.onStartGoal, this.onStopGoal,
      required this.onWeekly, required this.onVisit, required this.onChat});

  @override
  Widget build(BuildContext context) {
    final title = Theme.of(context).textTheme.titleMedium;
    final small = Theme.of(context).textTheme.bodySmall;
    final findings = ((profile['findings'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final watching = ((profile['watching'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final m = (profile['metrics'] as Map?)?.cast<String, dynamic>() ?? const {};
    final urgent = [for (final f in findings) if (f['urgent'] == true) f];
    final rest = [for (final f in findings) if (f['urgent'] != true) f];
    return Column(key: const Key('care_sections'), crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 16),
      Text('今天', style: title),
      const SizedBox(height: 4),
      Card(child: Padding(padding: const EdgeInsets.fromLTRB(8, 10, 8, 6),
          child: DayTimeline(events: events, day: day, target: target))),
      Text('🍚 吃饭  💊 用药  🚶 活动  🌙 睡觉  ⚠️ 不舒服 · 空心点为指血', style: small),
      if (daily != null) _DailyCard(daily!),
      if (urgent.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text('需要留意', style: title?.copyWith(color: const Color(0xFFB71C1C))),
        for (final f in urgent) FindingCard(f, urgent: true),
      ],
      const SizedBox(height: 16),
      Text('我的状况', style: title),
      if (findings.isEmpty)
        const Padding(padding: EdgeInsets.all(8), child: Text('记录还不多，暂时整理不出结论。坚持记录血糖、三餐和用药，一两周后就能看到你自己的规律。')),
      for (final level in careLevelTitle.keys)
        if (rest.any((f) => f['level'] == level)) ...[
          Padding(padding: const EdgeInsets.only(top: 8, bottom: 2), child: Text(careLevelTitle[level]!, style: small?.copyWith(fontWeight: FontWeight.w600))),
          for (final f in rest) if (f['level'] == level) FindingCard(f),
        ],
      if (watching.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text('观察中（证据还不够，先不下结论）', style: title),
        for (final w in watching) _WatchRow(w),
      ],
      if ((m['post_meal'] as Map?)?.isNotEmpty == true || m['tir'] != null) ...[
        const SizedBox(height: 16),
        Text('图表', style: title),
        const SizedBox(height: 6),
        if ((m['post_meal'] as Map?)?.isNotEmpty == true)
          MealCompareBars(postMeal: (m['post_meal'] as Map).cast<String, dynamic>(), high: target.$2),
        const SizedBox(height: 12),
        if (m['tir'] != null && (m['readings'] as num? ?? 0) >= 20)
          RangeBar(tbr: (m['tbr'] as num?)?.toDouble(), tir: (m['tir'] as num?)?.toDouble(), tar: (m['tar'] as num?)?.toDouble(),
              source: '${m['source']}'),
      ],
      if (goal != null) _GoalCard(goal!, onStart: onStartGoal, onStop: onStopGoal),
      const SizedBox(height: 16),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.tonalIcon(key: const Key('open_weekly'), onPressed: onWeekly, icon: const Icon(Icons.date_range), label: const Text('周报')),
        FilledButton.tonalIcon(key: const Key('open_visit'), onPressed: onVisit, icon: const Icon(Icons.assignment_outlined), label: const Text('复诊摘要')),
        FilledButton.tonalIcon(key: const Key('open_care_chat'), onPressed: onChat, icon: const Icon(Icons.chat_outlined), label: const Text('问照护助理')),
      ]),
      const SizedBox(height: 6),
      Text('${profile['disclaimer'] ?? ''}', style: small),
    ]);
  }
}

class FindingCard extends StatelessWidget {
  final Map<String, dynamic> f;
  final bool urgent;
  const FindingCard(this.f, {super.key, this.urgent = false});
  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    final conf = f['confidence'] as String?;
    return Card(
      key: Key('finding_${f['id']}'),
      color: urgent ? const Color(0xFFFDECEA) : null,
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          title: Text('${f['headline']}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, height: 1.35)),
          subtitle: conf == null ? null : Padding(padding: const EdgeInsets.only(top: 4), child: Text(conf == '较明确' ? '比较明显' : '还要多观察', style: small)),
          trailing: Text('看依据', style: small?.copyWith(color: Theme.of(context).colorScheme.primary)),
          children: [
            if ((f['detail'] as String?)?.isNotEmpty == true) Text('${f['detail']}', style: const TextStyle(height: 1.45)),
            if (f['boundary'] != null) ...[
              const SizedBox(height: 6),
              Text('⚠ ${f['boundary']}', style: const TextStyle(color: Color(0xFFB71C1C))),
            ],
            if (f['question'] != null) ...[
              const SizedBox(height: 6),
              Text('复诊可以问：${f['question']}', style: small),
            ],
          ],
        ),
      ),
    );
  }
}

class _WatchRow extends StatelessWidget {
  final Map<String, dynamic> w;
  const _WatchRow(this.w);
  @override
  Widget build(BuildContext context) {
    final needed = (w['needed'] as num?)?.toInt() ?? 1;
    final have = (w['support'] as num?)?.toInt() ?? 0;
    return Padding(
      key: Key('watch_${w['id']}'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${w['title']}', style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(
            value: (have / needed).clamp(0.0, 1.0), minHeight: 6, backgroundColor: const Color(0xFFF3ECE6), color: const Color(0xFFB08968))),
        const SizedBox(height: 2),
        Text('${w['progress']}', style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}

class _DailyCard extends StatelessWidget {
  final Map<String, dynamic> d;
  const _DailyCard(this.d);
  @override
  Widget build(BuildContext context) {
    List<String> list(String k) => ((d[k] as List?) ?? const []).cast<String>();
    final small = Theme.of(context).textTheme.bodySmall;
    return Card(
      key: const Key('daily_summary'),
      color: const Color(0xFFFFF8F2),
      child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('今日小结', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        for (final l in list('lines')) Text('· $l', style: const TextStyle(height: 1.4)),
        for (final l in list('tonight')) Padding(padding: const EdgeInsets.only(top: 4),
            child: Text('🌙 今晚：$l', style: const TextStyle(color: Color(0xFFE65100), fontWeight: FontWeight.w600))),
        for (final l in list('new_findings')) Text('✨ 新发现：$l', style: const TextStyle(height: 1.4)),
        if (list('missing').isNotEmpty) Text('还没记录：${list('missing').join('、')}', style: small),
        const SizedBox(height: 6),
        Text('🐦 ${d['encouragement'] ?? ''}', style: const TextStyle(color: Color(0xFF5E7D4F))),
      ])),
    );
  }
}

class _GoalCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final void Function(String id)? onStart;
  final VoidCallback? onStop;
  const _GoalCard(this.data, {this.onStart, this.onStop});
  @override
  Widget build(BuildContext context) {
    final progress = (data['progress'] as Map?)?.cast<String, dynamic>();
    final g = ((progress?['goal'] ?? data['suggested']) as Map?)?.cast<String, dynamic>();
    if (g == null) return const SizedBox.shrink();
    final small = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Card(key: const Key('goal_card'), color: const Color(0xFFEFF3E6), child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(progress == null ? '可以试试的小目标' : '进行中的小目标', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Text('${g['title']}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          Text('为什么：${g['why']}', style: const TextStyle(height: 1.4)),
          for (final h in ((g['how'] as List?) ?? const [])) Text('· $h'),
          const SizedBox(height: 4),
          Text('⚠ ${g['boundary']}', style: small?.copyWith(color: const Color(0xFFB71C1C))),
          if (progress != null) ...[
            const SizedBox(height: 8),
            Text('${progress['verdict']}', key: const Key('goal_verdict'), style: const TextStyle(fontWeight: FontWeight.bold)),
            Text('${progress['text']}', style: const TextStyle(height: 1.4)),
            Text('开始于 ${progress['started']} · 做到 ${progress['done_days']}/${progress['days']} 天', style: small),
          ],
          Align(alignment: Alignment.centerRight, child: progress == null
              ? FilledButton(key: const Key('goal_start'), onPressed: onStart == null ? null : () => onStart!('${g['id']}'), child: const Text('开始这个目标'))
              : TextButton(key: const Key('goal_stop'), onPressed: onStop, child: const Text('结束目标'))),
        ]),
      )),
    );
  }
}
