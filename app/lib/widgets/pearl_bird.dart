// 珍珠鸟陪伴形象（团队成员绘制，素材见 assets/pet/SOURCE.md）。
// 开启动画时逐帧播放；用户关闭动画或系统要求减少动态效果时，显示同一状态的静态第一帧。
//
// 为什么不直接播放 GIF：Flutter 播放 GIF 时每一帧都重新解码并上传一张新图片，
// 安卓模拟器会在这个过程中随机崩溃（Windows 记录 qemu 0xc0000005，看起来像 APP 闪退；
// 2026-11-08 加入 GIF 后才开始出现）。现在把 GIF 预先拆成 PNG 帧（assets/pet/frames/），
// 进入页面时一次载入，播放只是轮流显示已载入的图片，不再每帧解码上传。
// 帧时长与原 GIF 相同；更换 GIF 后用 tools/split_pet_gif.py 重新拆帧。

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/life_journal.dart';
import '../core/pet_interaction.dart';

/// 每种状态的帧数与每帧时长（毫秒），取自原 GIF。
const birdFrames = {
  BirdMood.normal: (8, 180),
  BirdMood.happy: (8, 160),
  BirdMood.low: (8, 180),
  BirdMood.recover: (12, 140),
};

String birdFrameAsset(BirdMood mood, int i) => 'assets/pet/frames/bird_${mood.name}_$i.png';

class PearlBird extends ConsumerWidget {
  /// 测试用：逐帧播放会一直排程画面，测试环境默认关闭（见 test/flutter_test_config.dart），只显示第一帧。
  static bool playFrames = true;
  final BirdMood mood;
  final double size;
  const PearlBird({super.key, this.mood = BirdMood.normal, this.size = 120});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final animate = ref.watch(petPreferencesProvider).motion && !MediaQuery.disableAnimationsOf(context);
    return animate
        ? _AnimatedBird(key: ValueKey('bird_${mood.name}_anim'), mood: mood, size: size)
        : _frame(mood, null, size, key: ValueKey('bird_${mood.name}_still'));
  }
}

Widget _frame(BirdMood mood, int? i, double size, {Key? key}) => Image.asset(
      i == null ? 'assets/pet/bird_${mood.name}.png' : birdFrameAsset(mood, i),
      key: key,
      width: size,
      height: size,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      excludeFromSemantics: true,
      errorBuilder: (_, _, _) => SizedBox(width: size, height: size, child: Center(child: Text('🐦', style: TextStyle(fontSize: size * 0.6)))),
    );

class _AnimatedBird extends StatefulWidget {
  final BirdMood mood;
  final double size;
  const _AnimatedBird({super.key, required this.mood, required this.size});
  @override
  State<_AnimatedBird> createState() => _AnimatedBirdState();
}

class _AnimatedBirdState extends State<_AnimatedBird> with SingleTickerProviderStateMixin {
  // Ticker 会在页面被盖住（TickerMode 关闭）时自动暂停，不在后台换帧
  late final Ticker ticker = createTicker(_tick);
  int frame = 0;
  bool loaded = false;

  @override
  void initState() {
    super.initState();
    if (PearlBird.playFrames) ticker.start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (loaded) return;
    loaded = true;
    // 一次载入全部帧（之后在图片缓存中重复使用）；未载入完的帧由 gaplessPlayback 保留上一帧，不闪白
    final (count, _) = birdFrames[widget.mood]!;
    for (var i = 0; i < count; i++) {
      precacheImage(AssetImage(birdFrameAsset(widget.mood, i)), context);
    }
  }

  void _tick(Duration elapsed) {
    final (count, ms) = birdFrames[widget.mood]!;
    final next = (elapsed.inMilliseconds ~/ ms) % count;
    if (next != frame) setState(() => frame = next);
  }

  @override
  void dispose() {
    ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _frame(widget.mood, frame, widget.size);
}
