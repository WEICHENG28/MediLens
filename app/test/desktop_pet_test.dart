import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medilens/core/desktop_pet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DesktopPet.channel, (call) async {
      calls.add(call);
      return call.method == 'requestPin' ? true : null;
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(DesktopPet.channel, null));

  test('launcher receives only generic mood, never medical state', () async {
    for (final state in ['活泼', '困倦', '平静', '未知', null]) {
      await DesktopPet.update(energyState: state);
    }
    expect(calls.map((c) => c.arguments).toList(), [
      {'mood': 'active'}, {'mood': 'rest'}, {'mood': 'calm'},
      {'mood': 'calm'}, {'mood': 'calm'},
    ]);
    expect(await DesktopPet.requestPin(), isTrue);
  });

  test('恢复问候不发送任何个人数据', () async {
    expect(await DesktopPet.clearGreeting(), isTrue);
    expect(calls.single.method, 'clearGreeting'); expect(calls.single.arguments, isNull);
  });

  test('unsupported launcher does not break lifestyle recording', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DesktopPet.channel, (call) async {
      throw PlatformException(code: 'unavailable');
    });
    await DesktopPet.update(energyState: '活泼');
    expect(await DesktopPet.requestPin(), isFalse);
    expect(await DesktopPet.clearGreeting(), isFalse);
  });
}
