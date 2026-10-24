// 后端接口客户端。只发送用户确认后的结构化指标与问答，不发送图像、姓名、医院。
// 运行时只访问配置的 MediLens 后端（正式部署在中国大陆云服务器），不直接访问任何第三方服务。

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'models.dart';
import 'settings.dart';

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

/// 本地历史摘要（用于趋势类规则）。只含日期和指标。
class HistoryBrief {
  final String testDate;
  final List<Map<String, dynamic>> items; // toApi 格式
  const HistoryBrief(this.testDate, this.items);
  Map<String, dynamic> toJson() => {'test_date': testDate, 'items': items};
}

class ApiClient {
  final String baseUrl;
  final http.Client _http;
  ApiClient(this.baseUrl, [http.Client? client]) : _http = client ?? http.Client();

  static Map<String, dynamic> analysisBody(ParsedReport report, Map<String, dynamic> answers, List<HistoryBrief> history) => {
        'report': {
          'report_type': 'auto',
          'test_date': report.testDate,
          'items': report.items.map((i) => i.toApi()).toList(),
        },
        'answers': answers,
        'history': history.map((h) => h.toJson()).toList(),
      };

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final http.Response r;
    try {
      r = await _http
          .post(Uri.parse('$baseUrl$path'), headers: {'Content-Type': 'application/json; charset=utf-8'}, body: jsonEncode(body))
          .timeout(const Duration(seconds: 25));
    } catch (_) {
      throw ApiException('无法连接解读服务，请检查网络后重试。已识别的指标仍保留在本机。');
    }
    final data = jsonDecode(utf8.decode(r.bodyBytes));
    if (r.statusCode != 200) {
      throw ApiException(r.statusCode == 501 ? (data['message'] as String? ?? '功能待实现') : '服务暂时不可用（${r.statusCode}）');
    }
    return data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> analyze(Map<String, dynamic> analysisBody) => _post('/api/v1/analyze', analysisBody);

  Future<Map<String, dynamic>> explain(Map<String, dynamic> analysisBody, String target) =>
      _post('/api/v1/explain', {'analysis': analysisBody, 'target': target});

  Future<Map<String, dynamic>> chat(Map<String, dynamic> analysisBody, String message, {String? focus, String? quick, List<Map<String, String>> history = const []}) =>
      _post('/api/v1/chat', {
        'analysis': analysisBody,
        'message': message,
        'focus': focus,
        'quick': quick,
        'history': history.length > 20 ? history.sublist(history.length - 20) : history,
      });
}

final apiClientProvider = Provider<ApiClient>((ref) => ApiClient(ref.watch(settingsProvider).apiBaseUrl));
