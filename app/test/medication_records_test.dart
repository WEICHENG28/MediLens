import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medilens/core/medication_names.dart';
import 'package:medilens/core/medication_records.dart';
import 'package:medilens/core/models.dart';
import 'package:medilens/data/local_store.dart';
import 'package:medilens/features/medication_records_page.dart';
import 'package:medilens/features/settings_page.dart';

MedicationDictionary dict() => MedicationDictionary.decode(File('assets/medications/seed_names.json').readAsStringSync());
List<MedicationCandidate> selected() => medicationCandidates([const OcrLine(text: '恩格列净片', confidence: .99, box: NormBox(x: 0,y: 0,w: 1,h: 1))], dict());
class FailingStore extends MemoryStore {
  bool fail = false;
  @override Future<void> putSetting(String key, String value) async { if (fail) throw StateError('failed'); return super.putSetting(key, value); }
}
void main() {
  test('保存源版本、完整原文、独立使用状态；重复/并发保存不新增同名记录', () async {
    final store = MemoryStore(); final records = MedicationRecords(store, () => DateTime(2026,11,1,9));
    await Future.wait([records.save(selected(), dict(), MedicationUse.unspecified), records.save(selected(), dict(), MedicationUse.unspecified)]);
    final data = await records.load(); expect(data, hasLength(1)); expect(data.single.use, MedicationUse.unspecified);
    expect(data.single.dictionaryVersion, dict().version); expect(data.single.sourceCheckedAt, '2026-11-01');
    expect(data.single.originalText, '恩格列净片'); expect(data.single.sourceUrl, contains('nmpa.gov.cn'));
    expect(store.reports, isEmpty); expect(store.settings.keys, [MedicationRecords.storageKey]);
    final restarted = MedicationRecords(store, () => DateTime(2026,11,2));
    await restarted.setUse('恩格列净片', MedicationUse.reportedTaking);
    final updated = (await restarted.load()).single;
    expect(updated.use, MedicationUse.reportedTaking); expect(updated.confirmedAt, DateTime(2026,11,1,9)); expect(updated.updatedAt, DateTime(2026,11,2));
  });
  test('保存失败不改变原记录，失败后可重试；篡改候选不保存', () async {
    final store = FailingStore(); final records = MedicationRecords(store, () => DateTime(2026,11,1));
    await records.save(selected(), dict(), MedicationUse.unspecified); final before = await store.getSetting(MedicationRecords.storageKey);
    store.fail = true; await expectLater(records.setUse('恩格列净片', MedicationUse.reportedTaking), throwsStateError);
    expect(await store.getSetting(MedicationRecords.storageKey), before);
    store.fail = false;
    final forged = MedicationCandidate(dict().entries.first, selected().single.evidence);
    await expectLater(records.save([forged], dict(), MedicationUse.reportedTaking), throwsFormatException);
    await records.setUse('恩格列净片', MedicationUse.reportedTaking); expect((await records.load()).single.use, MedicationUse.reportedTaking);
  });
  test('损坏/未知版本保留原文不覆盖；明确清空后能重新保存', () async {
    final store = MemoryStore(); final records = MedicationRecords(store, DateTime.now);
    await store.putSetting(MedicationRecords.storageKey, '{"version":99,"records":[]}');
    await expectLater(records.save(selected(), dict(), MedicationUse.unspecified), throwsFormatException);
    expect(await store.getSetting(MedicationRecords.storageKey), contains('99'));
    await records.clear(); expect(await records.load(), isEmpty);
    await records.save(selected(), dict(), MedicationUse.unspecified);
    final raw = jsonDecode((await store.getSetting(MedicationRecords.storageKey))!) as Map<String,dynamic>;
    (raw['records'] as List).first['use'] = 'automatically_taking'; await store.putSetting(MedicationRecords.storageKey,jsonEncode(raw));
    await expectLater(records.load(), throwsFormatException);
  });
  test('删除不改变其他记录；删除后状态不能重新产生不存在的药名', () async {
    final store = MemoryStore(); final records = MedicationRecords(store, DateTime.now);
    await records.save(selected(), dict(), MedicationUse.unspecified);
    await records.remove('恩格列净片'); expect(await records.load(), isEmpty);
    await expectLater(records.setUse('恩格列净片', MedicationUse.reportedTaking), throwsStateError);
  });
  testWidgets('保存使用情况必须单独选择，取消无选择', (t) async {
    MedicationUse? result; bool called = false;
    await t.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => TextButton(onPressed: () async {
      result = await chooseMedicationUse(context, '恩格列净片'); called = true;
    }, child: const Text('打开'))))));
    await t.tap(find.text('打开')); await t.pumpAndSettle(); await t.tap(find.text('取消')); await t.pumpAndSettle(); expect(called, isTrue); expect(result, isNull);
    await t.tap(find.text('打开')); await t.pumpAndSettle(); await t.tap(find.text('仅保存药名，不确认在用')); await t.pumpAndSettle(); expect(result, MedicationUse.unspecified);
    await t.tap(find.text('打开')); await t.pumpAndSettle(); await t.tap(find.text('我确认以上药名均目前在用')); await t.pumpAndSettle(); expect(result, MedicationUse.reportedTaking);
  });
  testWidgets('记录页更改本人状态，删除要确认，删除后为空；大字无溢出', (t) async {
    final store = MemoryStore();
    final service = MedicationRecords(store, () => DateTime(2026,11,1));
    await service.save(selected(), dict(), MedicationUse.unspecified);
    final c = ProviderContainer(overrides: [medicationRecordsProvider.overrideWithValue(service)]); addTearDown(c.dispose);
    await t.pumpWidget(UncontrolledProviderScope(container: c, child: MaterialApp(builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.5)), child: child!), home: const MedicationRecordsPage()))); await t.pumpAndSettle();
    await t.ensureVisible(find.text('更改本人使用情况')); await t.tap(find.text('更改本人使用情况')); await t.pumpAndSettle();
    await t.tap(find.text('我确认以上药名均目前在用')); await t.pumpAndSettle(); expect(find.text('本人已确认当时正在使用'), findsOneWidget);
    await t.ensureVisible(find.text('删除记录')); await t.tap(find.text('删除记录')); await t.pumpAndSettle();
    await t.tap(find.text('取消')); await t.pumpAndSettle(); expect(await service.load(), hasLength(1));
    await t.tap(find.text('删除记录')); await t.pumpAndSettle(); await t.tap(find.widgetWithText(FilledButton,'删除记录')); await t.pumpAndSettle();
    expect(find.text('尚未保存药名，可从药盒识别页开始。'), findsOneWidget); expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('设置删除全部记录同时清除药名，取消不清除', (t) async {
    final store = MemoryStore(); final service = MedicationRecords(store, DateTime.now);
    await service.save(selected(), dict(), MedicationUse.unspecified);
    await t.pumpWidget(ProviderScope(overrides: [localStoreProvider.overrideWithValue(store), medicationRecordsProvider.overrideWithValue(service)],
      child: const MaterialApp(home: SettingsPage()))); await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('删除本机全部记录'), 250);
    await Scrollable.ensureVisible(t.element(find.text('删除本机全部记录')), alignment: .5); await t.pumpAndSettle();
    await t.tap(find.text('删除本机全部记录')); await t.pumpAndSettle(); await t.tap(find.text('取消')); await t.pumpAndSettle();
    expect(await service.load(), hasLength(1));
    await t.tap(find.text('删除本机全部记录')); await t.pumpAndSettle(); await t.tap(find.text('删除')); await t.pumpAndSettle();
    expect(await service.load(), isEmpty); expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox.shrink());
  });

}
