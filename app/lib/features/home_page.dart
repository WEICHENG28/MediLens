// 主页：突出「拍照解读」，次级「相册」「文件」「合成示例」；历史、语音、药盒、设置入口。

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pdfx/pdfx.dart';

import '../core/session.dart';
import '../ocr/ocr_engine.dart';
import '../widgets/common.dart';

/// 文件格式白名单（交接说明 P02：至少常见图片与 PDF）。
const allowedExtensions = ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'pdf'];

bool isAllowedFile(String name) => allowedExtensions.contains(name.split('.').last.toLowerCase());

const syntheticSamples = {
  '01_normal_urinalysis': '正常尿常规',
  '02_glucose_ketone': '尿糖+尿酮体阳性',
  '03_protein_ambiguous': '尿蛋白被遮挡（需确认）',
  '04_uacr_infection': 'UACR 升高 + 感染指标',
  '05_uacr_mgmmol': 'UACR（mg/mmol 单位）',
  '06_missing_reference': '缺少参考范围',
  '07_non_target_liver': '非尿检报告（肝功能）',
  '08_rotated_glucose_ketone': '横置拍摄的报告',
};

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  Future<void> _loadBytes(BuildContext context, WidgetRef ref, Uint8List bytes, {bool synthetic = false}) async {
    final image = await runWithProgress(context, '正在读取图片…', () async => decodeImageBytes(bytes));
    if (!context.mounted) return;
    if (image == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('无法读取这张图片，请换一张或重拍')));
      return;
    }
    ref.read(sessionProvider.notifier).setImage(image, synthetic: synthetic);
    context.push('/import');
  }

  Future<void> _pickImage(BuildContext context, WidgetRef ref, ImageSource source) async {
    try {
      final x = await ImagePicker().pickImage(source: source, imageQuality: 95, maxWidth: 3000);
      if (x == null) return;
      final bytes = await x.readAsBytes();
      if (context.mounted) await _loadBytes(context, ref, bytes);
    } on PlatformException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.code.contains('denied') ? '没有相机/相册权限，可在系统设置中开启' : '无法打开：${e.message}')));
      }
    }
  }

  Future<void> _pickFile(BuildContext context, WidgetRef ref) async {
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: allowedExtensions);
    if (f == null || !context.mounted) return;
    if (!isAllowedFile(f.name)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('不支持该文件格式，请选择图片或 PDF')));
      return;
    }
    var bytes = await f.readAsBytes();
    if (!context.mounted) return;
    if (f.name.toLowerCase().endsWith('.pdf')) {
      // PDF：渲染第 1 页为图片后在本机识别（多页 PDF 逐页处理待完善）
      final rendered = await runWithProgress(context, '正在读取 PDF…', () async {
        final doc = await PdfDocument.openData(bytes);
        final page = await doc.getPage(1);
        final pageImg = await page.render(width: page.width * 2, height: page.height * 2, format: PdfPageImageFormat.png, backgroundColor: '#FFFFFF');
        await page.close();
        final pages = doc.pagesCount;
        await doc.close();
        return (pageImg?.bytes, pages);
      });
      if (!context.mounted || rendered == null) return;
      if (rendered.$1 == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('无法读取该 PDF')));
        return;
      }
      if (rendered.$2 > 1) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('该 PDF 共 ${rendered.$2} 页，当前先识别第 1 页')));
      }
      bytes = rendered.$1!;
    }
    if (context.mounted) await _loadBytes(context, ref, bytes);
  }

  Future<void> _pickSample(BuildContext context, WidgetRef ref) async {
    final key = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const ListTile(title: Text('合成示例报告（虚构数据，仅供演示）')),
          for (final e in syntheticSamples.entries)
            ListTile(leading: const Icon(Icons.description_outlined), title: Text(e.value), onTap: () => Navigator.pop(c, e.key)),
        ]),
      ),
    );
    if (key == null || !context.mounted) return;
    final data = await rootBundle.load('assets/fixtures/$key.synthetic.png');
    if (context.mounted) await _loadBytes(context, ref, data.buffer.asUint8List(), synthetic: true);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('MediLens'), actions: [
        IconButton(tooltip: '设置', icon: const Icon(Icons.settings_outlined), onPressed: () => context.push('/settings')),
      ]),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Text('上传尿常规或 UACR 报告', style: t.titleLarge),
        const SizedBox(height: 4),
        Text('图片只在本机识别，不会上传', style: t.bodyMedium),
        const SizedBox(height: 20),
        SizedBox(
          height: 120,
          child: FilledButton.icon(
            key: const Key('camera_button'),
            icon: const Icon(Icons.photo_camera, size: 40),
            label: const Text('拍照解读', style: TextStyle(fontSize: 24)),
            onPressed: () => _pickImage(context, ref, ImageSource.camera),
          ),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: OutlinedButton.icon(icon: const Icon(Icons.photo_library_outlined), label: const Text('从相册选择'), onPressed: () => _pickImage(context, ref, ImageSource.gallery))),
          const SizedBox(width: 12),
          Expanded(child: OutlinedButton.icon(icon: const Icon(Icons.folder_open), label: const Text('选择文件'), onPressed: () => _pickFile(context, ref))),
        ]),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('sample_button'),
          icon: const Icon(Icons.science_outlined),
          label: const Text('体验合成示例报告（演示用）'),
          onPressed: () => _pickSample(context, ref),
        ),
        const Divider(height: 40),
        _entry(context, Icons.history, '历史记录', '本机保存的报告', '/history'),
        _entry(context, Icons.question_answer_outlined, '复诊问题', '整理要问医生的问题', '/doctor'),
        _entry(context, Icons.mic_none, '语音对话', '实时语音、可打断（待实现）', '/voice'),
        _entry(context, Icons.medication_outlined, '药盒识别', '拍药盒辅助识别（待实现）', '/medication'),
        _entry(context, Icons.alarm, '复查提醒', '根据医嘱设置提醒（待实现）', '/reminder'),
      ]),
    );
  }

  Widget _entry(BuildContext context, IconData icon, String title, String sub, String route) => Card(
        child: ListTile(leading: Icon(icon), title: Text(title), subtitle: Text(sub), trailing: const Icon(Icons.chevron_right), onTap: () => context.push(route)),
      );
}
