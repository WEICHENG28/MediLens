// 设置中心的数据（统一管理常规偏好）。持久化在本地加密数据库中。

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local_store.dart';
import 'theme.dart';

class AppSettings {
  final DisplayMode displayMode;
  final String ocrMode; // local（游客只能 local）/ cloud（待实现，仅注册用户）
  final double speechRate; // 朗读语速 0.3~0.7
  final bool autoRead; // 自动朗读解释
  final String apiBaseUrl; // 后端地址（开发期可改；正式版固定为国内服务器）
  final bool onboarded; // 是否看过启动说明
  final bool aiConsent; // 同意将脱敏结构化指标发送到云端解读服务（首次使用前单独告知）
  final String apiToken; // 访问口令（部署在共享网络的服务器要求；本机开发留空）
  final bool connectionCustom; // 用户是否在设置中手动改过地址/口令；未改过则一律使用本版 APK 的预设

  const AppSettings({
    this.displayMode = DisplayMode.normal,
    this.ocrMode = 'local',
    this.speechRate = 0.5,
    this.autoRead = false,
    this.apiBaseUrl = defaultApiBaseUrl,
    this.onboarded = false,
    this.aiConsent = false,
    this.apiToken = defaultApiToken,
    this.connectionCustom = false,
  });

  /// Android 模拟器访问开发机本地后端的地址。可在编译时用 --dart-define=API_BASE_URL=... 覆盖。
  static const defaultApiBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: 'http://10.0.2.2:8000');

  static const defaultApiToken = String.fromEnvironment('API_TOKEN');

  bool get elder => displayMode == DisplayMode.elder;

  AppSettings copyWith({DisplayMode? displayMode, String? ocrMode, double? speechRate, bool? autoRead, String? apiBaseUrl, bool? onboarded, bool? aiConsent, String? apiToken, bool? connectionCustom}) =>
      AppSettings(
        displayMode: displayMode ?? this.displayMode,
        ocrMode: ocrMode ?? this.ocrMode,
        speechRate: speechRate ?? this.speechRate,
        autoRead: autoRead ?? this.autoRead,
        apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
        onboarded: onboarded ?? this.onboarded,
        aiConsent: aiConsent ?? this.aiConsent,
        apiToken: apiToken ?? this.apiToken,
        connectionCustom: connectionCustom ?? this.connectionCustom,
      );

  Map<String, dynamic> toJson() => {
        'displayMode': displayMode.name,
        'ocrMode': ocrMode,
        'speechRate': speechRate,
        'autoRead': autoRead,
        'apiBaseUrl': apiBaseUrl,
        'onboarded': onboarded,
        'aiConsent': aiConsent,
        'apiToken': apiToken,
        'connectionCustom': connectionCustom,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        displayMode: DisplayMode.values.firstWhere((m) => m.name == j['displayMode'], orElse: () => DisplayMode.normal),
        ocrMode: 'local', // 本轮无注册用户，强制本地
        speechRate: (j['speechRate'] as num?)?.toDouble() ?? 0.5,
        autoRead: j['autoRead'] as bool? ?? false,
        // 旧版会把当时的默认地址一并存下；只有用户手动改过才沿用，否则跟随新版 APK 的预设
        apiBaseUrl: j['connectionCustom'] == true ? (j['apiBaseUrl'] as String? ?? defaultApiBaseUrl) : defaultApiBaseUrl,
        onboarded: j['onboarded'] as bool? ?? false,
        aiConsent: j['aiConsent'] as bool? ?? false,
        apiToken: j['connectionCustom'] == true ? (j['apiToken'] as String? ?? defaultApiToken) : defaultApiToken,
        connectionCustom: j['connectionCustom'] as bool? ?? false,
      );
}

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() => const AppSettings();

  Future<void> load() async {
    final raw = await ref.read(localStoreProvider).getSetting('app_settings');
    if (raw != null) state = AppSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> update(AppSettings s) async {
    state = s;
    await ref.read(localStoreProvider).putSetting('app_settings', jsonEncode(s.toJson()));
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);
