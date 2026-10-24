// 课程文档截图（合成数据）。运行：
// flutter drive --driver=test_driver/screenshot_driver.dart --target=integration_test/screenshots_test.dart -d emulator-5554
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:medilens/app.dart';
import 'package:medilens/data/local_store.dart';

import 'app_flow_test.dart' show pumpUntil, tapWhenReady, goBack;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> shot(WidgetTester t, String name) async {
    await t.pump(const Duration(milliseconds: 800));
    await binding.takeScreenshot(name);
  }

  testWidgets('截图：主要页面（普通模式 + 老年模式）', (t) async {
    await binding.convertFlutterSurfaceToImage();
    await t.pumpWidget(ProviderScope(
      overrides: [localStoreProvider.overrideWithValue(MemoryStore())],
      child: const MediLensApp(onboarded: false),
    ));
    await pumpUntil(t, find.byKey(const Key('guest_entry')));
    await shot(t, '01_启动页');
    await tapWhenReady(t, find.byKey(const Key('guest_entry')));
    await pumpUntil(t, find.text('拍照解读'));
    await shot(t, '02_主页');

    await tapWhenReady(t, find.byKey(const Key('sample_button')));
    await tapWhenReady(t, find.text('尿蛋白被遮挡（需确认）'));
    await pumpUntil(t, find.byKey(const Key('recognize_button')));
    await shot(t, '03_导入预览');
    await tapWhenReady(t, find.byKey(const Key('recognize_button')));
    await pumpUntil(t, find.textContaining('请确认 第 1/'));
    await t.pump(const Duration(seconds: 2));
    await shot(t, '04_局部确认_原图高亮与候选');
    await tapWhenReady(t, find.byKey(const Key('candidate_2+')));
    await pumpUntil(t, find.text('识别结果'));
    await shot(t, '05_识别结果');
    await tapWhenReady(t, find.byKey(const Key('to_overview')));
    await pumpUntil(t, find.text('同意并继续'));
    await shot(t, '06_首次解读前告知同意');
    await tapWhenReady(t, find.text('同意并继续'));
    await pumpUntil(t, find.text('解读总览'));
    await shot(t, '07_解读总览');
    await tapWhenReady(t, find.byKey(const Key('start_followup')));
    await pumpUntil(t, find.textContaining('留尿检查前'));
    await shot(t, '08_动态选择题');
    await goBack(t);
    await tapWhenReady(t, find.byKey(const Key('detail_PRO')));
    await pumpUntil(t, find.byKey(const Key('explain_PRO')));
    await shot(t, '09_详细了解原位展开');
    await tapWhenReady(t, find.text('有疑问？文字提问'));
    await tapWhenReady(t, find.byKey(const Key('chat_input')));
    await t.enterText(find.byKey(const Key('chat_input')), '我能停药吗');
    await tapWhenReady(t, find.byKey(const Key('chat_send')));
    await pumpUntil(t, find.text('安全提示'));
    await tapWhenReady(t, find.byKey(const Key('quick_复诊问什么')));
    await pumpUntil(t, find.textContaining('复诊时可以问医生'));
    FocusManager.instance.primaryFocus?.unfocus();
    await shot(t, '10_文字对话_越界问题安全回复');
    await goBack(t);
    await tapWhenReady(t, find.byKey(const Key('finish')));
    await pumpUntil(t, find.byKey(const Key('save_local')));
    await shot(t, '11_保存选择');
    await tapWhenReady(t, find.byKey(const Key('no_save')));

    // 老年模式：尿糖+酮体阳性
    await tapWhenReady(t, find.byTooltip('设置'));
    await tapWhenReady(t, find.byKey(const Key('elder_switch')));
    await t.pump(const Duration(seconds: 1));
    await shot(t, '12_设置中心_老年模式');
    await goBack(t);
    await tapWhenReady(t, find.byKey(const Key('sample_button')));
    await tapWhenReady(t, find.text('尿糖+尿酮体阳性'));
    await tapWhenReady(t, find.byKey(const Key('recognize_button')));
    await tapWhenReady(t, find.byKey(const Key('to_overview')));
    await pumpUntil(t, find.byKey(const Key('urgent_alert')));
    await shot(t, '13_老年模式_紧急提示置顶');
    await tapWhenReady(t, find.byKey(const Key('start_followup')));
    await pumpUntil(t, find.textContaining('格列净'));
    await shot(t, '14_老年模式_选择题');
  });
}
