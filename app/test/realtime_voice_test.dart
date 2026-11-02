import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:medilens/core/realtime_voice.dart';
import 'package:medilens/core/voice_input.dart';

class RealtimeInputFake extends VoiceInputPlatform {
  final results = <Completer<String>>[];
  final events = StreamController<String>.broadcast(sync: true);
  bool allowed = true, busy = false;
  int cancels = 0, stops = 0;
  Completer<void>? cancelGate;
  @override
  Stream<String> get partials => events.stream;
  @override
  Future<VoiceInputStatus> status() async =>
      VoiceInputStatus(available: true, permission: allowed, busy: busy);
  @override
  Future<String> listenRealtime() {
    final c = Completer<String>();
    results.add(c);
    return c.future;
  }

  @override
  Future<void> cancel() async {
    cancels++;
    await cancelGate?.future;
  }

  @override
  Future<void> stop() async {
    stops++;
  }
}

class RealtimeOutputFake implements RealtimeVoiceOutput {
  final played = <String>[];
  final completions = <Completer<void>>[];
  bool fail = false;
  int stops = 0;
  @override
  Future<void> play(String text) {
    if (fail) throw StateError('synthetic');
    played.add(text);
    final c = Completer<void>();
    completions.add(c);
    return c.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    for (final c in completions) {
      if (!c.isCompleted) c.complete();
    }
  }
}

Future<void> flush() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  RealtimeVoiceController setup(
    RealtimeInputFake input,
    RealtimeOutputFake output, {
    RealtimeAsk? ask,
    Duration delay = Duration.zero,
    bool Function()? canSend,
  }) {
    final c = RealtimeVoiceController(
      input: input,
      output: output,
      ask: ask ?? ((text, valid) async => '合成回答'),
      canSend: canSend ?? () => true,
      previewDelay: delay,
      settleDelay: Duration.zero,
    );
    addTearDown(() async {
      c.dispose();
      await input.events.close();
    });
    return c;
  }

  test('普通问题可自动，数字、药名、阴阳性需人工核对', () {
    for (final text in ['尿蛋白是什么', '再解释一下', '我有点担心']) {
      expect(voiceNeedsReview(text), isFalse);
    }
    for (final text in [
      '尿蛋白2+',
      'UACR三十毫克',
      '我在吃二甲双胍',
      '一天两次',
      '有一个加号',
      '尿蛋白阴性',
      '血糖十二',
      '百分之五',
    ]) {
      expect(voiceNeedsReview(text), isTrue, reason: text);
    }
  });
  test('停顿后自动提问，实际播报完成前不打开下一轮麦克风', () async {
    final p = RealtimeInputFake(), o = RealtimeOutputFake();
    final questions = <String>[];
    final c = setup(
      p,
      o,
      ask: (t, v) async {
        questions.add(t);
        return '合成回答';
      },
    );
    unawaited(c.start());
    await flush();
    p.events.add('尿蛋');
    expect(c.partial, '尿蛋');
    p.results[0].complete('尿蛋白是什么');
    await flush();
    expect(questions, ['尿蛋白是什么']);
    expect(c.phase, RealtimePhase.speaking);
    expect(p.results.length, 1);
    o.completions[0].complete();
    await flush();
    expect(p.results.length, 2);
    expect(c.phase, RealtimePhase.listening);
    p.results[1].complete('再解释一下');
    await flush();
    expect(questions.length, 2);
    expect(o.played.length, 2);
    await c.stop();
  });
  test('带数值的识别不自动发送，修改确认后发送编辑值', () async {
    final p = RealtimeInputFake(), o = RealtimeOutputFake();
    final sent = <String>[];
    final c = setup(
      p,
      o,
      ask: (t, v) async {
        sent.add(t);
        return '回答';
      },
    );
    unawaited(c.start());
    await flush();
    p.results[0].complete('尿蛋白2+');
    await flush();
    expect(c.phase, RealtimePhase.review);
    expect(sent, isEmpty);
    await c.confirm('');
    expect(sent, isEmpty);
    unawaited(c.confirm('我想了解这个指标'));
    await flush();
    expect(sent, ['我想了解这个指标']);
    await c.stop();
  });
  test('倒计时期间修改可阻止自动发送', () async {
    final p = RealtimeInputFake(), o = RealtimeOutputFake();
    var sent = 0;
    final c = setup(
      p,
      o,
      delay: const Duration(milliseconds: 30),
      ask: (t, v) async {
        sent++;
        return '回答';
      },
    );
    unawaited(c.start());
    await flush();
    p.results[0].complete('尿蛋白是什么');
    await flush();
    expect(c.phase, RealtimePhase.pending);
    await c.review();
    await Future<void>.delayed(const Duration(milliseconds: 45));
    expect(c.phase, RealtimePhase.review);
    expect(sent, 0);
    await c.stop();
  });
  test('倒计时期间停止不会发送或自动恢复', () async {
    final p = RealtimeInputFake(), o = RealtimeOutputFake();
    var sent = 0;
    final c = setup(
      p,
      o,
      delay: const Duration(milliseconds: 30),
      ask: (t, v) async {
        sent++;
        return '回答';
      },
    );
    unawaited(c.start());
    await flush();
    p.results[0].complete('尿蛋白是什么');
    await flush();
    await c.stop();
    await Future<void>.delayed(const Duration(milliseconds: 45));
    expect(sent, 0);
    expect(c.active, isFalse);
    expect(p.results.length, 1);
  });
  test('停止后迟到识别和临时文字不触发发送', () async {
    final p = RealtimeInputFake(), o = RealtimeOutputFake();
    var sent = 0;
    final c = setup(
      p,
      o,
      ask: (t, v) async {
        sent++;
        return '回答';
      },
    );
    unawaited(c.start());
    await flush();
    await c.stop();
    p.results[0].complete('迟到问题');
    p.events.add('迟到临时文字');
    await flush();
    expect(sent, 0);
    expect(c.partial, isEmpty);
  });
  test('停止后迟到模型结果不可播报，accept回调失效', () async {
    final p = RealtimeInputFake(),
        o = RealtimeOutputFake(),
        answer = Completer<String?>();
    bool Function()? accept;
    final c = setup(
      p,
      o,
      ask: (t, v) {
        accept = v;
        return answer.future;
      },
    );
    unawaited(c.start());
    await flush();
    p.results[0].complete('尿蛋白是什么');
    await flush();
    expect(c.phase, RealtimePhase.thinking);
    await c.stop();
    expect(accept!(), isFalse);
    answer.complete('迟到回答');
    await flush();
    expect(o.played, isEmpty);
    expect(p.results.length, 1);
  });
  test('点击打断播报只开启一个新轮次，旧播放完成不恢复旧轮', () async {
    final p = RealtimeInputFake(), o = RealtimeOutputFake();
    final c = setup(p, o);
    unawaited(c.start());
    await flush();
    p.results[0].complete('尿蛋白是什么');
    await flush();
    unawaited(c.interruptAndListen());
    await flush();
    expect(o.stops, greaterThan(0));
    expect(p.results.length, 2);
    expect(c.phase, RealtimePhase.listening);
    await flush();
    expect(p.results.length, 2);
    await c.stop();
  });
  test('等待回答时打断使旧模型回调失效', () async {
    final p = RealtimeInputFake(),
        o = RealtimeOutputFake(),
        answer = Completer<String?>();
    bool Function()? accept;
    final c = setup(
      p,
      o,
      ask: (t, v) {
        accept = v;
        return answer.future;
      },
    );
    unawaited(c.start());
    await flush();
    p.results[0].complete('尿蛋白是什么');
    await flush();
    unawaited(c.interruptAndListen());
    await flush();
    expect(accept!(), isFalse);
    expect(p.results.length, 2);
    answer.complete('旧回答');
    await flush();
    expect(o.played, isEmpty);
    await c.stop();
  });
  test('无声或识别失败自动暂停，不持续重新录音', () async {
    for (final fail in [false, true]) {
      final p = RealtimeInputFake(), o = RealtimeOutputFake();
      final c = setup(p, o);
      unawaited(c.start());
      await flush();
      if (fail) {
        p.results[0].completeError(StateError('synthetic'));
      } else {
        p.results[0].complete('');
      }
      await flush();
      expect(c.active, isFalse);
      expect(c.phase, RealtimePhase.paused);
      expect(p.results.length, 1);
    }
  });
  test('权限或云端授权无效不启动识别', () async {
    final p = RealtimeInputFake()..allowed = false, o = RealtimeOutputFake();
    final c = setup(p, o);
    await c.start();
    expect(p.results, isEmpty);
    expect(c.active, isFalse);
    final p2 = RealtimeInputFake(), o2 = RealtimeOutputFake();
    final c2 = setup(p2, o2, canSend: () => false);
    await c2.start();
    expect(p2.results, isEmpty);
  });
  test('模型失败保留本句，朗读失败保留回答并暂停', () async {
    final p = RealtimeInputFake(), o = RealtimeOutputFake();
    final c = setup(p, o, ask: (t, v) async => null);
    unawaited(c.start());
    await flush();
    p.results[0].complete('尿蛋白是什么');
    await flush();
    expect(c.draft, '尿蛋白是什么');
    expect(c.active, isFalse);
    final p2 = RealtimeInputFake(), o2 = RealtimeOutputFake()..fail = true;
    final c2 = setup(p2, o2);
    unawaited(c2.start());
    await flush();
    p2.results[0].complete('尿蛋白是什么');
    await flush();
    expect(c2.reply, '合成回答');
    expect(c2.active, isFalse);
    expect(p2.results.length, 1);
  });
  test('停止清理结束之前不能开启新的麦克风', () async {
    final p = RealtimeInputFake(), o = RealtimeOutputFake();
    final c = setup(p, o);
    unawaited(c.start());
    await flush();
    p.cancelGate = Completer<void>();
    final stopping = c.stop();
    unawaited(c.start());
    await flush();
    expect(p.results.length, 1);
    p.cancelGate!.complete();
    await stopping;
    await flush();
    expect(p.results.length, 2);
    p.cancelGate = null;
    await c.stop();
  });
  test('旧句倒计时不能在下一轮误发旧问题', () async {
    final p = RealtimeInputFake(), o = RealtimeOutputFake();
    final sent = <String>[];
    final c = setup(
      p,
      o,
      delay: const Duration(milliseconds: 80),
      ask: (t, v) async {
        sent.add(t);
        return '回答';
      },
    );
    unawaited(c.start());
    await flush();
    p.results[0].complete('第一个问题');
    await flush();
    await c.review();
    unawaited(c.confirm('第一个问题'));
    await flush();
    o.completions[0].complete();
    await flush();
    await Future<void>.delayed(const Duration(milliseconds: 45));
    p.results[1].complete('下一个问题');
    await flush();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(sent, ['第一个问题']);
    await Future<void>.delayed(const Duration(milliseconds: 45));
    expect(sent, ['第一个问题', '下一个问题']);
    await c.stop();
  });
  test('结束对话指令和单字噪声不发送到模型', () async {
    for (final text in ['结束对话', '请结束对话。', '嗯']) {
      final p = RealtimeInputFake(), o = RealtimeOutputFake();
      var calls = 0;
      final c = setup(
        p,
        o,
        ask: (t, v) async {
          calls++;
          return '回答';
        },
      );
      unawaited(c.start());
      await flush();
      p.results[0].complete(text);
      await flush();
      expect(calls, 0);
      expect(c.active, isFalse);
      expect(p.results.length, 1);
    }
  });

  test('切换带入的草稿必须先确认，不丢弃或直接录音发送', () async {
    final p = RealtimeInputFake(), o = RealtimeOutputFake();
    final sent = <String>[];
    final c = setup(
      p,
      o,
      ask: (t, v) async {
        sent.add(t);
        return '回答';
      },
    );
    await c.start(initialDraft: '保留的草稿');
    expect(c.draft, '保留的草稿');
    expect(c.phase, RealtimePhase.review);
    expect(p.results, isEmpty);
    expect(sent, isEmpty);
    unawaited(c.confirm('修改后的问题'));
    await flush();
    expect(sent, ['修改后的问题']);
    await c.stop();
  });
}
