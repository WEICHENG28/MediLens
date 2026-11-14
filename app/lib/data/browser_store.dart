// 网页版：设备设定与登入令牌放在当前浏览器的 localStorage（个人健康资料不放这里）。

import 'package:web/web.dart' as web;

import 'device_store.dart';

class BrowserDeviceStore implements DeviceStore {
  static const _p = 'medilens_device_';
  @override
  Future<String?> read(String key) async => web.window.localStorage.getItem('$_p$key');
  @override
  Future<void> write(String key, String value) async => web.window.localStorage.setItem('$_p$key', value);
  @override
  Future<void> delete(String key) async => web.window.localStorage.removeItem('$_p$key');
}

DeviceStore createDeviceStore() => BrowserDeviceStore();
