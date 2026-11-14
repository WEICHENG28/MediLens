// 全部测试共用的设置：系统安全存储改用内存模拟（测试环境没有 Android Keystore），
// 避免设定与登入令牌的读写在测试中等不到回应。
import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  FlutterSecureStorage.setMockInitialValues({});
  await testMain();
}
