// P11 设置中心：集中管理显示、OCR、语音、隐私与数据、账号、提醒、医疗边界说明。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth.dart';
import '../core/settings.dart';
import '../core/medication_records.dart';
import '../core/life_journal.dart';
import '../core/local_reminders.dart';
import '../core/task_receipts.dart';
import '../core/checkup_reminders.dart';
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
        Builder(builder: (_) {
          final auth = ref.watch(authProvider);
          return ListTile(key: const Key('account_tile'), leading: Icon(auth.loggedIn ? Icons.account_circle : Icons.person_outline),
              title: Text(auth.loggedIn ? '已登入：${auth.username}' : '当前：游客（记录不会保留）'),
              subtitle: Text(auth.loggedIn ? '记录保存在你的账户；点这里修改密码、登出或删除账户' : '注册或登入后，记录会保存在你的账户'),
              onTap: () => context.push('/auth'));
        }),
        head('显示'),
        SwitchListTile(
          key: const Key('elder_switch'),
          secondary: const Icon(Icons.text_increase),
          title: const Text('老年模式'),
          subtitle: const Text('大字号、大按钮、高对比度，功能与普通模式完全相同'),
          value: s.elder,
          onChanged: (v) => n.update(s.copyWith(displayMode: v ? DisplayMode.elder : DisplayMode.normal)),
        ),
        ListTile(leading: const Icon(Icons.pets_outlined), title: const Text('桌面珍珠鸟'), subtitle: const Text('把陪伴珍珠鸟添加到 Android 手机桌面'), onTap: () => context.push('/desktop-pet')),
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
        SwitchListTile(
          key: const Key('auto_read_overview'),
          secondary: const Icon(Icons.record_voice_over_outlined),
          title: const Text('自动朗读总览摘要'),
          subtitle: const Text('开启后进入解读总览会出声朗读摘要；只使用已安装的离线中文语音。切页或进入后台即停止，可随时点击停止。'),
          value: s.autoRead,
          onChanged: (v) async {
            try { await n.update(s.copyWith(autoRead: v)); }
            catch (_) {
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('自动朗读设置未能保存，请重试。')));
            }
          },
        ),
        ListTile(leading: const Icon(Icons.graphic_eq), title: const Text('中文朗读与音色'), subtitle: const Text('检测离线中文语音、选择音色、试听与停止'), onTap: () => context.push('/speech-settings')),
        ListTile(leading: const Icon(Icons.mic_none), title: const Text('语音对话'), subtitle: const Text('按键或连续实时对话，普通话离线识别'), onTap: () => context.push('/voice')),
        ListTile(leading: const Icon(Icons.medication_outlined), title: const Text('本机药名记录'), subtitle: const Text('查看主动保存的药名和本人确认的使用情况'), onTap: () => context.push('/medications-saved')),
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
              builder: (c) => AlertDialog(content: const Text('删除本机全部报告、药名记录、生活打卡、任务完成记录和用药时间？本机提醒也会关闭。此操作不可恢复。'), actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
                FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('删除')),
              ]),
            );
            if (ok == true) {
              final reminders = ref.read(remindersProvider);
              if (reminders.available && !await ref.read(checkupProvider.notifier).clearAll()) {
                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('复查提醒未能撤销，暂未删除记录，请重试。')));
                return;
              }
              if (reminders.available && !await ref.read(remindersProvider.notifier).setEnabled(false)) return;
              try { await ref.read(medicationRecordsProvider).clear(); } catch (_) {
                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('药名记录未能清除，暂未继续删除其他记录，请重试。')));
                return;
              }
              ref.invalidate(savedMedicationsProvider);
              await ref.read(localStoreProvider).deleteAll();
              await ref.read(localStoreProvider).putSetting('life_events', '[]');
              await ref.read(localStoreProvider).putSetting('life_tasks', '[]');
              await ref.read(localStoreProvider).putSetting('life_schedule', '[]');
              await ref.read(localStoreProvider).putSetting('life_demo_mode', 'false');
              await ref.read(localStoreProvider).putSetting(TaskReceipts.storageKey, '{}');
              ref.invalidate(taskReceiptsProvider);
              await ref.read(localStoreProvider).putSetting(ReminderNotifier.enabledKey, 'false');
              await updateLocalCompanion(ref.read(localStoreProvider), DateTime.now());
              ref.invalidate(historyProvider);
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已删除')));
            }
          },
        ),
        head('提醒'),
        ListTile(leading: const Icon(Icons.notifications_none), title: const Text('本机任务提醒'), subtitle: const Text('按确认的用药时间通知'), onTap: () => context.push('/reminder')),
        ListTile(leading: const Icon(Icons.event_available), title: const Text('复查日期提醒'), subtitle: const Text('按医嘱手动设置一次性提醒'), onTap: () => context.push('/checkup-reminders')),
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
