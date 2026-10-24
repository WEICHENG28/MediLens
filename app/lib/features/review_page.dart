// P03 OCR 识别与局部确认（强制细节）：
// - 对低置信/矛盾字段，在原图正确坐标绘制高亮框，可放大查看；
// - 旁边展示候选供点选；「其他」可手工更正该项；「无法确认」标记 unknown，不参与依赖该值的规则；可重拍；
// - 多个字段逐项处理并显示「第 x/y 项」；不要求重新手填整张报告。

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img;

import '../core/api_client.dart';
import '../core/models.dart';
import '../core/session.dart';
import '../core/settings.dart';
import '../ocr/report_parser.dart';
import '../widgets/common.dart';

class ReviewPage extends ConsumerStatefulWidget {
  const ReviewPage({super.key});
  @override
  ConsumerState<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends ConsumerState<ReviewPage> {
  late final List<LabItem> queue; // 本次需确认的项目（固定顺序，便于显示第 x/y 项）
  int index = 0;

  @override
  void initState() {
    super.initState();
    queue = ref.read(sessionProvider).report?.pendingReview ?? [];
  }

  void _resolve(LabItem item, {String? value, ReviewStatus status = ReviewStatus.confirmed}) {
    ref.read(sessionProvider.notifier).resolveItem(item, value: value, status: status);
    setState(() => index++);
  }

  Future<void> _manual(LabItem item) async {
    final c = TextEditingController(text: item.value);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('更正「${kItemNames[item.code] ?? item.label}」'),
        content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(hintText: '按报告上的写法输入，如 1+、阴性、86.5')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('确定')),
        ],
      ),
    );
    if (v != null && v.isNotEmpty) _resolve(item, value: v);
  }

  Future<void> _toOverview() async {
    final consent = ref.read(settingsProvider).aiConsent;
    if (!consent) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('解读前请确认'),
          content: const Text('为生成解读，将把您确认后的检验指标（项目名、结果、单位、参考范围、检验日期）发送到 MediLens 解读服务。\n\n'
              '· 不发送报告图片、姓名、医院\n· 服务器位于中国大陆\n· 您可在「设置」中查看和撤回'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('不同意')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('同意并继续')),
          ],
        ),
      );
      if (ok != true) return;
      final s = ref.read(settingsProvider);
      await ref.read(settingsProvider.notifier).update(s.copyWith(aiConsent: true));
    }
    if (!mounted) return;
    try {
      await runWithProgress(context, '正在解读…', () => ref.read(sessionProvider.notifier).analyze());
      if (mounted) context.pushReplacement('/overview');
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    final report = s.report;
    if (report == null) return const Scaffold(body: Center(child: Text('没有识别结果')));
    if (index >= queue.length) return _summary(context, s, report);
    final item = queue[index];
    final name = kItemNames[item.code] ?? item.label;
    return Scaffold(
      appBar: AppBar(title: Text('请确认 第 ${index + 1}/${queue.length} 项')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('「$name」需要您确认', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        for (final r in item.reviewReasons) Text('· $r', style: const TextStyle(color: Colors.deepOrange)),
        const SizedBox(height: 12),
        if (s.displayPng != null) _HighlightedImage(png: s.displayPng!, box: item.valueBox ?? item.rowBox),
        const SizedBox(height: 8),
        if (s.ocr != null && (item.rowBox ?? item.valueBox) != null)
          _ZoomCrop(source: s.ocr!.image, box: item.rowBox ?? item.valueBox!),
        const SizedBox(height: 16),
        Text('报告上写的是：', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(spacing: 12, runSpacing: 12, children: [
          for (final c in item.candidates)
            FilledButton.tonal(key: Key('candidate_$c'), onPressed: () => _resolve(item, value: c), child: Text(c, style: const TextStyle(fontSize: 22))),
          OutlinedButton(onPressed: () => _manual(item), child: const Text('其他（手动更正）')),
        ]),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          key: const Key('cannot_confirm'),
          icon: const Icon(Icons.help_outline),
          label: const Text('无法确认（该项不参与判断）'),
          onPressed: () => _resolve(item, status: ReviewStatus.unknown),
        ),
        const SizedBox(height: 8),
        TextButton.icon(icon: const Icon(Icons.photo_camera_outlined), label: const Text('重拍'), onPressed: () => context.go('/home')),
      ]),
    );
  }

  Widget _summary(BuildContext context, ReportSession s, ParsedReport report) {
    String st(LabItem i) => switch (i.status) {
          ReviewStatus.autoAccepted => '已识别',
          ReviewStatus.confirmed => '已确认',
          ReviewStatus.unknown => '无法确认',
          ReviewStatus.excluded => '已排除',
          ReviewStatus.needsConfirmation => '待确认',
        };
    return Scaffold(
      appBar: AppBar(title: const Text('识别结果')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (s.synthetic) const Text('合成示例报告（虚构数据）', style: TextStyle(color: Colors.red)),
        Text('检验日期：${report.testDate ?? '未识别'}'),
        const SizedBox(height: 8),
        for (final i in report.items)
          Card(
            child: ListTile(
              title: Text(kItemNames[i.code] ?? i.label),
              subtitle: Text([i.value ?? '—', if (i.unit != null) i.unit!, if (i.reference != null) '参考 ${i.reference}'].join('  ')),
              trailing: Text(st(i), style: TextStyle(color: i.status == ReviewStatus.unknown ? Colors.grey : null)),
            ),
          ),
        if (report.otherLabels.isNotEmpty) Text('以下项目不在首期支持范围，不做解读：${report.otherLabels.join('、')}'),
      ]),
      // 主要操作固定在底部，长列表（尤其老年模式）无需滚动即可点到
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton(key: const Key('to_overview'), onPressed: _toOverview, child: const Text('查看解读')),
        ),
      ),
    );
  }
}

/// 在正向图像上按归一化坐标绘制高亮框（图像与 OCR 坐标同一坐标系，避免框错行）。
class _HighlightedImage extends StatelessWidget {
  final Uint8List png;
  final NormBox? box;
  const _HighlightedImage({required this.png, required this.box});

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        return FutureBuilder<ImageInfo>(
          future: _info(),
          builder: (context, snap) {
            if (!snap.hasData) return const SizedBox(height: 200, child: Center(child: CircularProgressIndicator()));
            final w = snap.data!.image.width, h = snap.data!.image.height;
            return ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                height: math.min(320, c.maxWidth * h / w),
                child: InteractiveViewer(
                  maxScale: 6,
                  child: AspectRatio(
                    aspectRatio: w / h,
                    child: Stack(fit: StackFit.expand, children: [
                      Image.memory(png, fit: BoxFit.fill),
                      if (box != null) CustomPaint(painter: _BoxPainter(box!)),
                    ]),
                  ),
                ),
              ),
            );
          },
        );
      });

  Future<ImageInfo> _info() {
    final completer = Completer<ImageInfo>();
    MemoryImage(png).resolve(const ImageConfiguration()).addListener(ImageStreamListener((i, _) => completer.complete(i)));
    return completer.future;
  }
}

class _BoxPainter extends CustomPainter {
  final NormBox b;
  _BoxPainter(this.b);
  @override
  void paint(Canvas canvas, Size s) {
    final r = Rect.fromLTWH(b.x * s.width, b.y * s.height, b.w * s.width, b.h * s.height).inflate(4);
    canvas.drawRect(r, Paint()..color = const Color(0x55FFEB3B));
    canvas.drawRect(r, Paint()
      ..color = const Color(0xFFE53935)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3);
  }

  @override
  bool shouldRepaint(_BoxPainter o) => o.b != b;
}

/// 局部放大：裁出该行附近区域放大显示。
class _ZoomCrop extends StatelessWidget {
  final img.Image source;
  final NormBox box;
  const _ZoomCrop({required this.source, required this.box});

  @override
  Widget build(BuildContext context) {
    final padX = 0.05, padY = 0.02;
    final x = ((box.x - padX).clamp(0.0, 1.0) * source.width).round();
    final y = ((box.y - padY).clamp(0.0, 1.0) * source.height).round();
    final w = (((box.w + 2 * padX).clamp(0.0, 1.0)) * source.width).round().clamp(1, source.width - x);
    final h = (((box.h + 2 * padY).clamp(0.0, 1.0)) * source.height).round().clamp(1, source.height - y);
    final crop = img.copyCrop(source, x: x, y: y, width: w, height: h);
    return Container(
      decoration: BoxDecoration(border: Border.all(color: Colors.red, width: 2), borderRadius: BorderRadius.circular(8)),
      child: Column(children: [
        const Padding(padding: EdgeInsets.all(4), child: Text('局部放大')),
        Image.memory(img.encodePng(crop), fit: BoxFit.fitWidth, width: double.infinity),
      ]),
    );
  }
}
