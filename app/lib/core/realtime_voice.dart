import 'dart:async';

import 'package:flutter/foundation.dart';

import 'voice_input.dart';

enum RealtimePhase {
  off,
  listening,
  pending,
  review,
  thinking,
  speaking,
  paused,
}

/// Conservative format guard, not a medical classifier. The user can review any sentence.
bool voiceNeedsReview(String text) => RegExp(
  r'[0-9０-９+＋±<>≤≥]|百分之|[零〇一二三四五六七八九十百千万两]{2,}|(?:血糖|血压|尿蛋白|尿酮|比重|肌酐|体温|数值)(?:是|为|有)?[零〇一二三四五六七八九十百千万两点]+|药|片|胶囊|剂量|胰岛素|二甲双胍|格列|阿卡波|毫克|毫升|单位|阴性|阳性|阴阳|加号|服用|注射|升高|降低|[一二三四五六七八九十两半]+(?:粒|次|天|周|月|年|点|加号|个单位)|\b(?:mg|ml|mmol)\b',
  caseSensitive: false,
).hasMatch(text);

abstract class RealtimeVoiceOutput {
  /// Completes on actual playback completion, not merely the native start acknowledgement.
  Future<void> play(String text);
  Future<void> stop();
}

typedef RealtimeAsk = Future<String?> Function(
  String text,
  bool Function() accept,
);

class RealtimeVoiceController extends ChangeNotifier {
  final VoiceInputPlatform input;
  final RealtimeVoiceOutput output;
  final RealtimeAsk ask;
  final bool Function() canSend;
  final Duration previewDelay, settleDelay;
  RealtimeVoiceController({
    required this.input,
    required this.output,
    required this.ask,
    required this.canSend,
    this.previewDelay = const Duration(milliseconds: 1200),
    this.settleDelay = const Duration(milliseconds: 250),
  });

  RealtimePhase phase = RealtimePhase.off;
  bool active = false;
  String draft = '', partial = '', reply = '', message = '';
  int _generation = 0, _utterance = 0;
  bool _disposed = false, _forceReview = false;
  StreamSubscription<String>? _partials;
  Future<void> _cleanup = Future<void>.value();
  bool _current(int ticket) => !_disposed && active && ticket == _generation;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start({String initialDraft = ''}) async {
    if (_disposed || active) return;
    if (!canSend()) {
      message = '请先完成报告解读并允许发送指标。';
      _notify();
      return;
    }
    active = true;
    final ticket = ++_generation;
    message = '';
    _forceReview = false;
    await _cleanup;
    if (!_current(ticket)) return;
    _partials = input.partials.listen(
      (text) {
        if (_current(ticket) && phase == RealtimePhase.listening) {
          partial = text;
          _notify();
        }
      },
      onError: (Object _) {
        if (_current(ticket)) {
          unawaited(stopWithOptions('本机实时识别暂不可用，请改用按键模式。', paused: true));
        }
      },
    );
    if (initialDraft.trim().isNotEmpty) {
      draft = initialDraft.trim();
      phase = RealtimePhase.review;
      message = '已有草稿尚未发送，请核对后确认。';
      _notify();
      return;
    }
    await _capture(ticket);
  }

  Future<void> _capture(int ticket) async {
    if (!_current(ticket)) return;
    final utterance = ++_utterance;
    try {
      // A cancelled native recognizer must release its microphone before the next one starts.
      var status = await input.status();
      for (var i = 0; status.busy && i < 30 && _current(ticket); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        status = await input.status();
      }
      if (!_current(ticket)) return;
      if (!status.available ||
          !status.permission ||
          status.busy ||
          !canSend()) {
        await stopWithOptions('请检查麦克风权限、报告授权，或稍后重试。', paused: true);
        return;
      }
      phase = RealtimePhase.listening;
      draft = '';
      partial = '';
      _forceReview = false;
      _notify();
      final text = (await input.listenRealtime()).trim();
      if (!_current(ticket)) return;
      partial = '';
      draft = text;
      final command = text.replaceAll(RegExp(r'[\s，,。.!！?？]'), '');
      if (const {
        '结束对话',
        '结束实时对话',
        '停止对话',
        '停止实时对话',
        '退出对话',
        '不聊了',
        '请结束对话',
      }.contains(command)) {
        await stopWithOptions('已按语音指令结束实时对话。', clearDraft: true);
        return;
      }
      if (text.runes.length == 1) {
        await stopWithOptions('没有听到完整问题，已暂停；可重新开启或改用按键模式。', paused: true);
        return;
      }
      if (text.isEmpty) {
        await stopWithOptions('没有听清，已暂停聆听。可重新开启或改用按键模式。', paused: true);
        return;
      }
      if (text.length > 500 || _forceReview || voiceNeedsReview(text)) {
        phase = RealtimePhase.review;
        message = '请核对这句话，尤其是药名、数值和阴阳性，再确认发送。';
        _notify();
        return;
      }
      phase = RealtimePhase.pending;
      message = '即将发送，可点“修改本句”暂停核对。';
      _notify();
      await Future<void>.delayed(previewDelay);
      if (_current(ticket) &&
          utterance == _utterance &&
          phase == RealtimePhase.pending) {
        await _send(ticket, text);
      }
    } catch (_) {
      if (_current(ticket)) {
        await stopWithOptions('本机识别未完成，已暂停；文字不会自动发送。', paused: true);
      }
    }
  }

  Future<void> _send(int ticket, String text) async {
    if (!_current(ticket)) return;
    if (!canSend()) {
      await stop('授权或报告已改变，实时对话已停止。');
      return;
    }
    phase = RealtimePhase.thinking;
    message = '';
    draft = text;
    _notify();
    try {
      final answer = await ask(text, () => _current(ticket));
      if (!_current(ticket)) return;
      if (answer == null || answer.trim().isEmpty) {
        await stopWithOptions('回答未完成，已暂停。可改用按键模式重试，问题仍保留。', paused: true);
        return;
      }
      reply = answer;
      phase = RealtimePhase.speaking;
      draft = '';
      _notify();
      await output.play(answer);
      if (!_current(ticket)) return;
      // Do not capture the speaker's trailing playback as a new question.
      await Future<void>.delayed(settleDelay);
      if (_current(ticket)) unawaited(_capture(ticket));
    } catch (_) {
      if (_current(ticket)) {
        await stopWithOptions('回答或中文朗读未完成，已暂停。文字回答仍可查看。', paused: true);
      }
    }
  }

  Future<void> confirm(String text) async {
    if (!active || phase != RealtimePhase.review) return;
    text = text.trim();
    if (text.isEmpty || text.length > 500) {
      message = '请将问题核对为1至500字后发送。';
      _notify();
      return;
    }
    await _send(_generation, text);
  }

  Future<void> review() async {
    if (!active) return;
    if (phase == RealtimePhase.pending) {
      phase = RealtimePhase.review;
      message = '已暂停自动发送，请核对或修改。';
      _notify();
    } else if (phase == RealtimePhase.listening) {
      _forceReview = true;
      try {
        await input.stop();
      } catch (_) {
        await stopWithOptions('未能结束识别，请改用按键模式。', paused: true);
      }
    }
  }

  Future<void> interruptAndListen() async {
    if (!active ||
        !(phase == RealtimePhase.speaking || phase == RealtimePhase.thinking)) {
      return;
    }
    final ticket = ++_generation;
    await _partials?.cancel();
    _partials = null;
    try {
      await output.stop();
      await input.cancel();
    } catch (_) {}
    await Future<void>.delayed(settleDelay);
    if (!_current(ticket)) return;
    _partials = input.partials.listen(
      (text) {
        if (_current(ticket) && phase == RealtimePhase.listening) {
          partial = text;
          _notify();
        }
      },
      onError: (Object _) {
        if (_current(ticket)) {
          unawaited(stopWithOptions('识别暂不可用，已暂停。', paused: true));
        }
      },
    );
    await _capture(ticket);
  }

  Future<void> stop([String reason = '实时对话已停止。']) => stopWithOptions(reason);

  Future<void> stopWithOptions(
    String reason, {
    bool clearDraft = false,
    bool paused = false,
  }) async {
    active = false;
    ++_generation;
    phase = paused ? RealtimePhase.paused : RealtimePhase.off;
    partial = '';
    message = reason;
    if (clearDraft) draft = '';
    _notify();
    final subscription = _partials;
    _partials = null;
    final cleanup = _cleanup.then((_) async {
      await subscription?.cancel();
      try {
        await input.cancel();
      } catch (_) {}
      try {
        await output.stop();
      } catch (_) {}
    });
    _cleanup = cleanup.catchError((Object _) {});
    await _cleanup;
  }

  @override
  void dispose() {
    _disposed = true;
    active = false;
    ++_generation;
    unawaited(_partials?.cancel() ?? Future<void>.value());
    unawaited(input.cancel().catchError((_) {}));
    unawaited(output.stop().catchError((_) {}));
    super.dispose();
  }
}
