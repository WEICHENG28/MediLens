import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/medication_records.dart';

Future<MedicationUse?> chooseMedicationUse(BuildContext context, String names) => showDialog<MedicationUse>(context: context,
  builder: (c) => AlertDialog(title: const Text('单独确认使用情况'), scrollable: true,
    content: Text('$names\n\n仅保存在本机。保存药名不等于正在使用；已有同名记录会由本次选择更新。不生成用药建议或提醒，也不自动填写报告问卷。'),
    actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
      TextButton(onPressed: () => Navigator.pop(c, MedicationUse.unspecified), child: const Text('仅保存药名，不确认在用')),
      FilledButton(onPressed: () => Navigator.pop(c, MedicationUse.reportedTaking), child: const Text('我确认以上药名均目前在用'))]));
class MedicationRecordsPage extends ConsumerStatefulWidget {
  const MedicationRecordsPage({super.key});
  @override ConsumerState<MedicationRecordsPage> createState() => _MedicationRecordsPageState();
}
class _MedicationRecordsPageState extends ConsumerState<MedicationRecordsPage> {
  bool busy = false;
  Future<void> change(MedicationRecord record, {bool remove = false}) async {
    if (busy) return;
    if (remove) {
      final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(title: const Text('删除本机药名记录？'),
        content: Text('${record.name}\n仅删除记录，不代表停用药物。'), actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('删除记录'))]));
      if (ok != true || !mounted) return;
    }
    final use = remove ? null : await chooseMedicationUse(context, record.name);
    if (!mounted || (!remove && use == null)) return;
    setState(() => busy = true);
    try {
      final service = ref.read(medicationRecordsProvider);
      if (remove) { await service.remove(record.name); } else { await service.setUse(record.name, use!); }
      if (mounted) ref.invalidate(savedMedicationsProvider);
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('药名记录未能更新，请重试。')));
    } finally { if (mounted) setState(() => busy = false); }
  }
  @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('本机药名记录')),
    body: ref.watch(savedMedicationsProvider).when(loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => Center(child: Column(mainAxisSize: MainAxisSize.min, children: [const Text('记录读取失败，原数据未被覆盖。'), TextButton(onPressed: () => ref.invalidate(savedMedicationsProvider), child: const Text('重试'))])),
      data: (records) => ListView(padding: const EdgeInsets.all(16), children: [
        const Text('这是您核对并主动保存的药名，不是处方，也不能证明药品真伪。使用情况仅为您在记录时间的自述，不代表今天已经服药。不会自动关联报告答案或提醒。'),
        if (busy) const LinearProgressIndicator(),
        if (records.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('尚未保存药名，可从药盒识别页开始。')),
        for (final r in records) Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(r.name, style: Theme.of(context).textTheme.titleMedium), Text(medicationUseLabel(r.use)),
          Text('使用情况记录时间：${r.updatedAt.toLocal().toString().substring(0, 16)}\n药名核对时间：${r.confirmedAt.toLocal().toString().substring(0, 16)}'),
          ExpansionTile(title: const Text('查看原文与资料版本'), children: [SelectableText('核对原文：${r.originalText}\n药名词表：${r.dictionaryVersion}\n${r.sourceTitle}\n资料日期：${r.sourceDate}；名称检索核对：${r.sourceCheckedAt}\n${r.sourceUrl}\n官方索引名称核对，非医学审核或当前注册状态核验。')]),
          Wrap(spacing: 8, children: [TextButton(onPressed: busy ? null : () => change(r), child: const Text('更改本人使用情况')),
            TextButton(onPressed: busy ? null : () => change(r, remove: true), child: const Text('删除记录'))]),
        ]))),
      ])));
}
