// P06 文字对话：快捷问题为主，自由输入为辅；越界问题（停药/确诊）由服务端安全模板回答。
// 与语音模式（待实现）共享同一会话。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/session.dart';
import '../widgets/common.dart';

class ChatPage extends ConsumerStatefulWidget {
  final String? focus;
  const ChatPage({super.key, this.focus});
  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final controller = TextEditingController();
  bool sending = false;

  Future<void> _send(String text, {String? quick}) async {
    if (text.trim().isEmpty || sending) return;
    setState(() => sending = true);
    controller.clear();
    await ref.read(sessionProvider.notifier).sendChat(text.trim(), focus: widget.focus, quick: quick);
    if (mounted) setState(() => sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    final quicks = [
      ('这个指标是什么', null),
      ('哪些指标有关', 'related'),
      ('复诊问什么', 'doctor'),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(widget.focus == null ? '提问' : '关于 ${widget.focus} 提问'), actions: [
        IconButton(tooltip: '语音对话（待实现）', icon: const Icon(Icons.mic_none), onPressed: () => context.push('/voice')),
      ]),
      body: Column(children: [
        const Padding(padding: EdgeInsets.fromLTRB(12, 8, 12, 0), child: TestRuleBanner()),
        Expanded(
          child: ListView(padding: const EdgeInsets.all(12), children: [
            if (s.messages.isEmpty) const Text('可以点下面的常用问题，或直接输入。', style: TextStyle(color: Colors.black54)),
            for (final m in s.messages) _Bubble(m),
            if (sending) const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator()),
          ]),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(children: [
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final q in quicks) ActionChip(key: Key('quick_${q.$1}'), label: Text(q.$1), onPressed: () => _send(q.$1, quick: q.$2)),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: TextField(
                    key: const Key('chat_input'),
                    controller: controller,
                    maxLength: 500,
                    decoration: const InputDecoration(hintText: '输入您的问题', counterText: '', border: OutlineInputBorder()),
                    onSubmitted: _send,
                  ),
                ),
                IconButton(key: const Key('chat_send'), icon: const Icon(Icons.send), onPressed: () => _send(controller.text)),
              ]),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _Bubble extends StatelessWidget {
  final ChatMessage m;
  const _Bubble(this.m);
  @override
  Widget build(BuildContext context) {
    final user = m.role == 'user';
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
        decoration: BoxDecoration(
          color: user ? Theme.of(context).colorScheme.primaryContainer : (m.safetyCategory != null ? const Color(0xFFFFF8E1) : Colors.grey.shade100),
          borderRadius: BorderRadius.circular(12),
        ),
        child: DefaultTextStyle.merge(
          // 用户气泡底色随主题变化（老年模式为深色），文字使用配对颜色；其他气泡为固定浅底色，文字固定深色
          style: TextStyle(color: user ? Theme.of(context).colorScheme.onPrimaryContainer : Colors.black87),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (m.safetyCategory != null)
            const Text('安全提示', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFFE65100))),
          Text(m.content),
          if (!user) ...[
            if (m.citations.isNotEmpty) Text('资料来源', style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.bold)),
            for (final c in m.citations) Text(citationLine(c), style: Theme.of(context).textTheme.bodySmall),
            Row(mainAxisSize: MainAxisSize.min, children: [
              ReadAloudButton(m.content),
              if (m.usedFallback) Text('（使用经规则约束的标准说明）', style: Theme.of(context).textTheme.bodySmall),
            ]),
          ],
        ]),
        ),
      ),
    );
  }
}
