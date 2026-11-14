// 注册 / 登入 / 账户管理（用户名 + 密码）。登入后个人资料存在服务器；游客模式只在内存。

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/account_api.dart';
import '../core/auth.dart';
import '../data/local_store.dart';

const accountPrivacyNote = '登入后，报告解读、打卡、血糖、日记与设置都会保存在学校服务器上你的账户里（课程演示用途），'
    '只有登入你的账户才能看到；报告照片仍只在手机上识别，不会上传。你可以随时在这里删除账户与全部资料。';

class AuthPage extends ConsumerStatefulWidget {
  const AuthPage({super.key});
  @override
  ConsumerState<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends ConsumerState<AuthPage> {
  bool registering = false, busy = false, agreed = false, showPassword = false;
  final user = TextEditingController(), pass = TextEditingController(), pass2 = TextEditingController();
  String? error;

  Future<void> _submit() async {
    final notifier = ref.read(authProvider.notifier);
    if (registering) {
      if (pass.text != pass2.text) return setState(() => error = '两次输入的密码不一样');
      if (!agreed) return setState(() => error = '请先阅读并勾选上面的说明');
    }
    setState(() { busy = true; error = null; });
    try {
      registering ? await notifier.register(user.text, pass.text) : await notifier.login(user.text, pass.text);
      if (!mounted) return;
      await offerLegacyMigration(context, ref);
      if (mounted) context.canPop() ? context.pop() : context.go('/');
    } on AccountException catch (e) {
      if (mounted) setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    return Scaffold(
      appBar: AppBar(title: Text(auth.loggedIn ? '我的账户' : (registering ? '注册账户' : '登入'))),
      body: auth.loggedIn ? _AccountPanel(username: auth.username ?? '') : _form(context),
    );
  }

  Widget _form(BuildContext context) => ListView(padding: const EdgeInsets.all(20), children: [
        SegmentedButton<bool>(
          segments: const [ButtonSegment(value: false, label: Text('登入')), ButtonSegment(value: true, label: Text('注册'))],
          selected: {registering},
          onSelectionChanged: (s) => setState(() { registering = s.first; error = null; }),
        ),
        const SizedBox(height: 16),
        TextField(key: const Key('auth_user'), controller: user, autofillHints: const [AutofillHints.username],
            decoration: const InputDecoration(labelText: '用户名', helperText: '3–32 个字：中文、英文字母、数字或底线')),
        const SizedBox(height: 8),
        TextField(key: const Key('auth_pass'), controller: pass, obscureText: !showPassword,
            autofillHints: [registering ? AutofillHints.newPassword : AutofillHints.password],
            decoration: InputDecoration(labelText: '密码', helperText: registering ? '至少 8 个字，不要和其他网站用同一个密码' : null,
                suffixIcon: IconButton(icon: Icon(showPassword ? Icons.visibility_off : Icons.visibility),
                    tooltip: showPassword ? '隐藏密码' : '显示密码', onPressed: () => setState(() => showPassword = !showPassword)))),
        if (registering) ...[
          const SizedBox(height: 8),
          TextField(key: const Key('auth_pass2'), controller: pass2, obscureText: !showPassword,
              decoration: const InputDecoration(labelText: '再输入一次密码')),
          const SizedBox(height: 12),
          Text(accountPrivacyNote, style: Theme.of(context).textTheme.bodySmall),
          CheckboxListTile(key: const Key('auth_agree'), contentPadding: EdgeInsets.zero, value: agreed,
              controlAffinity: ListTileControlAffinity.leading, title: const Text('我已了解，资料会存在服务器'),
              onChanged: (v) => setState(() => agreed = v ?? false)),
        ],
        if (error != null) Padding(padding: const EdgeInsets.only(top: 8),
            child: Text(error!, key: const Key('auth_error'), style: TextStyle(color: Theme.of(context).colorScheme.error))),
        const SizedBox(height: 16),
        FilledButton(key: const Key('auth_submit'), onPressed: busy ? null : _submit,
            child: Text(busy ? '请稍候…' : (registering ? '注册并登入' : '登入'))),
        const SizedBox(height: 16),
        Text('不登入也可以用（游客模式）：记录只在这次使用期间保留，关闭 APP 后就不见了。', style: Theme.of(context).textTheme.bodySmall),
        Text('忘记密码请联系负责同学重置。', style: Theme.of(context).textTheme.bodySmall),
      ]);
}

class _AccountPanel extends ConsumerWidget {
  final String username;
  const _AccountPanel({required this.username});

  Future<String?> _askPassword(BuildContext context, String title, {String? hint, bool twoFields = false}) async {
    final a = TextEditingController(), b = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: Text(title),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        if (hint != null) Text(hint),
        TextField(key: const Key('dialog_pass'), controller: a, obscureText: true, decoration: InputDecoration(labelText: twoFields ? '原密码' : '密码')),
        if (twoFields) TextField(key: const Key('dialog_pass_new'), controller: b, obscureText: true, decoration: const InputDecoration(labelText: '新密码（至少 8 个字）')),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
        FilledButton(key: const Key('dialog_ok'), onPressed: () => Navigator.pop(c, true), child: const Text('确定'))],
    ));
    if (ok != true) return null;
    return twoFields ? '${a.text}\u0000${b.text}' : a.text;
  }

  void _toast(BuildContext context, String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.read(authProvider.notifier);
    return ListView(padding: const EdgeInsets.all(20), children: [
      ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.account_circle, size: 40),
          title: Text(username, key: const Key('account_name'), style: Theme.of(context).textTheme.titleLarge),
          subtitle: const Text('已登入：记录保存在你的账户')),
      const SizedBox(height: 8),
      Text(accountPrivacyNote, style: Theme.of(context).textTheme.bodySmall),
      const Divider(height: 32),
      ListTile(leading: const Icon(Icons.lock_reset), title: const Text('修改密码'), onTap: () async {
        final r = await _askPassword(context, '修改密码', twoFields: true);
        if (r == null || !context.mounted) return;
        final [old, next] = r.split('\u0000');
        try {
          await auth.changePassword(old, next);
          if (context.mounted) _toast(context, '密码已修改');
        } on AccountException catch (e) {
          if (context.mounted) _toast(context, e.message);
        }
      }),
      if (!kIsWeb)
        ListTile(leading: const Icon(Icons.drive_file_move_outline), title: const Text('把手机上以前的记录搬到账户'),
            subtitle: const Text('只有登入前存在这台手机的记录才需要'), onTap: () async {
          final m = LegacyMigration();
          if (await m.check() == null) {
            if (context.mounted) _toast(context, '手机上没有以前的记录');
            return;
          }
          if (context.mounted) await offerLegacyMigration(context, ref, m);
        }),
      ListTile(key: const Key('logout'), leading: const Icon(Icons.logout), title: const Text('登出'),
          subtitle: const Text('登出后回到游客模式；资料仍保存在账户里'), onTap: () async {
        await auth.logout();
        if (context.mounted) _toast(context, '已登出');
      }),
      ListTile(key: const Key('delete_account'), leading: Icon(Icons.delete_forever, color: Theme.of(context).colorScheme.error),
          title: Text('删除账户与全部资料', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          subtitle: const Text('服务器上的报告、打卡、日记会全部删除，不能恢复'), onTap: () async {
        final pw = await _askPassword(context, '删除账户', hint: '会删除服务器上这个账户的全部资料，不能恢复。请输入密码确认。');
        if (pw == null || !context.mounted) return;
        try {
          await auth.deleteAccount(pw);
          if (context.mounted) _toast(context, '账户与全部资料已删除');
        } on AccountException catch (e) {
          if (context.mounted) _toast(context, e.message);
        }
      }),
    ]);
  }
}

/// 登入后：手机上若有以前留下的记录，询问要搬到账户、删除，还是先不处理。
Future<void> offerLegacyMigration(BuildContext context, WidgetRef ref, [LegacyMigration? migration]) async {
  final m = migration ?? LegacyMigration();
  final data = await m.check();
  if (data == null || !context.mounted) return;
  final choice = await showDialog<String>(context: context, barrierDismissible: false, builder: (c) => AlertDialog(
    title: const Text('手机上有以前的记录'),
    content: Text('这台手机上有 ${data.reports} 份报告、${data.records} 项生活记录（登入前存的）。\n'
        '要搬到你的账户吗？搬好后会从手机上删除，以后只存在账户里。'),
    actions: [
      TextButton(onPressed: () => Navigator.pop(c, 'later'), child: const Text('先不处理')),
      TextButton(onPressed: () => Navigator.pop(c, 'discard'), child: const Text('删除这些记录')),
      FilledButton(key: const Key('migrate_move'), onPressed: () => Navigator.pop(c, 'move'), child: const Text('搬到账户')),
    ],
  ));
  try {
    if (choice == 'move') {
      await m.moveTo(ref.read(localStoreProvider));
      ref.invalidate(historyProvider);
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已搬到账户，手机上的旧记录已删除')));
    } else if (choice == 'discard') {
      await m.discard();
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('搬移没有完成，手机上的记录保留着，可以稍后在「我的账户」再试')));
    }
  }
}
