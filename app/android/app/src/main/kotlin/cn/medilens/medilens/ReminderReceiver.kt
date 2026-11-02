package cn.medilens.medilens

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val scheduler = LocalReminderScheduler(context)
        when (intent.action) {
            LocalReminderScheduler.ACTION_FIRE -> scheduler.deliver(intent.getStringExtra("plan_id") ?: return, false)
            LocalReminderScheduler.ACTION_TEST -> scheduler.deliver("test", true)
            LocalReminderScheduler.ACTION_SNOOZE -> scheduler.deliverSnooze(intent.getStringExtra("plan_id") ?: return, intent.getLongExtra("snooze_at", -1))
            CheckupScheduler.ACTION -> CheckupScheduler(context).deliver(intent.getStringExtra("checkup_id") ?: return, intent.getLongExtra("checkup_at", -1))
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_TIME_CHANGED, Intent.ACTION_TIMEZONE_CHANGED,
            Intent.ACTION_MY_PACKAGE_REPLACED, "android.app.action.SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED" -> {
                scheduler.restore(); CheckupScheduler(context).restore()
            }
        }
    }
}
