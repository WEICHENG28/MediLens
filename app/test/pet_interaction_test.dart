import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medilens/core/pet_interaction.dart';
import 'package:medilens/data/local_store.dart';
import 'package:medilens/widgets/interactive_bunny.dart';

class FailedStore extends MemoryStore {
  bool readFail = false, writeFail = false;
  @override Future<String?> getSetting(String key) async { if (readFail) throw StateError('read'); return super.getSetting(key); }
  @override Future<void> putSetting(String key,String value) async { if (writeFail) throw StateError('write'); return super.putSetting(key,value); }
}
void main() {
  Future<ProviderContainer> host(WidgetTester t, MemoryStore store, {bool reduced = false, bool large = false}) async {
    final c=ProviderContainer(overrides:[localStoreProvider.overrideWithValue(store)]);addTearDown(c.dispose);
    await t.pumpWidget(UncontrolledProviderScope(container:c, child:MaterialApp(navigatorObservers:[petRoutes], builder:(context,child)=>
      MediaQuery(data:MediaQuery.of(context).copyWith(disableAnimations:reduced,textScaler:TextScaler.linear(large?1.5:1)),child:child!),
      home:Scaffold(body:Builder(builder:(context)=>ListView(children:[const InteractiveBunny(),const PetMotionSwitch(),
        TextButton(onPressed:()=>Navigator.of(context).push(MaterialPageRoute<void>(builder:(_)=>const Scaffold(body:Text('下一页')))),child:const Text('前往下一页'))]))))));
    await t.pumpAndSettle();return c;
  }
  Animation<double> scale(WidgetTester t)=>t.widget<ScaleTransition>(find.byKey(const Key('bunny_scale'))).scale;
  testWidgets('只在点击时单次轻动，问候循环且不写医疗或交互记录', (t) async {
    final store=MemoryStore();await host(t,store);
    expect(scale(t).value,1);expect(scale(t).status,AnimationStatus.dismissed);
    await t.tap(find.byKey(const Key('bunny_greet')));await t.pump();await t.pump(const Duration(milliseconds:150));
    expect(scale(t).value,greaterThan(1));expect(find.text(petGreetings[0]),findsOneWidget);
    await t.pumpAndSettle();expect(scale(t).value,1);
    await t.tap(find.byKey(const Key('bunny_greet')));await t.pumpAndSettle();expect(find.text(petGreetings[1]),findsOneWidget);
    await t.tap(find.byKey(const Key('bunny_greet')));await t.pumpAndSettle();expect(find.text(petGreetings[2]),findsOneWidget);
    await t.tap(find.byKey(const Key('bunny_greet')));await t.pumpAndSettle();expect(find.text(petGreetings[0]),findsOneWidget);
    expect(store.settings,isEmpty);expect(store.reports,isEmpty);await t.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('关闭动画仍能问候，偏好保存后重新读取保持关闭', (t) async {
    final store=MemoryStore();final c=await host(t,store);
    await t.tap(find.byKey(const Key('pet_motion_switch')));await t.pumpAndSettle();expect(c.read(petPreferencesProvider).motion,isFalse);
    await t.tap(find.byKey(const Key('bunny_greet')));await t.pump(const Duration(milliseconds:150));
    expect(scale(t).value,1);expect(find.text(petGreetings[0]),findsOneWidget);
    expect(store.settings.keys,[PetPreferences.storageKey]);
    final restarted=ProviderContainer(overrides:[localStoreProvider.overrideWithValue(store)]);addTearDown(restarted.dispose);
    restarted.read(petPreferencesProvider);await t.pumpAndSettle();expect(restarted.read(petPreferencesProvider).motion,isFalse);
    await t.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('遵从系统减少动画，大字模式无溢出', (t) async {
    await host(t,MemoryStore(),reduced:true,large:true);
    await t.tap(find.byKey(const Key('bunny_greet')));await t.pump(const Duration(milliseconds:150));
    expect(scale(t).value,1);expect(find.textContaining('系统已要求减少动态效果'),findsOneWidget);expect(t.takeException(),isNull);
    await t.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('进入后台或下一页立即复原，不残留动画', (t) async {
    await host(t,MemoryStore());await t.tap(find.byKey(const Key('bunny_greet')));await t.pump();await t.pump(const Duration(milliseconds:150));
    expect(scale(t).value,greaterThan(1));t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);await t.pump();
    expect(scale(t).value,1);expect(scale(t).status,AnimationStatus.dismissed);t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.tap(find.byKey(const Key('bunny_greet')));await t.pump();await t.pump(const Duration(milliseconds:100));final animation=scale(t);
    await t.tap(find.text('前往下一页'));await t.pump();expect(animation.status,AnimationStatus.dismissed);await t.pumpAndSettle();
    expect(t.takeException(),isNull);await t.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('设置读取失败静态降级可重试，写失败不误报保存', (t) async {
    final store=FailedStore()..readFail=true;final c=await host(t,store);
    expect(c.read(petPreferencesProvider).motion,isFalse);await t.tap(find.byKey(const Key('bunny_greet')));await t.pumpAndSettle();expect(scale(t).value,1);
    store.readFail=false;await t.tap(find.text('重试读取动画设置'));await t.pumpAndSettle();expect(c.read(petPreferencesProvider).motion,isTrue);
    store.writeFail=true;await t.tap(find.byKey(const Key('pet_motion_switch')));await t.pumpAndSettle();
    expect(c.read(petPreferencesProvider).motion,isTrue);expect(find.text('动画设置未能保存，请重试。'),findsOneWidget);
    expect(store.settings,isEmpty);await t.pumpWidget(const SizedBox.shrink());
  });
}
