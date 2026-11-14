// ignore_for_file: avoid_print
// 本机端到端检查：用 APP 的证书钉选连线，对本机 HTTPS 后端注册、存取资料；错误指纹与明文 HTTP 必须被拒绝。
// 用法：dart run tool/tls_e2e.dart <https 地址> <http 地址> <证书指纹> <访问口令>
import 'package:medilens/core/account_api.dart';
import 'package:medilens/core/http_client_io.dart';

Future<void> main(List<String> a) async {
  final ok = AccountApi(a[0], accessCode: a[3], client: createHttpClient(pin: a[2]));
  final (token, name) = await ok.register('tls_user_${DateTime.now().millisecondsSinceEpoch % 100000}', 'synthetic-pass-1');
  final me = ok.withSession(token);
  await me.putSetting('life_events', '[1,2]');
  print('1. 正确指纹：注册 $name、存取资料 → ${(await me.settings())['life_events'] == '[1,2]' ? '通过' : '失败'}');
  try {
    await AccountApi(a[0], accessCode: a[3], client: createHttpClient(pin: 'deadbeef')).login(name, 'synthetic-pass-1');
    print('2. 错误指纹：竟然连上了 → 失败');
  } on AccountException {
    print('2. 错误指纹：被拒绝 → 通过');
  }
  try {
    await AccountApi(a[1], accessCode: a[3]).login(name, 'synthetic-pass-1');
    print('3. 明文 HTTP 登入：竟然成功 → 失败');
  } on AccountException catch (e) {
    print('3. 明文 HTTP 登入：被拒绝（${e.message.substring(0, 20)}…）→ 通过');
  }
}
