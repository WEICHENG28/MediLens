import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import '../core/medication_names.dart';
import '../core/medication_records.dart';
import 'medication_records_page.dart';
import 'package:go_router/go_router.dart';
import '../core/models.dart';
import '../ocr/image_tools.dart';
import '../ocr/ocr_engine.dart';

abstract class MedicationImages {
  Future<Uint8List?> pick(ImageSource source);
}
class SystemMedicationImages implements MedicationImages {
  @override Future<Uint8List?> pick(ImageSource source) async {
    final file = await ImagePicker().pickImage(source: source, maxWidth: 2400, maxHeight: 2400, imageQuality: 95);
    return file == null ? null : await file.readAsBytes();
  }
}
final medicationImagesProvider = Provider<MedicationImages>((ref) => SystemMedicationImages());
// Own OCR instance: medication scans cannot replace a report session or race its model initialization.
class QueuedMedicationOcr implements OcrEngine {
  final OcrEngine engine;
  Future<void> tail = Future.value();
  QueuedMedicationOcr(this.engine);
  @override Future<OcrResult> recognize(img.Image source, {int rotation = 0, bool autoOrient = true}) {
    final result = tail.then((_) => engine.recognize(source, rotation: rotation, autoOrient: autoOrient));
    tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
final medicationOcrProvider = Provider<OcrEngine>((ref) => QueuedMedicationOcr(OnnxOcrEngine()));

class MedicationPage extends ConsumerStatefulWidget {
  const MedicationPage({super.key});
  @override ConsumerState<MedicationPage> createState() => _MedicationPageState();
}
class _MedicationPageState extends ConsumerState<MedicationPage> {
  img.Image? source;
  Uint8List? preview;
  int rotation = 0;
  bool busy = false, confirmed = false, scanned = false;
  String? message;
  List<String> warnings = [];
  List<OcrLine> lines = [];
  List<MedicationCandidate> candidates = [];
  final selected = <String>{};
  NormBox? highlight;
  void clearResults() { confirmed = false; scanned = false; lines = []; candidates = []; selected.clear(); highlight = null; message = null; }
  Future<void> pick(ImageSource from) async {
    setState(() { busy = true; message = null; });
    try {
      final bytes = await ref.read(medicationImagesProvider).pick(from);
      if (!mounted || bytes == null) return;
      final image = decodeImageBytes(bytes);
      if (image == null) throw const FormatException();
      final png = img.encodePng(image), quality = checkQuality(image);
      if (!mounted) return;
      setState(() { clearResults(); source = image; preview = png; rotation = 0; warnings = quality.warnings; });
    } catch (_) {
      if (mounted) setState(() { message = '无法读取图片或未获相机/相册权限，请检查系统权限后重试。'; });
    } finally { if (mounted) setState(() => busy = false); }
  }
  void turn() {
    if (source == null) return;
    setState(() { rotation = (rotation + 90) % 360; preview = img.encodePng(rotate(source!, rotation)); clearResults(); });
  }
  Future<void> scan(MedicationDictionary dictionary) async {
    if (source == null || busy) return;
    setState(() { clearResults(); busy = true; });
    try {
      final result = await ref.read(medicationOcrProvider).recognize(source!, rotation: rotation, autoOrient: false);
      if (!mounted) return;
      final matches = medicationCandidates(result.lines, dictionary);
      setState(() { lines = result.lines; candidates = matches; scanned = true; preview = img.encodePng(result.image); });
    } catch (_) {
      if (mounted) setState(() { message = '本机识别未能完成，请重拍或换图重试。图片没有上传。'; });
    } finally { if (mounted) setState(() => busy = false); }
  }
  Future<void> confirmNames() async {
    final accepted = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('请对照包装完整通用名'),
      content: Text('${selected.join('、')}\n\n已核对包括“缓释”等字样的完整名称？这只确认文字，不代表正在服用，不会添加提醒或回答报告问卷。'),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('继续核对')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('名称一致'))]));
    if (mounted && accepted == true) setState(() => confirmed = true);
  }
  Future<void> saveNames(MedicationDictionary dictionary) async {
    if (!confirmed || busy || selected.isEmpty) return;
    final use = await chooseMedicationUse(context, selected.join('、'));
    if (!mounted || use == null || !confirmed) return;
    setState(() => busy = true);
    try {
      await ref.read(medicationRecordsProvider).save(candidates.where((c) => selected.contains(c.entry.name)).toList(), dictionary, use);
      if (!mounted) return;
      ref.invalidate(savedMedicationsProvider);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('药名已保存到本机。同名记录已合并；未新增提醒或报告答案。')));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('药名未能保存，原记录保留，请重试。')));
    } finally { if (mounted) setState(() => busy = false); }
  }
  @override Widget build(BuildContext context) {
    final dictionary = ref.watch(medicationDictionaryProvider);
    return Scaffold(appBar: AppBar(title: const Text('药盒药名辅助识别')), body: ListView(padding: const EdgeInsets.all(16), children: [
      const Text('一次拍一个药盒的完整通用名区域，保持正向、清晰，避开反光。图片只在本机处理；识别结果须人工核对，不判断药品真伪或是否适合您服用。'),
      TextButton.icon(onPressed: busy ? null : () => context.push('/medications-saved'), icon: const Icon(Icons.list_alt_outlined), label: const Text('查看本机药名记录')),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(key: const Key('med_camera'), onPressed: busy ? null : () => pick(ImageSource.camera), icon: const Icon(Icons.photo_camera_outlined), label: const Text('拍药盒')),
        OutlinedButton.icon(key: const Key('med_gallery'), onPressed: busy ? null : () => pick(ImageSource.gallery), icon: const Icon(Icons.photo_library_outlined), label: const Text('从相册选图')),
        if (source != null) OutlinedButton.icon(onPressed: busy ? null : turn, icon: const Icon(Icons.rotate_right), label: const Text('旋转图片')),
      ]),
      if (busy) const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Column(children: [LinearProgressIndicator(), Text('正在本机处理，请稍候；返回可离开，识别不会自动保存。')])),
      if (message != null) Text(message!, key: const Key('med_error')),
      for (final warning in warnings) Text('· $warning'),
      if (preview != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: SizedBox(height: 280,
        child: InteractiveViewer(maxScale: 6, child: Center(child: AspectRatio(aspectRatio: (rotation % 180 == 0 ? source!.width / source!.height : source!.height / source!.width),
          child: Stack(fit: StackFit.expand, children: [Image.memory(preview!, fit: BoxFit.fill), if (highlight != null) CustomPaint(painter: _MedicationBox(highlight!))])))))),
      dictionary.when(loading: () => const Text('正在读取本机药名词表…'), error: (_, _) => Column(children: [const Text('药名词表读取失败，暂不识别，请重试。'), TextButton(onPressed: () => ref.invalidate(medicationDictionaryProvider), child: const Text('重新读取词表'))]), data: (d) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('本机小型词表：${d.entries.length} 个完整药名。未覆盖名称、商品名、复方、手写处方和特殊后缀本阶段不匹配。'),
        FilledButton.icon(key: const Key('med_scan'), onPressed: source == null || busy ? null : () => scan(d), icon: const Icon(Icons.document_scanner_outlined), label: const Text('开始本机识别')),
        if (scanned) ...[
          const SizedBox(height: 12),
          Text(candidates.isEmpty ? '没有找到可供确认的药名。请重拍完整通用名；也可能是当前词表尚未覆盖，不能据此认定不是药品。' : '以下只是文字候选，请逐项对照原图。OCR 分数不是药名正确率。'),
          for (final candidate in candidates) Card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CheckboxListTile(key: ValueKey('med_${candidate.entry.name}'), title: Text(candidate.entry.name),
              subtitle: Text('识别原文：${candidate.evidence.text}\nOCR 分数：${candidate.evidence.confidence.toStringAsFixed(2)} · ${confirmed && selected.contains(candidate.entry.name) ? '本次已人工核对' : '待人工核对'}'),
              value: selected.contains(candidate.entry.name), onChanged: busy ? null : (v) => setState(() { confirmed = false; highlight = candidate.evidence.box; if (v == true) { selected.add(candidate.entry.name); } else { selected.remove(candidate.entry.name); } })),
            TextButton(onPressed: () => setState(() => highlight = candidate.evidence.box), child: const Text('在原图标出这一行')),
            Padding(padding: const EdgeInsets.all(12), child: SelectableText('名称出处：${candidate.entry.sourceTitle}\n${candidate.entry.sourceUrl}\n资料日期：${candidate.entry.sourceDate}；名称检索核对：${candidate.entry.checkedAt}（官方搜索索引）\n仅核对名称来源，未经医学审核，不表示当前注册状态或产品真伪已核验。')),
          ])),
          if (candidates.isNotEmpty) FilledButton(key: const Key('med_confirm'), onPressed: selected.isEmpty || confirmed || busy ? null : confirmNames, child: const Text('确认所选药名')),
          if (confirmed) ...[Text('本次已核对药名：${selected.join('、')}\n未主动保存前仅本页显示，不代表正在服用；保存后也不会自动填写报告答案或生成提醒。', key: const Key('med_confirmed')),
            OutlinedButton(key: const Key('med_save'), onPressed: busy ? null : () => saveNames(d), child: const Text('选择使用情况并保存到本机'))],
          ExpansionTile(title: Text('查看识别原文（${lines.length} 行）'), children: [
            const Padding(padding: EdgeInsets.all(12), child: Text('低分、未完整匹配或不在词表内的文字不会推断药名；不同文字行不会拼接猜测。')),
            for (final line in lines) ListTile(title: SelectableText(line.text), subtitle: Text('OCR 分数 ${line.confidence.toStringAsFixed(2)}')),
          ]),
        ],
        ExpansionTile(title: const Text('查看首版词表及边界'), children: [
          SelectableText('${d.scope}\n版本：${d.version}\n名称检索核对：${d.checkedAt}\n${d.entries.map((e) => e.name).join('、')}\n只匹配完整一行，不自动合并剂型、补字或纠错；含规格同一行时也可能无法匹配。\n已可主动保存核对后的药名并单独确认使用情况；本阶段不自动分类或联动问卷。'),
        ]),
      ])),
    ]));
  }
}
class _MedicationBox extends CustomPainter {
  final NormBox box;
  _MedicationBox(this.box);
  @override void paint(Canvas canvas, Size size) {
    canvas.drawRect(Rect.fromLTWH(box.x * size.width, box.y * size.height, box.w * size.width, box.h * size.height), Paint()..color = Colors.blue..style = PaintingStyle.stroke..strokeWidth = 3);
  }
  @override bool shouldRepaint(covariant _MedicationBox oldDelegate) => oldDelegate.box != box;
}
