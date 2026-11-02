import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/local_store.dart';
import 'medication_names.dart';
import 'task_receipts.dart';

enum MedicationUse { unspecified, reportedTaking }
String medicationUseLabel(MedicationUse use) => use == MedicationUse.reportedTaking ? '本人已确认当时正在使用' : '仅保存药名，未确认在用';

class MedicationRecord {
  final String name, originalText, dictionaryVersion, sourceTitle, sourceUrl, sourceDate, sourceCheckedAt;
  final DateTime confirmedAt, updatedAt;
  final MedicationUse use;
  const MedicationRecord({required this.name, required this.originalText, required this.dictionaryVersion,
    required this.sourceTitle, required this.sourceUrl, required this.sourceDate, required this.sourceCheckedAt,
    required this.confirmedAt, required this.updatedAt, required this.use});
  Map<String, dynamic> toJson() => {'name': name, 'original_text': originalText, 'dictionary_version': dictionaryVersion,
    'source_title': sourceTitle, 'source_url': sourceUrl, 'source_date': sourceDate, 'source_checked_at': sourceCheckedAt,
    'confirmed_at': confirmedAt.toIso8601String(), 'updated_at': updatedAt.toIso8601String(), 'use': use.name};
  factory MedicationRecord.fromJson(Map<String, dynamic> j) {
    for (final field in ['name','original_text','dictionary_version','source_title','source_url','source_date','source_checked_at','confirmed_at','updated_at','use']) {
      if (j[field] is! String || (j[field] as String).isEmpty) throw const FormatException('药名记录格式错误');
    }
    if (Uri.tryParse(j['source_url'])?.scheme != 'https' || Uri.tryParse(j['source_url'])?.host != 'www.nmpa.gov.cn' || !MedicationUse.values.any((v) => v.name == j['use'])) throw const FormatException('药名记录来源或状态错误');
    return MedicationRecord(name: j['name'], originalText: j['original_text'], dictionaryVersion: j['dictionary_version'],
      sourceTitle: j['source_title'], sourceUrl: j['source_url'], sourceDate: j['source_date'], sourceCheckedAt: j['source_checked_at'],
      confirmedAt: DateTime.parse(j['confirmed_at']), updatedAt: DateTime.parse(j['updated_at']),
      use: MedicationUse.values.firstWhere((v) => v.name == j['use']));
  }
  MedicationRecord withUse(MedicationUse next, DateTime now) => MedicationRecord(name: name, originalText: originalText,
    dictionaryVersion: dictionaryVersion, sourceTitle: sourceTitle, sourceUrl: sourceUrl, sourceDate: sourceDate,
    sourceCheckedAt: sourceCheckedAt, confirmedAt: confirmedAt, updatedAt: now, use: next);
}

class MedicationRecords {
  static const storageKey = 'medication_names_v1';
  final LocalStore store;
  final DateTime Function() clock;
  Future<void> tail = Future.value();
  MedicationRecords(this.store, this.clock);
  Future<List<MedicationRecord>> load() async {
    final raw = await store.getSetting(storageKey);
    if (raw == null) return [];
    final j = jsonDecode(raw);
    if (j is! Map || j['version'] != 1 || j['records'] is! List) throw const FormatException('药名记录版本无法读取');
    final records = (j['records'] as List).map((r) => MedicationRecord.fromJson(Map<String, dynamic>.from(r as Map))).toList();
    if (records.map((r) => r.name).toSet().length != records.length) throw const FormatException('药名记录重复');
    return records;
  }
  Future<T> serial<T>(Future<T> Function() task) {
    final result = tail.then((_) => task()); tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {}); return result;
  }
  Future<void> write(List<MedicationRecord> records) => store.putSetting(storageKey, jsonEncode({'version': 1, 'records': records.map((r) => r.toJson()).toList()}));
  Future<void> save(List<MedicationCandidate> candidates, MedicationDictionary dictionary, MedicationUse use) => serial(() async {
    if (candidates.isEmpty || candidates.any((c) => !medicationCandidates([c.evidence], dictionary).any((v) => v.entry.name == c.entry.name))) throw const FormatException('请先核对药名');
    final records = await load(); final next = {for (final r in records) r.name: r}; final now = clock();
    for (final c in candidates) {
      final entry = dictionary.entries.firstWhere((e) => e.name == c.entry.name);
      next[c.entry.name] = MedicationRecord(name: entry.name, originalText: c.evidence.text, dictionaryVersion: dictionary.version,
        sourceTitle: entry.sourceTitle, sourceUrl: entry.sourceUrl, sourceDate: entry.sourceDate, sourceCheckedAt: entry.checkedAt,
        confirmedAt: now, updatedAt: now, use: use);
    }
    await write(next.values.toList());
  });
  Future<void> setUse(String name, MedicationUse use) => serial(() async {
    final records = await load(); if (!records.any((r) => r.name == name)) throw StateError('记录已不存在');
    await write([for (final r in records) r.name == name ? r.withUse(use, clock()) : r]);
  });
  Future<void> remove(String name) => serial(() async { await write((await load()).where((r) => r.name != name).toList()); });
  Future<void> clear() => serial(() async { await write([]); });
}
final medicationRecordsProvider = Provider<MedicationRecords>((ref) => MedicationRecords(ref.read(localStoreProvider), ref.read(taskClockProvider)));
final savedMedicationsProvider = FutureProvider<List<MedicationRecord>>((ref) => ref.watch(medicationRecordsProvider).load());
