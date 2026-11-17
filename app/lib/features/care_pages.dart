// 照护的三个页面：周报、复诊摘要（可存成图片或复制文字给医生）、问照护助理。
// 资料来自照护核心；每次只发送记录的时间、类型与数值，不含身份信息。

import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../widgets/care_charts.dart';

/// 照护请求的共同内容（记录、用药时间、目标范围）。
typedef CareBody = Map<String, dynamic>;

class _Loader extends ConsumerStatefulWidget {
  final String title;
  final Future<Map<String, dynamic>> Function(ApiClient api) load;
  final Widget Function(BuildContext, Map<String, dynamic>) builder;
  final List<Widget> Function(Map<String, dynamic>)? actions;
  const _Loader({required this.title, required this.load, required this.builder, this.actions});
  @override
  ConsumerState<_Loader> createState() => _LoaderState();
}

class _LoaderState extends ConsumerState<_Loader> {
  late Future<Map<String, dynamic>> data = widget.load(ref.read(apiClientProvider));
  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, dynamic>>(
        future: data,
        builder: (context, s) => Scaffold(
          appBar: AppBar(title: Text(widget.title), actions: s.hasData && widget.actions != null ? widget.actions!(s.data!) : null),
          body: s.hasData
              ? widget.builder(context, s.data!)
              : Center(child: s.hasError
                  ? Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text('${s.error}', textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton(onPressed: () => setState(() => data = widget.load(ref.read(apiClientProvider))), child: const Text('重试')),
                    ]))
                  : const CircularProgressIndicator()),
        ),
      );
}

// ---------- 周报 ----------

class WeeklyPage extends StatelessWidget {
  final CareBody body;
  const WeeklyPage({super.key, required this.body});
  @override
  Widget build(BuildContext context) => _Loader(
        title: '本周周报',
        load: (api) => api.careWeekly(body),
        builder: (context, w) {
          final small = Theme.of(context).textTheme.bodySmall;
          String fmt(Object? v) => v == null ? '—' : '$v';
          return ListView(padding: const EdgeInsets.all(16), children: [
            Text('${w['start']} 至 ${w['end']}', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final l in ((w['lines'] as List?) ?? const [])) Text('· $l', style: const TextStyle(height: 1.45)),
            const SizedBox(height: 12),
            Table(
              key: const Key('weekly_table'),
              border: TableBorder.all(color: const Color(0xFFE0D6CC)),
              columnWidths: const {0: FlexColumnWidth(2), 1: FlexColumnWidth(1), 2: FlexColumnWidth(1)},
              children: [
                const TableRow(decoration: BoxDecoration(color: Color(0xFFFFF4EA)), children: [
                  Padding(padding: EdgeInsets.all(8), child: Text('项目', style: TextStyle(fontWeight: FontWeight.bold))),
                  Padding(padding: EdgeInsets.all(8), child: Text('本周', style: TextStyle(fontWeight: FontWeight.bold))),
                  Padding(padding: EdgeInsets.all(8), child: Text('上周', style: TextStyle(fontWeight: FontWeight.bold))),
                ]),
                for (final c in ((w['compare'] as List?) ?? const []).cast<Map<String, dynamic>>())
                  TableRow(children: [
                    Padding(padding: const EdgeInsets.all(8), child: Text('${c['label']}')),
                    Padding(padding: const EdgeInsets.all(8), child: Text(fmt(c['this_week']))),
                    Padding(padding: const EdgeInsets.all(8), child: Text(fmt(c['last_week']))),
                  ]),
              ],
            ),
            if (w['goal'] is Map) ...[
              const SizedBox(height: 16),
              Text('小目标：${w['goal']['goal']['title']}', style: Theme.of(context).textTheme.titleSmall),
              Text('${w['goal']['verdict']}：${w['goal']['text']}'),
            ],
            const SizedBox(height: 16),
            Text('目前的整理', style: Theme.of(context).textTheme.titleSmall),
            for (final f in ((w['findings'] as List?) ?? const []).cast<Map<String, dynamic>>())
              Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text('· ${f['headline']}')),
            const SizedBox(height: 12),
            Text('「关联」只代表相关，不代表原因；这不是诊断，也不是用药建议。', style: small),
          ]);
        },
      );
}

// ---------- 复诊摘要 ----------

class VisitSummaryPage extends StatefulWidget {
  final CareBody body;
  const VisitSummaryPage({super.key, required this.body});
  @override
  State<VisitSummaryPage> createState() => _VisitSummaryPageState();
}

class _VisitSummaryPageState extends State<VisitSummaryPage> {
  final boundary = GlobalKey();

  static String asText(Map<String, dynamic> v) {
    List<String> l(String k) => ((v[k] as List?) ?? const []).cast<String>();
    final lab = (v['lab'] as Map?)?.cast<String, dynamic>();
    const pm = {'breakfast': '早餐后', 'lunch': '午餐后', 'dinner': '晚餐后'};
    final b = StringBuffer('MediLens 复诊摘要（${v['start']} 至 ${v['end']}）\n');
    if (lab != null) {
      b.writeln('医院检验（${v['lab_date'] ?? ''}）：${[
        if (lab['hba1c'] != null) '糖化血红蛋白 ${lab['hba1c']}%',
        if (lab['fpg'] != null) '空腹血糖 ${lab['fpg']}',
        if (lab['clinic_sbp'] != null) '诊间血压 ${(lab['clinic_sbp'] as num).round()}/${(lab['clinic_dbp'] as num?)?.round() ?? '—'}',
      ].join('｜')}');
    }
    for (final o in l('overview')) {
      b.writeln(o);
    }
    final p = (v['post_meal'] as Map?) ?? const {};
    if (p.isNotEmpty) b.writeln('餐后 2 小时中位数：${[for (final k in pm.keys) if (p[k] != null) '${pm[k]} ${p[k]}'].join('、')}');
    void sec(String t, List<String> xs, {bool numbered = false}) {
      if (xs.isEmpty) return;
      b.writeln('\n【$t】');
      for (final (i, x) in xs.indexed) {
        b.writeln(numbered ? '${i + 1}. $x' : '· $x');
      }
    }
    sec('确认的事实', l('facts'));
    sec('多次出现的关联（不代表原因）', l('associations'));
    sec('想请教医生', l('questions'), numbered: true);
    sec('目前还不能判断', l('cannot_judge'));
    b.writeln('\n${v['note'] ?? ''}');
    return b.toString();
  }

  Future<void> _saveImage() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final obj = boundary.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (obj == null) return;
      final img = await obj.toImage(pixelRatio: 2.5);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) return;
      final uri = await FilePicker.saveFile(fileName: 'MediLens_复诊摘要.png', bytes: png.buffer.asUint8List(), mimeType: 'image/png',
          dialogTitle: '保存复诊摘要');
      if (uri != null) messenger.showSnackBar(const SnackBar(content: Text('已保存，可以在相册或文件里找到')));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('保存没有成功，可以改用「复制文字」')));
    }
  }

  @override
  Widget build(BuildContext context) => _Loader(
        title: '复诊摘要',
        load: (api) => api.careVisit({...widget.body, 'days': 14}),
        actions: (v) => [
          IconButton(key: const Key('visit_copy'), tooltip: '复制文字', icon: const Icon(Icons.copy),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: asText(v)));
                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制，可以贴到微信或备忘录')));
              }),
          IconButton(key: const Key('visit_save'), tooltip: '存成图片', icon: const Icon(Icons.image_outlined), onPressed: _saveImage),
        ],
        builder: (context, v) {
          List<String> l(String k) => ((v[k] as List?) ?? const []).cast<String>();
          final lab = (v['lab'] as Map?)?.cast<String, dynamic>();
          final pm = (v['post_meal'] as Map?)?.cast<String, dynamic>() ?? const {};
          Widget sec(String t, List<String> xs, {Color? color, bool numbered = false}) => xs.isEmpty
              ? const SizedBox.shrink()
              : Padding(padding: const EdgeInsets.only(top: 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('■ $t', style: TextStyle(fontWeight: FontWeight.bold, color: color ?? const Color(0xFF0E3B43))),
                  for (final (i, x) in xs.indexed)
                    Padding(padding: const EdgeInsets.only(top: 3, left: 8),
                        child: Text(numbered ? '${i + 1}. $x' : '· $x', style: const TextStyle(height: 1.4))),
                ]));
          return SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: RepaintBoundary(
              key: boundary,
              child: Container(
                key: const Key('visit_summary'),
                color: Colors.white,
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('复诊摘要｜${v['start']} 至 ${v['end']}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  if (lab != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text('医院检验：${[
                    if (lab['hba1c'] != null) '糖化血红蛋白 ${lab['hba1c']}%',
                    if (lab['fpg'] != null) '空腹血糖 ${lab['fpg']}',
                    if (lab['clinic_sbp'] != null) '诊间血压 ${(lab['clinic_sbp'] as num).round()}/${(lab['clinic_dbp'] as num?)?.round() ?? '—'}',
                  ].join('｜')}')),
                  for (final o in l('overview')) Text(o),
                  if (pm.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    MealCompareBars(postMeal: {for (final e in pm.entries) e.key: {'median': e.value, 'n': 0}}),
                  ],
                  sec('确认的事实', l('facts')),
                  sec('多次出现的关联（不代表原因）', l('associations')),
                  sec('想请教医生', l('questions'), color: const Color(0xFFB71C1C), numbered: true),
                  sec('目前还不能判断', l('cannot_judge'), color: Colors.black54),
                  const SizedBox(height: 12),
                  Text('${v['note'] ?? ''}', style: const TextStyle(fontSize: 12, color: Colors.black54)),
                ]),
              ),
            ),
          );
        },
      );
}

// ---------- 问照护助理 ----------

class CareChatPage extends ConsumerStatefulWidget {
  final CareBody body;
  const CareChatPage({super.key, required this.body});
  @override
  ConsumerState<CareChatPage> createState() => _CareChatPageState();
}

class _CareChatPageState extends ConsumerState<CareChatPage> {
  final input = TextEditingController();
  final turns = <Map<String, String>>[];
  bool busy = false;
  static const examples = ['我最近情况怎么样？', '我昨晚为什么会偏低？', '晚餐要注意什么？', '饭后散步有用吗？', '复诊要问医生什么？'];

  Future<void> send(String text) async {
    final q = text.trim();
    if (q.isEmpty || busy) return;
    setState(() { turns.add({'role': 'user', 'content': q}); busy = true; input.clear(); });
    try {
      final r = await ref.read(apiClientProvider).careChat({...widget.body, 'message': q,
        'history': turns.length > 20 ? turns.sublist(turns.length - 20) : turns});
      if (mounted) setState(() => turns.add({'role': 'assistant', 'content': '${r['answer']}'}));
    } catch (e) {
      if (mounted) setState(() => turns.add({'role': 'assistant', 'content': '$e'}));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('问照护助理')),
        body: Column(children: [
          Expanded(child: ListView(padding: const EdgeInsets.all(12), children: [
            const Text('根据你自己的记录回答。关联只代表相关；用药与剂量请问医生。', style: TextStyle(fontSize: 12, color: Colors.black54)),
            if (turns.isEmpty) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final e in examples) ActionChip(label: Text(e), onPressed: () => send(e)),
              ]),
            ],
            for (final t in turns)
              Align(
                alignment: t['role'] == 'user' ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  padding: const EdgeInsets.all(10),
                  constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.82),
                  decoration: BoxDecoration(color: t['role'] == 'user' ? const Color(0xFFE3F2FD) : const Color(0xFFFFF8F2),
                      borderRadius: BorderRadius.circular(12)),
                  child: Text(t['content']!, style: const TextStyle(height: 1.45)),
                ),
              ),
            if (busy) const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator()),
          ])),
          SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 8), child: Row(children: [
            Expanded(child: TextField(key: const Key('care_chat_input'), controller: input, onSubmitted: send,
                decoration: const InputDecoration(hintText: '想问什么？'))),
            IconButton(key: const Key('care_chat_send'), icon: const Icon(Icons.send), onPressed: busy ? null : () => send(input.text)),
          ]))),
        ]),
      );
}
