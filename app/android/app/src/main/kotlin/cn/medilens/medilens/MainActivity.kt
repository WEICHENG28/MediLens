package cn.medilens.medilens

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.os.Build

class MainActivity : FlutterActivity() {
    private var reminders: ReminderBridge? = null
    private var voice: OfflineVoiceBridge? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        reminders = ReminderBridge(this, flutterEngine)
        voice = OfflineVoiceBridge(this, flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cn.medilens.medilens/floating_pet")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "status" -> result.success(FloatingPetService.status(this))
                        "start" -> result.success(FloatingPetService.start(this))
                        "stop" -> result.success(FloatingPetService.stop(this))
                        "openOverlaySettings" -> {
                            startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")))
                            result.success(null)
                        }
                        "openNotifications" -> {
                            startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName))
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (_: Exception) { result.error("floating_unavailable", "悬浮珍珠鸟操作未完成，请检查系统权限后重试。", null) }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cn.medilens.medilens/speech")
            .setMethodCallHandler { call, result ->
                if (call.method != "openSettings") { result.notImplemented() }
                else {
                    try {
                        startActivity(Intent("com.android.settings.TTS_SETTINGS"))
                        result.success(true)
                    } catch (_: Exception) {
                        try {
                            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                            result.success(true)
                        } catch (_: Exception) { result.success(false) }
                    }
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cn.medilens.medilens/desktop_pet")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestPin" -> {
                        val manager = AppWidgetManager.getInstance(this)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && manager.isRequestPinAppWidgetSupported) {
                            result.success(manager.requestPinAppWidget(ComponentName(this, DesktopPetWidget::class.java), null, null))
                        } else result.success(false)
                    }
                    "clearGreeting" -> {
                        DesktopPetWidget.clearGreeting(this)
                        result.success(null)
                    }
                    "updateMood" -> {
                        val mood = call.argument<String>("mood") ?: "calm"
                        DesktopPetWidget.saveMood(this, mood)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onStop() { voice?.stop(true); super.onStop() }
    override fun onDestroy() { voice?.close(); voice = null; super.onDestroy() }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        reminders?.permissionFinished(requestCode)
    }
}
