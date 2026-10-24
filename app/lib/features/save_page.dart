// 保存选择：仅保存到本机（加密）或不保存；明示游客数据风险。云备份待实现（仅注册用户）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/session.dart';

class SavePage extends ConsumerWidget {
  const SavePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('是否保存这份报告')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        if (s.synthetic) const Text('提示：这是合成示例报告。', style: TextStyle(color: Colors.red)),
        const Text('游客模式下，记录只能保存在本机：', style: TextStyle(fontSize: 18)),
        const SizedBox(height: 8),
        const ListTile(leading: Icon(Icons.lock_outline), title: Text('保存内容：识别后的指标、问答、解读与对话（加密保存）')),
        const ListTile(leading: Icon(Icons.image_not_supported_outlined), title: Text('不保存报告原图')),
        const ListTile(
          leading: Icon(Icons.warning_amber, color: Colors.orange),
          title: Text('删除 APP、换手机或清除应用数据后，本机记录会丢失，无法找回'),
        ),
        const ListTile(leading: Icon(Icons.cloud_off), title: Text('游客不支持云端备份；注册后可选择云端备份（待实现）')),
        const SizedBox(height: 16),
        if (s.saved)
          const Card(child: ListTile(leading: Icon(Icons.check_circle, color: Colors.green), title: Text('已保存到本机')))
        else
          FilledButton.icon(
            key: const Key('save_local'),
            icon: const Icon(Icons.phone_android),
            label: const Text('保存到本机'),
            onPressed: () async {
              await ref.read(sessionProvider.notifier).saveLocally();
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已加密保存到本机')));
            },
          ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('no_save'),
          icon: const Icon(Icons.exit_to_app),
          label: Text(s.saved ? '返回首页' : '不保存，结束'),
          onPressed: () {
            // 不保存：清除内存中的会话（含原图），不写入任何存储
            ref.read(sessionProvider.notifier).reset();
            context.go('/home');
          },
        ),
      ]),
    );
  }
}
