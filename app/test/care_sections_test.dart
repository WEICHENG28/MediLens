import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:medilens/core/api_client.dart';
import 'package:medilens/core/desktop_pet.dart';
import 'package:medilens/core/task_receipts.dart';
import 'package:medilens/data/local_store.dart';
import 'package:medilens/features/care_pages.dart';
import 'package:medilens/features/life_page.dart';

final _now = DateTime(2026, 11, 18, 10, 0);

Map<String, dynamic> _ev(int day, int h, Map<String, dynamic> x) =>
    {'time': DateTime(2026, 11, 4 + day, h).toIso8601String().substring(0, 19), ...x};

/// 两天的合成示范资料（第 0、1 天）。
final _demoEvents = [
  for (final d in [0, 1]) ...[
    _ev(d, 7, {'type': 'glucose', 'glucose': 7.2, 'glucose_source': 'finger'}),
    _ev(d, 18, {'type': 'meal', 'meal_slot': 'dinner', 'food': '米饭', 'carbs_g': 60.0, 'grams': 180.0, 'estimate': 'photo'}),
    _ev(d, 20, {'type': 'glucose', 'glucose': 12.1, 'glucose_source': 'finger'}),
  ],
];

const _profile = {
  'findings': [
    {'id': 'night_low', 'level': 'fact', 'urgent': true, 'title': '夜间低值', 'headline': '有 2 晚出现夜间低血糖',
      'detail': '指血复核 3.8、3.7', 'boundary': '请尽快带记录回诊；不要自行调整用药。'},
    {'id': 'high_carb_dinner', 'level': 'association', 'urgent': false, 'title': '晚餐内容', 'confidence': '初步',
      'headline': '主食多或有甜饮料的晚餐，饭后血糖比较高', 'detail': '6 次中 5 次', 'question': '晚餐怎么分配？'},
    {'id': 'photo_estimate', 'level': 'unknown', 'urgent': false, 'title': '照片估算', 'headline': '照片估算的份量只供参考'},
  ],
  'watching': [{'id': 'walk_dinner', 'title': '晚餐后活动', 'progress': '已记录 1 次，至少需要 4 次', 'support': 1, 'against': 0, 'needed': 4}],
  'metrics': {'source': 'finger', 'readings': 4, 'tir': 0.5, 'tar': 0.5, 'tbr': 0.0,
    'post_meal': {'breakfast': {'median': 9.0, 'n': 14, 'high_count': 0}, 'dinner': {'median': 12.1, 'n': 14, 'high_count': 7}}},
  'disclaimer': '关联只代表相关。',
};

class DemoApi extends ApiClient {
  final calls = <String, List<Map<String, dynamic>>>{};
  DemoApi() : super('https://unused.invalid');
  void _log(String k, Map<String, dynamic> b) => (calls[k] ??= []).add(b);
  @override
  Future<Map<String, dynamic>> lifestyle(Map<String, dynamic> body) async => throw ApiException('离线');
  @override
  Future<Map<String, dynamic>> careDemo(String state, String today, {bool cgm = true}) async {
    _log('demo', {'state': state, 'today': today, 'cgm': cgm});
    return {'synthetic': true, 'events': _demoEvents, 'schedule': [{'task': 'medication', 'time': '18:00', 'label': '晚'}]};
  }
  @override
  Future<Map<String, dynamic>> careProfile(Map<String, dynamic> body) async { _log('profile', body); return Map.of(_profile); }
  @override
  Future<Map<String, dynamic>> careDaily(Map<String, dynamic> body) async {
    _log('daily', body);
    return {'lines': ['今天测了 2 次血糖'], 'tonight': ['今天晚餐比平常晚，睡前请测一次血糖'], 'missing': [], 'watching': [],
      'new_findings': [], 'encouragement': '记录本身就很了不起'};
  }
  @override
  Future<Map<String, dynamic>> careGoal(Map<String, dynamic> body) async {
    _log('goal', body);
    final g = {'id': 'dinner_carbs', 'title': '晚餐主食少一点、不喝甜饮料', 'why': '饭后血糖比较高', 'how': ['主食减少约四分之一'],
      'check': '比较前后', 'boundary': '请先和医生或营养师确认。'};
    return {'suggested': g, 'progress': body['goal_id'] == null ? null
        : {'goal': g, 'started': body['started'], 'days': 1, 'done_days': 0, 'verdict': '资料还不够', 'text': '至少需要 4 次'}};
  }
  @override
  Future<Map<String, dynamic>> careRecord(Map<String, dynamic> body) async {
    _log('record', body);
    return {'feedback': [
      {'tone': 'info', 'title': '血糖已记录', 'text': '普通'},
      {'tone': 'caution', 'title': '晚餐已记录', 'text': '比平常晚'},
    ], 'changes': [], 'reminders': [], 'alerts': []};
  }
  @override
  Future<Map<String, dynamic>> careScenario(String name, String at, {bool cgm = true}) async {
    _log('scenario', {'name': name, 'at': at});
    return {'events': [{'type': 'glucose', 'time': at, 'glucose': 3.6, 'glucose_source': 'cgm'}]};
  }
  @override
  Future<Map<String, dynamic>> careVisit(Map<String, dynamic> body) async => {
    'start': '2026-11-03', 'end': '2026-11-16', 'lab': {'hba1c': 7.3}, 'lab_date': '2026-11-01',
    'overview': ['指血：范围内 50%'], 'post_meal': {'dinner': 12.1}, 'facts': ['晚餐后的血糖最高'],
    'associations': ['主食多的晚餐，饭后血糖比较高'], 'questions': ['晚餐延迟时，用药和进餐时间应该怎么配合？'],
    'cannot_judge': ['照片估算的份量只供参考'], 'note': '不构成诊断或用药建议'};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MemoryStore store;
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(DesktopPet.channel, (_) async => null);
    store = MemoryStore();
  });
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(DesktopPet.channel, null));

  Future<void> open(WidgetTester t, DemoApi api) async {
    await store.putSetting('life_onboarded', 'true');
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 2.75;
    addTearDown(t.view.reset);
    await t.pumpWidget(ProviderScope(overrides: [localStoreProvider.overrideWithValue(store),
      apiClientProvider.overrideWithValue(api), taskClockProvider.overrideWithValue(() => _now)],
      child: const MaterialApp(home: LifePage())));
    await t.pumpAndSettle();
  }

  Future<void> startDemo(WidgetTester t, String state) async {
    await t.tap(find.byType(PopupMenuButton<String>));
    await t.pumpAndSettle();
    await t.tap(find.text('示范模式：陈女士（虚构病例）'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key('demo_$state')));
    await t.pumpAndSettle();
  }


  testWidgets('示范完整资料：显示需要留意、分级结论、观察中、图表、今日小结与小目标', (t) async {
    final api = DemoApi();
    await open(t, api);
    await startDemo(t, 'chen14');
    expect(api.calls['demo']!.single['today'], '2026-11-17'); // 以昨天为最后一天
    expect(find.byKey(const Key('demo_bar')), findsOneWidget);
    final list = find.byType(Scrollable).first;
    for (final k in ['day_timeline', 'daily_summary', 'finding_night_low', 'finding_high_carb_dinner', 'watch_walk_dinner',
      'meal_compare', 'goal_card']) {
      await t.scrollUntilVisible(find.byKey(Key(k)), 300, scrollable: list);
      expect(find.byKey(Key(k)), findsOneWidget, reason: k);
    }
    expect(find.text('需要留意'), findsOneWidget);
    expect(find.textContaining('今晚：今天晚餐比平常晚'), findsOneWidget);
    await t.ensureVisible(find.byKey(const Key('goal_start')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('goal_start')));
    await t.pumpAndSettle();
    expect(api.calls['goal']!.last['goal_id'], 'dinner_carbs');
    expect(find.byKey(const Key('goal_verdict')), findsOneWidget);
    // 示范时提醒不写入本机
    expect(await store.getSetting('care_reminders_v1'), isNull);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('从空白开始逐日播放；情境按钮在隔天发生，连按两个在同一天', (t) async {
    final api = DemoApi();
    await open(t, api);
    await startDemo(t, 'new');
    expect(find.text('下一天'), findsOneWidget);
    await t.tap(find.byKey(const Key('demo_next')));
    await t.pumpAndSettle();
    final day0 = (api.calls['record']!.last['new'] as List);
    expect(day0, hasLength(3));
    expect(find.text('晚餐已记录'), findsOneWidget); // 逐日播放只留需要注意的回应
    expect(find.text('血糖已记录'), findsNothing);
    await t.tap(find.byKey(const Key('scenario_late_high_carb_dinner')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('scenario_night_low')));
    await t.pumpAndSettle();
    final ats = [for (final c in api.calls['scenario']!) (c['at'] as String).substring(0, 10)];
    expect(ats, ['2026-11-05', '2026-11-05']);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('复诊摘要页：分段显示，复制文字包含问题清单', (t) async {
    final api = DemoApi();
    await t.pumpWidget(ProviderScope(overrides: [apiClientProvider.overrideWithValue(api)],
        child: const MaterialApp(home: VisitSummaryPage(body: {'events': []}))));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('visit_summary')), findsOneWidget);
    expect(find.textContaining('想请教医生'), findsOneWidget);
    expect(find.textContaining('糖化血红蛋白 7.3%'), findsOneWidget);
    String? copied;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    await t.tap(find.byKey(const Key('visit_copy')));
    await t.pumpAndSettle();
    expect(copied, contains('1. 晚餐延迟时'));
    expect(copied, contains('不构成诊断或用药建议'));
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });
}
