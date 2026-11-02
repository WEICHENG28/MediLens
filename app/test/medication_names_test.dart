import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:medilens/core/medication_names.dart';
import 'package:medilens/core/models.dart';
import 'package:medilens/core/medication_records.dart';
import 'package:medilens/data/local_store.dart';
import 'package:medilens/core/session.dart';
import 'package:medilens/features/medication_page.dart';
import 'package:medilens/ocr/ocr_engine.dart';

MedicationDictionary dictionary() => MedicationDictionary.decode(File('assets/medications/seed_names.json').readAsStringSync());
OcrLine line(String text, [double score = .98]) => OcrLine(text: text, confidence: score, box: const NormBox(x: .1, y: .2, w: .8, h: .1));
class Images implements MedicationImages {
  Uint8List? bytes = img.encodePng(img.Image(width: 600, height: 600));
  @override Future<Uint8List?> pick(ImageSource source) async => bytes;
}
class Engine implements OcrEngine {
  List<OcrLine> lines = [line('盐酸二甲双胍缓释片')];
  bool fail = false;
  int count = 0;
  @override Future<OcrResult> recognize(img.Image source, {int rotation = 0, bool autoOrient = true}) async {
    count++; if (fail) throw StateError('internal private error');
    return OcrResult(image: source, rotation: rotation, lines: lines, elapsed: const Duration(milliseconds: 1));
  }
}
void main() {
  test('词表为6个完整药名且每条有官方来源，普通片与缓释片分开', () {
    final d = dictionary(); expect(d.entries, hasLength(6));
    final data = medicationCandidates([line('盐酸二甲双胍片'), line('盐酸二甲双胍缓释片'), line('通用名称：阿卡波糖片')], d);
    expect(data.map((v) => v.entry.name), ['盐酸二甲双胍片', '盐酸二甲双胍缓释片', '阿卡波糖片']);
    expect(data.every((v) => Uri.parse(v.entry.sourceUrl).host == 'www.nmpa.gov.cn'), isTrue);
    final json = jsonDecode(File('assets/medications/seed_names.json').readAsStringSync()) as Map<String, dynamic>;
    (json['entries'] as List).first['source'] = 'unknown';
    expect(() => MedicationDictionary.decode(jsonEncode(json)), throwsFormatException);
  });
  test('不模糊补字、不把复方/成份/特殊后缀/规格拼成单药，不跨行猜测', () {
    final data = medicationCandidates([
      line('盐酸二甲双瓜片'), line('复方盐酸二甲双胍片'), line('盐酸二甲双胍缓释片（IV）'),
      line('本品成份：盐酸二甲双胍片'), line('阿卡波糖片50mg'), line('阿卡波'), line('糖片'),
      line('XX未知药片'), line('阿卡波糖片。'), line('通 用 名 称：达格列净片')], dictionary());
    expect(data.map((v) => v.entry.name), ['阿卡波糖片', '达格列净片']);
  });
  test('低分、无效分数不候选，重复名称取最高分原文', () {
    final data = medicationCandidates([line('达格列净片', .89), line('阿卡波糖片', double.nan), line('阿卡波糖片', 1.1),
      line('盐酸二甲双胍片', .92), line('通用名称：盐酸二甲双胍片', .99)], dictionary());
    expect(data, hasLength(1)); expect(data.single.evidence.text, startsWith('通用名称'));
  });
  test('识别队列失败后可恢复', () async {
    final engine = Engine()..fail = true; final queued = QueuedMedicationOcr(engine), image = img.Image(width: 10, height: 10);
    await expectLater(queued.recognize(image), throwsStateError); engine.fail = false;
    expect((await queued.recognize(image)).lines, isNotEmpty); expect(engine.count, 2);
  });
  Future<ProviderContainer> host(WidgetTester t, Images images, Engine engine, {double scale = 1}) async {
    final c = ProviderContainer(overrides: [localStoreProvider.overrideWithValue(MemoryStore()), medicationDictionaryProvider.overrideWith((_) async => dictionary()),
      medicationImagesProvider.overrideWithValue(images), medicationOcrProvider.overrideWithValue(engine)]);
    addTearDown(c.dispose);
    t.view.physicalSize = const Size(1080, 2400); t.view.devicePixelRatio = 2.75; addTearDown(t.view.reset);
    await t.pumpWidget(UncontrolledProviderScope(container: c, child: MaterialApp(builder: (context, child) =>
      MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!), home: const MedicationPage())));
    await t.pumpAndSettle(); return c;
  }
  Future<void> show(WidgetTester t, Finder f, {double step = 250}) async {
    if (f.evaluate().isEmpty) { await t.scrollUntilVisible(f, step,
      scrollable: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first); }
    await Scrollable.ensureVisible(t.element(f), alignment: .5); await t.pumpAndSettle();
  }
  Future<void> scan(WidgetTester t) async {
    await t.tap(find.byKey(const Key('med_gallery'))); await t.pumpAndSettle();
    await show(t, find.byKey(const Key('med_scan'))); await t.tap(find.byKey(const Key('med_scan'))); await t.pumpAndSettle();
  }
  testWidgets('候选需两次人工核对；取消不确认；不修改报告会话；重选图清空确认', (t) async {
    final images = Images(); final c = await host(t, images, Engine()); final before = c.read(sessionProvider);
    await scan(t);
    await show(t, find.byType(CheckboxListTile)); expect(t.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value, isFalse);
    await t.tap(find.byType(CheckboxListTile)); await t.pumpAndSettle();
    await show(t, find.byKey(const Key('med_confirm'))); await t.tap(find.byKey(const Key('med_confirm'))); await t.pumpAndSettle();
    await t.tap(find.text('继续核对')); await t.pumpAndSettle(); expect(find.byKey(const Key('med_confirmed')), findsNothing);
    await t.tap(find.byKey(const Key('med_confirm'))); await t.pumpAndSettle(); await t.tap(find.text('名称一致')); await t.pumpAndSettle();
    await show(t, find.byKey(const Key('med_confirmed'))); expect(find.byKey(const Key('med_confirmed')), findsOneWidget);
    expect(identical(c.read(sessionProvider), before), isTrue);
    expect(await c.read(medicationRecordsProvider).load(), isEmpty);
    await show(t, find.byKey(const Key('med_save'))); await t.tap(find.byKey(const Key('med_save'))); await t.pumpAndSettle();
    await t.tap(find.text('取消')); await t.pumpAndSettle(); expect(await c.read(medicationRecordsProvider).load(), isEmpty);
    await t.tap(find.byKey(const Key('med_save'))); await t.pumpAndSettle();
    await t.tap(find.text('仅保存药名，不确认在用')); await t.pumpAndSettle();
    expect((await c.read(medicationRecordsProvider).load()).single.use, MedicationUse.unspecified);
    expect(identical(c.read(sessionProvider), before), isTrue);
    await show(t, find.byKey(const Key('med_gallery')), step: -250); await t.tap(find.byKey(const Key('med_gallery'))); await t.pumpAndSettle();
    expect(find.byKey(const Key('med_confirmed')), findsNothing); expect(find.byType(CheckboxListTile), findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('低分不提供可确认药名，识别原文保留；大字无溢出', (t) async {
    await host(t, Images(), Engine()..lines = [line('阿卡波糖片', .3)], scale: 1.5); await scan(t);
    expect(find.byType(CheckboxListTile), findsNothing); await show(t, find.textContaining('没有找到可供确认'));
    expect(find.textContaining('不能据此认定不是药品'), findsOneWidget);
    await show(t, find.text('查看识别原文（1 行）')); await t.tap(find.text('查看识别原文（1 行）')); await t.pumpAndSettle();
    await show(t, find.text('阿卡波糖片')); expect(find.text('阿卡波糖片'), findsOneWidget); expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('取消选图保持空页面，损坏图片与OCR失败有可重试说明', (t) async {
    final images = Images()..bytes = null, engine = Engine()..fail = true;
    await host(t, images, engine); await t.tap(find.byKey(const Key('med_gallery'))); await t.pumpAndSettle();
    expect(engine.count, 0); expect(t.widget<FilledButton>(find.byKey(const Key('med_scan'))).onPressed, isNull);
    images.bytes = Uint8List.fromList([1,2,3]); await t.tap(find.byKey(const Key('med_gallery'))); await t.pumpAndSettle();
    expect(find.byKey(const Key('med_error')), findsOneWidget);
    images.bytes = img.encodePng(img.Image(width: 600, height: 600)); await scan(t);
    await show(t, find.byKey(const Key('med_error'))); expect(find.textContaining('本机识别未能完成'), findsOneWidget);
    expect(find.textContaining('internal private error'), findsNothing); expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox.shrink());
  });
}
