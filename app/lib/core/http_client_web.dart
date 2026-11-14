import 'package:http/http.dart' as http;

import 'http_client.dart' show tlsPin;

/// 网页版：证书由浏览器校验（自签证书需要先在浏览器里确认一次）。
http.Client createHttpClient({String pin = tlsPin}) => http.Client();
