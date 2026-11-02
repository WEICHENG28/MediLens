import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class FloatingPetStatus {
  final bool available, overlayAllowed, notificationsAllowed, running, starting;
  final String? error;
  const FloatingPetStatus({this.available = false, this.overlayAllowed = false, this.notificationsAllowed = false, this.running = false, this.starting = false, this.error});
  factory FloatingPetStatus.parse(Map data) => FloatingPetStatus(available: data['available'] == true,
    overlayAllowed: data['overlayAllowed'] == true, notificationsAllowed: data['notificationsAllowed'] == true,
    running: data['running'] == true, starting: data['starting'] == true, error: data['error'] is String ? data['error'] : null);
}
class FloatingPetPlatform {
  static const channel = MethodChannel('cn.medilens.medilens/floating_pet');
  Future<FloatingPetStatus> call(String method) async => FloatingPetStatus.parse(await channel.invokeMapMethod<String,dynamic>(method).timeout(const Duration(seconds: 3)) ?? {});
  Future<FloatingPetStatus> status() => call('status');
  Future<FloatingPetStatus> start() => call('start');
  Future<FloatingPetStatus> stop() => call('stop');
  Future<void> overlaySettings() => channel.invokeMethod<void>('openOverlaySettings').timeout(const Duration(seconds: 3));
  Future<void> notifications() => channel.invokeMethod<void>('openNotifications').timeout(const Duration(seconds: 3));
}
final floatingPetPlatformProvider = Provider<FloatingPetPlatform>((ref) => FloatingPetPlatform());
