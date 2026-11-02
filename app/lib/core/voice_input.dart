import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class VoiceInputStatus {
  final bool available, permission, ready, busy;
  const VoiceInputStatus({
    this.available = false,
    this.permission = false,
    this.ready = false,
    this.busy = false,
  });
}

class VoiceInputPlatform {
  static const channel = MethodChannel('cn.medilens.medilens/offline_voice');
  Future<VoiceInputStatus> status() async {
    final data =
        await channel
            .invokeMapMethod<String, dynamic>('status')
            .timeout(const Duration(seconds: 3)) ??
        {};
    return VoiceInputStatus(
      available: data['available'] == true,
      permission: data['permission'] == true,
      ready: data['ready'] == true,
      busy: data['busy'] == true,
    );
  }

  Future<bool> permission() async =>
      await channel
          .invokeMethod<bool>('permission')
          .timeout(const Duration(seconds: 60)) ??
      false;
  Future<String> listen() async =>
      await channel
          .invokeMethod<String>('listen')
          .timeout(const Duration(seconds: 75)) ??
      '';
  Future<String> listenRealtime() async =>
      await channel
          .invokeMethod<String>('listenRealtime')
          .timeout(const Duration(seconds: 75)) ??
      '';
  Stream<String> get partials =>
      const EventChannel('cn.medilens.medilens/voice_events')
          .receiveBroadcastStream()
          .where((event) => event is String)
          .cast<String>();
  Future<String> recognizeEndpointPcm(Uint8List pcm) async =>
      await channel
          .invokeMethod<String>('recognizePcm', {'pcm': pcm, 'endpoint': true})
          .timeout(const Duration(seconds: 60)) ??
      '';
  Future<void> stop() =>
      channel.invokeMethod<void>('stop').timeout(const Duration(seconds: 3));
  Future<void> cancel() =>
      channel.invokeMethod<void>('cancel').timeout(const Duration(seconds: 3));
  Future<String> recognizePcm(Uint8List pcm) async =>
      await channel
          .invokeMethod<String>('recognizePcm', {'pcm': pcm})
          .timeout(const Duration(seconds: 60)) ??
      '';
}

final voiceInputPlatformProvider = Provider<VoiceInputPlatform>(
  (ref) => VoiceInputPlatform(),
);
