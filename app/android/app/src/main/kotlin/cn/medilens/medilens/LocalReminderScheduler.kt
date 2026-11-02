package cn.medilens.medilens

import android.Manifest
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar
import java.text.SimpleDateFormat
import java.util.Locale

/** Native storage contains opaque IDs and clock times only, never medication names. */
class LocalReminderScheduler(private val context: Context) {
    private val prefs = context.getSharedPreferences("local_reminder_clock", Context.MODE_PRIVATE)
    private val alarms = context.getSystemService(AlarmManager::class.java)
    private val notifications = context.getSystemService(NotificationManager::class.java)

    data class Plan(val id: String, val hour: Int, val minute: Int)

    private fun channel() {
        if (Build.VERSION.SDK_INT >= 26) {
            val channel = NotificationChannel(CHANNEL, "本机任务提醒", NotificationManager.IMPORTANCE_DEFAULT)
            channel.description = "按您确认的时间发送通用提醒，详细任务仅在应用内显示"
            channel.lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            notifications.createNotificationChannel(channel)
        }
    }

    fun allowed(): Boolean {
        channel()
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return false
        return notifications.areNotificationsEnabled() &&
            (Build.VERSION.SDK_INT < 26 || notifications.getNotificationChannel(CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE)
    }

    fun exact(): Boolean = Build.VERSION.SDK_INT < 31 || alarms.canScheduleExactAlarms()

    fun status(): Map<String, Any> = mapOf("available" to true, "notificationsAllowed" to allowed(),
        "exactAllowed" to exact(), "scheduledCount" to if (prefs.getBoolean("enabled", false)) read().size else 0,
        "snoozes" to readSnoozes().keys().asSequence().mapNotNull { id -> validSnooze(id)?.let { id to it.getLong("at") } }.toMap())

    private fun day(at: Long = System.currentTimeMillis()): String = SimpleDateFormat("yyyy-MM-dd", Locale.ROOT).format(at)
    private fun readSnoozes() = JSONObject(prefs.getString("snoozes", "{}"))
    private fun completed() = JSONObject(prefs.getString("completedDays", "{}"))
    private fun handled() = JSONObject(prefs.getString("dailyHandledDays", "{}"))
    private fun isCompleted(id: String) = completed().optString(id) == day()
    private fun clearSnooze(id: String) {
        alarms.cancel(snoozePending(id, 0))
        val data = readSnoozes(); data.remove(id)
        prefs.edit().putString("snoozes", data.toString()).commit()
    }
    private fun validSnooze(id: String): JSONObject? {
        if (!prefs.getBoolean("enabled", false) || isCompleted(id)) return null
        val entry = readSnoozes().optJSONObject(id) ?: return null
        val plan = read().find { it.id == id } ?: return null
        return entry.takeIf { it.optString("day") == day() && it.optInt("hour") == plan.hour && it.optInt("minute") == plan.minute }
    }

    private fun read(): List<Plan> {
        val data = JSONArray(prefs.getString("plans", "[]"))
        return (0 until data.length()).map { data.getJSONObject(it).let { p -> Plan(p.getString("id"), p.getInt("hour"), p.getInt("minute")) } }
    }

    fun replace(enabled: Boolean, input: List<Map<*, *>>): Map<String, Any> {
        require(input.size <= 32) { "最多支持 32 个时间" }
        val plans = input.map {
            val id = it["id"] as? String ?: error("缺少 ID")
            val hour = it["hour"] as? Int ?: error("时间格式不正确")
            val minute = it["minute"] as? Int ?: error("时间格式不正确")
            require(Regex("[a-f0-9-]{36}").matches(id) && hour in 0..23 && minute in 0..59)
            Plan(id, hour, minute)
        }
        require(plans.map { it.id }.distinct().size == plans.size)
        val json = JSONArray().apply { plans.forEach { put(JSONObject().put("id", it.id).put("hour", it.hour).put("minute", it.minute)) } }.toString()
        if (!enabled) {
            readSnoozes().keys().asSequence().toList().forEach { clearSnooze(it) }
            alarms.cancel(pending(TEST, true))
            notifications.cancel(TEST, 0)
            prefs.edit().remove("testAt").apply()
        }
        if (enabled == prefs.getBoolean("enabled", false) && json == prefs.getString("plans", "[]") &&
            prefs.getBoolean("exactMode", false) == exact()) return status()
        val done = completed()
        val daily = handled()
        read().forEach { old ->
            cancel(old.id)
            if (!enabled || plans.none { it == old }) {
                clearSnooze(old.id)
                if (plans.none { it == old }) { done.remove(old.id); daily.remove(old.id) }
            }
        }
        prefs.edit().putString("completedDays", done.toString()).apply()
        prefs.edit().putString("dailyHandledDays", daily.toString()).apply()
        prefs.edit().putBoolean("enabled", enabled).putString("plans", json).putBoolean("exactMode", exact()).apply()
        if (enabled) plans.forEach { schedule(it) }
        return status()
    }

    private fun pending(id: String, test: Boolean = false): PendingIntent {
        val intent = Intent(context, ReminderReceiver::class.java).apply {
            action = if (test) ACTION_TEST else ACTION_FIRE
            data = Uri.parse("medilens://local-reminder/$id")
            putExtra("plan_id", id)
        }
        return PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    private fun snoozePending(id: String, at: Long): PendingIntent {
        val intent = Intent(context, ReminderReceiver::class.java).apply {
            action = ACTION_SNOOZE
            data = Uri.parse("medilens://local-reminder/snooze/$id")
            putExtra("plan_id", id); putExtra("snooze_at", at)
        }
        return PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    fun snooze(id: String, minutes: Int, taskDay: String): Map<String, Any> {
        check(prefs.getBoolean("enabled", false) && allowed()) { "请先开启并允许通知" }
        require(minutes in listOf(5, 10, 15, 30) && taskDay == day())
        check(!isCompleted(id)) { "这项任务已完成" }
        val plan = read().find { it.id == id } ?: error("计划不存在")
        val now = System.currentTimeMillis()
        val due = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, plan.hour); set(Calendar.MINUTE, plan.minute)
            set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }.timeInMillis
        check(now >= due) { "计划时间尚未到达" }
        val at = now + minutes * 60_000L
        require(day(at) == taskDay) { "不能延后到下一天" }
        val data = readSnoozes()
        data.put(id, JSONObject().put("at", at).put("day", taskDay).put("hour", plan.hour).put("minute", plan.minute))
        // The same pending-intent identity replaces the previous postponement.
        set(at, snoozePending(id, at))
        val daily = handled(); daily.put(id, day())
        prefs.edit().putString("snoozes", data.toString()).putString("dailyHandledDays", daily.toString()).commit()
        alarms.cancel(pending(id)); schedule(plan)
        notifications.cancel(id, 0)
        return status()
    }

    fun cancelSnooze(id: String): Map<String, Any> {
        clearSnooze(id)
        return status()
    }

    fun deliverSnooze(id: String, expectedAt: Long) {
        val entry = validSnooze(id) ?: return
        val at = entry.getLong("at")
        if (at != expectedAt) return
        if (at > System.currentTimeMillis()) { set(at, snoozePending(id, at)); return }
        clearSnooze(id)
        showNotification(id, false)
    }

    private fun set(at: Long, pending: PendingIntent) {
        if (exact()) {
            try {
                alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
                return
            } catch (_: SecurityException) { /* Permission may change while scheduling. */ }
        }
        alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
    }

    private fun schedule(plan: Plan) {
        val now = System.currentTimeMillis()
        val time = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, plan.hour); set(Calendar.MINUTE, plan.minute)
            set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
            if (timeInMillis <= now) add(Calendar.DAY_OF_YEAR, 1)
        }
        set(time.timeInMillis, pending(plan.id))
    }

    private fun cancel(id: String) {
        alarms.cancel(pending(id))
        notifications.cancel(id, 0)
    }

    fun restore() {
        channel()
        if (prefs.getBoolean("enabled", false)) read().forEach { schedule(it) }
        readSnoozes().keys().asSequence().toList().forEach { id ->
            val entry = validSnooze(id)
            if (entry == null || entry.getLong("at") <= System.currentTimeMillis()) clearSnooze(id)
            else set(entry.getLong("at"), snoozePending(id, entry.getLong("at")))
        }
        prefs.edit().putBoolean("exactMode", exact()).apply()
    }

    fun test() {
        check(allowed()) { "请先允许通知" }
        val at = System.currentTimeMillis() + 10_000
        prefs.edit().putLong("testAt", at).apply()
        set(at, pending(TEST, true))
    }

    fun acknowledge(id: String) {
        val plan = read().find { it.id == id } ?: return
        val done = completed(); done.put(id, day())
        prefs.edit().putString("completedDays", done.toString()).commit()
        clearSnooze(id)
        cancel(id)
        // A late inexact alarm must not notify again after completion.
        if (prefs.getBoolean("enabled", false)) schedule(plan)
    }

    fun undoAcknowledge(id: String) {
        val done = completed(); done.remove(id)
        prefs.edit().putString("completedDays", done.toString()).commit()
        // Undo changes the record only; never replay a past notification.
    }

    fun deliver(id: String, test: Boolean) {
        if (test) {
            if (prefs.getLong("testAt", 0) == 0L) return
            prefs.edit().remove("testAt").apply()
        } else {
            if (!prefs.getBoolean("enabled", false)) return
            val plan = read().find { it.id == id } ?: return
            schedule(plan) // Each delivery schedules the next local calendar day.
            if (isCompleted(id) || validSnooze(id) != null || handled().optString(id) == day()) return
            val daily = handled(); daily.put(id, day())
            prefs.edit().putString("dailyHandledDays", daily.toString()).commit()
        }
        showNotification(id, test)
    }

    fun scheduleOneOff(at: Long, operation: PendingIntent) { set(at, operation) }
    fun notifyOneOff(id: String): Boolean = showNotification("checkup:$id", false)

    private fun showNotification(id: String, test: Boolean): Boolean {
        if (!allowed()) return false
        val open = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN; addCategory(Intent.CATEGORY_LAUNCHER)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
        }
        val click = PendingIntent.getActivity(context, 7210, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL) else Notification.Builder(context)
        val notification = builder.setSmallIcon(R.drawable.ic_reminder)
            .setContentTitle(if (test) "MediLens 测试提醒" else "MediLens 任务提醒")
            .setContentText(if (test) "本机通知已送达，点此打开应用。" else "您设置的一项任务到时间了，点此打开应用查看。")
            .setContentIntent(click).setAutoCancel(true).setVisibility(Notification.VISIBILITY_PRIVATE)
            .setCategory(Notification.CATEGORY_REMINDER).build()
        notifications.notify(id, 0, notification)
        return true
    }

    companion object {
        private const val CHANNEL = "medilens_local_tasks_v1"
        private const val TEST = "test"
        const val ACTION_FIRE = "cn.medilens.medilens.REMIND"
        const val ACTION_TEST = "cn.medilens.medilens.REMIND_TEST"
        const val ACTION_SNOOZE = "cn.medilens.medilens.REMIND_SNOOZE"
    }
}
