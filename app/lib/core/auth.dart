// 登入状态：登入后个人资料都存服务器；未登入为游客模式（只在内存，关闭 APP 即消失）。

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/device_store.dart';
import '../data/local_store.dart';
import 'account_api.dart';
import 'settings.dart';

class AuthState {
  final String? token;
  final String? username;
  const AuthState({this.token, this.username});
  bool get loggedIn => token != null;
}

/// 不带登入令牌的账户接口（注册、登入用；登入状态本身也从这里取，避免互相依赖）。
final accountApiBaseProvider = Provider<AccountApi>((ref) {
  final s = ref.watch(settingsProvider);
  return AccountApi(s.apiBaseUrl, accessCode: s.apiToken);
});

/// 带目前登入令牌的账户接口（读写个人资料用）。
final accountApiProvider = Provider<AccountApi>(
    (ref) => ref.watch(accountApiBaseProvider).withSession(ref.watch(authProvider.select((a) => a.token))));

class AuthNotifier extends Notifier<AuthState> {
  static const _kToken = 'session_token', _kUser = 'session_username';
  @override
  AuthState build() => const AuthState();

  DeviceStore get _device => ref.read(deviceStoreProvider);
  AccountApi get _api => ref.read(accountApiBaseProvider).withSession(state.token);

  Future<void> load() async {
    try {
      final token = await _device.read(_kToken);
      if (token != null) state = AuthState(token: token, username: await _device.read(_kUser));
    } catch (_) {
      state = const AuthState(); // 读不到安全存储时以游客模式开始
    }
  }

  Future<void> _signedIn((String, String) r) async {
    await _device.write(_kToken, r.$1);
    await _device.write(_kUser, r.$2);
    state = AuthState(token: r.$1, username: r.$2);
  }

  Future<void> register(String username, String password) async =>
      _signedIn(await _api.register(username.trim(), password));

  Future<void> login(String username, String password) async =>
      _signedIn(await _api.login(username.trim(), password));

  Future<void> _clear() async {
    await _device.delete(_kToken);
    await _device.delete(_kUser);
    state = const AuthState();
  }

  Future<void> logout() async {
    try {
      await _api.logout();
    } catch (_) {
      // 离线时也要能在本机登出；服务器上的会话 30 天后自动失效
    }
    await _clear();
  }

  Future<void> changePassword(String old, String next) => _api.changePassword(old, next);

  Future<void> deleteAccount(String password) async {
    await _api.deleteAccount(password);
    await _clear();
  }

  /// 会话失效（例如在别处删除了账户）时调用。
  Future<void> expired() => _clear();
}

final authProvider = NotifierProvider<AuthNotifier, AuthState>(AuthNotifier.new);

/// 手机上登入前留下的旧记录（加密数据库）。网页版没有。
class LegacyData {
  final int reports;
  final int records;
  const LegacyData(this.reports, this.records);
  bool get isEmpty => reports == 0 && records == 0;
}

/// 把旧记录搬到账户（成功后删除手机上的数据库），或直接删除。
class LegacyMigration {
  final SqlCipherStore legacy;
  LegacyMigration([SqlCipherStore? store]) : legacy = store ?? SqlCipherStore();

  Future<LegacyData?> check() async {
    if (kIsWeb) return null;
    try {
      if (!await legacy.exists()) return null;
      final settings = await legacy.allSettings();
      final data = LegacyData((await legacy.listReports()).length, settings.keys.where((k) => k != 'app_settings').length);
      if (data.isEmpty) {
        await legacy.wipe();
        return null;
      }
      return data;
    } catch (_) {
      return null;
    }
  }

  Future<void> moveTo(LocalStore account) async {
    for (final e in (await legacy.allSettings()).entries) {
      if (e.key != 'app_settings') await account.putSetting(e.key, e.value);
    }
    for (final r in await legacy.listReports()) {
      await account.saveReport(r);
    }
    await legacy.wipe();
  }

  Future<void> discard() => legacy.wipe();
}
