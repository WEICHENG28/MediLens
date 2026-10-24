// P01 启动与入口：说明核心功能与隐私边界；游客体验 / 注册登录（待实现）；不强制填写病史。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/settings.dart';
import '../core/theme.dart';

class WelcomePage extends ConsumerWidget {
  const WelcomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final t = Theme.of(context).textTheme;
    Widget point(IconData i, String title, String body) => ListTile(
          leading: Icon(i, color: Theme.of(context).colorScheme.primary, size: 32),
          title: Text(title, style: t.titleMedium),
          subtitle: Text(body),
        );
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(20), children: [
          const SizedBox(height: 12),
          Text('MediLens', style: t.headlineLarge?.copyWith(fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary)),
          Text('尿常规 / UACR 报告智能解读', style: t.titleLarge),
          const SizedBox(height: 20),
          point(Icons.photo_camera_outlined, '拍照即可解读', '自动识别报告，只对不确定的地方请您确认'),
          point(Icons.phone_android, '游客模式：报告图片只在本机识别', '原始图片不会上传；解读时仅发送确认后的指标数值（不含姓名、医院）'),
          point(Icons.medical_information_outlined, '辅助理解，不替代医生', '不做诊断，不建议停药、换药或调整剂量；医生医嘱优先'),
          point(Icons.science_outlined, '当前为内部测试版', '判读规则未经医学审核，仅用于合成报告测试'),
          const SizedBox(height: 12),
          SwitchListTile(
            title: const Text('老年模式（大字、大按钮）'),
            subtitle: const Text('之后也可在「设置」中切换'),
            value: s.elder,
            onChanged: (v) => ref.read(settingsProvider.notifier).update(s.copyWith(displayMode: v ? DisplayMode.elder : DisplayMode.normal)),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('guest_entry'),
            icon: const Icon(Icons.person_outline),
            label: const Text('游客体验（无需注册）'),
            onPressed: () async {
              await ref.read(settingsProvider.notifier).update(s.copyWith(onboarded: true));
              if (context.mounted) context.go('/home');
            },
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.login),
            label: const Text('注册 / 登录（待实现）'),
            onPressed: () => context.push('/auth'),
          ),
        ]),
      ),
    );
  }
}
