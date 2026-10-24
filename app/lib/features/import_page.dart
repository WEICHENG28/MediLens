// P02 导入预览：质量提示（模糊/偏暗/反光/分辨率）、旋转、重拍，然后本机 OCR。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/session.dart';
import '../widgets/common.dart';

class ImportPage extends ConsumerWidget {
  const ImportPage({super.key});

  Future<void> _recognize(BuildContext context, WidgetRef ref) async {
    final sw = Stopwatch()..start();
    try {
      await runWithProgress(context, '正在本机识别报告…\n（图片不会上传）', () => ref.read(sessionProvider.notifier).runOcr());
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('识别失败，请重拍或换一张图片（$e）')));
      }
      return;
    }
    if (!context.mounted) return;
    final report = ref.read(sessionProvider).report!;
    debugPrint('[MediLens] 本地 OCR 用时 ${sw.elapsedMilliseconds}ms，识别项目 ${report.items.length}');
    // 有待确认项时 P03 逐项确认；没有时直接显示识别结果汇总，用户核对后进入总览
    context.pushReplacement(report.supported ? '/review' : '/unsupported');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('确认图片')),
      body: Column(children: [
        if (s.synthetic)
          Container(
            width: double.infinity,
            color: const Color(0xFFFFEBEE),
            padding: const EdgeInsets.all(8),
            child: const Text('这是合成示例报告（虚构数据），仅供演示', textAlign: TextAlign.center),
          ),
        for (final w in s.qualityWarnings)
          ListTile(leading: const Icon(Icons.warning_amber, color: Colors.orange), title: Text(w), dense: true),
        Expanded(
          child: s.displayPng == null
              ? const Center(child: Text('没有图片'))
              : InteractiveViewer(maxScale: 5, child: Center(child: Image.memory(s.displayPng!, gaplessPlayback: true))),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              Row(children: [
                Expanded(child: OutlinedButton.icon(icon: const Icon(Icons.rotate_right), label: const Text('旋转'), onPressed: () => ref.read(sessionProvider.notifier).rotate90())),
                const SizedBox(width: 12),
                Expanded(child: OutlinedButton.icon(icon: const Icon(Icons.replay), label: const Text('重拍/重选'), onPressed: () => context.pop())),
              ]),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: const Key('recognize_button'),
                  icon: const Icon(Icons.document_scanner_outlined),
                  label: Text(s.qualityWarnings.isEmpty ? '开始识别' : '仍然识别'),
                  onPressed: () => _recognize(context, ref),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}
