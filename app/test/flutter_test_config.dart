// 全部测试共用的设置：系统安全存储改用内存模拟（测试环境没有 Android Keystore），
// 避免设定与登入令牌的读写在测试中等不到回应。
// 珍珠鸟逐帧播放会一直排程画面，让 pumpAndSettle 等不到结束，默认关闭（pearl_bird_test 单独验证播放）。
import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:medilens/widgets/pearl_bird.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  FlutterSecureStorage.setMockInitialValues({});
  PearlBird.playFrames = false;
  await testMain();
}
