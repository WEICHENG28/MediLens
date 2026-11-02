import 'package:flutter/services.dart';

/// Only a generic companion mood crosses into the unencrypted launcher widget.
/// Report values, medication records, tokens and model responses stay in the app.
class DesktopPet {
  static const channel = MethodChannel('cn.medilens.medilens/desktop_pet');

  static Future<bool> clearGreeting() async {
    try { await channel.invokeMethod<void>('clearGreeting'); return true; }
    on MissingPluginException { return false; }
    on PlatformException { return false; }
  }

  static Future<bool> requestPin() async {
    try {
      return await channel.invokeMethod<bool>('requestPin') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<void> update({String? energyState}) async {
    final mood = switch (energyState) {
      '活泼' => 'active',
      '困倦' => 'rest',
      _ => 'calm',
    };
    try {
      await channel.invokeMethod<void>('updateMood', {'mood': mood});
    } on MissingPluginException {
      // Other platforms can keep using lifestyle records without a widget.
    } on PlatformException {
      // A launcher update must not interrupt saving a lifestyle record.
    }
  }
}
