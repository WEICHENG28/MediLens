import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/speech.dart';

class SpeechPage extends ConsumerStatefulWidget {
  const SpeechPage({super.key});
  @override ConsumerState<SpeechPage> createState() => _SpeechPageState();
}
class _SpeechPageState extends ConsumerState<SpeechPage> with WidgetsBindingObserver {
  late SpeechNotifier speech;
  @override void initState() {
    super.initState(); speech = ref.read(speechProvider.notifier);
    WidgetsBinding.instance.addObserver(this);
    Future.microtask(speech.refresh);
  }
  @override void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(speech.stop());
  }
  @override void dispose() {
    WidgetsBinding.instance.removeObserver(this); unawaited(Future.microtask(() => speech.stop(owner: 'preview'))); super.dispose();
  }
  @override Widget build(BuildContext context) {
    final state = ref.watch(speechProvider);
    return Scaffold(appBar: AppBar(title: const Text('中文朗读与音色')), body: ListView(padding: const EdgeInsets.all(16), children: [
      const Text('使用手机系统中已安装、声明无需联网的普通话音色。不会自动下载语音包，也不会调用云端朗读。系统引擎的实际质量和离线能力仍取决于手机。'),
      const SizedBox(height: 12),
      OutlinedButton.icon(onPressed: state.loading ? null : speech.openSettings, icon: const Icon(Icons.settings_outlined), label: const Text('打开系统语音设置')),
      const Text('在系统中选择语音引擎 → 引擎设置 → 安装语音数据 → 中文／普通话。菜单因手机而异；如无中文选项，需要支持中文离线语音的系统引擎。返回后点“重新检测”。'),
      OutlinedButton.icon(onPressed: state.loading ? null : speech.refresh, icon: const Icon(Icons.refresh), label: const Text('重新检测中文语音')),
      if (state.loading) const LinearProgressIndicator(),
      if (state.message != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(state.message!, key: const Key('speech_message'))),
      if (state.voices.isNotEmpty) ...[
        Text('检测到 ${state.voices.length} 个离线普通话音色'),
        const Text('音色名称由系统提供。未选择时使用列表第一个；更换手机或语音引擎后请重新检测。'),
        for (final voice in state.voices) ListTile(
          leading: Icon(state.selected == voice.id ? Icons.radio_button_checked : Icons.radio_button_off),
          title: Text(voice.name), subtitle: Text(voice.locale), selected: state.selected == voice.id,
          onTap: state.loading ? null : () => speech.select(voice.id)),
        FilledButton.icon(onPressed: state.loading ? null : () => speech.speak('您好，我是 MediLens。我们可以一起慢慢看懂报告，有不明白的地方也可以记下来询问医生。', 'preview'), icon: const Icon(Icons.volume_up_outlined), label: const Text('试听中文音色')),
      ],
      OutlinedButton.icon(onPressed: state.speaking || state.loading ? () => speech.stop() : null, icon: const Icon(Icons.stop_circle_outlined), label: const Text('停止朗读')),
      const SizedBox(height: 12),
      const Text('没有声音时，请检查媒体音量和系统“文字转语音”设置。部分手机需自行安装中文离线语音包；安装来源和国内可用性请以手机厂商为准。文字阅读始终可用。'),
    ]));
  }
}
