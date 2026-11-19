// 登入后的个人资料存储：报告、打卡、血糖、日记与设置都存在服务器（按账户分开）。
// 设置在第一次读取时整批取回并放在内存，之后读取不再联网；写入时同时更新内存与服务器。

import 'dart:convert';

import '../core/account_api.dart';
import 'local_store.dart';

/// 两台设备都改过生活记录时的合并：依记录编号合并（同编号以本机这次的为准），没有编号的旧记录去掉完全相同的重复。
/// 本机是清空（[]）或示范资料（模拟）时，代表用户有意整份替换，不合并。
String mergeLifeEvents(String serverJson, String localJson) {
  List<Map<String, dynamic>> parse(String s) {
    try {
      final v = jsonDecode(s);
      return v is List ? [for (final e in v) if (e is Map) Map<String, dynamic>.from(e)] : [];
    } catch (_) {
      return [];
    }
  }
  final local = parse(localJson);
  if (local.isEmpty || local.any((e) => e['is_simulated'] == true)) return localJson;
  final server = parse(serverJson).where((e) => e['is_simulated'] != true);
  final byId = <String, Map<String, dynamic>>{};
  final noId = <String, Map<String, dynamic>>{};
  for (final e in [...server, ...local]) {
    final id = e['id'];
    if (id is String && id.isNotEmpty) {
      byId[id] = e;
    } else {
      noId[jsonEncode(e)] = e;
    }
  }
  final merged = [...byId.values, ...noId.values]
    ..sort((a, b) => '${a['time']}'.compareTo('${b['time']}'));
  return jsonEncode(merged);
}

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
  Map<String, double> _versions = {};
  Future<Map<String, String>>? _loading;

  Future<Map<String, String>> _settings() async {
    if (_cache != null) return _cache!;
    _loading ??= _guard(() async {
      final values = await api.settings();
      try { _versions = await api.settingsVersions(); } catch (_) { _versions = {}; }
      return values;
    }).then((m) => _cache = m).whenComplete(() => _loading = null);
    return _loading!;
  }

  @override
  Future<String?> getSetting(String key) async => (await _settings())[key];

  /// 带上次读到的版本写入；另一台设备已更新时，生活记录依编号合并后重送，其他设置以这次为准。
  @override
  Future<void> putSetting(String key, String value) async {
    final cache = await _settings();
    var send = value;
    var base = _versions[key];
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final v = await _guard(() => api.putSetting(key, send, base: base));
        cache[key] = send;
        if (v != null) _versions[key] = v;
        return;
      } on AccountException catch (e) {
        final d = e.data;
        if (e.status != 409 || d is! Map) rethrow;
        base = (d['updated_at'] as num?)?.toDouble();
        if (key == 'life_events' && d['value'] is String) send = mergeLifeEvents(d['value'] as String, send);
      }
    }
    throw AccountException('记录同步冲突，请稍后重试');
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
