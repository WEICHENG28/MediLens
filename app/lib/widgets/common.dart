import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';
import '../core/speech.dart';

import '../core/settings.dart';
import '../core/theme.dart';

/// 资料来源一行：标题、出处与年份、是否经医学审核。
String citationLine(Map c) {
  final status = c['review_status'];
  final reviewed = status == 'reviewed' || status == '已审核';
  final version = (c['source_version'] ?? '').toString();
  final uri = Uri.tryParse((c['source_url'] ?? '').toString());
  final url = uri != null && uri.scheme == 'https' && uri.host.isNotEmpty ? uri.toString() : '';
  final checked = (c['checked_at'] ?? '').toString();
  return '· ${c['title']}\n  出处：${c['source']}${version.isEmpty ? '' : '（$version）'}'
      '${reviewed ? '' : ' · 未经医学审核'}'
      '${url.isEmpty ? '' : '\n  原始出处：$url'}'
      '${checked.isEmpty ? '' : '\n  网页核对：$checked（不代表医学审核）'}';
}

/// 资料来源：默认收起，只显示一行「资料来源（n 条）」；点击后展开逐条出处。
class CitationsBox extends StatelessWidget {
  final List cites;
  final Color? textColor;
  const CitationsBox(this.cites, {super.key, this.textColor});

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: textColor);
    return Theme(
      // 去掉 ExpansionTile 默认的上下分隔线
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: Material(
        color: Colors.transparent,
        child: ExpansionTile(
        key: const Key('citations'),
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        dense: true,
        visualDensity: VisualDensity.compact,
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        leading: Icon(Icons.menu_book_outlined, size: 18, color: textColor),
        title: Text('资料来源（${cites.length} 条）· 点击查看', style: small?.copyWith(fontWeight: FontWeight.bold)),
        children: [
          for (final c in cites) Padding(padding: const EdgeInsets.only(bottom: 6), child: SelectableText(citationLine(c as Map), style: small)),
        ],
        ),
      ),
    );
  }
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

/// 所有页面共享一个系统朗读会话；离开当前按钮或进入后台时停止。
class ReadAloudButton extends ConsumerStatefulWidget {
  final String text;
  final bool autoRead;
  const ReadAloudButton(this.text, {super.key, this.autoRead = false});
  @override ConsumerState<ReadAloudButton> createState() => _ReadAloudButtonState();
}
class _ReadAloudButtonState extends ConsumerState<ReadAloudButton> with WidgetsBindingObserver, RouteAware {
  late SpeechNotifier speech;
  late final String owner = 'read_${identityHashCode(this)}';
  bool foreground = true;
  String? spokenAuto, pendingAuto;
  int autoGeneration = 0;
  void cancelPending() { ++autoGeneration; pendingAuto = null; }
  bool get visible => foreground && ModalRoute.of(context)?.isCurrent != false;
  void scheduleAuto(bool enabled) {
    if (!widget.autoRead || !enabled || !visible) return;
    final text = widget.text.trim();
    if (text.isEmpty || text == spokenAuto || text == pendingAuto) return;
    final ticket = ++autoGeneration;
    pendingAuto = text;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ticket != autoGeneration) return;
      pendingAuto = null;
      if (!widget.autoRead || !visible || !ref.read(settingsProvider).autoRead || widget.text.trim() != text) return;
      spokenAuto = text;
      unawaited(speech.speak(text, owner));
    });
  }
  @override void initState() { super.initState(); speech = ref.read(speechProvider.notifier); foreground = (WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed) == AppLifecycleState.resumed; WidgetsBinding.instance.addObserver(this); }
  @override void didChangeDependencies() { super.didChangeDependencies(); final route = ModalRoute.of(context); if (route != null) speechRoutes.subscribe(this, route); }
  @override void didPushNext() { cancelPending(); unawaited(Future.microtask(() => speech.stop(owner: owner))); }
  @override void didPopNext() { if (mounted) setState(() {}); }
  @override void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) { cancelPending(); unawaited(speech.stop(owner: owner)); }
    else if (mounted) { setState(() {}); }
  }
  @override void dispose() { WidgetsBinding.instance.removeObserver(this); speechRoutes.unsubscribe(this); unawaited(Future.microtask(() => speech.stop(owner: owner))); super.dispose(); }
  @override Widget build(BuildContext context) {
    final enabled = ref.watch(settingsProvider.select((s) => s.autoRead));
    ref.listen<bool>(settingsProvider.select((s) => s.autoRead), (previous, next) {
      if (!next && widget.autoRead) {
        cancelPending(); spokenAuto = null;
        unawaited(Future.microtask(() => speech.stop(owner: owner)));
      }
    });
    scheduleAuto(enabled);
    ref.listen(speechProvider, (previous, next) {
      if (next.owner == owner && next.message != null && next.message != previous?.message) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(next.message!)));
      }
    });
    final state = ref.watch(speechProvider);
    final active = state.owner == owner && (state.speaking || state.loading);
    return IconButton(tooltip: active ? '停止朗读' : '朗读',
      icon: Icon(active ? Icons.stop_circle_outlined : Icons.volume_up_outlined),
      onPressed: () async {
        cancelPending(); spokenAuto = widget.text.trim();
        if (active) { await speech.stop(owner: owner); return; }
        await speech.speak(widget.text, owner);
      });
  }
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
