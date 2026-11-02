// P09 历史记录：查看、删除与历史指标对照入口。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/settings.dart';
import '../data/local_store.dart';
import '../ocr/report_parser.dart';
import '../widgets/common.dart';

String _typeName(String t) => const {'urinalysis': '尿常规', 'uacr': 'UACR', 'urinalysis+uacr': '尿常规 + UACR'}[t] ?? t;

class HistoryPage extends ConsumerWidget {
  const HistoryPage({super.key});

  Future<bool> _confirm(BuildContext context, String msg) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(content: Text(msg), actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('删除')),
        ]),
      ) ??
      false;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final h = ref.watch(historyProvider);
    final elder = ref.watch(settingsProvider).elder;
    return Scaffold(
      appBar: AppBar(title: const Text('历史记录'), actions: [
        IconButton(
          tooltip: '删除全部',
          icon: const Icon(Icons.delete_sweep_outlined),
          onPressed: () async {
            if (await _confirm(context, '删除本机全部报告记录？此操作不可恢复。')) {
              await ref.read(localStoreProvider).deleteAll();
              ref.invalidate(historyProvider);
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已删除本机全部记录')));
            }
          },
        ),
      ]),
      body: h.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('读取失败：$e')),
        data: (list) => ListView(padding: const EdgeInsets.all(12), children: [
          ListTile(
            leading: const Icon(Icons.show_chart),
            title: const Text('历史指标对照'),
            subtitle: const Text('按原单位与参考范围分组；检测方法需人工核对，不自动判断病情变化'),
            onTap: list.isEmpty ? null : () => context.push('/trends'),
          ),
          if (list.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('本机还没有保存的报告', textAlign: TextAlign.center)),
          for (final r in list)
            Card(
              child: ExpansionTile(
                leading: LevelChip(r.overallLevel),
                title: Text('检验日期 ${r.testDate ?? '未知'}'),
                subtitle: Text('${_typeName(r.reportType)} · 保存于 ${r.savedAt.toString().substring(0, 16)}'),
                children: [
                  for (final i in r.items)
                    ListTile(
                      dense: !elder, // 老年模式不使用紧凑版面，字号随主题放大
                      title: Text(kItemNames[i['code']] ?? i['original_label'] as String),
                      trailing: Text('${i['raw_value'] ?? '—'} ${i['unit'] ?? ''}', style: Theme.of(context).textTheme.bodyLarge),
                      subtitle: Text(i['review_status'] == 'unknown' ? '无法确认' : ''),
                    ),
                  TextButton.icon(
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('删除这条记录'),
                    onPressed: () async {
                      if (await _confirm(context, '删除这份报告记录？')) {
                        await ref.read(localStoreProvider).deleteReport(r.id);
                        ref.invalidate(historyProvider);
                      }
                    },
                  ),
                ],
              ),
            ),
        ]),
      ),
    );
  }
}
