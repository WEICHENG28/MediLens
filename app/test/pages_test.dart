// 页面测试：用真实后端生成的解读结果（test/fixtures/analysis_glucose_ketone.json，合成数据）渲染总览，
// 普通模式与老年模式各渲染一次，确认关键元素都在、老年模式字号更大。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:medilens/core/models.dart';
import 'package:medilens/core/session.dart';
import 'package:medilens/core/settings.dart';
import 'package:medilens/core/theme.dart';
import 'package:medilens/data/local_store.dart';
import 'package:medilens/features/overview_page.dart';
import 'package:medilens/features/settings_page.dart';

class _FixedSession extends SessionNotifier {
  @override
  ReportSession build() => ReportSession(
        id: 't',
        report: const ParsedReport(reportType: 'urinalysis', items: []),
        analysis: jsonDecode(File('test/fixtures/analysis_glucose_ketone.json').readAsStringSync()) as Map<String, dynamic>,
      );
}

class _Settings extends SettingsNotifier {
  final DisplayMode mode;
  _Settings(this.mode);
  @override
  AppSettings build() => AppSettings(displayMode: mode, onboarded: true);
}

Widget host(DisplayMode mode, Widget page) => ProviderScope(
      overrides: [
        sessionProvider.overrideWith(_FixedSession.new),
        settingsProvider.overrideWith(() => _Settings(mode)),
        localStoreProvider.overrideWithValue(MemoryStore()),
      ],
      child: MaterialApp.router(
        theme: buildTheme(mode),
        routerConfig: GoRouter(routes: [GoRoute(path: '/', builder: (_, _) => page)]),
      ),
    );

void main() {
  for (final mode in DisplayMode.values) {
    testWidgets('总览页关键元素齐全（${mode.name}）', (t) async {
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 2.75;
      addTearDown(t.view.reset);
      await t.pumpWidget(host(mode, const OverviewPage()));
      await t.pump();
      expect(find.byKey(const Key('urgent_alert')), findsOneWidget);
      expect(find.textContaining('测试规则，未经医学审核'), findsWidgets);
      expect(find.text('建议尽快就医'), findsOneWidget);
      expect(find.byKey(const Key('start_followup')), findsOneWidget);
      // 无法确认的尿蛋白显示为「无法确认」，不显示为正常
      await t.scrollUntilVisible(find.text('尿蛋白'), 300);
      expect(find.text('无法确认'), findsWidgets);
      await t.scrollUntilVisible(find.byKey(const Key('finish')), 300);
      expect(find.byKey(const Key('finish')), findsOneWidget);
    });
  }

  testWidgets('老年模式字号与点击区域大于普通模式', (t) async {
    double fontOf(DisplayMode m) => buildTheme(m).textTheme.bodyLarge!.fontSize!;
    double tapOf(DisplayMode m) => buildTheme(m).filledButtonTheme.style!.minimumSize!.resolve({})!.height;
    expect(fontOf(DisplayMode.elder), greaterThan(fontOf(DisplayMode.normal)));
    expect(tapOf(DisplayMode.elder), greaterThanOrEqualTo(64));
  });

  testWidgets('设置页可切换老年模式', (t) async {
    await t.pumpWidget(host(DisplayMode.normal, const SettingsPage()));
    await t.pump();
    expect(find.byKey(const Key('elder_switch')), findsOneWidget);
    expect(find.textContaining('游客只能使用本机识别'), findsOneWidget);
  });
}
