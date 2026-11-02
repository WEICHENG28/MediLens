import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/pet_interaction.dart';

class InteractiveBunny extends ConsumerStatefulWidget {
  final double size;
  const InteractiveBunny({super.key, this.size = 64});
  @override ConsumerState<InteractiveBunny> createState() => _InteractiveBunnyState();
}
class _InteractiveBunnyState extends ConsumerState<InteractiveBunny> with SingleTickerProviderStateMixin, WidgetsBindingObserver, RouteAware {
  late final AnimationController controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
  late final Animation<double> bounce = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.10).chain(CurveTween(curve: Curves.easeOut)), weight: 1),
    TweenSequenceItem(tween: Tween(begin: 1.10, end: 1.0).chain(CurveTween(curve: Curves.easeIn)), weight: 1),
  ]).animate(controller);
  int greeting = -1;
  bool visible = true;
  @override void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); }
  @override void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context); if (route != null) petRoutes.subscribe(this, route);
    if (MediaQuery.disableAnimationsOf(context)) controller.reset();
  }
  @override void didPushNext() { visible = false; controller.reset(); }
  @override void didPopNext() { visible = true; }
  @override void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) { controller.reset(); }
  }
  void greet() {
    setState(() => greeting = (greeting + 1) % petGreetings.length);
    if (visible && ref.read(petPreferencesProvider).motion && !MediaQuery.disableAnimationsOf(context)) {
      controller.forward(from: 0);
    } else { controller.reset(); }
  }
  @override void dispose() { petRoutes.unsubscribe(this); WidgetsBinding.instance.removeObserver(this); controller.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) {
    ref.listen(petPreferencesProvider, (_, next) { if (!next.motion) controller.reset(); });
    ref.watch(petPreferencesProvider);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      TextButton(key: const Key('bunny_greet'), onPressed: greet,
        child: Semantics(label: '和小兔打个招呼', child: ExcludeSemantics(child: ScaleTransition(key: const Key('bunny_scale'), scale: bounce,
          child: Text('🐰', key: const Key('pet_avatar'), style: TextStyle(fontSize: widget.size)))))),
      Semantics(liveRegion: true, child: Text(greeting < 0 ? '点小兔，打个招呼' : petGreetings[greeting], key: const Key('bunny_greeting'), textAlign: TextAlign.center)),
    ]);
  }
}

class PetMotionSwitch extends ConsumerWidget {
  const PetMotionSwitch({super.key});
  @override Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(petPreferencesProvider);
    final reduced = MediaQuery.disableAnimationsOf(context);
    return Column(children: [
      SwitchListTile(key: const Key('pet_motion_switch'), title: const Text('小兔点击动画'),
        subtitle: Text(reduced ? '系统已要求减少动态效果，点击只显示文字。' : '只在点小兔时轻轻动一下；关闭后仍可看到问候。'),
        value: settings.motion, onChanged: settings.loaded && !settings.busy ? ref.read(petPreferencesProvider.notifier).setMotion : null),
      if (settings.error != null) Text(settings.error!),
      if (!settings.loaded && !settings.busy) TextButton(onPressed: ref.read(petPreferencesProvider.notifier).load, child: const Text('重试读取动画设置')),
    ]);
  }
}
