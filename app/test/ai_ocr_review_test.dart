import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:medilens/core/api_client.dart';
import 'package:medilens/core/models.dart';
import 'package:medilens/core/ocr_review.dart';
import 'package:medilens/widgets/ai_ocr_review.dart';

LabItem item() => LabItem(code: 'PRO', label: '姓名张三 医院测试', value: '+',
  unit: '医院标识', reference: '姓名', confidence: 0.5,
  status: ReviewStatus.needsConfirmation, candidates: ['1+', '阴性', '张三']);

Widget host(ApiClient api, LabItem lab, ValueChanged<String> confirm) => ProviderScope(
  overrides: [apiClientProvider.overrideWithValue(api)],
  child: MaterialApp(home: Scaffold(body: SingleChildScrollView(
    child: AiOcrReviewCard(item: lab, onConfirm: confirm)))),
);

void main() {
  test('上传内容只包含代码与筛选后的值，不包含身份、单位、原始 OCR', () {
    expect(ocrReviewPayload(item()), {
      'consent': true, 'code': 'PRO', 'value': '+', 'candidates': ['1+', '阴性'],
    });
    final unsafe = item()..value = '张三';
    expect(ocrReviewPayload(unsafe), isNull);
  });

  testWidgets('取消不发送；同意后仅显示建议，点击确认前不改变原值', (t) async {
    var requests = 0;
    String? confirmed;
    final lab = item();
    final api = ApiClient('https://example.org', MockClient((r) async {
      requests++;
      expect(jsonDecode(r.body), ocrReviewPayload(lab));
      return http.Response(jsonEncode({'status': 'ok', 'candidate': '1+',
        'tip': '请核对加号', 'notice': '没有读取图片'}), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
    }));
    await t.pumpWidget(host(api, lab, (v) => confirmed = v));
    await t.tap(find.byKey(const Key('ocr_ai_request')));
    await t.pumpAndSettle();
    expect(requests, 0);
    expect(find.textContaining('候选：1+、阴性'), findsOneWidget);
    expect(find.textContaining('张三'), findsNothing);
    await t.tap(find.text('取消'));
    await t.pumpAndSettle();
    expect(requests, 0);
    await t.tap(find.byKey(const Key('ocr_ai_request')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('ocr_ai_consent')));
    await t.pumpAndSettle();
    expect(requests, 1);
    expect(lab.value, '+');
    expect(lab.status, ReviewStatus.needsConfirmation);
    expect(confirmed, isNull);
    await t.ensureVisible(find.byKey(const Key('ocr_ai_confirm')));
    await t.tap(find.byKey(const Key('ocr_ai_confirm')));
    expect(confirmed, '1+');
  });

  testWidgets('旧服务器错误页面也能回退，不改变识别结果', (t) async {
    final lab = item();
    final api = ApiClient('https://example.org', MockClient((_) async => http.Response('<html>unavailable</html>', 502)));
    await t.pumpWidget(host(api, lab, (_) => fail('不得自动确认')));
    await t.tap(find.byKey(const Key('ocr_ai_request')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('ocr_ai_consent')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('ocr_ai_error')), findsOneWidget);
    expect(lab.value, '+');
    expect(lab.needsReview, isTrue);
  });
}
