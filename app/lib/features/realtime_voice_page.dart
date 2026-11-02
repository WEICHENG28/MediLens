import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/realtime_voice.dart';
import '../core/session.dart';
import '../core/settings.dart';
import '../core/speech.dart';
import '../core/voice_input.dart';
import '../widgets/common.dart';
import 'chat_page.dart';

class _PageOutput implements RealtimeVoiceOutput {
  final Future<void> Function(String) onPlay;
  final Future<void> Function() onStop;
  _PageOutput(this.onPlay, this.onStop);
  @override
  Future<void> play(String text) => onPlay(text);
  @override
  Future<void> stop() => onStop();
}

class RealtimeVoicePage extends ConsumerStatefulWidget {
  final String? focus;
  final String? initialDraft;
  const RealtimeVoicePage({super.key, this.focus, this.initialDraft});
  @override
  ConsumerState<RealtimeVoicePage> createState() => _RealtimeVoicePageState();
}

class _RealtimeVoicePageState extends ConsumerState<RealtimeVoicePage>
    with WidgetsBindingObserver, RouteAware {
  late RealtimeVoiceController conversation;
  late SpeechNotifier speech;
  late VoiceInputPlatform input;
  late final owner = 'realtime_${identityHashCode(this)}';
  final editor = TextEditingController(), scroll = ScrollController();
  String previousDraft = '', hint = '';
  bool starting = false, foreground = true;
  @override
  void initState() {
    super.initState();
    speech = ref.read(speechProvider.notifier);
    input = ref.read(voiceInputPlatformProvider);
    foreground =
        (WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed) ==
        AppLifecycleState.resumed;
    conversation = RealtimeVoiceController(
      input: input,
      output: _PageOutput(play, () => speech.stop(owner: owner)),
      canSend: () =>
          mounted &&
          foreground &&
          ref.read(settingsProvider).aiConsent &&
          ref.read(sessionProvider).analysis != null &&
          ref.read(sessionProvider).report != null,
      ask: (text, accept) async {
        final ok = await ref
            .read(sessionProvider.notifier)
            .sendChat(text, focus: widget.focus, accept: accept);
        if (!mounted || !ok || !accept()) return null;
        return ref.read(sessionProvider).messages.last.content;
      },
    )..addListener(changed);
    conversation.draft = widget.initialDraft ?? '';
    previousDraft = conversation.draft;
    editor.text = previousDraft;
    WidgetsBinding.instance.addObserver(this);
  }

  void changed() {
    if (!mounted) return;
    if (previousDraft != conversation.draft) {
      previousDraft = conversation.draft;
      editor.text = previousDraft;
    }
    final follow =
        !scroll.hasClients ||
        scroll.offset >= scroll.position.maxScrollExtent - 140;
    setState(() {});
    if (follow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && scroll.hasClients) {
          scroll.jumpTo(scroll.position.maxScrollExtent);
        }
      });
    }
  }

  Future<void> play(String text) async {
    if (!mounted) throw StateError('page_left');
    final c = ProviderScope.containerOf(context, listen: false),
        done = Completer<String?>();
    var began = false;
    final sub = c.listen(speechProvider, (_, next) {
      if (next.owner == owner && (next.loading || next.speaking)) began = true;
      if (began && !next.loading && !next.speaking && !done.isCompleted) {
        done.complete(next.message);
      }
    });
    try {
      await speech.speak(text, owner);
      final state = c.read(speechProvider);
      if (state.message != null && !done.isCompleted) {
        done.complete(state.message);
      }
      if (!state.loading && !state.speaking && !done.isCompleted) {
        done.complete(null);
      }
      final failure = await done.future.timeout(
        const Duration(seconds: 90),
        onTimeout: () => '朗读等待超时',
      );
      if (failure != null) throw StateError('speech_unavailable');
    } finally {
      sub.close();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) speechRoutes.subscribe(this, route);
  }

  @override
  void didPushNext() {
    unawaited(conversation.stop('页面已切换，实时对话已停止。'));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) unawaited(conversation.stop('已离开前台，实时对话已停止；返回不会自动录音。'));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    speechRoutes.unsubscribe(this);
    conversation.removeListener(changed);
    conversation.dispose();
    editor.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> begin() async {
    if (starting || conversation.active) return;
    setState(() {
      starting = true;
      hint = '';
    });
    try {
      final status = await input.status();
      if (!mounted || !foreground) return;
      if (!status.available) {
        setState(() => hint = '本机识别暂不可用，可改用按键模式。');
        return;
      }
      if (!status.permission) {
        await input.permission();
        if (mounted) setState(() => hint = '请在系统中选择麦克风权限，返回后再次点开启。不会自动开始录音。');
        return;
      }
      final yes = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('开启连续实时对话？'),
          content: const SingleChildScrollView(
            child: Text(
              '开启后，普通问题停顿结束约1秒后会自动发送识别文字到现有解读服务。请留意屏幕上的识别结果，可点“修改本句”暂停。\n\n检测到部分药名、数值或阴阳性时会先停下核对；识别仍可能出错。音频不上传、不保存。回答后会继续聆听下一句，长时间无声会暂停。\n\n播报时麦克风关闭，点“打断并说话”可中止回答。离开页面或退后台即停止，返回不会自动开启。',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('realtime_consent'),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('同意并开启'),
            ),
          ],
        ),
      );
      if (yes == true &&
          mounted &&
          foreground &&
          ModalRoute.of(context)?.isCurrent != false) {
        unawaited(conversation.start(initialDraft: editor.text));
      }
    } catch (_) {
      if (mounted) setState(() => hint = '暂未开启，请检查本机语音或改用按键模式。');
    } finally {
      if (mounted) setState(() => starting = false);
    }
  }

  void fallback() {
    final value = editor.text.trim();
    unawaited(conversation.stop());
    context.pushReplacement(
      widget.focus == null
          ? '/voice'
          : Uri(
              path: '/voice',
              queryParameters: {'focus': widget.focus!},
            ).toString(),
      extra: value,
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(sessionProvider.select((s) => s.id), (old, next) {
      if (old != next) {
        unawaited(
          conversation.stopWithOptions('报告已切换，实时对话已停止。', clearDraft: true),
        );
      }
    });
    ref.listen(settingsProvider.select((s) => s.aiConsent), (old, next) {
      if (!next) unawaited(conversation.stop('指标云端授权已关闭，实时对话已停止。'));
    });
    final session = ref.watch(sessionProvider), phase = conversation.phase;
    final ready = session.analysis != null && session.report != null;
    final label = switch (phase) {
      RealtimePhase.off => '尚未开启',
      RealtimePhase.listening => '正在聆听，停顿后自动处理',
      RealtimePhase.pending => '即将发送',
      RealtimePhase.review => '请核对这句话',
      RealtimePhase.thinking => '正在等待回答',
      RealtimePhase.speaking => '正在播报，麦克风已关闭',
      RealtimePhase.paused => '已暂停',
    };
    return Scaffold(
      appBar: AppBar(title: const Text('实时语音对话')),
      body: CustomScrollView(
        controller: scroll,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverList.list(
              children: [
                const Text(
                  '轮流说话：停顿后提问，回答播完继续聆听。播报时麦克风关闭，可点击打断；说“结束对话”也可停止。音频只在本机处理。',
                ),
                const SizedBox(height: 12),
                const TestRuleBanner(),
                for (final m in session.messages)
                  ChatBubble(m, allowSpeech: !conversation.active),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          label,
                          key: const Key('realtime_status'),
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        if (conversation.partial.isNotEmpty)
                          Text(
                            conversation.partial,
                            key: const Key('realtime_partial'),
                          ),
                        if (conversation.message.isNotEmpty)
                          Text(
                            conversation.message,
                            key: const Key('realtime_message'),
                          ),
                        if (hint.isNotEmpty) Text(hint),
                        if (!ready) const Text('请先导入报告并完成解读，再开启实时对话。'),
                        if (phase == RealtimePhase.pending)
                          Text('本句：${conversation.draft}'),
                        if (phase == RealtimePhase.review ||
                            (!conversation.active &&
                                conversation.draft.isNotEmpty))
                          TextField(
                            key: const Key('realtime_editor'),
                            controller: editor,
                            maxLength: 500,
                            minLines: 1,
                            maxLines: 4,
                            decoration: const InputDecoration(
                              labelText: '核对或修改本句',
                            ),
                          ),
                        if (phase == RealtimePhase.review)
                          FilledButton(
                            key: const Key('realtime_confirm'),
                            onPressed: () => conversation.confirm(editor.text),
                            child: const Text('确认发送并继续'),
                          ),
                        if (!conversation.active)
                          FilledButton(
                            key: const Key('realtime_start'),
                            onPressed: !ready || starting ? null : begin,
                            child: const Text('开启实时对话'),
                          ),
                        if (phase == RealtimePhase.pending ||
                            phase == RealtimePhase.listening)
                          OutlinedButton(
                            key: const Key('realtime_review'),
                            onPressed: conversation.review,
                            child: const Text('修改本句'),
                          ),
                        if (phase == RealtimePhase.speaking ||
                            phase == RealtimePhase.thinking)
                          FilledButton(
                            key: const Key('realtime_interrupt'),
                            onPressed: conversation.interruptAndListen,
                            child: const Text('打断并说话'),
                          ),
                        if (conversation.active)
                          OutlinedButton(
                            key: const Key('realtime_stop'),
                            onPressed: () => conversation.stop(),
                            child: const Text('停止实时对话'),
                          ),
                        TextButton(
                          key: const Key('realtime_fallback'),
                          onPressed: fallback,
                          child: const Text('改用按键模式'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
