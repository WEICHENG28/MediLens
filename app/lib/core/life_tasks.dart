// 复查/咨询任务：由尿检解读中的规则建议生成，用户明确选择后才加入「小兔任务」，保存在本机。
// 紧急事项（尿糖+尿酮体）不会成为任务，只由总览页的红色提示卡传达。

import 'dart:convert';

import '../data/local_store.dart';

const kLifeTasks = 'life_tasks';

class LifeTask {
  final String id; // 「规则编号|检验日期」，同一份报告同一规则不重复添加
  final String title;
  final String? due; // 最早建议日期 yyyy-MM-dd；null 表示下次复诊/以医生为准
  final bool done;
  const LifeTask({required this.id, required this.title, this.due, this.done = false});

  LifeTask copyWith({bool? done}) => LifeTask(id: id, title: title, due: due, done: done ?? this.done);
  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'due': due, 'done': done};
  factory LifeTask.fromJson(Map<String, dynamic> j) =>
      LifeTask(id: j['id'] as String, title: j['title'] as String, due: j['due'] as String?, done: j['done'] as bool? ?? false);
}

Future<List<LifeTask>> loadTasks(LocalStore store) async {
  final raw = await store.getSetting(kLifeTasks);
  if (raw == null) return [];
  return (jsonDecode(raw) as List).map((e) => LifeTask.fromJson(e as Map<String, dynamic>)).toList();
}

Future<void> saveTasks(LocalStore store, List<LifeTask> tasks) => store.putSetting(kLifeTasks, jsonEncode(tasks.map((t) => t.toJson()).toList()));

/// 本次解读中带有复查/咨询建议的命中规则 → 候选任务。days 非空时，最早建议日期 = 检验日期 + days。
List<LifeTask> candidatesFromHits(List<Map<String, dynamic>> hits, String? testDate) {
  final base = DateTime.tryParse(testDate ?? '') ?? DateTime.now();
  final stamp = base.toIso8601String().substring(0, 10);
  final out = <LifeTask>[];
  for (final h in hits) {
    final t = h['followup_task'] as Map<String, dynamic>?;
    if (t == null || h['urgent'] == true) continue;
    final days = t['days'] as int?;
    out.add(LifeTask(
      id: '${h['rule_id']}|$stamp',
      title: t['title'] as String,
      due: days == null ? null : base.add(Duration(days: days)).toIso8601String().substring(0, 10),
    ));
  }
  return out;
}

/// 合并并去重，返回新增的数量。
Future<int> addTasks(LocalStore store, List<LifeTask> candidates) async {
  final cur = await loadTasks(store);
  final known = cur.map((t) => t.id).toSet();
  final fresh = candidates.where((t) => !known.contains(t.id)).toList();
  if (fresh.isNotEmpty) await saveTasks(store, [...cur, ...fresh]);
  return fresh.length;
}
