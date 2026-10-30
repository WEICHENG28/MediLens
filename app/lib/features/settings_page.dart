// P11 设置中心：集中管理显示、OCR、语音、隐私与数据、账号、提醒、医疗边界说明。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/settings.dart';
import '../core/theme.dart';
import '../data/local_store.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    Widget head(String t) => Padding(padding: const EdgeInsets.fromLTRB(16, 20, 16, 4), child: Text(t, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Theme.of(context).colorScheme.primary)));
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(children: [
        head('账号'),
        ListTile(leading: const Icon(Icons.person_outline), title: const Text('当前：游客'), subtitle: const Text('注册/登录（待实现）'), onTap: () => context.push('/auth')),
        head('显示'),
        SwitchListTile(
          key: const Key('elder_switch'),
          secondary: const Icon(Icons.text_increase),
          title: const Text('老年模式'),
          subtitle: const Text('大字号、大按钮、高对比度，功能与普通模式完全相同'),
          value: s.elder,
          onChanged: (v) => n.update(s.copyWith(displayMode: v ? DisplayMode.elder : DisplayMode.normal)),
        ),
        head('报告识别'),
        const ListTile(
          leading: Icon(Icons.phone_android),
          title: Text('识别方式：本机识别'),
          subtitle: Text('游客只能使用本机识别，原图不会上传。云端识别仅注册用户在单独授权后可选（待实现）'),
        ),
        head('语音'),
        ListTile(
          leading: const Icon(Icons.speed),
          title: const Text('朗读语速'),
          subtitle: Slider(value: s.speechRate, min: 0.3, max: 0.7, divisions: 4, label: s.speechRate.toStringAsFixed(1), onChanged: (v) => n.update(s.copyWith(speechRate: v))),
        ),
        SwitchListTile(secondary: const Icon(Icons.record_voice_over_outlined), title: const Text('自动朗读解释'), value: s.autoRead, onChanged: (v) => n.update(s.copyWith(autoRead: v))),
        const ListTile(leading: Icon(Icons.graphic_eq), title: Text('音色选择、实时语音对话（待实现）'), subtitle: Text('当前朗读使用手机系统中文语音')),
        head('隐私与数据'),
        SwitchListTile(
          secondary: const Icon(Icons.cloud_outlined),
          title: const Text('允许发送确认后的指标用于解读'),
          subtitle: const Text('只发送项目、结果、单位、参考范围、日期；不发送图片、姓名、医院。关闭后无法生成解读'),
          value: s.aiConsent,
          onChanged: (v) => n.update(s.copyWith(aiConsent: v)),
        ),
        const ListTile(leading: Icon(Icons.backup_outlined), title: Text('云端备份（待实现）'), subtitle: Text('注册后可按类别选择：报告、结构化指标、对话记录；未选中的不会上传')),
        ListTile(
          leading: const Icon(Icons.delete_forever_outlined, color: Colors.red),
          title: const Text('删除本机全部记录'),
          onTap: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (c) => AlertDialog(content: const Text('删除本机全部报告记录？此操作不可恢复。'), actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
                FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('删除')),
              ]),
            );
            if (ok == true) {
              await ref.read(localStoreProvider).deleteAll();
              await ref.read(localStoreProvider).putSetting('life_events', '[]');
              await ref.read(localStoreProvider).putSetting('life_tasks', '[]');
              ref.invalidate(historyProvider);
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已删除')));
            }
          },
        ),
        head('提醒'),
        ListTile(leading: const Icon(Icons.notifications_none), title: const Text('复查提醒（待实现）'), subtitle: const Text('使用本机通知，不依赖境外推送服务'), onTap: () => context.push('/reminder')),
        head('开发调试'),
        ListTile(
          leading: const Icon(Icons.dns_outlined),
          title: const Text('解读服务地址'),
          subtitle: Text(s.apiBaseUrl),
          onTap: () async {
            final c = TextEditingController(text: s.apiBaseUrl);
            final v = await showDialog<String>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('解读服务地址'),
                content: TextField(controller: c),
                actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('确定'))],
              ),
            );
            if (v != null && v.isNotEmpty) n.update(s.copyWith(apiBaseUrl: v, connectionCustom: true));
          },
        ),
        ListTile(
          leading: const Icon(Icons.key_outlined),
          title: const Text('访问口令'),
          subtitle: Text(s.apiToken.isEmpty ? '未设置（连接本机后端时不需要）' : '已设置'),
          onTap: () async {
            final c = TextEditingController(text: s.apiToken);
            final v = await showDialog<String>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('访问口令'),
                content: TextField(controller: c, decoration: const InputDecoration(hintText: '服务器部署时设置的口令')),
                actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('确定'))],
              ),
            );
            if (v != null) n.update(s.copyWith(apiToken: v, connectionCustom: true));
          },
        ),
        head('关于'),
        const ListTile(
          leading: Icon(Icons.medical_information_outlined),
          title: Text('产品说明与医疗边界'),
          subtitle: Text('MediLens 帮助理解尿常规与 UACR 报告，不做诊断，不建议停药、换药或调整剂量，医生医嘱优先。当前判读规则为测试规则，未经医学审核。'),
        ),
        const SizedBox(height: 24),
      ]),
    );
  }
}
