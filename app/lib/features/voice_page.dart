import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/session.dart';
import '../core/settings.dart';
import '../core/speech.dart';
import '../core/voice_input.dart';
import '../widgets/common.dart';
import 'chat_page.dart';

/// Push-to-talk: local ASR -> editable draft -> explicit send -> existing chat -> optional local TTS.
class VoicePage extends ConsumerStatefulWidget {
  final String? focus;
  final String? initialDraft;
  const VoicePage({super.key, this.focus, this.initialDraft});
  @override
  ConsumerState<VoicePage> createState() => _VoicePageState();
}

class _VoicePageState extends ConsumerState<VoicePage>
    with WidgetsBindingObserver, RouteAware {
  final draft = TextEditingController();
  late VoiceInputPlatform input;
  late SpeechNotifier speech;
  bool recording = false,
      sending = false,
      preparing = false,
      autoSpeak = true,
      foreground = true;
  int operation = 0;
  String? message;
  @override
  void initState() {
    super.initState();
    draft.text = widget.initialDraft ?? '';
    input = ref.read(voiceInputPlatformProvider);
    speech = ref.read(speechProvider.notifier);
    foreground =
        (WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed) ==
        AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) speechRoutes.subscribe(this, route);
  }

  Future<void> interrupt() async {
    ++operation;
    if (mounted) setState(() => recording = false);
    try {
      await input.cancel();
    } catch (_) {}
    await speech.stop(owner: 'voice_reply');
  }

  @override
  void didPushNext() {
    unawaited(interrupt());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) unawaited(interrupt());
  }

  @override
  void dispose() {
    ++operation;
    WidgetsBinding.instance.removeObserver(this);
    speechRoutes.unsubscribe(this);
    unawaited(input.cancel().catchError((_) {}));
    unawaited(Future.microtask(() => speech.stop(owner: 'voice_reply')));
    draft.dispose();
    super.dispose();
  }

  Future<void> start() async {
    if (recording || sending || preparing) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      preparing = true;
      message = null;
    });
    final ticket = ++operation;
    await speech.stop();
    try {
      final status = await input.status();
      if (!mounted ||
          ticket != operation ||
          !foreground ||
          ModalRoute.of(context)?.isCurrent == false) {
        return;
      }
      if (!status.available) {
        setState(() => message = '当前设备暂不支持本机语音识别，可以继续输入文字。');
        return;
      }
      if (!status.permission) {
        final allowed = await input.permission();
        if (mounted) {
          setState(
            () => message = allowed
                ? '麦克风已允许，请再次点击“开始说话”。'
                : '请在系统弹窗中选择权限，返回后再次点击“开始说话”。未允许麦克风时仍可输入文字；未弹出确认框可到系统设置中开启。',
          );
        }
        return;
      }
      setState(() => recording = true);
      final text = await input.listen();
      if (!mounted ||
          ticket != operation ||
          !foreground ||
          ModalRoute.of(context)?.isCurrent == false) {
        return;
      }
      setState(() {
        recording = false;
        if (text.trim().isEmpty) {
          message = '没有听清，请重新说一遍，或直接输入文字。';
        } else {
          draft.text = text.trim();
          message = '请核对药名、数字和问题内容，修改无误后再发送。';
        }
      });
    } catch (_) {
      if (mounted && ticket == operation && foreground) {
        setState(() {
          recording = false;
          message = '本机语音识别未完成，可重试或改用文字。原来的文字仍保留。';
        });
      }
      try {
        await input.cancel();
      } catch (_) {}
    } finally {
      if (mounted) setState(() => preparing = false);
    }
  }

  Future<void> stopRecording() async {
    try {
      await input.stop();
    } catch (_) {
      if (mounted) setState(() => message = '未确认录音结束，请取消后重试。');
    }
  }

  Future<void> send() async {
    final text = draft.text.trim();
    if (sending || recording || preparing || text.isEmpty) return;
    if (text.length > 500) {
      setState(() => message = '问题请控制在500字以内，再确认发送。');
      return;
    }
    if (!ref.read(settingsProvider).aiConsent) {
      setState(() => message = '发送问题前，请先在设置中允许发送确认后的指标用于解读。');
      return;
    }
    final session = ref.read(sessionProvider);
    if (session.analysis == null || session.report == null) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final ticket = ++operation, id = session.id;
    setState(() {
      sending = true;
      message = null;
    });
    await speech.stop();
    try {
      final ok = await ref
          .read(sessionProvider.notifier)
          .sendChat(text, focus: widget.focus);
      if (!mounted || ticket != operation) return;
      if (ok) {
        draft.clear();
      } else {
        setState(() => message = '这次回答未完成，问题已保留，可重试或切换文字查看提示。');
      }
      final current = ref.read(sessionProvider);
      if (ok &&
          current.id == id &&
          autoSpeak &&
          foreground &&
          ModalRoute.of(context)?.isCurrent != false) {
        await speech.speak(current.messages.last.content, 'voice_reply');
      }
    } catch (_) {
      if (mounted) setState(() => message = '这次提问未完成，请稍后重试；文字仍保留。');
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(sessionProvider.select((s) => s.id), (before, after) {
      if (before != after) {
        draft.clear();
        unawaited(Future.microtask(interrupt));
      }
    });
    final session = ref.watch(sessionProvider),
        spoken = ref.watch(speechProvider);
    final ready = session.analysis != null && session.report != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('语音对话'),
        actions: [
          IconButton(
            tooltip: '离线语音许可',
            icon: const Icon(Icons.info_outline),
            onPressed: () =>
                showLicensePage(context: context, applicationName: 'MediLens'),
          ),
          IconButton(
            tooltip: '切换文字对话',
            icon: const Icon(Icons.keyboard_outlined),
            onPressed: !ready
                ? null
                : () => context.pushReplacement(
                    widget.focus == null
                        ? '/chat'
                        : Uri(
                            path: '/chat',
                            queryParameters: {'focus': widget.focus!},
                          ).toString(),
                  ),
          ),
        ],
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              '普通话离线识别，音频不上传、不保存。文字需核对后主动发送到现有解读服务；回答和来源同时显示。最长每次30秒，药名和数字可能识别有误。',
            ),
          ),
          if (ready)
            TextButton.icon(
              key: const Key('open_realtime'),
              icon: const Icon(Icons.record_voice_over),
              label: const Text('进入实时对话'),
              onPressed: () => context.pushReplacement(
                widget.focus == null
                    ? '/realtime-voice'
                    : Uri(
                        path: '/realtime-voice',
                        queryParameters: {'focus': widget.focus!},
                      ).toString(),
                extra: draft.text,
              ),
            ),
          if (!ready)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('请先导入报告并完成解读，再就报告进行语音提问。'),
                    TextButton(
                      onPressed: () => context.go('/home'),
                      child: const Text('去导入报告'),
                    ),
                  ],
                ),
              ),
            )
          else
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  const TestRuleBanner(),
                  for (final m in session.messages) ChatBubble(m),
                  if (sending) const LinearProgressIndicator(),
                ],
              ),
            ),
          if (message != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(message!, key: const Key('voice_message')),
            ),
          if (spoken.owner == 'voice_reply' && spoken.message != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(spoken.message!),
            ),
          if (ready)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    if (recording)
                      const Text(
                        '正在准备或聆听…说完请点“结束并识别”。',
                        key: Key('voice_listening'),
                      ),
                    Wrap(
                      spacing: 8,
                      children: [
                        FilledButton.icon(
                          key: const Key('voice_start'),
                          onPressed: recording || sending || preparing
                              ? null
                              : start,
                          icon: const Icon(Icons.mic),
                          label: const Text('开始说话'),
                        ),
                        if (recording)
                          OutlinedButton(
                            key: const Key('voice_stop'),
                            onPressed: stopRecording,
                            child: const Text('结束并识别'),
                          ),
                        if (recording)
                          TextButton(
                            key: const Key('voice_cancel'),
                            onPressed: interrupt,
                            child: const Text('取消这次录音'),
                          ),
                        if (spoken.speaking || spoken.loading)
                          OutlinedButton(
                            key: const Key('voice_stop_reply'),
                            onPressed: () => speech.stop(),
                            child: const Text('停止朗读'),
                          ),
                      ],
                    ),
                    TextField(
                      key: const Key('voice_draft'),
                      controller: draft,
                      maxLength: 500,
                      minLines: 1,
                      maxLines: 3,
                      enabled: !recording && !sending && !preparing,
                      decoration: const InputDecoration(
                        labelText: '核对或输入问题',
                        hintText: '确认文字后再发送',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('回答后朗读'),
                            value: autoSpeak,
                            onChanged: (v) {
                              setState(() => autoSpeak = v);
                              if (!v) {
                                unawaited(speech.stop(owner: 'voice_reply'));
                              }
                            },
                          ),
                        ),
                        FilledButton(
                          key: const Key('voice_send'),
                          onPressed: recording || sending || preparing
                              ? null
                              : send,
                          child: const Text('确认文字并发送'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
