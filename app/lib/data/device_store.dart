// 只存在这台设备上的少量设定：连接哪个服务器、显示模式、登入令牌。
// 个人健康资料不放这里（登入后存服务器；游客模式只在内存，关闭即消失）。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'platform_store.dart';

abstract class DeviceStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// 测试与无存储环境使用。
class MemoryDeviceStore implements DeviceStore {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

final deviceStoreProvider = Provider<DeviceStore>((ref) => createDeviceStore());
