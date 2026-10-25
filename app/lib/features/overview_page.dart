// P04 解读总览：紧急提示置顶；已识别/需关注/无法确认项目数；初步提示（测试规则）；数据完整性。
// 先展示已知信息，不要求先完成问卷；未知数据不自动变绿。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/session.dart';
import '../widgets/common.dart';
import 'explain_panel.dart';

class OverviewPage extends ConsumerWidget {
  const OverviewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionProvider);
    final a = s.analysis;
    if (a == null) return const Scaffold(body: Center(child: Text('尚无解读结果')));
    final t = Theme.of(context).textTheme;
    final urgent = a['urgent_alert'] as Map<String, dynamic>;
    final overall = a['overall'] as Map<String, dynamic>;
    final counts = a['counts'] as Map<String, dynamic>;
    final hits = (a['hits'] as List).cast<Map<String, dynamic>>();
    final notEval = (a['not_evaluable'] as List).cast<Map<String, dynamic>>();
    final uncovered = (a['uncovered_abnormal'] as List).cast<String>();
    final missingKey = (a['missing_key_items'] as List).cast<String>();
    final items = (a['items'] as List).cast<Map<String, dynamic>>();
    final next = s.nextQuestion;

    return Scaffold(
      appBar: AppBar(title: const Text('解读总览'), actions: [
        IconButton(tooltip: '保存/结束', icon: const Icon(Icons.save_alt), onPressed: () => context.push('/save')),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (urgent['show'] == true) _UrgentCard(urgent),
        const TestRuleBanner(),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                LevelChip(overall['level'] as String, label: overall['label'] as String),
                const Spacer(),
                ReadAloudButton('${overall['label']}。${hits.map((h) => h['summary']).join('。')}'),
              ]),
              const SizedBox(height: 8),
              Text(overall['explanation'] as String, style: t.bodyMedium),
              const Divider(height: 24),
              Wrap(spacing: 16, runSpacing: 8, children: [
                _count('已识别', counts['recognized']),
                _count('需关注', counts['abnormal']),
                _count('无法确认', counts['unknown']),
              ]),
            ]),
          ),
        ),
        if (next != null)
          Card(
            color: Theme.of(context).colorScheme.primaryContainer,
            child: ListTile(
              // 文字与图标使用与底色配对的颜色（老年模式高对比度下底色为深色）
              textColor: Theme.of(context).colorScheme.onPrimaryContainer,
              iconColor: Theme.of(context).colorScheme.onPrimaryContainer,
              key: const Key('start_followup'),
              leading: const Icon(Icons.quiz_outlined),
              title: const Text('回答几个简单问题，让解释更准确'),
              subtitle: const Text('可随时跳过，不回答不会被当作「没有」'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/followup'),
            ),
          ),
        const SizedBox(height: 8),
        if (hits.isNotEmpty) Text('重点提示', style: t.titleLarge),
        for (final h in hits) _HitCard(h),
        if (uncovered.isNotEmpty || notEval.isNotEmpty || missingKey.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('哪些结论受信息缺失影响', style: t.titleMedium),
          if (uncovered.isNotEmpty) _info('以下异常项目暂无规则覆盖，无法据此判断：${uncovered.join('、')}'),
          if (missingKey.isNotEmpty) _info('报告中未识别到：${missingKey.join('、')}'),
          for (final n in notEval) _info('${n['title']}：无法判断（${(n['missing'] as List).join('；')}）。这不代表正常。'),
        ],
        const SizedBox(height: 12),
        Text('全部指标', style: t.titleLarge),
        for (final i in items) _ItemTile(i),
        const SizedBox(height: 12),
        OutlinedButton.icon(icon: const Icon(Icons.chat_outlined), label: const Text('有疑问？文字提问'), onPressed: () => context.push('/chat')),
        const SizedBox(height: 8),
        OutlinedButton.icon(icon: const Icon(Icons.question_answer_outlined), label: const Text('复诊时问医生什么'), onPressed: () => context.push('/doctor')),
        const SizedBox(height: 8),
        FilledButton.icon(key: const Key('finish'), icon: const Icon(Icons.check), label: const Text('完成并选择是否保存'), onPressed: () => context.push('/save')),
        DisclaimerText(text: a['disclaimer'] as String),
        Text('规则版本：${(a['versions'] as Map).values.join(' / ')}', style: t.bodySmall),
      ]),
    );
  }

  Widget _count(String label, Object? n) => Column(children: [
        Text('$n', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
        Text(label),
      ]);

  // 说明文字使用正文字号（不用紧凑版面），老年模式下随主题放大
  Widget _info(String text) => ListTile(leading: const Icon(Icons.info_outline, color: Colors.blueGrey), title: Text(text));
}

class _UrgentCard extends StatelessWidget {
  final Map<String, dynamic> urgent;
  const _UrgentCard(this.urgent);
  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        child: Card(
          key: const Key('urgent_alert'),
          color: const Color(0xFFFFEBEE),
          shape: RoundedRectangleBorder(side: const BorderSide(color: Color(0xFFC62828), width: 2), borderRadius: BorderRadius.circular(14)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Row(children: [
                Icon(Icons.emergency, color: Color(0xFFC62828), size: 32),
                SizedBox(width: 8),
                Expanded(child: Text('请优先注意', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFFC62828)))),
              ]),
              const SizedBox(height: 8),
              Text(urgent['message'] as String, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text('原因：${(urgent['reasons'] as List).join('；')}'),
              const Text('（测试规则，未经医学审核）', style: TextStyle(color: Colors.black54)),
            ]),
          ),
        ),
      );
}

class _HitCard extends StatelessWidget {
  final Map<String, dynamic> h;
  const _HitCard(this.h);
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: ExpandableExplain(
            target: h['rule_id'] as String,
            header: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                LevelChip(h['level'] as String),
                const SizedBox(width: 8),
                Expanded(child: Text(h['title'] as String, style: Theme.of(context).textTheme.titleMedium)),
                ReadAloudButton(h['summary'] as String),
              ]),
              const SizedBox(height: 8),
              Text(h['summary'] as String),
              Text('${h['rule_id']} · 测试规则，未经医学审核', style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
        ),
      );
}

class _ItemTile extends StatelessWidget {
  final Map<String, dynamic> i;
  const _ItemTile(this.i);
  @override
  Widget build(BuildContext context) {
    final usable = i['usable'] == true;
    final status = i['status'] as String;
    final (txt, color) = !usable
        ? ('无法确认', Colors.grey)
        : switch (status) {
            'abnormal' => ('超出参考范围', Colors.deepOrange),
            'normal' => ('在参考范围内', Colors.green),
            _ => ('无法比对', Colors.grey),
          };
    final value = [i['raw_value'] ?? '—', if (i['unit'] != null) i['unit']].join(' ');
    final tile = ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(i['name'] as String),
      subtitle: Text('$value${i['reference_text'] != null ? '  参考 ${i['reference_text']}' : ''}\n${i['status_reason']}'),
      isThreeLine: true,
      trailing: Text(txt, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        child: i['code'] == null ? tile : ExpandableExplain(target: i['code'] as String, header: tile),
      ),
    );
  }
}
