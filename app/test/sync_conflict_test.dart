import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:medilens/core/account_api.dart';
import 'package:medilens/core/care_events.dart';
import 'package:medilens/data/remote_store.dart';

/// 有版本的模拟服务器：带 base 且版本过旧时回 409（与后端相同的规则）。
class VersionedServer {
  final values = <String, String>{};
  final versions = <String, double>{};
  double clock = 100;
  int conflicts = 0;

  late final client = MockClient((r) async {
    http.Response json(Object? body, [int code = 200]) =>
        http.Response(jsonEncode(body), code, headers: {'content-type': 'application/json; charset=utf-8'});
    final path = r.url.path;
    if (path == '/api/v1/store/settings' && r.method == 'GET') return json(values);
    if (path == '/api/v1/store/settings-versions') return json(versions);
    if (path.startsWith('/api/v1/store/settings/') && r.method == 'PUT') {
      final key = Uri.decodeComponent(path.split('/').last);
      final b = jsonDecode(r.body) as Map;
      final base = (b['base'] as num?)?.toDouble();
      if (base != null && (versions[key] ?? 0) > base + 1e-6) {
        conflicts++;
        return json({'detail': {'message': '冲突', 'value': values[key], 'updated_at': versions[key]}}, 409);
      }
      values[key] = b['value'] as String;
      versions[key] = ++clock;
      return json({'ok': true, 'updated_at': clock});
    }
    return json({'detail': 'not found'}, 404);
  });
}

RemoteStore device(VersionedServer s) =>
    RemoteStore(AccountApi('https://server.test', session: 'tok', client: s.client));

String ev(String id, String time) => jsonEncode({'id': id, 'type': 'glucose', 'time': time, 'glucose': 6.0});

void main() {
  test('两台设备各自新增记录，都保留（组员问题清单：B 覆盖 A）', () async {
    final s = VersionedServer()..values['life_events'] = '[]'..versions['life_events'] = 100;
    final a = device(s), b = device(s);
    expect(await a.getSetting('life_events'), '[]');
    expect(await b.getSetting('life_events'), '[]');   // 两台都先读到空的
    await a.putSetting('life_events', '[${ev('A', '2026-11-19T08:00:00')}]');
    await b.putSetting('life_events', '[${ev('B', '2026-11-19T09:00:00')}]');   // B 用旧版本写 → 冲突 → 合并后重送
    final ids = [for (final e in jsonDecode(s.values['life_events']!) as List) e['id']];
    expect(ids, ['A', 'B']);
    expect(s.conflicts, 1);
    expect(await b.getSetting('life_events'), s.values['life_events']);   // 本机缓存也更新为合并结果
  });

  test('同编号以本机这次的为准（例如修正份量）；清空与示范资料整份替换', () {
    final server = '[${ev('A', '2026-11-19T08:00:00')},${ev('B', '2026-11-19T09:00:00')}]';
    final local = '[${jsonEncode({'id': 'A', 'type': 'glucose', 'time': '2026-11-19T08:00:00', 'glucose': 7.5})}]';
    final merged = jsonDecode(mergeLifeEvents(server, local)) as List;
    expect(merged.firstWhere((e) => e['id'] == 'A')['glucose'], 7.5);
    expect(merged.map((e) => e['id']), containsAll(['A', 'B']));
    expect(mergeLifeEvents(server, '[]'), '[]');
    final demo = '[${jsonEncode({'id': 'demo-1', 'type': 'wake', 'time': '2026-11-19T06:00:00', 'is_simulated': true})}]';
    expect(mergeLifeEvents(server, demo), demo);
    // 服务器上的示范资料不会混进实际记录
    final merged2 = jsonDecode(mergeLifeEvents(demo, local)) as List;
    expect(merged2.any((e) => e['is_simulated'] == true), isFalse);
  });

  test('其他设置冲突时以这次写入为准；旧版服务器（没有版本）照常写入', () async {
    final s = VersionedServer()..values['life_schedule'] = '[]'..versions['life_schedule'] = 100;
    final a = device(s), b = device(s);
    await a.getSetting('life_schedule');
    await b.getSetting('life_schedule');
    await a.putSetting('life_schedule', '["a"]');
    await b.putSetting('life_schedule', '["b"]');
    expect(s.values['life_schedule'], '["b"]');
  });

  test('送往后端的记录带编号与模拟标记；mg/dL 换算成 mmol/L 显示', () {
    final j = careEventJson({'id': 'x1', 'type': 'glucose', 'time': '2026-11-19T08:00:00', 'glucose': 180, 'unit': 'mg/dL',
      'is_simulated': true, 'recorded_at': '2026-11-19T08:00:01', 'timezone_name': 'CST'})!;
    expect(j['id'], 'x1');
    expect(j['is_simulated'], isTrue);
    expect(j['unit'], 'mg/dL');
    expect(j.containsKey('timezone_name'), isFalse);
    expect(glucoseMmol({'glucose': 180, 'unit': 'mg/dL'}), 10);
    expect(glucoseMmol({'glucose': 6.2}), 6.2);
    expect(glucoseMmol({'glucose': 'x'}), isNull);
  });
}
