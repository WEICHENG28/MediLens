import 'package:flutter_test/flutter_test.dart';
import 'package:medilens/core/settings.dart';

void main() {
  test('旧版存下的默认地址不会盖过新版 APK 的预设', () {
    final s = AppSettings.fromJson({'apiBaseUrl': 'http://10.0.2.2:8000', 'apiToken': '', 'displayMode': 'elder'});
    expect(s.apiBaseUrl, AppSettings.defaultApiBaseUrl);
    expect(s.apiToken, AppSettings.defaultApiToken);
    expect(s.connectionCustom, isFalse);
  });

  test('用户手动改过的地址与口令会保留', () {
    final saved = const AppSettings().copyWith(apiBaseUrl: 'http://192.168.1.5:8000', apiToken: 'abc', connectionCustom: true);
    final s = AppSettings.fromJson(saved.toJson());
    expect(s.apiBaseUrl, 'http://192.168.1.5:8000');
    expect(s.apiToken, 'abc');
  });
}
