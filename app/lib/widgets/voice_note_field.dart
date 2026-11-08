// 可以用说的文字框：点麦克风说话，本机离线识别（普通话）后填进文字框，用户核对后再保存。
// 声音只在手机上识别，不上传；不支持语音的设备仍可直接打字。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/voice_input.dart';

class VoiceNoteField extends ConsumerStatefulWidget {
  final TextEditingController controller;
  final String hint;
  const VoiceNoteField({super.key, required this.controller, this.hint = '写下今天的感受或身体情况'});
  @override
  ConsumerState<VoiceNoteField> createState() => _VoiceNoteFieldState();
}

class _VoiceNoteFieldState extends ConsumerState<VoiceNoteField> {
  bool listening = false;
  String? message;

  Future<void> _listen() async {
    final input = ref.read(voiceInputPlatformProvider);
    if (listening) {
      await input.stop().catchError((Object _) {});
      return;
    }
    setState(() => message = null);
    try {
      final status = await input.status();
      if (!status.available) {
        setState(() => message = '这台手机暂不支持语音输入，可以直接打字。');
        return;
      }
      if (!status.permission) {
        final ok = await input.permission();
        if (mounted) setState(() => message = ok ? '麦克风已允许，请再点一次麦克风开始说话。' : '没有麦克风权限，可以直接打字。');
        return;
      }
      setState(() => listening = true);
      final text = (await input.listen()).trim();
      if (!mounted) return;
      setState(() {
        listening = false;
        if (text.isEmpty) {
          message = '没有听清，请再说一次，或直接打字。';
        } else {
          final cur = widget.controller.text.trim();
          widget.controller.text = cur.isEmpty ? text : '$cur $text';
          message = '请看一下文字对不对，可以直接修改。';
        }
      });
    } catch (_) {
      if (mounted) setState(() { listening = false; message = '语音没有识别成功，可以再试一次或直接打字。'; });
    }
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(
          key: const Key('voice_note_text'),
          controller: widget.controller,
          minLines: 2,
          maxLines: 4,
          maxLength: 300,
          decoration: InputDecoration(
            hintText: widget.hint,
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              key: const Key('voice_note_mic'),
              tooltip: listening ? '说完了' : '用说的',
              icon: Icon(listening ? Icons.stop_circle : Icons.mic, color: listening ? Colors.red : null),
              onPressed: _listen,
            ),
          ),
        ),
        if (listening) const Text('正在听…说完后点红色按钮', style: TextStyle(color: Colors.red)),
        if (message != null) Text(message!, key: const Key('voice_note_message'), style: Theme.of(context).textTheme.bodySmall),
      ]);
}
