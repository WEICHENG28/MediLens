import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'models.dart';

class MedicationName {
  final String name, sourceTitle, sourceUrl, sourceDate, checkedAt, verification;
  const MedicationName(this.name, this.sourceTitle, this.sourceUrl, {this.sourceDate = '', this.checkedAt = '', this.verification = ''});
}
class MedicationDictionary {
  final String version, checkedAt, scope;
  final List<MedicationName> entries;
  const MedicationDictionary(this.version, this.checkedAt, this.scope, this.entries);
  factory MedicationDictionary.decode(String raw) {
    final j = jsonDecode(raw) as Map<String, dynamic>;
    final sources = {for (final s in j['sources'] as List) s['id'] as String: s as Map};
    final entries = <MedicationName>[];
    final names = <String>{};
    for (final e in j['entries'] as List) {
      final name = e['name'] as String, source = sources[e['source']];
      if (name.isEmpty || !names.add(name) || source == null) throw const FormatException('药名词表格式错误');
      final url = Uri.parse(source['url'] as String);
      if (url.scheme != 'https' || url.host != 'www.nmpa.gov.cn') throw const FormatException('药名来源未识别');
      if (source['verification'] != 'official_search_index' || source['medical_review'] != 'not_reviewed' ||
          DateTime.tryParse(source['publication_date'] as String? ?? '') == null || DateTime.tryParse(source['checked_at'] as String? ?? '') == null) { throw const FormatException('药名核对版本缺失'); }
      entries.add(MedicationName(name, source['title'] as String, url.toString(), sourceDate: source['publication_date'] as String, checkedAt: source['checked_at'] as String, verification: source['verification'] as String));
    }
    return MedicationDictionary(j['version'] as String, j['checked_at'] as String, j['scope'] as String, entries);
  }
}
final medicationDictionaryProvider = FutureProvider<MedicationDictionary>((ref) async =>
  MedicationDictionary.decode(await rootBundle.loadString('assets/medications/seed_names.json')));

class MedicationCandidate {
  final MedicationName entry;
  final OcrLine evidence;
  const MedicationCandidate(this.entry, this.evidence);
}
/// Exact whole line only. Never strip formulation, roman suffix, ingredient prefixes or compound names.
String _nameText(String text) => text.replaceAll(RegExp(r'\s+'), '')
    .replaceFirst(RegExp(r'^(?:【通用名称】|通用名称[:：]|药品通用名称[:：])'), '')
    .replaceFirst(RegExp(r'[。；;]$'), '');
List<MedicationCandidate> medicationCandidates(List<OcrLine> lines, MedicationDictionary dictionary) {
  final candidates = <String, MedicationCandidate>{};
  for (final line in lines) {
    if (!line.confidence.isFinite || line.confidence < .9 || line.confidence > 1) continue;
    for (final entry in dictionary.entries) {
      if (_nameText(line.text) != entry.name) continue;
      final old = candidates[entry.name];
      if (old == null || old.evidence.confidence < line.confidence) candidates[entry.name] = MedicationCandidate(entry, line);
    }
  }
  return candidates.values.toList();
}
