import 'package:flutter/material.dart';

import '../core/glucose_context.dart';

class GlucoseContextCard extends StatelessWidget {
  final List<Map<String, dynamic>> events;
  final DateTime now;
  const GlucoseContextCard({
    super.key,
    required this.events,
    required this.now,
  });

  String _time(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

  String _event(LifeObservation event) {
    final g = event.glucose;
    if (g != null) return '实测血糖 ${g.toStringAsFixed(1)} mmol/L';
    return switch (event.type) {
      'meal' =>
        '吃饭${event.data['meal_food'] is String ? ' · ${event.data['meal_food']}' : ''}'
            '${event.carbs == null ? '' : ' · 估计碳水 ${event.carbs!.toStringAsFixed(1)} g'}',
      'medication' || 'insulin' =>
        '${event.type == 'insulin' ? '打针' : '用药'} · ${switch (event.data['taken']) {
          true => '已记录完成',
          false => '已记录未完成',
          _ => '状态未记录',
        }}',
      'sleep' => '入睡',
      'wake' => '起床',
      'exercise' =>
        '运动${event.data['minutes'] is num ? ' · ${event.data['minutes']} 分钟' : ''}',
      _ => '生活记录',
    };
  }

  @override
  Widget build(BuildContext context) {
    final result = describeGlucose(events, now);
    final related = result.context;
    final latest = result.latest;
    final trend = switch (result.direction) {
      HistoricalDirection.higher => '相似历史多见上升',
      HistoricalDirection.lower => '相似历史多见下降',
      HistoricalDirection.similar => '相似历史多见小幅变化',
      HistoricalDirection.mixed => '相似历史的方向不一致',
      null => '暂不提供方向线索',
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('血糖与生活记录', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            if (latest != null)
              Text(
                '最近实测 · ${latest.time.month}月${latest.time.day}日 ${_time(latest.time)} · '
                '${latest.glucose!.toStringAsFixed(1)} mmol/L',
              ),
            if (related != null) ...[
              Text(
                related.meal == null
                    ? '餐饮：近 3 小时无打卡'
                    : '餐饮：${_event(related.meal!)}',
              ),
              Text(
                related.medication.isEmpty
                    ? '用药与打针：近 6 小时未记录'
                    : '用药与打针：${related.medication.map((e) => '${_time(e.time)} ${_event(e)}').join('、')}',
              ),
              Text(
                related.sleepHours == null
                    ? '睡眠：无完整入睡和起床记录'
                    : '睡眠：最近一段约 ${related.sleepHours!.toStringAsFixed(1)} 小时',
              ),
              Text(
                related.activity.isEmpty
                    ? '运动：近 3 小时未记录'
                    : '运动：${related.activity.map((e) => '${_time(e.time)} ${_event(e)}').join('、')}',
              ),
            ],
            const SizedBox(height: 8),
            Text(
              '餐后约 2 小时 · $trend',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(result.status),
            const Text('研究原型，仅供对照个人记录。复测确认实际变化，药量和用药时间遵医嘱。'),
            if (result.timeline.isNotEmpty)
              ExpansionTile(
                title: const Text('最近 24 小时的实测与打卡'),
                children: [
                  for (final event in result.timeline.reversed)
                    ListTile(
                      dense: true,
                      title: Text(_event(event)),
                      leading: Text(_time(event.time)),
                    ),
                ],
              ),
            const ExpansionTile(
              title: Text('血糖参考值与出处'),
              children: [
                ListTile(
                  title: Text('中国 2 型糖尿病一般控制目标'),
                  subtitle: SelectableText(
                    '空腹 4.4–7.0，非空腹 <10.0 mmol/L。目标应个体化。\n'
                    '中华医学会《中国糖尿病防治指南（2024版）》表 6\n'
                    'https://doi.org/10.3760/cma.j.cn115791-20241203-00705',
                  ),
                ),
                ListTile(
                  title: Text('ADA 多数非妊娠糖尿病成人目标'),
                  subtitle: SelectableText(
                    '餐前 4.4–7.2，餐后峰值 <10.0 mmol/L。餐后按开餐起 1–2 小时测量。\n'
                    'ADA 2026 Standards of Care，表 6.3\nhttps://doi.org/10.2337/dc26-s006',
                  ),
                ),
                ListTile(
                  title: Text('非妊娠人群的实验室筛查参考'),
                  subtitle: SelectableText(
                    'NIDDK 正常参考：空腹血浆葡萄糖 <5.6 mmol/L；75 g OGTT 2 小时 <7.8 mmol/L。'
                    'OGTT 采用规定的葡萄糖负荷，日常进餐的结果应单独解读。\n'
                    'https://www.niddk.nih.gov/health-information/diabetes/overview/tests-diagnosis',
                  ),
                ),
                ListTile(
                  title: Text('同一餐的血糖变化因人而异'),
                  subtitle: SelectableText(
                    '指南提供测量时间和控制目标。餐食、药物、运动、睡眠和测量时点都会影响实测变化。\n'
                    'https://www.cdc.gov/diabetes/diabetes-testing/monitoring-blood-sugar.html\n'
                    'https://www.cdc.gov/diabetes/living-with/10-things-that-spike-blood-sugar.html\n'
                    'https://doi.org/10.1016/j.cell.2015.11.001',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
