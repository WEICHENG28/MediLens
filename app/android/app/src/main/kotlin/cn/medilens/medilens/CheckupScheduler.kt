package cn.medilens.medilens

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Locale

/** Only opaque IDs, timestamps and notification state; no report or appointment details. */
class CheckupScheduler(private val context: Context) {
    private val prefs = context.getSharedPreferences("checkup_clock", Context.MODE_PRIVATE)
    private val alarms = context.getSystemService(AlarmManager::class.java)
    private val local = LocalReminderScheduler(context)
    private fun read() = JSONObject(prefs.getString("entries", "{}"))
    private fun save(data: JSONObject) { check(prefs.edit().putString("entries", data.toString()).commit()) }
    private fun day(at: Long) = SimpleDateFormat("yyyy-MM-dd", Locale.ROOT).format(at)

    fun status(): Map<String, Any> {
        val data = read()
        return local.status() + mapOf("checkups" to data.keys().asSequence().associateWith { id ->
            val entry = data.getJSONObject(id)
            mapOf("at" to entry.getLong("at"), "state" to entry.getString("state"))
        })
    }

    private fun pending(id: String, at: Long): PendingIntent {
        val intent = Intent(context, ReminderReceiver::class.java).apply {
            action = ACTION
            this.data = Uri.parse("medilens://checkup/$id")
            putExtra("checkup_id", id); putExtra("checkup_at", at)
        }
        return PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    fun upsert(id: String, at: Long): Map<String, Any> {
        require(Regex("[a-f0-9-]{36}").matches(id))
        check(local.allowed()) { "请先允许通知" }
        require(at > System.currentTimeMillis()) { "请选择未来时间" }
        val data = read()
        require(data.has(id) || data.length() < 32) { "最多支持 32 项" }
        require(data.keys().asSequence().none { it != id && data.getJSONObject(it).let { e -> e.getString("state") == "scheduled" && e.getLong("at") == at } })
        val old = data.optJSONObject(id)?.toString()
        data.put(id, JSONObject().put("at", at).put("state", "scheduled"))
        save(data)
        try { local.scheduleOneOff(at, pending(id, at)) }
        catch (error: Exception) {
            if (old == null) data.remove(id) else data.put(id, JSONObject(old))
            save(data)
            if (old != null) {
                val previous = JSONObject(old)
                if (previous.getString("state") == "scheduled" && previous.getLong("at") > System.currentTimeMillis())
                    local.scheduleOneOff(previous.getLong("at"), pending(id, previous.getLong("at")))
            }
            throw error
        }
        context.getSystemService(android.app.NotificationManager::class.java).cancel("checkup:$id", 0)
        return status()
    }

    fun cancel(id: String): Map<String, Any> {
        val data = read(); data.remove(id); save(data)
        alarms.cancel(pending(id, 0))
        context.getSystemService(android.app.NotificationManager::class.java).cancel("checkup:$id", 0)
        return status()
    }

    fun clear(): Map<String, Any> {
        val ids = read().keys().asSequence().toList()
        save(JSONObject())
        ids.forEach { alarms.cancel(pending(it, 0)); context.getSystemService(android.app.NotificationManager::class.java).cancel("checkup:$it", 0) }
        return status()
    }

    fun restore() {
        val data = read(); val now = System.currentTimeMillis()
        data.keys().asSequence().toList().forEach { id ->
            val entry = data.getJSONObject(id)
            if (entry.getString("state") == "scheduled") {
                if (entry.getLong("at") > now) local.scheduleOneOff(entry.getLong("at"), pending(id, entry.getLong("at")))
                else { entry.put("state", "expired"); alarms.cancel(pending(id, 0)) }
            }
        }
        save(data)
    }

    fun deliver(id: String, expected: Long) {
        val data = read(); val entry = data.optJSONObject(id) ?: return
        if (entry.getString("state") != "scheduled" || entry.getLong("at") != expected) return
        val now = System.currentTimeMillis()
        if (expected > now) { local.scheduleOneOff(expected, pending(id, expected)); return }
        // Commit a terminal state before posting, so duplicate broadcasts cannot repeat it.
        entry.put("state", if (day(expected) != day(now)) "expired" else "sending"); save(data)
        if (entry.getString("state") == "expired") return
        val sent = try { local.notifyOneOff(id) } catch (_: SecurityException) { false }
        entry.put("state", if (sent) "sent" else "blocked"); save(data)
    }

    companion object { const val ACTION = "cn.medilens.medilens.CHECKUP" }
}
