import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medilens/core/api_client.dart';
import 'package:medilens/core/care_reminders.dart';
import 'package:medilens/core/desktop_pet.dart';
import 'package:medilens/core/task_receipts.dart';
import 'package:medilens/data/local_store.dart';
import 'package:medilens/features/life_page.dart';

/// 照护核心的假服务：记录送出的内容，回一张即时回馈卡与一个提醒。
class CareApi extends ApiClient {
  final careBodies = <Map<String, dynamic>>[];
  final bool offline;
  CareApi({this.offline = false}) : super('https://unused.invalid');
  @override
  Future<Map<String, dynamic>> lifestyle(Map<String, dynamic> body) async => throw ApiException('合成测试：离线');
  @override
  Future<Map<String, dynamic>> careRecord(Map<String, dynamic> body) async {
    careBodies.add(body);
    if (offline) throw ApiException('合成测试：离线');
    return {
      'feedback': [{'time': '2026-11-17T19:10:00', 'type': 'glucose', 'tone': 'alert', 'title': '血糖偏低',
        'text': '指血复核 3.6，确认偏低。请先按医生教过的方法处理。', 'based_on': ['这笔血糖'], 'reminders': []}],
      'changes': [{'kind': 'promoted', 'id': 'late_dinner_night_low', 'text': '「晚餐延迟与夜间低值」证据够了'}],
      'alerts': [],
      'reminders': [{'at': '2026-11-17T19:25:00', 'title': '复测血糖', 'reason': '血糖低于 3.9'}],
      'profile': {},
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2026, 11, 17, 19, 10);
  late MemoryStore store;
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(DesktopPet.channel, (_) async => null);
    store = MemoryStore();
  });
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(DesktopPet.channel, null));

  Future<void> open(WidgetTester t, CareApi api) async {
    await store.putSetting('life_onboarded', 'true');
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 2.75;
    addTearDown(t.view.reset);
    await t.pumpWidget(ProviderScope(overrides: [localStoreProvider.overrideWithValue(store),
      apiClientProvider.overrideWithValue(api), taskClockProvider.overrideWithValue(() => now)],
      child: const MaterialApp(home: LifePage())));
    await t.pumpAndSettle();
  }

  testWidgets('记血糖可选来源与复核；即时回馈卡、档案变化与提醒都显示出来', (t) async {
    final api = CareApi();
    await open(t, api);
    await t.ensureVisible(find.byKey(const Key('life_日常记录')));
    await t.tap(find.byKey(const Key('life_日常记录')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('life_记血糖')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('glucose_input')), '3.6');
    await t.tap(find.byKey(const Key('glucose_confirm')));
    await t.pumpAndSettle();
    await t.tap(find.text('记录').last);
    await t.pumpAndSettle();

    final sent = (api.careBodies.single['new'] as List).single as Map<String, dynamic>;
    expect(sent['glucose'], 3.6);
    expect(sent['glucose_source'], 'finger');
    expect(sent['confirmatory'], isTrue);
    expect(sent.containsKey('id'), isFalse); // 只送时间、类型与数值
    expect(api.careBodies.single['target_low'], 3.9);

    await t.drag(find.byType(ListView).first, const Offset(0, 3000));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('care_reply')), findsOneWidget);
    expect(find.text('血糖偏低'), findsWidgets);
    expect(find.byKey(const Key('care_change')), findsOneWidget);
    expect(find.textContaining('19:25  复测血糖'), findsOneWidget);
    final saved = jsonDecode((await store.getSetting(careRemindersKey))!) as List;
    expect(saved.single['title'], '复测血糖');
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('服务器连不上时照样保存记录，不显示错误', (t) async {
    final api = CareApi(offline: true);
    await open(t, api);
    await t.ensureVisible(find.byKey(const Key('life_日常记录')));
    await t.tap(find.byKey(const Key('life_日常记录')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('life_体重')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('num_体重')), '66.5');
    await t.tap(find.text('记录').last);
    await t.pumpAndSettle();
    final events = jsonDecode((await store.getSetting('life_events'))!) as List;
    expect(events.single['weight_kg'], 66.5);
    expect(api.careBodies, hasLength(1));
    expect(find.byKey(const Key('care_reply')), findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('今天的饮食可以修正份量，原始估算保留并送去即时回馈', (t) async {
    await store.putSetting('life_events', jsonEncode([
      {'id': 'm1', 'type': 'meal', 'time': '2026-11-17T18:15:00', 'meal_slot': 'dinner', 'food': '米饭＋红烧排骨',
        'grams': 200.0, 'carbs_g': 64.0, 'estimate': 'photo'},
    ]));
    final api = CareApi();
    await open(t, api);
    await t.scrollUntilVisible(find.byKey(const Key('meal_fix_m1')), 300, scrollable: find.byType(Scrollable).first);
    await t.tap(find.byKey(const Key('meal_fix_m1')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('fix_grams')), '280');
    await t.tap(find.text('保存修正'));
    await t.pumpAndSettle();
    final meal = (jsonDecode((await store.getSetting('life_events'))!) as List).single as Map<String, dynamic>;
    expect([meal['original_grams'], meal['grams'], meal['carbs_g'], meal['corrected_by']], [200.0, 280.0, 89.6, '家属']);
    final sent = (api.careBodies.single['new'] as List).single as Map<String, dynamic>;
    expect(sent['original_grams'], 200.0);
    expect((api.careBodies.single['events'] as List).where((e) => e['type'] == 'meal'), isEmpty); // 不重复计算旧的那餐
    await t.pumpWidget(const SizedBox.shrink());
  });
}
