import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medilens/widgets/common.dart';

void main() {
  testWidgets('资料来源在有色解释框中可正常展开', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Container(
      color: Colors.grey.shade100,
      child: const CitationsBox([
        {'id': 'test-source', 'title': '合成测试资料', 'source': '测试来源',
          'source_url': 'https://example.org/source', 'checked_at': '2026-10-30'},
      ]),
    ))));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('citations')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('合成测试资料'), findsOneWidget);
    expect(find.textContaining('https://example.org/source'), findsOneWidget);
    expect(find.textContaining('不代表医学审核'), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
  });

  test('旧版资料没有网址也能显示，非 HTTPS 地址不展示', () {
    expect(citationLine({'title': '资料', 'source': '出处'}), contains('未经医学审核'));
    expect(citationLine({'title': '资料', 'source': '出处', 'source_url': 'javascript:alert(1)'}), isNot(contains('javascript:')));
  });
}
