import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:medilens/core/account_api.dart';
import 'package:medilens/core/auth.dart';
import 'package:medilens/data/device_store.dart';
import 'package:medilens/data/local_store.dart';
import 'package:medilens/data/remote_store.dart';
import 'package:medilens/features/auth_page.dart';

/// 模拟服务器：一个用户名 xiaoming / synthetic-pass-1。
class FakeServer {
  final settings = <String, String>{};
  final reports = <String, Map<String, dynamic>>{};
  final requests = <http.Request>[];
  bool expired = false;

  late final client = MockClient((r) async {
    requests.add(r);
    final auth = r.headers['authorization'];
    http.Response json(Object? body, [int code = 200]) =>
        http.Response(jsonEncode(body), code, headers: {'content-type': 'application/json; charset=utf-8'});
    final path = r.url.path;
    if (path == '/api/v1/auth/login' || path == '/api/v1/auth/register') {
      final b = jsonDecode(r.body) as Map;
      if (b['password'] != 'synthetic-pass-1') return json({'detail': '用户名或密码不正确'}, 401);
      return json({'token': 'tok-1', 'username': b['username']});
    }
    if (auth != 'Bearer tok-1' || expired) return json({'detail': '登入已过期，请重新登入'}, 401);
    if (path == '/api/v1/auth/logout') return json({'ok': true});
    if (path == '/api/v1/store/settings' && r.method == 'GET') return json(settings);
    if (path.startsWith('/api/v1/store/settings/')) {
      settings[Uri.decodeComponent(path.split('/').last)] = (jsonDecode(r.body) as Map)['value'] as String;
      return json({'ok': true});
    }
    if (path == '/api/v1/store/reports' && r.method == 'GET') return json(reports.values.toList());
    if (path.startsWith('/api/v1/store/reports/') && r.method == 'PUT') {
      final b = jsonDecode(r.body) as Map<String, dynamic>;
      reports[b['id'] as String] = b;
      return json({'ok': true});
    }
    return json({'detail': 'not found'}, 404);
  });
}

ProviderContainer containerFor(FakeServer s, MemoryDeviceStore device) => ProviderContainer(overrides: [
      deviceStoreProvider.overrideWithValue(device),
      accountApiBaseProvider.overrideWithValue(AccountApi('https://server.test', accessCode: 'code', client: s.client)),
    ]);

void main() {
  test('游客模式不写入设备；登入后资料走服务器，登出回到游客', () async {
    final s = FakeServer(), device = MemoryDeviceStore();
    final c = containerFor(s, device);
    addTearDown(c.dispose);
    await c.read(localStoreProvider).putSetting('life_events', '[guest]');
    expect(c.read(localStoreProvider), isA<MemoryStore>());
    expect(device.values, isEmpty); // 游客资料不留在设备
    expect(s.requests, isEmpty);

    await c.read(authProvider.notifier).login('xiaoming', 'synthetic-pass-1');
    expect(c.read(authProvider).username, 'xiaoming');
    expect(device.values['session_token'], 'tok-1');
    final store = c.read(localStoreProvider);
    expect(store, isA<RemoteStore>());
    await store.putSetting('life_events', '[1]');
    expect(s.settings['life_events'], '[1]');
    expect(s.requests.every((r) => r.headers['x-medilens-token'] == 'code'), isTrue);

    await c.read(authProvider.notifier).logout();
    expect(c.read(authProvider).loggedIn, isFalse);
    expect(device.values, isEmpty);
    expect(c.read(localStoreProvider), isA<MemoryStore>());
  });

  test('登入状态在重新开启 APP 后还在', () async {
    final s = FakeServer(), device = MemoryDeviceStore()..values.addAll({'session_token': 'tok-1', 'session_username': 'xiaoming'});
    final c = containerFor(s, device);
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).load();
    expect(c.read(authProvider).username, 'xiaoming');
    expect(c.read(localStoreProvider), isA<RemoteStore>());
  });

  test('服务器上的设置一次取回、写入同步；报告存取', () async {
    final s = FakeServer()..settings['a'] = '1';
    final store = RemoteStore(AccountApi('https://server.test', session: 'tok-1', client: s.client));
    expect(await store.getSetting('a'), '1');
    expect(await store.getSetting('b'), isNull);
    expect(s.requests.where((r) => r.url.path == '/api/v1/store/settings').length, 1); // 只取一次
    await store.putSetting('b', '2');
    expect(await store.getSetting('b'), '2');
    await store.saveReport(SavedReport(id: 'r1', testDate: '2026-11-01', savedAt: DateTime(2026, 11, 1), reportType: 'urinalysis',
        items: const [], answers: const {}));
    expect((await store.listReports()).single.id, 'r1');
  });

  test('会话过期时回到游客模式', () async {
    final s = FakeServer(), device = MemoryDeviceStore();
    final c = containerFor(s, device);
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).login('xiaoming', 'synthetic-pass-1');
    s.expired = true;
    await expectLater(c.read(localStoreProvider).getSetting('x'), throwsA(isA<AccountException>()));
    await Future<void>.delayed(Duration.zero);
    expect(c.read(authProvider).loggedIn, isFalse);
  });

  testWidgets('登入页：显示服务器的错误；注册要勾选说明；成功后显示账户', (t) async {
    final s = FakeServer(), device = MemoryDeviceStore();
    final c = containerFor(s, device);
    addTearDown(c.dispose);
    await t.pumpWidget(UncontrolledProviderScope(container: c, child: const MaterialApp(home: AuthPage())));
    await t.enterText(find.byKey(const Key('auth_user')), 'xiaoming');
    await t.enterText(find.byKey(const Key('auth_pass')), 'wrong-pass');
    await t.tap(find.byKey(const Key('auth_submit')));
    await t.pumpAndSettle();
    expect(find.text('用户名或密码不正确'), findsOneWidget);

    await t.tap(find.text('注册'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('auth_pass')), 'synthetic-pass-1');
    await t.enterText(find.byKey(const Key('auth_pass2')), 'synthetic-pass-1');
    await t.tap(find.byKey(const Key('auth_submit')));
    await t.pumpAndSettle();
    expect(find.textContaining('请先阅读并勾选'), findsOneWidget);
    await t.tap(find.byKey(const Key('auth_agree')));
    await t.tap(find.byKey(const Key('auth_submit')));
    await t.pumpAndSettle();
    expect(c.read(authProvider).loggedIn, isTrue);
    expect(find.byKey(const Key('account_name')), findsOneWidget);
  });
}
