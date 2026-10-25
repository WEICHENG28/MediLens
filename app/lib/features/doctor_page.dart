// P10 复诊问题：汇总规则给出的可问医生的问题，可复制。明确不是处方或诊断。提醒待实现。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/session.dart';
import '../data/local_store.dart';

class DoctorPage extends ConsumerWidget {
  const DoctorPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 优先使用当前会话；会话已结束（如保存后返回首页）时，使用本机最近一份报告的解读
    final current = ref.watch(sessionProvider).analysis;
    final latest = ref.watch(historyProvider).value?.firstOrNull;
    final a = current ?? latest?.analysis;
    final fromHistory = current == null && latest?.analysis != null;
    final qs = ((a?['doctor_questions'] as List?) ?? const []).cast<String>();
    final general = ['这份报告整体有哪些需要我注意的地方？', '我下次复查应该查哪些项目、什么时候查？'];
    final all = [...qs, ...general.where((g) => !qs.contains(g))];
    return Scaffold(
      appBar: AppBar(title: const Text('复诊时可以问医生')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (a == null) const Text('尚未解读报告，以下为通用问题。', style: TextStyle(color: Colors.black54)),
        if (fromHistory) Text('来自本机最近保存的报告（检验日期 ${latest!.testDate ?? '未知'}）', style: const TextStyle(color: Colors.black54)),
        for (final q in all) Card(child: ListTile(leading: const Icon(Icons.help_outline), title: Text(q))),
        const SizedBox(height: 12),
        FilledButton.icon(
          icon: const Icon(Icons.copy),
          label: const Text('复制全部问题'),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: all.map((q) => '· $q').join('\n')));
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制')));
          },
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(icon: const Icon(Icons.alarm), label: const Text('设置复查提醒（待实现）'), onPressed: () => context.push('/reminder')),
        const SizedBox(height: 12),
        const Text('以上仅为沟通参考，不是处方或诊断。复查时间以医生医嘱为准。', style: TextStyle(color: Colors.black54)),
      ]),
    );
  }
}
