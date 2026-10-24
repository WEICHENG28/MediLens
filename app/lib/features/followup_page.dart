// P05 动态选择题：每题单一主题；可跳过/不确定/不愿透露；可回到上一题修改；题数不固定。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api_client.dart';
import '../core/session.dart';
import '../widgets/common.dart';

class FollowupPage extends ConsumerStatefulWidget {
  const FollowupPage({super.key});
  @override
  ConsumerState<FollowupPage> createState() => _FollowupPageState();
}

class _FollowupPageState extends ConsumerState<FollowupPage> {
  final Set<String> multi = {};
  bool busy = false;

  Future<void> _submit(String qid, dynamic value) async {
    setState(() => busy = true);
    try {
      await ref.read(sessionProvider.notifier).answer(qid, value);
      multi.clear();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _back() async {
    setState(() => busy = true);
    try {
      await ref.read(sessionProvider.notifier).back();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    final q = s.nextQuestion;
    final urgent = s.analysis?['urgent_alert'] as Map<String, dynamic>?;
    if (q == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('补充信息')),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Icon(Icons.check_circle_outline, size: 64, color: Colors.teal),
            const SizedBox(height: 12),
            const Text('问题已完成，解释已根据您的回答更新。', textAlign: TextAlign.center, style: TextStyle(fontSize: 18)),
            const SizedBox(height: 24),
            if (s.answerOrder.isNotEmpty) OutlinedButton.icon(icon: const Icon(Icons.undo), label: const Text('修改上一题'), onPressed: busy ? null : _back),
            const SizedBox(height: 12),
            FilledButton(key: const Key('followup_done'), onPressed: () => context.pop(), child: const Text('查看更新后的解读')),
          ]),
        ),
      );
    }
    final qid = q['question_id'] as String;
    final isMulti = q['answer_type'] == 'multi';
    final options = (q['options'] as List).cast<Map<String, dynamic>>();
    final prev = s.answers[qid];
    return Scaffold(
      appBar: AppBar(title: Text('补充信息（第 ${q['index']} 题）')),
      body: AbsorbPointer(
        absorbing: busy,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          if (urgent?['show'] == true)
            Card(
              color: const Color(0xFFFFEBEE),
              child: ListTile(leading: const Icon(Icons.emergency, color: Colors.red), title: Text(urgent!['message'] as String)),
            ),
          const TestRuleBanner(),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: Text(q['plain_language_prompt'] as String, style: Theme.of(context).textTheme.titleLarge)),
            ReadAloudButton(q['plain_language_prompt'] as String),
          ]),
          const SizedBox(height: 4),
          Text('为什么问：${q['medical_rationale']}', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 16),
          for (final o in options)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: isMulti
                  ? CheckboxListTile(
                      key: Key('opt_${o['id']}'),
                      title: Text(o['label'] as String),
                      value: multi.contains(o['id']),
                      shape: RoundedRectangleBorder(side: const BorderSide(color: Colors.black26), borderRadius: BorderRadius.circular(10)),
                      onChanged: (v) => setState(() {
                        final id = o['id'] as String;
                        if (v == true) {
                          if (o['exclusive'] == true) multi.clear();
                          multi.removeWhere((m) => options.any((x) => x['id'] == m && x['exclusive'] == true));
                          multi.add(id);
                        } else {
                          multi.remove(id);
                        }
                      }),
                    )
                  : OutlinedButton(
                      key: Key('opt_${o['id']}'),
                      style: OutlinedButton.styleFrom(alignment: Alignment.centerLeft, padding: const EdgeInsets.all(16), backgroundColor: prev == o['id'] ? Colors.teal.shade50 : null),
                      onPressed: () => _submit(qid, o['id']),
                      child: Text(o['label'] as String),
                    ),
            ),
          if (isMulti) FilledButton(onPressed: multi.isEmpty ? null : () => _submit(qid, multi.toList()), child: const Text('确定')),
          if (q['medication_photo_hint'] == true)
            TextButton.icon(icon: const Icon(Icons.medication_outlined), label: const Text('拍药盒帮我识别（待实现）'), onPressed: () => context.push('/medication')),
          const Divider(height: 32),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (q['allow_unknown'] == true) OutlinedButton(key: const Key('ans_unknown'), onPressed: () => _submit(qid, '__unknown__'), child: const Text('不确定')),
            if (q['allow_decline'] == true) OutlinedButton(onPressed: () => _submit(qid, '__decline__'), child: const Text('不愿透露')),
            if (q['allow_skip'] == true) OutlinedButton(key: const Key('ans_skip'), onPressed: () => _submit(qid, '__skip__'), child: const Text('跳过')),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            if (s.answerOrder.isNotEmpty) TextButton.icon(key: const Key('prev_question'), icon: const Icon(Icons.arrow_back), label: const Text('上一题'), onPressed: _back),
            const Spacer(),
            TextButton(onPressed: () => context.pop(), child: const Text('先看解读')),
          ]),
          const Text('未回答的问题不会被当作「没有」。', style: TextStyle(color: Colors.black54)),
          if (busy) const LinearProgressIndicator(),
        ]),
      ),
    );
  }
}
