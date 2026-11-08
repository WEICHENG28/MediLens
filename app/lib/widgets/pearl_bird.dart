// 珍珠鸟陪伴形象（团队成员绘制，素材见 assets/pet/SOURCE.md）。
// 开启动画时播放 GIF；用户关闭动画或系统要求减少动态效果时，显示同一状态的静态第一帧。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/life_journal.dart';
import '../core/pet_interaction.dart';

class PearlBird extends ConsumerWidget {
  final BirdMood mood;
  final double size;
  const PearlBird({super.key, this.mood = BirdMood.normal, this.size = 120});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final animate = ref.watch(petPreferencesProvider).motion && !MediaQuery.disableAnimationsOf(context);
    return Image.asset(
      'assets/pet/bird_${mood.name}.${animate ? 'gif' : 'png'}',
      key: ValueKey('bird_${mood.name}_${animate ? 'anim' : 'still'}'),
      width: size,
      height: size,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      excludeFromSemantics: true,
      errorBuilder: (_, _, _) => SizedBox(width: size, height: size, child: Center(child: Text('🐦', style: TextStyle(fontSize: size * 0.6)))),
    );
  }
}
