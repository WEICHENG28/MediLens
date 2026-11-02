import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:medilens/core/api_client.dart';
import 'package:medilens/core/models.dart';
import 'package:medilens/core/session.dart';
import 'package:medilens/data/local_store.dart';
import 'package:medilens/ocr/ocr_engine.dart';

class InitialSession extends SessionNotifier {
  @override
  ReportSession build() => ReportSession(
    id: 'synthetic-old',
    report: ParsedReport(
      reportType: 'urinalysis',
      items: [
        LabItem(
          code: 'PRO',
          label: '尿蛋白',
          value: '1+',
          confidence: 1,
          status: ReviewStatus.confirmed,
        ),
      ],
    ),
    answers: const {'q_test': 'old'},
    answerOrder: const ['q_test'],
    analysis: const {'marker': 'old'},
    saved: true,
  );
}

class DeferredApi extends ApiClient {
  final Future<Map<String, dynamic>> Function() response;
  DeferredApi(this.response) : super('http://synthetic.test');
  @override
  Future<Map<String, dynamic>> analyze(Map<String, dynamic> body) => response();
  @override
  Future<Map<String, dynamic>> chat(
    Map<String, dynamic> body,
    String message, {
    String? focus,
    String? quick,
    List<Map<String, String>> history = const [],
  }) => response();
}

class DeferredOcr implements OcrEngine {
  final result = Completer<OcrResult>();
  @override
  Future<OcrResult> recognize(
    img.Image source, {
    int rotation = 0,
    bool autoOrient = true,
  }) => result.future;
}

class DeferredStore extends MemoryStore {
  final started = Completer<void>(), done = Completer<void>();
  @override
  Future<void> saveReport(SavedReport r) async {
    started.complete();
    await done.future;
    await super.saveReport(r);
  }
}

ProviderContainer setup(ApiClient api, {LocalStore? store, OcrEngine? ocr}) =>
    ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(InitialSession.new),
        apiClientProvider.overrideWithValue(api),
        localStoreProvider.overrideWithValue(store ?? MemoryStore()),
        if (ocr != null) ocrEngineProvider.overrideWithValue(ocr),
      ],
    );
void main() {
  for (final back in [false, true]) {
    test('${back ? '上一题' : '回答'}请求失败不改变已确认答案、解读或保存标记', () async {
      final c = setup(DeferredApi(() async => throw ApiException('合成网络失败')));
      addTearDown(c.dispose);
      final n = c.read(sessionProvider.notifier),
          before = c.read(sessionProvider);
      await expectLater(
        back ? n.back() : n.answer('q_test', 'new'),
        throwsA(isA<ApiException>()),
      );
      expect(c.read(sessionProvider).answers, before.answers);
      expect(c.read(sessionProvider).answerOrder, before.answerOrder);
      expect(c.read(sessionProvider).analysis, before.analysis);
      expect(c.read(sessionProvider).saved, isTrue);
    });
  }
  test('旧解读迟到不能进入新报告', () async {
    final response = Completer<Map<String, dynamic>>(),
        started = Completer<void>();
    final c = setup(
      DeferredApi(() {
        started.complete();
        return response.future;
      }),
    );
    addTearDown(c.dispose);
    final n = c.read(sessionProvider.notifier);
    final pending = n.analyze();
    await started.future;
    n.reset();
    final id = c.read(sessionProvider).id;
    response.complete({'marker': 'stale'});
    await pending;
    expect(c.read(sessionProvider).id, id);
    expect(c.read(sessionProvider).analysis, isNull);
  });
  test('旧聊天迟到不能进入新会话', () async {
    final response = Completer<Map<String, dynamic>>(),
        started = Completer<void>();
    final c = setup(
      DeferredApi(() {
        started.complete();
        return response.future;
      }),
    );
    addTearDown(c.dispose);
    final n = c.read(sessionProvider.notifier);
    final pending = n.sendChat('合成问题');
    await started.future;
    n.reset();
    response.complete({'answer': '旧报告回答'});
    await pending;
    expect(c.read(sessionProvider).messages, isEmpty);
  });
  test('旧图片OCR迟到不能覆盖新图片', () async {
    final ocr = DeferredOcr();
    final c = setup(DeferredApi(() async => {}), ocr: ocr);
    addTearDown(c.dispose);
    final n = c.read(sessionProvider.notifier);
    final old = img.Image(width: 600, height: 600),
        fresh = img.Image(width: 601, height: 600);
    n.setImage(old);
    final pending = n.runOcr();
    n.setImage(fresh);
    ocr.result.complete(
      OcrResult(
        image: old,
        rotation: 0,
        lines: const [],
        elapsed: Duration.zero,
      ),
    );
    await pending;
    expect(identical(c.read(sessionProvider).source, fresh), isTrue);
    expect(c.read(sessionProvider).report, isNull);
  });
  test('保存完成不复活已经离开的旧报告', () async {
    final store = DeferredStore();
    final c = setup(DeferredApi(() async => {}), store: store);
    addTearDown(c.dispose);
    final n = c.read(sessionProvider.notifier);
    final pending = n.saveLocally();
    await store.started.future;
    n.reset();
    final id = c.read(sessionProvider).id;
    store.done.complete();
    await pending;
    expect(store.reports.keys, ['synthetic-old']);
    expect(c.read(sessionProvider).id, id);
    expect(c.read(sessionProvider).report, isNull);
    expect(c.read(sessionProvider).saved, isFalse);
  });
  test('复核修改后旧解读和请求正文失效，重新分析使用新数值', () async {
    final c = setup(DeferredApi(() async => {'marker': 'analyzed'}));
    addTearDown(c.dispose);
    final n = c.read(sessionProvider.notifier);
    await n.analyze();
    n.resolveItem(c.read(sessionProvider).report!.items.first, value: '2+');
    expect(c.read(sessionProvider).analysis, isNull);
    expect((n.analysisBody['report'] as Map)['items'][0]['raw_value'], '2+');
    expect(c.read(sessionProvider).saved, isFalse);
  });
  test('同一报告并发解读只接受最新一次结果', () async {
    final replies = [
      Completer<Map<String, dynamic>>(),
      Completer<Map<String, dynamic>>(),
    ];
    final starts = [Completer<void>(), Completer<void>()];
    var count = 0;
    final c = setup(
      DeferredApi(() {
        final i = count++;
        starts[i].complete();
        return replies[i].future;
      }),
    );
    addTearDown(c.dispose);
    final n = c.read(sessionProvider.notifier);
    final first = n.analyze();
    await starts[0].future;
    final second = n.analyze();
    await starts[1].future;
    replies[1].complete({'marker': 'latest'});
    await second;
    replies[0].complete({'marker': 'old'});
    await first;
    expect(c.read(sessionProvider).analysis!['marker'], 'latest');
  });
  test('实时对话取消后迟到回答不进入共享会话', () async {
    final response = Completer<Map<String, dynamic>>();
    var accept = true;
    final c = setup(DeferredApi(() => response.future));
    addTearDown(c.dispose);
    final pending = c
        .read(sessionProvider.notifier)
        .sendChat('合成实时问题', accept: () => accept);
    accept = false;
    response.complete({'answer': '过期回答'});
    expect(await pending, isFalse);
    expect(c.read(sessionProvider).messages.map((m) => m.role), ['user']);
  });
}
