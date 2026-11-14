// 账户与个人资料的服务器接口（用户名 + 密码）。
// 每个请求都带访问口令（X-MediLens-Token）；登入后再带会话令牌（Authorization: Bearer）。

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'http_client.dart';

class AccountException implements Exception {
  final String message;
  final int? status;
  AccountException(this.message, [this.status]);
  @override
  String toString() => message;
}

class AccountApi {
  final String baseUrl;
  final String accessCode;
  final String? session;
  final http.Client _http;
  AccountApi(this.baseUrl, {this.accessCode = '', this.session, http.Client? client}) : _http = client ?? createHttpClient();

  AccountApi withSession(String? s) => AccountApi(baseUrl, accessCode: accessCode, session: s, client: _http);

  Future<dynamic> _send(String method, String path, [Object? body]) async {
    final req = http.Request(method, Uri.parse('$baseUrl$path'))
      ..headers.addAll({
        'Content-Type': 'application/json; charset=utf-8',
        if (accessCode.isNotEmpty) 'X-MediLens-Token': accessCode,
        if (session != null) 'Authorization': 'Bearer $session',
      });
    if (body != null) req.body = jsonEncode(body);
    final http.Response r;
    try {
      r = await http.Response.fromStream(await _http.send(req).timeout(const Duration(seconds: 20)));
    } catch (_) {
      throw AccountException('连不上服务器（$baseUrl），请确认网络（校园网 / 学校 VPN）后重试。');
    }
    dynamic data;
    try {
      data = r.bodyBytes.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
    } catch (_) {
      data = null;
    }
    if (r.statusCode == 200) return data;
    final detail = data is Map ? (data['detail'] ?? data['message']) : null;
    final msg = detail is String ? detail : switch (r.statusCode) {
      401 => '请重新登入',
      429 => '尝试次数太多，请稍后再试',
      _ => '服务器暂时无法处理（${r.statusCode}），请稍后重试',
    };
    throw AccountException(msg, r.statusCode);
  }

  Future<(String, String)> register(String username, String password) async {
    final d = await _send('POST', '/api/v1/auth/register', {'username': username, 'password': password});
    return (d['token'] as String, d['username'] as String);
  }

  Future<(String, String)> login(String username, String password) async {
    final d = await _send('POST', '/api/v1/auth/login', {'username': username, 'password': password});
    return (d['token'] as String, d['username'] as String);
  }

  Future<String> me() async => (await _send('GET', '/api/v1/auth/me'))['username'] as String;
  Future<void> logout() => _send('POST', '/api/v1/auth/logout');
  Future<void> changePassword(String old, String next) =>
      _send('POST', '/api/v1/auth/password', {'password': old, 'new_password': next});
  Future<void> deleteAccount(String password) => _send('POST', '/api/v1/auth/delete-account', {'password': password});

  Future<Map<String, String>> settings() async =>
      Map<String, String>.from(await _send('GET', '/api/v1/store/settings') as Map);
  Future<void> putSetting(String key, String value) =>
      _send('PUT', '/api/v1/store/settings/${Uri.encodeComponent(key)}', {'value': value});
  Future<List<Map<String, dynamic>>> reports() async =>
      (await _send('GET', '/api/v1/store/reports') as List).cast<Map<String, dynamic>>();
  Future<void> putReport(Map<String, Object?> row) =>
      _send('PUT', '/api/v1/store/reports/${Uri.encodeComponent(row['id'] as String)}', row);
  Future<void> deleteReport(String id) => _send('DELETE', '/api/v1/store/reports/${Uri.encodeComponent(id)}');
  Future<void> deleteAllReports() => _send('DELETE', '/api/v1/store/reports');
}
