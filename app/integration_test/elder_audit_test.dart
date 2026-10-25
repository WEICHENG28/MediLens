// 老年模式全页面截图检查（对比度、截断、可点击区域）。截图保存到 docs/screenshots/audit/（不入库）。
// 运行：flutter drive --driver=test_driver/screenshot_driver.dart --target=integration_test/elder_audit_test.dart -d emulator-5554
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:medilens/app.dart';
import 'package:medilens/data/local_store.dart';

import 'app_flow_test.dart' show pumpUntil, tapWhenReady, goBack;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  var n = 0;

  Future<void> shot(WidgetTester t, String name) async {
    await t.pump(const Duration(milliseconds: 800));
    n++;
    await binding.takeScreenshot('audit/${n.toString().padLeft(2, '0')}_$name');
  }

  Future<void> scrollDown(WidgetTester t) async {
    await t.drag(find.byType(Scrollable).first, const Offset(0, -600), warnIfMissed: false);
    await t.pump(const Duration(milliseconds: 600));
  }

  Future<void> scrollTop(WidgetTester t) async {
    for (var i = 0; i < 4; i++) {
      await t.drag(find.byType(Scrollable).first, const Offset(0, 1500), warnIfMissed: false);
      await t.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('老年模式全页面截图', (t) async {
    await binding.convertFlutterSurfaceToImage();
    await t.pumpWidget(ProviderScope(
      overrides: [localStoreProvider.overrideWithValue(MemoryStore())],
      child: const MediLensApp(onboarded: false),
    ));
    await pumpUntil(t, find.byKey(const Key('guest_entry')));
    await tapWhenReady(t, find.byType(SwitchListTile));
    await shot(t, '启动页');
    await tapWhenReady(t, find.byKey(const Key('guest_entry')));
    await pumpUntil(t, find.text('拍照解读'));
    await shot(t, '主页');
    await scrollDown(t);
    await shot(t, '主页_下方');

    // 局部确认
    await tapWhenReady(t, find.byKey(const Key('sample_button')));
    await shot(t, '示例报告选单');
    await tapWhenReady(t, find.text('尿蛋白被遮挡（需确认）'));
    await pumpUntil(t, find.byKey(const Key('recognize_button')));
    await shot(t, '导入预览');
    await tapWhenReady(t, find.byKey(const Key('recognize_button')));
    await pumpUntil(t, find.textContaining('请确认 第 1/'));
    await t.pump(const Duration(seconds: 2));
    await shot(t, '局部确认');
    await scrollDown(t);
    await shot(t, '局部确认_下方');
    await tapWhenReady(t, find.byKey(const Key('candidate_2+')));
    await pumpUntil(t, find.text('识别结果'));
    await shot(t, '识别结果');
    await tapWhenReady(t, find.byKey(const Key('to_overview')));
    await pumpUntil(t, find.text('同意并继续'));
    await shot(t, '告知同意');
    await tapWhenReady(t, find.text('同意并继续'));
    await pumpUntil(t, find.text('解读总览'));
    await shot(t, '总览');
    await scrollDown(t);
    await shot(t, '总览_中');
    await scrollDown(t);
    await shot(t, '总览_下');
    await scrollTop(t);

    // 选择题
    await tapWhenReady(t, find.byKey(const Key('start_followup')));
    await pumpUntil(t, find.textContaining('留尿检查前'));
    await shot(t, '选择题_多选');
    await tapWhenReady(t, find.byKey(const Key('ans_skip')));
    await pumpUntil(t, find.textContaining('医生是否已经'));
    await shot(t, '选择题_单选');
    await tapWhenReady(t, find.byKey(const Key('ans_unknown')));
    await pumpUntil(t, find.byKey(const Key('followup_done')));
    await shot(t, '选择题_完成');
    await tapWhenReady(t, find.byKey(const Key('followup_done')));

    // 详细了解
    await tapWhenReady(t, find.byKey(const Key('detail_PRO')));
    await pumpUntil(t, find.byKey(const Key('explain_PRO')));
    await shot(t, '详细了解');

    // 对话（用户气泡 + 安全提示 + 普通回答）
    await tapWhenReady(t, find.text('有疑问？文字提问'));
    await tapWhenReady(t, find.byKey(const Key('quick_复诊问什么')));
    await pumpUntil(t, find.textContaining('复诊时可以问医生'));
    await tapWhenReady(t, find.byKey(const Key('chat_input')));
    await t.enterText(find.byKey(const Key('chat_input')), '我能停藥嗎');
    await tapWhenReady(t, find.byKey(const Key('chat_send')));
    await pumpUntil(t, find.text('安全提示'));
    FocusManager.instance.primaryFocus?.unfocus();
    await shot(t, '对话');
    await goBack(t);

    // 保存
    await tapWhenReady(t, find.byKey(const Key('finish')));
    await pumpUntil(t, find.byKey(const Key('save_local')));
    await shot(t, '保存选择');
    await tapWhenReady(t, find.byKey(const Key('save_local')));
    await pumpUntil(t, find.text('已保存到本机'));
    await shot(t, '已保存');
    await tapWhenReady(t, find.byKey(const Key('no_save')));

    // 历史、复诊问题、设置、待实现、不支持
    await tapWhenReady(t, find.text('历史记录'));
    await tapWhenReady(t, find.text('检验日期 2026-10-01'));
    await shot(t, '历史记录');
    await goBack(t);
    await tapWhenReady(t, find.text('复诊问题'));
    await shot(t, '复诊问题');
    await goBack(t);
    await tapWhenReady(t, find.text('语音对话'));
    await shot(t, '待实现_语音');
    await goBack(t);
    await tapWhenReady(t, find.byTooltip('设置'));
    await shot(t, '设置');
    await scrollDown(t);
    await shot(t, '设置_下方');
    await goBack(t);
    await tapWhenReady(t, find.byKey(const Key('sample_button')));
    await tapWhenReady(t, find.text('非尿检报告（肝功能）'));
    await tapWhenReady(t, find.byKey(const Key('recognize_button')));
    await pumpUntil(t, find.text('暂不支持该报告'));
    await shot(t, '不支持报告');
  });
}
