import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medilens/widgets/common.dart';

void main() {
  testWidgets('资料来源在有色解释框中可正常展开', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Container(
      color: Colors.grey.shade100,
      child: const CitationsBox([
        {'id': 'test-source', 'title': '合成测试资料', 'source': '测试来源'},
      ]),
    ))));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('citations')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('合成测试资料'), findsOneWidget);
  });
}
