// 端到端测试（在 Android 模拟器/真机上运行，连接本机后端 http://10.0.2.2:8000，使用真实端侧 OCR）。
// 使用内置合成报告（虚构数据）。运行：见 README「端到端测试」。
//
// 场景 A（普通模式）：游客 → 合成报告（尿蛋白被遮挡）→ 本地 OCR → 局部确认（选候选）→ 授权 → 总览
//                  → 选择题（跳过/上一题/回答）→ 详细了解（原位展开）→ 快捷提问 → 不保存
// 场景 B（老年模式）：尿糖+酮体阳性 → 紧急提示置顶 → 选择题 → 越界提问（停药）安全模板 → 保存到本机 → 历史可见 → 删除

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:medilens/app.dart';
import 'package:medilens/core/settings.dart';
import 'package:medilens/data/local_store.dart';

/// 等待目标出现；列表懒加载时目标可能尚未构建，等待一段时间后向下滚动查找。
Future<void> pumpUntil(WidgetTester t, Finder f, {Duration timeout = const Duration(seconds: 60), bool scroll = true}) async {
  final end = DateTime.now().add(timeout);
  var waited = 0;
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 250));
    if (f.evaluate().isNotEmpty) return;
    waited++;
    final scrollables = find.byType(Scrollable);
    if (scroll && waited > 8 && scrollables.evaluate().isNotEmpty && !_dialogOpen()) {
      await t.drag(scrollables.first, const Offset(0, -400), warnIfMissed: false);
    }
  }
  throw TestFailure('等待超时：$f');
}

/// 点击 AppBar 返回按钮（中文本地化提示为「返回」），与用户操作一致。
Future<void> goBack(WidgetTester t) async {
  await tapWhenReady(t, find.byTooltip('返回'));
  await t.pump(const Duration(seconds: 1));
}

bool _dialogOpen() => find.byType(AlertDialog).evaluate().isNotEmpty || find.byType(BottomSheet).evaluate().isNotEmpty;

Future<void> tapWhenReady(WidgetTester t, Finder f) async {
  await pumpUntil(t, f);
  // 等展开/转场动画结束再定位，否则目标位置会在滚动后继续移动
  await t.pump(const Duration(milliseconds: 600));
  await t.ensureVisible(f.first);
  await t.pump(const Duration(milliseconds: 600));
  await t.tap(f.first);
  await t.pump(const Duration(milliseconds: 300));
}

Future<void> startApp(WidgetTester t, MemoryStore store) async {
  await t.pumpWidget(ProviderScope(
    overrides: [localStoreProvider.overrideWithValue(store)],
    child: const MediLensApp(onboarded: false),
  ));
  await t.pump(const Duration(seconds: 1));
}

Future<void> openSample(WidgetTester t, String label) async {
  await tapWhenReady(t, find.byKey(const Key('sample_button')));
  await tapWhenReady(t, find.text(label));
  await tapWhenReady(t, find.byKey(const Key('recognize_button')));
}

Future<void> acceptConsentAndOverview(WidgetTester t) async {
  await tapWhenReady(t, find.byKey(const Key('to_overview')));
  await tapWhenReady(t, find.text('同意并继续'));
  await pumpUntil(t, find.text('解读总览'));
  expect(find.text('测试规则，未经医学审核 · 仅限合成数据测试，不能用于真实诊疗'), findsWidgets);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('场景 A：普通模式全流程（局部确认 + 选择题回退 + 详细了解 + 提问 + 不保存）', (t) async {
    final store = MemoryStore();
    await startApp(t, store);
    await tapWhenReady(t, find.byKey(const Key('guest_entry')));
    await openSample(t, '尿蛋白被遮挡（需确认）');

    // P03：被遮挡字段需要确认，显示第 x/y 项与候选
    await pumpUntil(t, find.textContaining('请确认 第 1/'));
    expect(find.textContaining('「尿蛋白」需要您确认'), findsOneWidget);
    await tapWhenReady(t, find.byKey(const Key('candidate_2+')));
    await pumpUntil(t, find.text('识别结果'));
    expect(find.text('已确认'), findsOneWidget);

    await acceptConsentAndOverview(t);
    // 尿蛋白 2+ 无规则覆盖 → 不能显示为绿色
    expect(find.text('部分信息无法判断'), findsOneWidget);

    // P05：跳过 → 上一题 → 重新回答
    await tapWhenReady(t, find.byKey(const Key('start_followup')));
    await pumpUntil(t, find.textContaining('留尿检查前'));
    await tapWhenReady(t, find.byKey(const Key('ans_skip')));
    await pumpUntil(t, find.textContaining('医生是否已经'));
    await tapWhenReady(t, find.byKey(const Key('prev_question')));
    await pumpUntil(t, find.textContaining('留尿检查前'));
    await tapWhenReady(t, find.byKey(const Key('opt_exercise')));
    await tapWhenReady(t, find.text('确定'));
    await pumpUntil(t, find.textContaining('医生是否已经'));
    await tapWhenReady(t, find.byKey(const Key('ans_unknown')));
    await tapWhenReady(t, find.byKey(const Key('followup_done')));

    // P06：指标「详细了解」原位展开
    await tapWhenReady(t, find.byKey(const Key('detail_PRO')));
    await pumpUntil(t, find.byKey(const Key('explain_PRO')));
    expect(find.text('这个指标是什么'), findsOneWidget);

    // 快捷提问
    await tapWhenReady(t, find.text('有疑问？文字提问'));
    await tapWhenReady(t, find.byKey(const Key('quick_复诊问什么')));
    await pumpUntil(t, find.textContaining('复诊时可以问医生'));
    await goBack(t);
    await t.pump(const Duration(seconds: 1));

    // 不保存
    await tapWhenReady(t, find.byKey(const Key('finish')));
    await tapWhenReady(t, find.byKey(const Key('no_save')));
    await pumpUntil(t, find.text('拍照解读'));
    expect(store.reports, isEmpty);
  });

  testWidgets('场景 B：老年模式全流程（紧急提示 + 越界提问 + 本机保存 + 删除）', (t) async {
    final store = MemoryStore();
    await startApp(t, store);
    // 老年模式
    await tapWhenReady(t, find.byType(SwitchListTile));
    await pumpUntil(t, find.byKey(const Key('guest_entry')));
    final ctx = t.element(find.byKey(const Key('guest_entry')));
    expect(ProviderScope.containerOf(ctx).read(settingsProvider).elder, isTrue);
    await tapWhenReady(t, find.byKey(const Key('guest_entry')));

    await openSample(t, '尿糖+尿酮体阳性');
    await pumpUntil(t, find.text('识别结果'));
    await acceptConsentAndOverview(t);

    // 紧急提示置顶，不等待问卷
    expect(find.byKey(const Key('urgent_alert')), findsOneWidget);
    expect(find.text('建议尽快就医'), findsOneWidget);

    // 选择题：SGLT2
    await tapWhenReady(t, find.byKey(const Key('start_followup')));
    await pumpUntil(t, find.textContaining('格列净'));
    await tapWhenReady(t, find.byKey(const Key('opt_yes_known')));
    await pumpUntil(t, find.textContaining('最近 24 小时'));
    await goBack(t);
    await t.pump(const Duration(seconds: 1));
    // 回答后命中 R-02（测试规则）
    await pumpUntil(t, find.textContaining('SGLT2 抑制剂'));

    // 规则「详细了解」
    await tapWhenReady(t, find.byKey(const Key('detail_R-01')));
    await pumpUntil(t, find.byKey(const Key('explain_R-01')));

    // 越界提问：停药 → 安全模板
    await tapWhenReady(t, find.text('有疑问？文字提问'));
    await tapWhenReady(t, find.byKey(const Key('chat_input')));
    await t.enterText(find.byKey(const Key('chat_input')), '我能停药吗');
    await tapWhenReady(t, find.byKey(const Key('chat_send')));
    await pumpUntil(t, find.text('安全提示'));
    expect(find.textContaining('必须由您的医生决定'), findsOneWidget);
    await goBack(t);
    await t.pump(const Duration(seconds: 1));

    // 保存到本机
    await tapWhenReady(t, find.byKey(const Key('finish')));
    await tapWhenReady(t, find.byKey(const Key('save_local')));
    await pumpUntil(t, find.text('已保存到本机'));
    expect(store.reports.length, 1);
    expect(store.reports.values.first.items, isNotEmpty);

    // 历史可见并删除
    await tapWhenReady(t, find.byKey(const Key('no_save')));
    await tapWhenReady(t, find.text('历史记录'));
    await pumpUntil(t, find.text('检验日期 2026-10-01'));
    await tapWhenReady(t, find.text('检验日期 2026-10-01'));
    await tapWhenReady(t, find.text('删除这条记录'));
    await tapWhenReady(t, find.text('删除'));
    await pumpUntil(t, find.text('本机还没有保存的报告'));
    expect(store.reports, isEmpty);
  });
}
