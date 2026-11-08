import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medilens/core/floating_pet.dart';
import 'package:medilens/widgets/floating_pet_panel.dart';

class FakeFloating extends FloatingPetPlatform {
  bool overlay=false, notification=false, running=false, fail=false, unsupported=false, pending=false;
  int reads=0, starts=0, stops=0, permissions=0;
  @override Future<FloatingPetStatus> status() async {
    reads++;
    if (unsupported) throw MissingPluginException();
    if (pending) { pending=false; running=true; }
    return FloatingPetStatus(available:true,overlayAllowed:overlay,notificationsAllowed:notification,running:running);
  }
  @override Future<FloatingPetStatus> start() async {
    starts++;if(fail) throw PlatformException(code:'private',message:'sensitive_native_error');
    pending=true;return FloatingPetStatus(available:true,overlayAllowed:true,notificationsAllowed:true,starting:true);
  }
  @override Future<FloatingPetStatus> stop() async { stops++;pending=false;running=false;return status(); }
  @override Future<void> overlaySettings() async { permissions++; }
  @override Future<void> notifications() async { permissions++; }
}
class DeferredFloating extends FakeFloating {
  Completer<FloatingPetStatus>? nextRead;
  @override Future<FloatingPetStatus> status() {
    final pending = nextRead;
    if (pending == null) return super.status();
    nextRead = null;
    return pending.future;
  }
}
void main() {
  Future<void> host(WidgetTester t,FakeFloating platform,{bool large=false}) async {
    await t.pumpWidget(ProviderScope(overrides:[floatingPetPlatformProvider.overrideWithValue(platform)],child:MaterialApp(builder:(context,child)=>
      MediaQuery(data:MediaQuery.of(context).copyWith(textScaler:TextScaler.linear(large?1.5:1)),child:child!),
      home:const Scaffold(body:SingleChildScrollView(child:Column(children:[Text('其他功能正常'),FloatingPetPanel()]))))));await t.pumpAndSettle();
  }
  Future<void> reveal(WidgetTester t,Finder f) async { await Scrollable.ensureVisible(t.element(f),alignment:.5);await t.pumpAndSettle(); }
  testWidgets('默认不启用，授权返回也不自动启动；缺任一权限时按钮禁用', (t) async {
    final p=FakeFloating();await host(t,p);
    expect(p.starts,0);expect(t.widget<FilledButton>(find.byKey(const Key('floating_start'))).onPressed,isNull);
    await reveal(t,find.text('悬浮权限设置'));await t.tap(find.text('悬浮权限设置'));await t.pumpAndSettle();expect(p.permissions,1);expect(p.starts,0);
    p.overlay=true;await reveal(t,find.text('刷新悬浮状态'));await t.tap(find.text('刷新悬浮状态'));await t.pumpAndSettle();
    expect(t.widget<FilledButton>(find.byKey(const Key('floating_start'))).onPressed,isNull);
    p.notification=true;await t.tap(find.text('刷新悬浮状态'));await t.pumpAndSettle();
    expect(t.widget<FilledButton>(find.byKey(const Key('floating_start'))).onPressed,isNotNull);expect(p.starts,0);
    await t.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('二次确认取消不启动，确认后等待真实状态，关闭可重开', (t) async {
    final p=FakeFloating()..overlay=true..notification=true;await host(t,p);
    await reveal(t,find.byKey(const Key('floating_start')));await t.tap(find.byKey(const Key('floating_start')));await t.pumpAndSettle();
    await t.tap(find.text('取消'));await t.pumpAndSettle();expect(p.starts,0);
    await t.tap(find.byKey(const Key('floating_start')));await t.pumpAndSettle();await t.tap(find.text('确认开启'));await t.pumpAndSettle();
    expect(p.starts,1);expect(find.text('悬浮珍珠鸟正在运行'),findsOneWidget);
    await reveal(t,find.byKey(const Key('floating_stop')));await t.tap(find.byKey(const Key('floating_stop')));await t.pumpAndSettle();
    expect(p.stops,1);expect(find.text('悬浮珍珠鸟未开启'),findsOneWidget);expect(t.widget<FilledButton>(find.byKey(const Key('floating_start'))).onPressed,isNotNull);
    await t.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('系统拒绝开启给出可重试提示，不显示内部错误或误报运行', (t) async {
    final p=FakeFloating()..overlay=true..notification=true..fail=true;await host(t,p);
    await reveal(t,find.byKey(const Key('floating_start')));await t.tap(find.byKey(const Key('floating_start')));await t.pumpAndSettle();
    await t.tap(find.text('确认开启'));await t.pumpAndSettle();expect(find.textContaining('未能开启悬浮珍珠鸟'),findsOneWidget);
    expect(find.textContaining('sensitive_native_error'),findsNothing);expect(find.text('悬浮珍珠鸟正在运行'),findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('不支持平台保留其他功能和关闭入口，大字无溢出', (t) async {
    await host(t,FakeFloating()..unsupported=true,large:true);expect(find.text('其他功能正常'),findsOneWidget);
    expect(find.textContaining('暂时无法读取悬浮珍珠鸟状态'),findsOneWidget);expect(find.byKey(const Key('floating_stop')),findsOneWidget);expect(t.takeException(),isNull);
    await t.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('系统停止后回到APP刷新状态，不自动重启', (t) async {
    final p=FakeFloating()..overlay=true..notification=true..running=true;await host(t,p);
    expect(find.text('悬浮珍珠鸟正在运行'),findsOneWidget);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);p.running=false;
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);await t.pumpAndSettle();
    expect(find.text('悬浮珍珠鸟未开启'),findsOneWidget);expect(p.starts,0);
    await t.pumpWidget(const SizedBox.shrink());
  });
  test('平台通道只发送固定操作名和空参数，不传医疗记录', () async {
    final calls=<MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(FloatingPetPlatform.channel,(call) async {
      calls.add(call);return call.method.startsWith('open')?null:{'available':true,'overlayAllowed':true,'notificationsAllowed':true,'running':false};
    });
    addTearDown(()=>TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(FloatingPetPlatform.channel,null));
    final p=FloatingPetPlatform();await p.status();await p.start();await p.stop();await p.overlaySettings();await p.notifications();
    expect(calls.map((c)=>c.method),['status','start','stop','openOverlaySettings','openNotifications']);expect(calls.every((c)=>c.arguments==null),isTrue);
  });
  for (final failed in [false, true]) {
    testWidgets('旧刷新${failed ? '失败' : '成功'}不能覆盖新开启结果', (t) async {
      final p = DeferredFloating()..overlay=true..notification=true;
      await host(t,p);
      final old = Completer<FloatingPetStatus>(); p.nextRead = old;
      await reveal(t,find.text('刷新悬浮状态')); await t.tap(find.text('刷新悬浮状态')); await t.pump();
      await reveal(t,find.byKey(const Key('floating_start'))); await t.tap(find.byKey(const Key('floating_start'))); await t.pumpAndSettle();
      await t.tap(find.text('确认开启')); await t.pumpAndSettle(); expect(find.text('悬浮珍珠鸟正在运行'),findsOneWidget);
      if (failed) { old.completeError(PlatformException(code:'synthetic')); }
      else { old.complete(const FloatingPetStatus(available:true,overlayAllowed:true,notificationsAllowed:true,running:false)); }
      await t.pumpAndSettle();
      expect(find.text('悬浮珍珠鸟正在运行'),findsOneWidget);
      expect(find.byKey(const Key('floating_message')),findsNothing);
      await t.pumpWidget(const SizedBox.shrink());
    });
  }

}
