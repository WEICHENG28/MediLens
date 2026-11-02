package cn.medilens.medilens

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class ReminderBridge(private val activity: FlutterActivity, engine: FlutterEngine) {
    private val scheduler = LocalReminderScheduler(activity)
    private val checkups = CheckupScheduler(activity)
    private var permissionResult: MethodChannel.Result? = null

    init {
        MethodChannel(engine.dartExecutor.binaryMessenger, "cn.medilens.medilens/local_reminders").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "status" -> result.success(scheduler.status())
                    "checkupStatus" -> result.success(checkups.status())
                    "saveCheckup" -> result.success(checkups.upsert(call.argument<String>("id") ?: error("缺少 ID"), (call.argument<Number>("at") ?: error("缺少时间")).toLong()))
                    "cancelCheckup" -> result.success(checkups.cancel(call.argument<String>("id") ?: error("缺少 ID")))
                    "clearCheckups" -> result.success(checkups.clear())
                    "replaceDaily" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        val plans = call.argument<List<Map<*, *>>>("plans") ?: emptyList()
                        result.success(scheduler.replace(enabled, plans))
                    }
                    "requestNotifications" -> {
                        if (Build.VERSION.SDK_INT >= 33 && !scheduler.allowed()) {
                            if (permissionResult != null) result.error("busy", "正在等待通知授权", null)
                            else {
                                permissionResult = result
                                activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST)
                            }
                        } else result.success(scheduler.status())
                    }
                    "openNotificationSettings" -> {
                        activity.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName))
                        result.success(null)
                    }
                    "openExactSettings" -> {
                        if (Build.VERSION.SDK_INT >= 31) activity.startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:${activity.packageName}")))
                        result.success(null)
                    }
                    "test" -> { scheduler.test(); result.success(null) }
                    "acknowledge" -> {
                        scheduler.acknowledge(call.argument<String>("id") ?: error("缺少 ID"))
                        result.success(null)
                    }
                    "undoAcknowledge" -> { scheduler.undoAcknowledge(call.argument<String>("id") ?: error("缺少 ID")); result.success(null) }
                    "snooze" -> result.success(scheduler.snooze(call.argument<String>("id") ?: error("缺少 ID"),
                        call.argument<Int>("minutes") ?: error("缺少分钟数"), call.argument<String>("day") ?: error("缺少日期")))
                    "cancelSnooze" -> result.success(scheduler.cancelSnooze(call.argument<String>("id") ?: error("缺少 ID")))
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                result.error("reminder_error", "本机提醒操作未完成，请检查系统权限后重试", null)
            }
        }
    }

    fun permissionFinished(requestCode: Int) {
        if (requestCode == REQUEST) {
            permissionResult?.success(scheduler.status())
            permissionResult = null
        }
    }

    companion object { private const val REQUEST = 7211 }
}
