// 按平台选择本机存储：手机用加密数据库，网页版用浏览器 localStorage。
export 'native_store.dart' if (dart.library.js_interop) 'browser_store.dart';
