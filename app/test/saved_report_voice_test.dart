import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medilens/app.dart';
import 'package:medilens/core/session.dart';
import 'package:medilens/data/local_store.dart';

import 'speech_test.dart' show FakeSpeech;
import 'voice_page_test.dart' as voice;

void main() {
  for (final entry in ['/voice', '/realtime-voice', '/history']) {
    testWidgets('重开后从 $entry 读取旧报告并继续语音', (t) async {
      final input = voice.Input(), api = voice.Api();
      final c = voice.scope(input, api, FakeSpeech(), report: false);
      addTearDown(c.dispose);
      final saved = SavedReport.fromRow({
        'id': 'saved-demo',
        'test_date': '2026-10-01',
        'saved_at': '2026-10-01T12:00:00',
        'report_type': 'urinalysis',
        'payload': jsonEncode({
          'items': [
            {
              'code': 'PRO',
              'original_label': '尿蛋白',
              'raw_value': '阴性',
              'review_status': 'confirmed',
            },
          ],
          'answers': {'demo': true},
          'analysis': {'overall': {'level': 'green'}},
          'messages': [
            {'role': 'assistant', 'content': '上次的报告解读'},
          ],
        }),
      });
      await c.read(localStoreProvider).saveReport(saved);
      final router = buildRouter(true);
      addTearDown(router.dispose);
      router.go(entry);
      await t.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp.router(routerConfig: router),
      ));
      await t.pumpAndSettle();
      if (entry != '/history') {
        await t.tap(find.text('选择已保存的报告'));
        await t.pumpAndSettle();
      }
      await t.tap(find.text('检验日期 2026-10-01'));
      await t.pumpAndSettle();
      final choose = find.text('用这份报告语音提问');
      await t.ensureVisible(choose);
      await t.tap(choose);
      await t.pumpAndSettle();

      final session = c.read(sessionProvider);
      expect(session.id, 'saved-demo');
      expect(session.report!.items.single.value, '阴性');
      expect(session.answers['demo'], true);
      expect(session.analysis, saved.analysis);
      expect(find.text('上次的报告解读'), findsOneWidget);
      expect(find.text(entry == '/realtime-voice' ? '开启实时对话' : '开始说话'),
          findsOneWidget);
      expect(input.starts, 0);
      expect(api.sent, isEmpty);
      await voice.cleanup(t);
    });
  }
}
