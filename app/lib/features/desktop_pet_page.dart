import 'package:flutter/material.dart';
import '../core/desktop_pet.dart';
import '../widgets/interactive_bunny.dart';
import '../widgets/floating_pet_panel.dart';

class DesktopPetPage extends StatefulWidget {
  const DesktopPetPage({super.key});

  @override
  State<DesktopPetPage> createState() => _DesktopPetPageState();
}

class _DesktopPetPageState extends State<DesktopPetPage> {
  bool busy = false;

  Future<void> _add() async {
    setState(() => busy = true);
    final requested = await DesktopPet.requestPin();
    if (!mounted) return;
    setState(() => busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(requested
        ? '请在手机桌面的确认框中选择添加；也可长按桌面手动添加。'
        : '请长按手机桌面空白处 → 小组件 → MediLens → 桌面小兔。')));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('桌面小兔')),
    body: ListView(padding: const EdgeInsets.all(24), children: [
      const InteractiveBunny(size: 88),
      const PetMotionSwitch(),
      const SizedBox(height: 12),
      Text('小兔陪你过好每一天', textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 24),
      const Text('把小兔放到 Android 手机桌面，点击小兔即可打开 MediLens。点击桌面的“打招呼”会换一句陪伴文字；本页点击小兔可看到轻量动画。'),
      const SizedBox(height: 16),
      const Text('桌面只显示通用陪伴文字，不显示报告、血糖、用药记录或访问口令。小组件显示不需要联网，也不依赖 Google 服务。'),
      const SizedBox(height: 16),
      const Text('桌面小组件只在点击或陪伴状态更新时刷新，没有持续动画；可拖动悬浮小兔可在下方单独开启。问候不代表健康或任务状态。手机桌面是否允许直接添加取决于桌面应用，也可以长按桌面手动添加。'),
      const SizedBox(height: 24),
      OutlinedButton(onPressed: busy ? null : () async {
        final ok = await DesktopPet.clearGreeting();
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? '已恢复桌面的通用陪伴文字。' : '暂时无法更新桌面小兔，请重试。')));
      }, child: const Text('恢复桌面陪伴文字')),
      FilledButton.icon(onPressed: busy ? null : _add,
          icon: const Icon(Icons.add_to_home_screen),
          label: Text(busy ? '正在请求添加…' : '添加到手机桌面')),
      const SizedBox(height: 24),
      const FloatingPetPanel(),
    ]),
  );
}
