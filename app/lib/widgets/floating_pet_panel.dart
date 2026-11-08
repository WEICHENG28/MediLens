import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/floating_pet.dart';

class FloatingPetPanel extends ConsumerStatefulWidget {
  const FloatingPetPanel({super.key});
  @override ConsumerState<FloatingPetPanel> createState() => _FloatingPetPanelState();
}
class _FloatingPetPanelState extends ConsumerState<FloatingPetPanel> with WidgetsBindingObserver {
  FloatingPetStatus status = const FloatingPetStatus();
  bool busy = false, loading = true;
  String? message;
  int stateRequest = 0;
  @override void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); Future.microtask(refresh); }
  @override void didChangeAppLifecycleState(AppLifecycleState state) { if (state == AppLifecycleState.resumed && !busy) refresh(); }
  @override void dispose() { WidgetsBinding.instance.removeObserver(this); super.dispose(); }
  Future<void> refresh() async {
    if (!mounted || busy) return;
    final request = ++stateRequest;
    try {
      final result = await ref.read(floatingPetPlatformProvider).status();
      if (mounted && request == stateRequest) setState(() { status = result; loading = false; message = null; });
    } catch (_) { if (mounted && request == stateRequest) setState(() { loading = false; message = '暂时无法读取悬浮珍珠鸟状态，请刷新重试。'; }); }
  }
  Future<void> permission(bool overlay) async {
    if (busy) return;
    ++stateRequest; // Invalidate older reads before permission or start/stop actions.
    setState(() { busy = true; message = null; });
    try {
      final platform = ref.read(floatingPetPlatformProvider);
      if (overlay) { await platform.overlaySettings(); } else { await platform.notifications(); }
    } catch (_) { if (mounted) setState(() => message = '无法打开系统设置，请在手机设置中查找MediLens的悬浮或通知权限。'); }
    finally { if (mounted) setState(() => busy = false); }
  }
  Future<void> toggle(bool start) async {
    if (busy) return;
    if (start) {
      final confirmed = await showDialog<bool>(context: context, builder: (c) => AlertDialog(title: const Text('开启悬浮珍珠鸟？'),
        content: const Text('珍珠鸟将显示在其他APP上方，可拖动头像移动。只显示通用问候，不读取屏幕内容。可点×、APP关闭按钮或通知中的停止结束。锁屏、移除最近任务或重启后需要重新手动开启。'),
        actions: [TextButton(onPressed: () => Navigator.pop(c,false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(c,true), child: const Text('确认开启'))]));
      if (!mounted || confirmed != true) return;
    }
    ++stateRequest; // Invalidate older reads before permission or start/stop actions.
    setState(() { busy = true; message = null; });
    final platform = ref.read(floatingPetPlatformProvider);
    try {
      var result = start ? await platform.start() : await platform.stop();
      for (var i=0; start && result.starting && i<10; i++) {
        await Future<void>.delayed(const Duration(milliseconds:100));
        result = await platform.status();
      }
      if (mounted) { setState(() {
        status = result;
        if (start && !result.running) { message = result.error ?? '暂未确认开启成功，请刷新状态；可随时点关闭。'; }
      }); }
    } catch (_) {
      if (mounted) setState(() => message = start ? '未能开启悬浮珍珠鸟，请检查系统权限后重试。' : '未确认关闭，请用珍珠鸟上的×或常驻通知中的停止按钮。');
    } finally { if (mounted) setState(() => busy = false); }
  }
  @override Widget build(BuildContext context) => Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    Text('可拖动悬浮珍珠鸟', style: Theme.of(context).textTheme.titleMedium),
    const Text('主动开启后可在其他APP上方陪伴；不显示医疗资料，不抓取屏幕、不联网。系统可能限制后台运行，本机桌面小组件仍可使用。'),
    if (loading || busy) const LinearProgressIndicator(),
    if (!loading) Text(status.running ? '悬浮珍珠鸟正在运行' : status.starting ? '正在开启，尚未确认运行' : '悬浮珍珠鸟未开启', key: const Key('floating_status')),
    if (message != null || status.error != null) Text(message ?? status.error!, key: const Key('floating_message')),
    if (status.available) ...[
      Text('悬浮权限：${status.overlayAllowed ? '已允许' : '未允许'}；通知权限：${status.notificationsAllowed ? '已允许' : '未允许'}'),
      const Text('先允许“显示在其他应用上层”及通知权限，再返回本页手动开启。通知用于显示运行状态和停止入口。'),
      Wrap(spacing: 8, children: [
        TextButton(onPressed: busy ? null : () => permission(true), child: const Text('悬浮权限设置')),
        TextButton(onPressed: busy ? null : () => permission(false), child: const Text('通知设置')),
      ]),
      FilledButton(key: const Key('floating_start'), onPressed: busy || loading || status.running || status.starting || !status.overlayAllowed || !status.notificationsAllowed ? null : () => toggle(true), child: const Text('开启悬浮珍珠鸟')),
    ] else if (!loading) const Text('当前设备或构建暂不可用，可继续使用桌面小组件。'),
    OutlinedButton(key: const Key('floating_stop'), onPressed: busy ? null : () => toggle(false), child: const Text('关闭悬浮珍珠鸟')),
    TextButton(onPressed: busy ? null : refresh, child: const Text('刷新悬浮状态')),
    const Text('不默认开启，不开机自启。拖动位置只在本次运行中保留；锁屏或从最近任务移除APP会关闭。系统限制可能因手机品牌而不同。'),
  ])));
}
