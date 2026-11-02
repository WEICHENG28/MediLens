import 'models.dart';

/// Deliberately excludes labels, OCR lines, dates, images and report metadata.
Map<String, dynamic>? ocrReviewPayload(LabItem item) {
  const codes = {'GLU', 'KET', 'PRO', 'LEU', 'NIT', 'BLD', 'SG', 'PH', 'UACR'};
  final token = RegExp(r'^(?:阴性|陽性|阳性|陰性|弱阳性|弱陽性|NEG|POS|negative|positive|trace|[0-9Il|Oo.,+＋\-－±<>≤≥ ]{1,24})$', caseSensitive: false);
  bool safe(String value) => value.length <= 24 && value.trim().isNotEmpty && token.firstMatch(value)?.end == value.length;
  final value = item.value;
  if (!codes.contains(item.code) || value == null || !safe(value)) return null;
  final candidates = item.candidates.where(safe).toSet().take(8).toList();
  if (candidates.isEmpty) return null;
  return {'consent': true, 'code': item.code, 'value': value, 'candidates': candidates};
}
