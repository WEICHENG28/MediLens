import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:medilens/core/api_client.dart';
import 'package:medilens/core/medication_records.dart';
import 'package:medilens/core/models.dart';
import 'package:medilens/core/session.dart';
import 'package:medilens/data/local_store.dart';
import 'package:medilens/features/followup_page.dart';
import 'package:medilens/widgets/medication_reference.dart';

Map<String, dynamic> question({bool hint = true}) => {'question_id': 'q_sglt2', 'index': 1, 'answer_type': 'single',
  'plain_language_prompt': '合成测试：请核对您目前的使用情况。', 'medical_rationale': '合成测试说明', 'medication_photo_hint': hint,
  'options': [{'id':'yes_known','label':'是，我知道药名'}, {'id':'no','label':'没有使用'}], 'allow_unknown':true, 'allow_skip':true, 'allow_decline':true};
class Session extends SessionNotifier {
  final bool hint;
  Session({this.hint = true});
  @override ReportSession build() => ReportSession(id: 'synthetic', report: const ParsedReport(reportType: 'urinalysis', items: []),
    analysis: {'next_question':question(hint: hint),'urgent_alert':{'show':true,'message':'合成测试：紧急提示仍须保留'}});
}
MedicationRecord record({MedicationUse use = MedicationUse.reportedTaking}) => MedicationRecord(name:'恩格列净片', originalText:'恩格列净片',
  dictionaryVersion:'synthetic', sourceTitle:'合成测试出处', sourceUrl:'https://www.nmpa.gov.cn/', sourceDate:'2026-01-12',sourceCheckedAt:'2026-11-01',
  confirmedAt:DateTime(2026,10,20,9), updatedAt:DateTime(2026,10,21,10), use:use);
class CountingStore extends MemoryStore {
  int reads = 0;
  @override Future<String?> getSetting(String key) { if (key == MedicationRecords.storageKey) reads++; return super.getSetting(key); }
}
void main() {
  Future<void> reveal(WidgetTester t, Finder finder) async {
    if (finder.evaluate().isEmpty) { await t.scrollUntilVisible(finder, 250, scrollable: find.byType(Scrollable).first); }
    await Scrollable.ensureVisible(t.element(finder), alignment: .5); await t.pumpAndSettle();
  }
  Future<({ProviderContainer container, GoRouter router, List<Map<String,dynamic>> bodies})> host(WidgetTester t, CountingStore store, {bool hint = true, bool large = false}) async {
    final bodies = <Map<String,dynamic>>[];
    final c = ProviderContainer(overrides: [localStoreProvider.overrideWithValue(store), sessionProvider.overrideWith(() => Session(hint:hint)),
      apiClientProvider.overrideWithValue(ApiClient('http://synthetic.test', MockClient((request) async {
        bodies.add(jsonDecode(request.body) as Map<String,dynamic>); return http.Response(jsonEncode({'next_question':null}),200);
      }))) ]);
    final router = GoRouter(initialLocation:'/followup', routes:[GoRoute(path:'/followup',builder:(_,_)=>const FollowupPage()),
      GoRoute(path:'/medications-saved',builder:(_,_)=>Scaffold(body:Builder(builder:(context)=>TextButton(onPressed:() async {
        await MedicationRecords(store,DateTime.now).clear(); if(context.mounted) context.pop();
      },child:const Text('合成测试：清空并返回')))))]);
    addTearDown(() { router.dispose(); c.dispose(); });
    t.view.physicalSize=const Size(1080,2400);t.view.devicePixelRatio=2.75;addTearDown(t.view.reset);
    await t.pumpWidget(UncontrolledProviderScope(container:c,child:MaterialApp.router(routerConfig:router,builder:(context,child)=>
      MediaQuery(data:MediaQuery.of(context).copyWith(textScaler:TextScaler.linear(large?1.5:1)),child:child!))));await t.pumpAndSettle();
    return (container:c,router:router,bodies:bodies);
  }
  testWidgets('主动展开才读药名，查看不写答案、不发送；紧急提示保持可见', (t) async {
    final store=CountingStore();await MedicationRecords(store,DateTime.now).write([record()]);
    final h=await host(t,store);expect(store.reads,0);expect(find.text('合成测试：紧急提示仍须保留'),findsOneWidget);
    await reveal(t,find.byKey(const Key('medication_reference')));await t.tap(find.text('答题前，查阅本机药名记录'));await t.pumpAndSettle();
    expect(store.reads,1);expect(find.text('恩格列净片'),findsOneWidget);expect(find.text('本人已确认当时正在使用'),findsOneWidget);
    expect(find.textContaining('2026-10-21 10:00'),findsOneWidget);expect(h.container.read(sessionProvider).answers,isEmpty);expect(h.bodies,isEmpty);
    await reveal(t,find.byKey(const Key('ans_unknown')));await t.tap(find.byKey(const Key('ans_unknown')));await t.pumpAndSettle();
    expect(h.bodies,hasLength(1));expect(h.bodies.single['answers'],{'q_sglt2':'__unknown__'});
    expect(h.bodies.single.keys.toSet(),{'report','answers','history'});expect(jsonEncode(h.bodies.single),isNot(contains('恩格列净片')));
    await t.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('没有药名不当作未用药，未确认在用与已确认记录分开；大字可读', (t) async {
    final store=CountingStore();final h=await host(t,store,large:true);
    await reveal(t,find.byKey(const Key('medication_reference')));await t.tap(find.text('答题前，查阅本机药名记录'));await t.pumpAndSettle();
    expect(find.textContaining('这不代表您没有用药'),findsOneWidget);expect(h.container.read(sessionProvider).answers,isEmpty);
    await MedicationRecords(store,DateTime.now).write([record(use:MedicationUse.unspecified)]);h.container.invalidate(savedMedicationsProvider);await t.pumpAndSettle();
    expect(find.text('仅保存药名，未确认在用'),findsOneWidget);expect(t.takeException(),isNull);expect(h.bodies,isEmpty);
    await t.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('修改返回后重新读取，药名消失不会更改题目或答案', (t) async {
    final store=CountingStore();await MedicationRecords(store,DateTime.now).write([record()]);final h=await host(t,store);
    await reveal(t,find.byKey(const Key('medication_reference')));await t.tap(find.text('答题前，查阅本机药名记录'));await t.pumpAndSettle();
    await reveal(t,find.byKey(const Key('manage_medications')));await t.tap(find.byKey(const Key('manage_medications')));await t.pumpAndSettle();
    await t.tap(find.text('合成测试：清空并返回'));await t.pumpAndSettle();expect(find.text('恩格列净片'),findsNothing);
    expect(find.textContaining('这不代表您没有用药'),findsOneWidget);expect(h.container.read(sessionProvider).answers,isEmpty);expect(h.bodies,isEmpty);
    await t.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('读取失败可重试且继续答题，其他题目不展示药名入口', (t) async {
    final store=CountingStore();await store.putSetting(MedicationRecords.storageKey,'broken');final h=await host(t,store);
    await reveal(t,find.byKey(const Key('medication_reference')));await t.tap(find.text('答题前，查阅本机药名记录'));await t.pumpAndSettle();
    expect(find.textContaining('本机药名暂时无法读取'),findsOneWidget);expect(h.container.read(sessionProvider).answers,isEmpty);
    await MedicationRecords(store,DateTime.now).clear();await reveal(t,find.text('重试读取药名'));await t.tap(find.text('重试读取药名'));await t.pumpAndSettle();
    expect(find.textContaining('还没有保存药名'),findsOneWidget);expect(t.takeException(),isNull);
    await t.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('不相关问题不读取或展示药名', (t) async {
    final store=CountingStore();await host(t,store,hint:false);expect(find.byType(MedicationReference),findsNothing);expect(store.reads,0);
    await t.pumpWidget(const SizedBox.shrink());
  });
}
