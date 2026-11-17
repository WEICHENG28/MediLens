// 照护记录：送往后端的统一格式、餐次推断、份量修正与语音记录解析。
// 只发送时间、类型与数值；日记（note）的文字只留在本机，不会送出。

/// 送往后端的字段（其余字段如 id、after、日记文字都不发送）。
const careEventKeys = [
  'type', 'time', 'taken', 'insulin_kind', 'med_name', 'meal_size', 'minutes', 'glucose', 'task', 'slot',
  'meal_slot', 'food', 'carbs_g', 'sugars_g', 'grams', 'sweet_drink', 'estimate', 'original_grams',
  'original_carbs_g', 'corrected_by', 'corrected_at', 'glucose_source', 'confirmatory', 'symptoms',
  'systolic', 'diastolic', 'weight_kg', 'steps', 'lab',
];

/// 本机记录 → 后端格式。旧版拍餐记录的 meal_* 字段换成新名称；日记不发送（返回 null）。
Map<String, dynamic>? careEventJson(Map<String, dynamic> e) {
  if (e['type'] == 'note') return null;
  final out = <String, dynamic>{
    for (final k in careEventKeys)
      if (e[k] != null) k: e[k],
  };
  const legacy = {'meal_carbs_g': 'carbs_g', 'meal_sugars_g': 'sugars_g', 'meal_grams': 'grams', 'meal_food': 'food'};
  for (final entry in legacy.entries) {
    if (out[entry.value] == null && e[entry.key] != null) out[entry.value] = e[entry.key];
  }
  if (out['type'] == 'meal' && out['estimate'] == null && out['carbs_g'] != null) out['estimate'] = 'photo';
  return out;
}

List<Map<String, dynamic>> careEventsJson(Iterable<Map<String, dynamic>> events) =>
    [for (final e in events) ?careEventJson(e)];

/// 按时间推断餐次（与后端一致）：10 点前早餐、15 点前午餐、之后晚餐。
String mealSlotFor(DateTime t) => t.hour < 10 ? 'breakfast' : t.hour < 15 ? 'lunch' : 'dinner';

const mealSlotZh = {'breakfast': '早餐', 'lunch': '午餐', 'dinner': '晚餐', 'snack': '加餐'};

/// 份量修正：保留原始估算（第一次修正时记下），按新克数等比例换算碳水与糖。
Map<String, dynamic> correctPortion(Map<String, dynamic> meal, double grams, String by, DateTime at) {
  final oldGrams = (meal['grams'] as num?)?.toDouble();
  final out = Map<String, dynamic>.from(meal);
  out['original_grams'] ??= oldGrams;
  out['original_carbs_g'] ??= meal['carbs_g'];
  if (oldGrams != null && oldGrams > 0) {
    final ratio = grams / oldGrams;
    for (final k in ['carbs_g', 'sugars_g']) {
      if (meal[k] is num) out[k] = double.parse(((meal[k] as num) * ratio).toStringAsFixed(1));
    }
  }
  out['grams'] = grams;
  out['corrected_by'] = by;
  out['corrected_at'] = at.toIso8601String().substring(0, 19);
  return out;
}

/// 一句话记录的解析结果（必须请用户确认后才保存）。
class VoiceRecord {
  final Map<String, dynamic> event;
  final String summary;
  const VoiceRecord(this.event, this.summary);
}

final _num = RegExp(r'(\d+(?:\.\d+)?)');
const _cnDigits = {'一': 1, '两': 2, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6, '七': 7, '八': 8, '九': 9, '十': 10, '半': 0.5};

double? _cnNumber(String s) {
  final m = _num.firstMatch(s);
  if (m != null) return double.tryParse(m.group(1)!);
  if (s.contains('十')) {
    final parts = s.split('十');
    final tens = parts[0].isEmpty ? 1 : (_cnDigits[parts[0][parts[0].length - 1]] ?? 1);
    final ones = parts.length > 1 && parts[1].isNotEmpty ? (_cnDigits[parts[1][0]] ?? 0) : 0;
    return (tens * 10 + ones).toDouble();
  }
  for (final ch in s.split('')) {
    if (_cnDigits.containsKey(ch)) return _cnDigits[ch]!.toDouble();
  }
  return null;
}

const _symptomWords = ['出汗', '心悸', '心慌', '手抖', '头晕', '饥饿', '乏力', '恶心', '口渴', '视物模糊'];

/// 把一句话（语音转文字或手打）解析成记录。只认常见说法；认不出就返回空，请用户改用按钮记录。
/// 不估算碳水（不知道份量），提示用户可以拍照或填克数。
List<VoiceRecord> parseVoiceRecord(String text, DateTime now) {
  final t = text.replaceAll(RegExp(r'\s'), '').replaceAll('，', ',').replaceAll('。', '');
  final time = now.toIso8601String().substring(0, 19);
  final out = <VoiceRecord>[];
  // 血压：135/80、高压135低压80
  final bp = RegExp(r'血压.{0,4}?(\d{2,3})[/／比](\d{2,3})').firstMatch(t) ??
      RegExp(r'高压(\d{2,3}).{0,3}低压(\d{2,3})').firstMatch(t);
  if (bp != null) {
    final s = int.parse(bp.group(1)!), d = int.parse(bp.group(2)!);
    if (s > d && s <= 260 && d >= 30) {
      out.add(VoiceRecord({'type': 'bp', 'time': time, 'systolic': s, 'diastolic': d}, '血压 $s/$d mmHg'));
    }
  }
  // 血糖：血糖7.8、测了血糖是7.8
  final g = RegExp(r'血糖.{0,4}?(\d{1,2}(?:\.\d)?)').firstMatch(t);
  if (g != null) {
    final v = double.parse(g.group(1)!);
    if (v > 1 && v < 35) {
      final finger = !t.contains('监测仪') && !t.contains('探头');
      out.add(VoiceRecord({'type': 'glucose', 'time': time, 'glucose': v, 'glucose_source': finger ? 'finger' : 'cgm'},
          '血糖 $v mmol/L（${finger ? '指血' : '监测仪'}）'));
    }
  }
  // 体重：体重66.5、66.5公斤
  final w = RegExp(r'体重.{0,3}?(\d{2,3}(?:\.\d)?)').firstMatch(t) ?? RegExp(r'(\d{2,3}(?:\.\d)?)(公斤|千克|kg)').firstMatch(t);
  if (w != null) {
    final v = double.parse(w.group(1)!);
    if (v >= 20 && v <= 300) out.add(VoiceRecord({'type': 'weight', 'time': time, 'weight_kg': v}, '体重 $v kg'));
  }
  // 步数
  final st = RegExp(r'(\d{3,6})步').firstMatch(t);
  if (st != null) out.add(VoiceRecord({'type': 'steps', 'time': time, 'steps': int.parse(st.group(1)!)}, '今天 ${st.group(1)} 步'));
  // 运动：散步了20分钟、走了半小时
  final ex = RegExp(r'(散步|走路|走了|快走|运动|锻炼|跳舞|打太极|骑车|游泳).{0,6}?([\d一二两三四五六七八九十半]+)(分钟|小时|个小时)').firstMatch(t);
  if (ex != null) {
    final n = _cnNumber(ex.group(2)!);
    if (n != null) {
      final minutes = (ex.group(3)!.contains('小时') ? n * 60 : n).round();
      if (minutes > 0 && minutes <= 600) {
        out.add(VoiceRecord({'type': 'exercise', 'time': time, 'minutes': minutes}, '${ex.group(1)} $minutes 分钟'));
      }
    }
  }
  // 用药：吃了药 / 忘了吃药
  if (RegExp(r'(忘了|没吃|漏了).{0,2}药').hasMatch(t)) {
    out.add(VoiceRecord({'type': 'medication', 'time': time, 'taken': false}, '这次漏了药'));
  } else if (RegExp(r'吃了.{0,4}药|药吃了|吃过药').hasMatch(t)) {
    out.add(VoiceRecord({'type': 'medication', 'time': time, 'taken': true}, '已用药'));
  }
  // 症状
  final sym = <String>{for (final s in _symptomWords) if (t.contains(s)) s == '心慌' ? '心悸' : s}.toList();
  if (sym.isNotEmpty) out.add(VoiceRecord({'type': 'symptom', 'time': time, 'symptoms': sym}, '症状：${sym.join('、')}'));
  // 进餐：我刚吃了一碗米饭和红烧肉、晚饭吃了面条
  final meal = RegExp(r'(早饭|早餐|午饭|午餐|中饭|晚饭|晚餐|夜宵|加餐)?.{0,3}?吃了(.{1,30})').firstMatch(t);
  if (meal != null && !RegExp(r'^.{0,4}药').hasMatch(meal.group(2)!)) {
    final word = meal.group(1);
    final slot = word == null ? mealSlotFor(now)
        : word.startsWith('早') ? 'breakfast' : (word.startsWith('午') || word.startsWith('中')) ? 'lunch'
        : (word == '夜宵' || word == '加餐') ? 'snack' : 'dinner';
    final food = meal.group(2)!.replaceAll(RegExp(r'[,，].*$'), '');
    final sweet = RegExp(r'可乐|果汁|奶茶|甜饮料|汽水|雪碧|含糖|蛋糕|甜点').hasMatch(t); // 整句判断：「……，还喝了可乐」
    out.add(VoiceRecord({'type': 'meal', 'time': time, 'meal_slot': slot, 'food': food, 'estimate': 'voice',
      'meal_size': 'normal', if (sweet) 'sweet_drink': true}, '${mealSlotZh[slot]}：$food${sweet ? '（含甜饮料）' : ''}'));
  }
  return out;
}
