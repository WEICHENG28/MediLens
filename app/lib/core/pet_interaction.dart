import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/local_store.dart';

final petRoutes = RouteObserver<ModalRoute<dynamic>>();
const petGreetings = ['你好呀，我在这里。', '慢慢来，也很好。', '可以按自己的节奏来。'];
class PetPreference {
  final bool motion, loaded, busy;
  final String? error;
  const PetPreference({this.motion = false, this.loaded = false, this.busy = false, this.error});
}
class PetPreferences extends Notifier<PetPreference> {
  static const storageKey = 'pet_motion_enabled_v1';
  late LocalStore store;
  @override PetPreference build() {
    store = ref.watch(localStoreProvider);
    Future.microtask(load);
    return const PetPreference(busy: true);
  }
  Future<void> load() async {
    if (!ref.mounted) return;
    try {
      final motion = await store.getSetting(storageKey) != 'false';
      if (ref.mounted) state = PetPreference(motion: motion, loaded: true);
    } catch (_) {
      if (ref.mounted) state = const PetPreference(error: '小兔动画设置未能读取，暂以静态方式显示。');
    }
  }
  Future<void> setMotion(bool enabled) async {
    if (!state.loaded || state.busy) return;
    final previous = state.motion;
    state = PetPreference(motion: previous, loaded: true, busy: true);
    try {
      await store.putSetting(storageKey, enabled ? 'true' : 'false');
      if (ref.mounted) state = PetPreference(motion: enabled, loaded: true);
    } catch (_) {
      if (ref.mounted) state = PetPreference(motion: previous, loaded: true, error: '动画设置未能保存，请重试。');
    }
  }
}
final petPreferencesProvider = NotifierProvider<PetPreferences, PetPreference>(PetPreferences.new);
