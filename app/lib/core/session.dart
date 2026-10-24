// 当前报告会话状态：导入 → OCR → 局部确认 → 总览 → 选择题 → 解释/对话 → 保存选择。
// 文字对话与（待实现的）语音模式共享同一会话，切换时上下文不丢失。

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:uuid/uuid.dart';

import '../data/local_store.dart';
import '../ocr/image_tools.dart';
import '../ocr/ocr_engine.dart';
import '../ocr/report_parser.dart';
import 'api_client.dart';
import 'models.dart';

class ChatMessage {
  final String role; // user / assistant
  final String content;
  final List<Map<String, dynamic>> citations;
  final String? safetyCategory;
  final bool usedFallback;
  const ChatMessage(this.role, this.content, {this.citations = const [], this.safetyCategory, this.usedFallback = false});
  Map<String, dynamic> toJson() => {'role': role, 'content': content, 'citations': citations, 'safety_category': safetyCategory};
}

class ReportSession {
  final String id;
  final img.Image? source; // 用户导入的原始图像（仅在内存，不上传）
  final Uint8List? displayPng; // 正向图像（与 OCR 坐标同一坐标系）
  final int rotation;
  final List<String> qualityWarnings;
  final bool synthetic; // 是否为内置合成示例
  final OcrResult? ocr;
  final ParsedReport? report;
  final Map<String, dynamic> answers;
  final List<String> answerOrder; // 回答顺序，用于「上一题」
  final Map<String, dynamic>? analysis;
  final List<ChatMessage> messages;
  final bool saved;

  const ReportSession({
    required this.id,
    this.source,
    this.displayPng,
    this.rotation = 0,
    this.qualityWarnings = const [],
    this.synthetic = false,
    this.ocr,
    this.report,
    this.answers = const {},
    this.answerOrder = const [],
    this.analysis,
    this.messages = const [],
    this.saved = false,
  });

  ReportSession copyWith({
    img.Image? source,
    Uint8List? displayPng,
    int? rotation,
    List<String>? qualityWarnings,
    bool? synthetic,
    OcrResult? ocr,
    ParsedReport? report,
    Map<String, dynamic>? answers,
    List<String>? answerOrder,
    Map<String, dynamic>? analysis,
    List<ChatMessage>? messages,
    bool? saved,
  }) =>
      ReportSession(
        id: id,
        source: source ?? this.source,
        displayPng: displayPng ?? this.displayPng,
        rotation: rotation ?? this.rotation,
        qualityWarnings: qualityWarnings ?? this.qualityWarnings,
        synthetic: synthetic ?? this.synthetic,
        ocr: ocr ?? this.ocr,
        report: report ?? this.report,
        answers: answers ?? this.answers,
        answerOrder: answerOrder ?? this.answerOrder,
        analysis: analysis ?? this.analysis,
        messages: messages ?? this.messages,
        saved: saved ?? this.saved,
      );

  Map<String, dynamic>? get nextQuestion => analysis?['next_question'] as Map<String, dynamic>?;
}

final ocrEngineProvider = Provider<OcrEngine>((ref) => OnnxOcrEngine());

class SessionNotifier extends Notifier<ReportSession> {
  @override
  ReportSession build() => ReportSession(id: const Uuid().v4());

  void reset() => state = ReportSession(id: const Uuid().v4());

  /// 导入图像：做质量检查，等待用户确认/旋转后再识别。
  void setImage(img.Image image, {bool synthetic = false}) {
    final q = checkQuality(image);
    state = ReportSession(
      id: const Uuid().v4(),
      source: image,
      displayPng: img.encodePng(image),
      qualityWarnings: q.warnings,
      synthetic: synthetic,
    );
  }

  void rotate90() {
    final src = state.source;
    if (src == null) return;
    final r = (state.rotation + 90) % 360;
    state = state.copyWith(rotation: r, displayPng: img.encodePng(rotate(src, r)));
  }

  Future<void> runOcr() async {
    final src = state.source;
    if (src == null) return;
    final result = await ref.read(ocrEngineProvider).recognize(src, rotation: state.rotation);
    state = state.copyWith(
      ocr: result,
      rotation: result.rotation,
      displayPng: img.encodePng(result.image),
      report: parseReport(result.lines),
    );
  }

  /// 测试与离线演示：直接注入 OCR 文本行。
  void setOcrLines(List<OcrLine> lines, {Uint8List? displayPng, bool synthetic = true}) {
    state = state.copyWith(report: parseReport(lines), displayPng: displayPng, synthetic: synthetic);
  }

  /// 局部确认：选择候选值 / 手工更正 / 无法确认 / 排除。
  void resolveItem(LabItem item, {String? value, ReviewStatus status = ReviewStatus.confirmed}) {
    item.status = status;
    if (value != null) item.value = value;
    state = state.copyWith(report: state.report);
  }

  Future<List<HistoryBrief>> _history() async {
    final saved = await ref.read(localStoreProvider).listReports();
    return saved
        .where((r) => r.id != state.id && r.testDate != null)
        .map((r) => HistoryBrief(r.testDate!, r.items.map((i) => LabItem.fromJson(i).toApi()).toList()))
        .toList();
  }

  Map<String, dynamic>? _lastBody;
  Map<String, dynamic> get analysisBody => _lastBody ?? ApiClient.analysisBody(state.report!, state.answers, const []);

  Future<void> analyze() async {
    final body = ApiClient.analysisBody(state.report!, state.answers, await _history());
    final res = await ref.read(apiClientProvider).analyze(body);
    _lastBody = body;
    state = state.copyWith(analysis: res);
  }

  /// 回答选择题后重新判读（服务端无状态）。特殊回答：__unknown__ / __decline__ / __skip__。
  Future<void> answer(String questionId, dynamic value) async {
    final answers = {...state.answers, questionId: value};
    final order = [...state.answerOrder.where((q) => q != questionId), questionId];
    state = state.copyWith(answers: answers, answerOrder: order);
    await analyze();
  }

  /// 上一题：撤销最近一个回答（该题会重新出现，可修改答案）。
  Future<void> back() async {
    if (state.answerOrder.isEmpty) return;
    final last = state.answerOrder.last;
    final answers = {...state.answers}..remove(last);
    state = state.copyWith(answers: answers, answerOrder: state.answerOrder.sublist(0, state.answerOrder.length - 1));
    await analyze();
  }

  Future<void> sendChat(String text, {String? focus, String? quick}) async {
    final history = state.messages.map((m) => {'role': m.role, 'content': m.content}).toList();
    state = state.copyWith(messages: [...state.messages, ChatMessage('user', text)]);
    try {
      final r = await ref.read(apiClientProvider).chat(analysisBody, text, focus: focus, quick: quick, history: history);
      state = state.copyWith(messages: [
        ...state.messages,
        ChatMessage('assistant', r['answer'] as String,
            citations: ((r['citations'] as List?) ?? const []).cast<Map<String, dynamic>>(),
            safetyCategory: r['safety_category'] as String?,
            usedFallback: r['used_fallback'] as bool? ?? false),
      ]);
    } on ApiException catch (e) {
      state = state.copyWith(messages: [...state.messages, ChatMessage('assistant', e.message)]);
    }
  }

  Future<void> saveLocally() async {
    final s = state;
    await ref.read(localStoreProvider).saveReport(SavedReport(
          id: s.id,
          testDate: s.report?.testDate,
          savedAt: DateTime.now(),
          reportType: s.report?.reportType ?? 'unknown',
          items: s.report?.items.map((i) => i.toJson()).toList() ?? const [],
          answers: s.answers,
          analysis: s.analysis,
          messages: s.messages.map((m) => m.toJson()).toList(),
        ));
    ref.invalidate(historyProvider);
    state = s.copyWith(saved: true);
  }
}

final sessionProvider = NotifierProvider<SessionNotifier, ReportSession>(SessionNotifier.new);
