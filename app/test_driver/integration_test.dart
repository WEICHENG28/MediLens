// 用于 flutter drive 以 profile/release 模式运行集成测试（验证 R8 代码压缩后功能正常）
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
