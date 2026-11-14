// 手机：设备设定与登入令牌放在系统安全存储（Android Keystore / iOS Keychain）。

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'device_store.dart';

class SecureDeviceStore implements DeviceStore {
  static const _s = FlutterSecureStorage();
  @override
  Future<String?> read(String key) => _s.read(key: 'medilens_device_$key');
  @override
  Future<void> write(String key, String value) => _s.write(key: 'medilens_device_$key', value: value);
  @override
  Future<void> delete(String key) => _s.delete(key: 'medilens_device_$key');
}

DeviceStore createDeviceStore() => SecureDeviceStore();
