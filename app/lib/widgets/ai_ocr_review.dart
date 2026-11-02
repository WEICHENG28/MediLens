import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../core/models.dart';
import '../core/ocr_review.dart';

/// Single-item, explicit-consent assistance. It never mutates the report itself.
class AiOcrReviewCard extends ConsumerStatefulWidget {
  final LabItem item;
  final ValueChanged<String> onConfirm;
  const AiOcrReviewCard({super.key, required this.item, required this.onConfirm});

  @override
  ConsumerState<AiOcrReviewCard> createState() => _AiOcrReviewCardState();
}

class _AiOcrReviewCardState extends ConsumerState<AiOcrReviewCard> {
  bool busy = false;
  Map<String, dynamic>? result;
  String? error;

  Future<void> _request(Map<String, dynamic> payload) async {
    final allowed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('本次 AI 文字核对'),
        content: SingleChildScrollView(child: Column(
          mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('以下文字将经 MediLens 服务器发送到配置的模型平台。它没有读取图片，无法判断报告上真正写了什么。\n\n不发送图片、姓名、医院、日期、单位或参考范围；仅同意本次发送。'),
            const SizedBox(height: 12),
            SelectableText('项目代码：${payload['code']}\n识别文字：${payload['value']}\n候选：${(payload['candidates'] as List).join('、')}'),
          ],
        )),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(key: const Key('ocr_ai_consent'), onPressed: () => Navigator.pop(c, true), child: const Text('同意本次发送')),
        ],
      ),
    );
    if (allowed != true || !mounted) return;
    setState(() { busy = true; error = null; result = null; });
    try {
      final data = await ref.read(apiClientProvider).reviewOcr(payload);
      if (mounted) setState(() => result = data);
    } on ApiException {
      if (mounted) setState(() => error = 'AI 辅助服务暂不可用或尚未更新，您仍可使用上方候选和“无法确认”。原识别结果没有改变。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final payload = ocrReviewPayload(widget.item);
    final candidate = result?['candidate'];
    final canConfirm = result?['status'] == 'ok' && candidate is String &&
        payload != null && (payload['candidates'] as List).contains(candidate);
    return Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('AI 辅助核对（可选）', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        const Text('只核对筛选后的文字，不重新识图，不自动改写结果。拿不准时请保留“无法确认”。'),
        if (payload == null)
          const Text('当前文字无法安全筛选，请使用上方候选或手动更正。')
        else
          TextButton.icon(key: const Key('ocr_ai_request'),
            onPressed: busy ? null : () => _request(payload),
            icon: busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.fact_check_outlined),
            label: Text(busy ? '正在辅助核对…可继续手动确认' : '预览本次发送内容')),
        if (error != null) Text(error!, key: const Key('ocr_ai_error')),
        if (result != null) ...[
          Text(result!['tip'] as String? ?? '请对照原报告核对。'),
          const SizedBox(height: 6),
          Text(result!['notice'] as String? ?? '请对照原报告后确认。'),
          if (canConfirm)
            OutlinedButton(key: const Key('ocr_ai_confirm'),
              onPressed: () => widget.onConfirm(candidate),
              child: Text('我已核对原图，确认：$candidate')),
        ],
      ],
    )));
  }
}
