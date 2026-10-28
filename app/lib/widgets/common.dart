import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../core/settings.dart';
import '../core/theme.dart';

/// 资料来源一行：标题、出处与年份、是否经医学审核。
String citationLine(Map c) {
  final status = c['review_status'];
  final reviewed = status == 'reviewed' || status == '已审核';
  final version = (c['source_version'] ?? '').toString();
  return '· ${c['title']}\n  出处：${c['source']}${version.isEmpty ? '' : '（$version）'}'
      '${reviewed ? '' : ' · 未经医学审核'}';
}

/// 「测试规则，未经医学审核」醒目标识：所有展示判读结果的页面都必须显示。
class TestRuleBanner extends StatelessWidget {
  const TestRuleBanner({super.key});
  @override
  Widget build(BuildContext context) => Semantics(
        label: '测试规则，未经医学审核',
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: const Color(0xFFFFF3E0), border: Border.all(color: const Color(0xFFE65100)), borderRadius: BorderRadius.circular(8)),
          child: Row(children: [
            const Icon(Icons.science_outlined, color: Color(0xFFE65100)),
            const SizedBox(width: 8),
            Expanded(
              child: Text('测试规则，未经医学审核 · 仅限合成数据测试，不能用于真实诊疗',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: const Color(0xFFBF360C), fontWeight: FontWeight.w600)),
            ),
          ]),
        ),
      );
}

class DisclaimerText extends StatelessWidget {
  final String? text;
  const DisclaimerText({super.key, this.text});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(text ?? '本结果仅帮助理解报告，不能替代医生诊断。请勿据此自行用药或调整治疗，医生医嘱优先。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black87)),
      );
}

class LevelChip extends ConsumerWidget {
  final String level;
  final String? label;
  const LevelChip(this.level, {super.key, this.label});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final elder = ref.watch(settingsProvider).elder;
    final c = LevelColors.of(level, elder: elder);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20), border: Border.all(color: c)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(LevelColors.icon(level), color: c, size: elder ? 24 : 18),
        const SizedBox(width: 4),
        // 颜色之外同时用文字表达等级，照顾色弱用户
        Text(label ?? LevelColors.label(level), style: TextStyle(color: c, fontWeight: FontWeight.bold)),
      ]),
    );
  }
}

/// 朗读按钮：使用系统 TTS（离线可用，不访问境外服务）。高质量云端语音待实现。
final ttsProvider = Provider<FlutterTts>((ref) {
  final tts = FlutterTts();
  tts.setLanguage('zh-CN');
  return tts;
});

class ReadAloudButton extends ConsumerStatefulWidget {
  final String text;
  const ReadAloudButton(this.text, {super.key});
  @override
  ConsumerState<ReadAloudButton> createState() => _ReadAloudButtonState();
}

class _ReadAloudButtonState extends ConsumerState<ReadAloudButton> {
  bool speaking = false;
  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: speaking ? '停止朗读' : '朗读',
        icon: Icon(speaking ? Icons.stop_circle_outlined : Icons.volume_up_outlined),
        onPressed: () async {
          final tts = ref.read(ttsProvider);
          if (speaking) {
            await tts.stop();
            setState(() => speaking = false);
            return;
          }
          await tts.setSpeechRate(ref.read(settingsProvider).speechRate);
          tts.setCompletionHandler(() {
            if (mounted) setState(() => speaking = false);
          });
          setState(() => speaking = true);
          final r = await tts.speak(widget.text);
          if (r != 1 && mounted) {
            setState(() => speaking = false);
            ScaffoldMessenger.of(this.context).showSnackBar(const SnackBar(content: Text('本机没有可用的中文朗读引擎，请在系统设置中安装')));
          }
        },
      );
}

/// 已确认但本轮待实现的功能页：保留入口与说明，不伪装为可用。
class PendingFeaturePage extends StatelessWidget {
  final String title;
  final String description;
  final List<String> plan;
  const PendingFeaturePage({super.key, required this.title, required this.description, this.plan = const []});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          Row(children: [
            const Icon(Icons.construction, size: 40, color: Colors.orange),
            const SizedBox(width: 12),
            Expanded(child: Text('待实现', style: Theme.of(context).textTheme.headlineSmall)),
          ]),
          const SizedBox(height: 12),
          Text(description, style: Theme.of(context).textTheme.bodyLarge),
          if (plan.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('计划实现内容', style: Theme.of(context).textTheme.titleMedium),
            for (final p in plan) ListTile(leading: const Icon(Icons.check_box_outline_blank), title: Text(p)),
          ],
        ]),
      );
}

Future<T?> runWithProgress<T>(BuildContext context, String message, Future<T> Function() task) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(content: Row(children: [const CircularProgressIndicator(), const SizedBox(width: 20), Expanded(child: Text(message))])),
    ),
  );
  try {
    return await task();
  } finally {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }
}
