// 建立连接服务器用的 HTTP 客户端。
// 手机：服务器用自签证书，APP 内置证书指纹（编译时 --dart-define=TLS_PIN=...，SHA-256 十六进制），
// 只有指纹相符才接受连接（证书钉选），其他自签证书一律拒绝。网页版由浏览器处理证书。
export 'http_client_io.dart' if (dart.library.js_interop) 'http_client_web.dart';

const tlsPin = String.fromEnvironment('TLS_PIN');
