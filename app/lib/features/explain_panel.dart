// P06 逐条「详细了解」：原位展开该条的原因、相关指标、依据、复诊问题；可朗读；不切换全局模式。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api_client.dart';
import '../core/session.dart';
import '../widgets/common.dart';

final explainProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, target) async {
  final body = ref.read(sessionProvider.notifier).analysisBody;
  // 回答变化时重新获取
  ref.watch(sessionProvider.select((s) => s.answers));
  return ref.read(apiClientProvider).explain(body, target);
});

class ExplainPanel extends ConsumerWidget {
  final String target;
  const ExplainPanel(this.target, {super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = ref.watch(explainProvider(target));
    return r.when(
      loading: () => const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator()),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(8),
        child: Text(e is ApiException ? e.message : '暂时无法获取详细说明', style: const TextStyle(color: Colors.red)),
      ),
      data: (d) {
        final sections = (d['sections'] as List).cast<Map<String, dynamic>>();
        final cites = (d['citations'] as List).cast<Map<String, dynamic>>();
        final dq = (d['doctor_questions'] as List).cast<String>();
        final fullText = [d['short'], ...sections.map((s) => '${s['heading']}：${s['body']}')].join('。');
        return Container(
          key: Key('explain_$target'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Colors.teal.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(10)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [const Spacer(), ReadAloudButton(fullText)]),
            for (final s in sections) ...[
              Text(s['heading'] as String, style: const TextStyle(fontWeight: FontWeight.bold)),
              Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(s['body'] as String)),
            ],
            if (dq.isNotEmpty) ...[
              const Text('复诊时可以问', style: TextStyle(fontWeight: FontWeight.bold)),
              for (final q in dq) Text('· $q'),
              const SizedBox(height: 8),
            ],
            if (cites.isNotEmpty) ...[
              const Text('资料来源', style: TextStyle(fontWeight: FontWeight.bold)),
              for (final c in cites)
                Text(citationLine(c), style: Theme.of(context).textTheme.bodySmall),
            ] else
              Text('暂无可核验的资料来源', style: Theme.of(context).textTheme.bodySmall),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(icon: const Icon(Icons.chat_outlined), label: const Text('就这一条提问'), onPressed: () => context.push('/chat?focus=$target')),
            ),
          ]),
        );
      },
    );
  }
}

/// 带「详细了解」原位展开的容器。
class ExpandableExplain extends StatefulWidget {
  final String target;
  final Widget header;
  const ExpandableExplain({super.key, required this.target, required this.header});
  @override
  State<ExpandableExplain> createState() => _ExpandableExplainState();
}

class _ExpandableExplainState extends State<ExpandableExplain> {
  bool open = false;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        widget.header,
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            key: Key('detail_${widget.target}'),
            icon: Icon(open ? Icons.expand_less : Icons.expand_more),
            label: Text(open ? '收起' : '详细了解'),
            onPressed: () => setState(() => open = !open),
          ),
        ),
        if (open) ExplainPanel(widget.target),
      ]);
}
