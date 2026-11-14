// 登入后的个人资料存储：报告、打卡、血糖、日记与设置都存在服务器（按账户分开）。
// 设置在第一次读取时整批取回并放在内存，之后读取不再联网；写入时同时更新内存与服务器。

import '../core/account_api.dart';
import 'local_store.dart';

class RemoteStore implements LocalStore {
  final AccountApi api;
  final void Function()? onExpired; // 会话失效（401）时回到游客模式
  RemoteStore(this.api, {this.onExpired});

  Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on AccountException catch (e) {
      if (e.status == 401) onExpired?.call();
      rethrow;
    }
  }

  Map<String, String>? _cache;
  Future<Map<String, String>>? _loading;

  Future<Map<String, String>> _settings() async {
    if (_cache != null) return _cache!;
    _loading ??= _guard(api.settings).then((m) => _cache = m).whenComplete(() => _loading = null);
    return _loading!;
  }

  @override
  Future<String?> getSetting(String key) async => (await _settings())[key];

  @override
  Future<void> putSetting(String key, String value) async {
    final cache = await _settings();
    await _guard(() => api.putSetting(key, value));
    cache[key] = value;
  }

  @override
  Future<void> saveReport(SavedReport r) => _guard(() => api.putReport(r.toRow()));

  @override
  Future<List<SavedReport>> listReports() async {
    final l = (await _guard(api.reports)).map((m) => SavedReport.fromRow(Map<String, Object?>.from(m))).toList();
    l.sort((a, b) => (b.testDate ?? '').compareTo(a.testDate ?? ''));
    return l;
  }

  @override
  Future<void> deleteReport(String id) => _guard(() => api.deleteReport(id));

  @override
  Future<void> deleteAll() => _guard(api.deleteAllReports);
}
