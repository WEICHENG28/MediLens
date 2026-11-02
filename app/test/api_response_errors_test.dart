import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:medilens/core/api_client.dart';

void main() {
  for (final status in [200, 401, 503]) {
    test('HTTP$status HTML异常页转换为可读错误，不回显正文', () async {
      final api = ApiClient(
        'http://synthetic.test',
        MockClient(
          (_) async =>
              http.Response('<html>sensitive_debug_text</html>', status),
        ),
      );
      await expectLater(
        api.analyze({}),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            isNot(contains('sensitive_debug_text')),
          ),
        ),
      );
    });
  }
  test('返回JSON列表也转换为接口异常', () async {
    final api = ApiClient(
      'http://synthetic.test',
      MockClient((_) async => http.Response('[]', 200)),
    );
    await expectLater(api.analyze({}), throwsA(isA<ApiException>()));
  });
}
