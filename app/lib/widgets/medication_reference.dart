import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/medication_records.dart';

/// Read-only local context. Never classifies drugs or changes/sends a questionnaire answer.
class MedicationReference extends ConsumerStatefulWidget {
  const MedicationReference({super.key});
  @override ConsumerState<MedicationReference> createState() => _MedicationReferenceState();
}
class _MedicationReferenceState extends ConsumerState<MedicationReference> {
  bool open = false;
  Future<void> manage() async {
    await context.push('/medications-saved');
    if (mounted) ref.invalidate(savedMedicationsProvider);
  }
  @override Widget build(BuildContext context) {
    final records = open ? ref.watch(savedMedicationsProvider) : null;
    return Card(child: ExpansionTile(
      key: const Key('medication_reference'),
      leading: const Icon(Icons.fact_check_outlined),
      title: const Text('答题前，查阅本机药名记录'),
      subtitle: const Text('按需展开，帮助核对；不会替您选择答案'),
      onExpansionChanged: (value) => setState(() => open = value),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: [if (open) ...[
        const Text('记录可能已变化，请对照当前药盒和您的实际使用情况。这里不做药物分类；拿不准时可以选择“不确定”，不必猜。展开查阅不会发送药名。'),
        const SizedBox(height: 8),
        records!.when(loading: () => const LinearProgressIndicator(),
          error: (_, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('本机药名暂时无法读取，原记录未修改。您仍可继续答题或选择“不确定”。'),
            TextButton(onPressed: () => ref.invalidate(savedMedicationsProvider), child: const Text('重试读取药名')),
          ]),
          data: (list) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (list.isEmpty) const Text('还没有保存药名。这不代表您没有用药，请根据实际情况回答。'),
            for (final r in list) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r.name, style: Theme.of(context).textTheme.titleMedium),
              Text(medicationUseLabel(r.use)),
              Text('使用情况记录于 ${r.updatedAt.toLocal().toString().substring(0, 16)}'),
            ])),
          ])),
        TextButton.icon(key: const Key('manage_medications'), onPressed: manage, icon: const Icon(Icons.edit_note_outlined), label: const Text('核对或修改药名记录')),
        const Text('修改记录后，仍请您在本题自行选择答案；答题只提交您所选的选项，不附带本机药名记录。'),
      ]],
    ));
  }
}
