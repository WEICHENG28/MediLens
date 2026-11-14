import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'http_client.dart' show tlsPin;

/// 证书校验失败（例如自签证书）时，只接受指纹等于 [pin] 的证书。pin 为空时不接受任何自签证书。
bool certificateMatches(X509Certificate cert, String pin) =>
    pin.isNotEmpty && sha256.convert(cert.der).toString() == pin.toLowerCase().replaceAll(':', '');

http.Client createHttpClient({String pin = tlsPin}) {
  final io = HttpClient()..badCertificateCallback = (cert, host, port) => certificateMatches(cert, pin);
  return IOClient(io);
}
