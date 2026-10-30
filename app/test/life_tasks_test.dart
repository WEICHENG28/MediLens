import 'package:flutter_test/flutter_test.dart';
import 'package:medilens/core/life_tasks.dart';
import 'package:medilens/data/local_store.dart';

void main() {
  final hits = [
    {'rule_id': 'R-01', 'urgent': true, 'followup_task': {'title': '不应出现', 'days': null}},
    {'rule_id': 'R-04', 'urgent': false, 'followup_task': {'title': '3–6 个月内复查 UACR', 'days': 90}},
    {'rule_id': 'R-06', 'urgent': false, 'followup_task': {'title': '向医生咨询是否需要做 UACR 检查', 'days': null}},
    {'rule_id': 'R-02', 'urgent': false},
  ];

  test('紧急规则与无建议的规则不会成为任务；有天数的算出最早日期', () {
    final c = candidatesFromHits(hits, '2026-10-01');
    expect(c.map((t) => t.id), ['R-04|2026-10-01', 'R-06|2026-10-01']);
    expect(c.first.due, '2026-12-30');
    expect(c.last.due, isNull);
  });

  test('重复加入同一份报告的任务不会重复', () async {
    final store = MemoryStore();
    final c = candidatesFromHits(hits, '2026-10-01');
    expect(await addTasks(store, c), 2);
    expect(await addTasks(store, c), 0);
    expect((await loadTasks(store)).length, 2);
    final done = [for (final t in await loadTasks(store)) t.copyWith(done: true)];
    await saveTasks(store, done);
    expect((await loadTasks(store)).every((t) => t.done), isTrue);
  });
}
