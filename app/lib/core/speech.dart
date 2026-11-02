import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import 'package:flutter_tts/flutter_tts.dart';
import '../data/local_store.dart';
import 'settings.dart';

final speechRoutes = RouteObserver<ModalRoute<dynamic>>();

class SpeechVoice {
  final String name, locale;
  const SpeechVoice(this.name, this.locale);
  String get id => jsonEncode([name, locale]);
  Map<String, String> get map => {'name': name, 'locale': locale};
  static List<SpeechVoice> offlineChinese(dynamic raw) {
    if (raw is! List) return [];
    final voices = <String, SpeechVoice>{};
    for (final item in raw.whereType<Map>()) {
      final name = item['name'], locale = item['locale'];
      if (name is! String || name.isEmpty || locale is! String) continue;
      final tag = locale.replaceAll('_', '-').toLowerCase();
      // Mandarin only; never silently select an online voice or missing voice data.
      if (!(tag == 'zh' || tag == 'zh-cn' || tag == 'cmn-cn' || tag.startsWith('zh-hans')) ||
          !{'0', 'false'}.contains(item['network_required'].toString()) ||
          (item['features']?.toString() ?? '').contains('notInstalled')) { continue; }
      final voice = SpeechVoice(name, locale); voices[voice.id] = voice;
    }
    return voices.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  }
}

abstract class SpeechPlatform {
  Future<dynamic> voices();
  Future<dynamic> useVoice(SpeechVoice voice);
  Future<dynamic> rate(double rate);
  Future<dynamic> speak(String text);
  Future<dynamic> stop();
  Future<bool> openSettings();
  void handlers(void Function() completed, void Function() cancelled, void Function() failed);
}
class SystemSpeech implements SpeechPlatform {
  final FlutterTts tts = FlutterTts();
  @override Future<dynamic> voices() => tts.getVoices;
  @override Future<dynamic> useVoice(SpeechVoice voice) => tts.setVoice(voice.map);
  @override Future<dynamic> rate(double rate) => tts.setSpeechRate(rate);
  @override Future<dynamic> speak(String text) => tts.speak(text);
  @override Future<dynamic> stop() => tts.stop();
  @override Future<bool> openSettings() async => await const MethodChannel('cn.medilens.medilens/speech').invokeMethod<bool>('openSettings') ?? false;
  @override void handlers(void Function() completed, void Function() cancelled, void Function() failed) {
    tts.setCompletionHandler(completed); tts.setCancelHandler(cancelled); tts.setErrorHandler((_) => failed());
  }
}
final speechPlatformProvider = Provider<SpeechPlatform>((ref) => SystemSpeech());

class SpeechState {
  final List<SpeechVoice> voices;
  final String? selected, owner, message;
  final bool loading, speaking;
  const SpeechState({this.voices = const [], this.selected, this.owner, this.message, this.loading = false, this.speaking = false});
}
class SpeechNotifier extends Notifier<SpeechState> {
  static const storageKey = 'speech_voice_v1';
  late SpeechPlatform platform;
  bool disposed = false, listening = false;
  int generation = 0;
  Future<void> queue = Future.value();
  @override SpeechState build() {
    platform = ref.read(speechPlatformProvider);
    void complete() { if (!disposed && listening) { listening = false; state = SpeechState(voices: state.voices, selected: state.selected); } }
    platform.handlers(complete, complete, () { if (!disposed && listening) { listening = false; state = SpeechState(voices: state.voices, selected: state.selected, owner: state.owner, message: '朗读失败，请检查系统中文语音和媒体音量后重试。'); } });
    ref.onDispose(() { disposed = true; listening = false; unawaited(platform.stop().catchError((_) => null)); });
    return const SpeechState();
  }
  Future<T> bounded<T>(Future<T> call) => call.timeout(const Duration(seconds: 10));
  Future<void> serial(Future<void> Function() action) {
    final result = queue.then((_) => action());
    queue = result.catchError((_) {}); return result;
  }
  Future<void> openSettings() async {
    await stop();
    try { if (await platform.openSettings()) return; } catch (_) {}
    if (!disposed) state = SpeechState(voices: state.voices, selected: state.selected, message: '无法直接打开系统语音设置，请在手机设置中搜索“文字转语音”，检查中文语音数据。');
  }
  Future<void> refresh() {
    final ticket = ++generation;
    return serial(() async {
      if (disposed || ticket != generation) return;
      listening = false;
      state = SpeechState(voices: state.voices, selected: state.selected, loading: true);
      try {
        await bounded(platform.stop());
        final voices = SpeechVoice.offlineChinese(await bounded(platform.voices()));
        final saved = await ref.read(localStoreProvider).getSetting(storageKey);
        if (disposed || ticket != generation) return;
        state = SpeechState(voices: voices, selected: voices.any((v) => v.id == saved) ? saved : null,
          message: voices.isEmpty ? '未检测到已安装的离线普通话音色。请到手机系统“文字转语音”设置检查中文语音包，再返回重新检测。APP 不会自动下载或切换联网语音。' : saved != null && !voices.any((v) => v.id == saved) ? '原音色已不可用，请先从下方重新选择音色再试听。' : null);
      } catch (_) {
        if (!disposed && ticket == generation) state = const SpeechState(message: '无法检测系统语音，请检查手机的文字转语音设置后重试。');
      }
    });
  }
  Future<void> select(String id) {
    final stopped = stop();
    final ticket = generation;
    return stopped.then((_) => serial(() async {
      if (disposed || ticket != generation || !state.voices.any((v) => v.id == id)) return;
      try {
        await ref.read(localStoreProvider).putSetting(storageKey, id);
        if (!disposed && ticket == generation) state = SpeechState(voices: state.voices, selected: id);
      } catch (_) {
        if (!disposed && ticket == generation) state = SpeechState(voices: state.voices, selected: state.selected, message: '音色选择未能保存，请重试。');
      }
    }));
  }
  Future<void> speak(String text, String owner) {
    final ticket = ++generation;
    return serial(() async {
      if (disposed || ticket != generation) return;
      listening = false;
      state = SpeechState(voices: state.voices, selected: state.selected, owner: owner, loading: true);
      try {
        await bounded(platform.stop());
        final voices = SpeechVoice.offlineChinese(await bounded(platform.voices()));
        final saved = await ref.read(localStoreProvider).getSetting(storageKey);
        if (disposed || ticket != generation) return;
        if (voices.isEmpty) throw StateError('no_voice');
        // A removed user selection requires a new explicit selection before private text is spoken.
        if (saved != null && !voices.any((v) => v.id == saved)) throw StateError('removed_voice');
        final voice = voices.firstWhere((v) => v.id == saved, orElse: () => voices.first);
        if (await bounded(platform.useVoice(voice)) != 1) throw StateError('set_voice');
        await bounded(platform.rate(ref.read(settingsProvider).speechRate));
        if (disposed || ticket != generation) return;
        listening = true;
        state = SpeechState(voices: voices, selected: saved, owner: owner, speaking: true);
        if (await bounded(platform.speak(text)) != 1) throw StateError('speak');
      } catch (_) {
        if (!disposed && ticket == generation) {
          listening = false;
          try { await bounded(platform.stop()); } catch (_) {}
          if (disposed || ticket != generation) return;
          state = SpeechState(voices: state.voices, selected: state.selected, owner: owner,
            message: '无法朗读：请在设置 → 中文朗读与音色中重新检测并选择已安装的离线普通话音色。');
        }
      }
    });
  }
  Future<void> stop({String? owner}) {
    if (disposed) return Future.value();
    if (owner != null && state.owner != owner) return Future.value();
    ++generation; listening = false;
    if (!disposed) state = SpeechState(voices: state.voices, selected: state.selected);
    return serial(() async {
      try { await bounded(platform.stop()); } catch (_) {
        if (!disposed) state = SpeechState(voices: state.voices, selected: state.selected, message: '系统未确认停止，请检查系统语音状态。');
      }
    });
  }
}
final speechProvider = NotifierProvider<SpeechNotifier, SpeechState>(SpeechNotifier.new);


/// Read urgent action first, then the same interpretation shown on screen.
String overviewSpeechText(Map<String, dynamic> analysis) {
  final urgent = analysis['urgent_alert'] as Map;
  final overall = analysis['overall'] as Map;
  return [
    if (urgent['show'] == true) urgent['message'],
    '以下是报告解读摘要，不能代替医生诊断。',
    overall['label'], overall['explanation'],
    ...(analysis['hits'] as List).map((h) => h['summary']),
  ].whereType<String>().where((s) => s.trim().isNotEmpty).join('。');
}
