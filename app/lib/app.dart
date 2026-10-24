import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/settings.dart';
import 'core/theme.dart';
import 'features/chat_page.dart';
import 'features/doctor_page.dart';
import 'features/followup_page.dart';
import 'features/history_page.dart';
import 'features/home_page.dart';
import 'features/import_page.dart';
import 'features/overview_page.dart';
import 'features/review_page.dart';
import 'features/save_page.dart';
import 'features/settings_page.dart';
import 'features/welcome_page.dart';
import 'widgets/common.dart';

GoRouter buildRouter(bool onboarded) => GoRouter(
      initialLocation: onboarded ? '/home' : '/welcome',
      routes: [
        GoRoute(path: '/welcome', builder: (_, _) => const WelcomePage()),
        GoRoute(path: '/home', builder: (_, _) => const HomePage()),
        GoRoute(path: '/import', builder: (_, _) => const ImportPage()),
        GoRoute(path: '/review', builder: (_, _) => const ReviewPage()),
        GoRoute(path: '/overview', builder: (_, _) => const OverviewPage()),
        GoRoute(path: '/followup', builder: (_, _) => const FollowupPage()),
        GoRoute(path: '/chat', builder: (_, s) => ChatPage(focus: s.uri.queryParameters['focus'])),
        GoRoute(path: '/save', builder: (_, _) => const SavePage()),
        GoRoute(path: '/history', builder: (_, _) => const HistoryPage()),
        GoRoute(path: '/doctor', builder: (_, _) => const DoctorPage()),
        GoRoute(path: '/settings', builder: (_, _) => const SettingsPage()),
        GoRoute(path: '/unsupported', builder: (_, _) => const UnsupportedPage()),
        GoRoute(
          path: '/voice',
          builder: (_, _) => const PendingFeaturePage(
            title: '语音对话',
            description: '用户主动进入的实时双向语音对话。与文字对话共享同一份报告和会话，切换时上下文不丢失；重要医疗提示同步显示文字。'
                '状态：未开启 → 连接中 → 聆听 → 思考 → 播报 → 被打断 → 重连 → 失败（失败时退回文字）。',
            plan: ['候选服务：讯飞开放平台 / 阿里云智能语音交互（国内可直接访问）', '支持说话打断（barge-in）、停止播报、转换话题', '弱网、断线、麦克风权限被拒时降级到文字', '实测自然度、延迟、老年人可听清程度'],
          ),
        ),
        GoRoute(
          path: '/medication',
          builder: (_, _) => const PendingFeaturePage(
            title: '药盒/处方识别',
            description: '拍摄药盒或处方，辅助识别药品名称与可能类别，需要您确认；识别不确定时不会猜测药名。只解释经审核的药物类别与尿检指标的可能关联，不给出停药、换药或调整剂量的建议。',
            plan: ['端侧 OCR 识别药名 + 药品名称字典匹配', '识别结果逐项确认', '与选择题「是否在用某类降糖药」联动'],
          ),
        ),
        GoRoute(
          path: '/auth',
          builder: (_, _) => const PendingFeaturePage(
            title: '注册 / 登录',
            description: '注册用于长期记录管理，推荐但不强制。注册不等于上传报告：默认仍只保存在本机，可在设置中按类别选择云端备份。游客升级注册时是否迁移本机历史由您选择，不会静默上传。',
            plan: ['注册方式（手机号/邮箱）待产品确认', '可选云端 OCR（单独授权后才上传原图）', '可选云端备份/恢复（不等于多设备实时同步）'],
          ),
        ),
        GoRoute(
          path: '/reminder',
          builder: (_, _) => const PendingFeaturePage(
            title: '复查提醒',
            description: '复查时间来源必须是您确认的医嘱或经审核的规则，不由 AI 自由决定。使用本机通知，不依赖境外推送服务。',
            plan: ['手动录入医嘱复查时间', '本地通知（通知权限由您决定）'],
          ),
        ),
      ],
    );

class MediLensApp extends ConsumerStatefulWidget {
  final bool onboarded;
  const MediLensApp({super.key, required this.onboarded});
  @override
  ConsumerState<MediLensApp> createState() => _MediLensAppState();
}

class _MediLensAppState extends ConsumerState<MediLensApp> {
  late final GoRouter router = buildRouter(widget.onboarded);

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(settingsProvider.select((s) => s.displayMode));
    return MaterialApp.router(
      title: 'MediLens',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(mode),
      routerConfig: router,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
    );
  }
}

class UnsupportedPage extends StatelessWidget {
  const UnsupportedPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('暂不支持该报告')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Icon(Icons.description_outlined, size: 64, color: Colors.blueGrey),
            const SizedBox(height: 16),
            const Text('没有识别到尿常规或尿白蛋白/肌酐比（UACR）项目。', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 8),
            const Text('当前版本只支持这两类报告，无法解读这份报告。如果这确实是尿检报告，请尝试重新拍摄（保持报告平整、光线充足）。'),
            const SizedBox(height: 24),
            FilledButton(onPressed: () => context.go('/home'), child: const Text('返回首页')),
          ]),
        ),
      );
}
