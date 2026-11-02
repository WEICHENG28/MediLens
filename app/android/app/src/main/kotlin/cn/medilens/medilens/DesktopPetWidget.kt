package cn.medilens.medilens

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

class DesktopPetWidget : AppWidgetProvider() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == GREET) {
            val id = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, DesktopPetWidget::class.java))
            if (!ids.contains(id)) return
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val next = prefs.getInt("greeting", 0).coerceIn(0, 3) % 3 + 1
            prefs.edit().putInt("greeting", next).apply()
            onUpdate(context, manager, ids)
            return
        }
        super.onReceive(context, intent)
    }
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val mood = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("mood", "calm")
        val moodCaption = when (mood) {
            "active" -> "今天也充满活力"
            "rest" -> "小兔休息一会儿"
            else -> "小兔一直陪着你"
        }
        val greeting = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getInt("greeting", 0)
        val caption = when (greeting) {
            1 -> "你好呀，我在这里。"
            2 -> "慢慢来，也很好。"
            3 -> "可以按自己的节奏来。"
            else -> moodCaption
        }
        for (id in ids) {
            val views = RemoteViews(context.packageName, R.layout.desktop_pet_widget)
            views.setTextViewText(R.id.pet_caption, caption)
            views.setTextViewText(R.id.pet_avatar, if (mood == "rest") "🐰💤" else "🐰")
            val open = Intent(context, MainActivity::class.java).apply {
                action = Intent.ACTION_MAIN
                addCategory(Intent.CATEGORY_LAUNCHER)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
            }
            val pending = PendingIntent.getActivity(context, 0, open,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            views.setOnClickPendingIntent(R.id.pet_widget_root, pending)
            views.setOnClickPendingIntent(R.id.pet_avatar, pending)
            val greet = Intent(context, DesktopPetWidget::class.java).apply {
                action = GREET
                putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
            }
            val greetingAction = PendingIntent.getBroadcast(context, id, greet,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            views.setOnClickPendingIntent(R.id.pet_greet_button, greetingAction)
            manager.updateAppWidget(id, views)
        }
    }

    companion object {
        private const val GREET = "cn.medilens.medilens.PET_GREET"
        fun clearGreeting(context: Context) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove("greeting").apply()
            val manager = AppWidgetManager.getInstance(context)
            DesktopPetWidget().onUpdate(context, manager,
                manager.getAppWidgetIds(ComponentName(context, DesktopPetWidget::class.java)))
        }
        private const val PREFS = "desktop_pet_public_mood"
        fun saveMood(context: Context, proposed: String) {
            val mood = if (proposed in setOf("active", "rest", "calm")) proposed else "calm"
            // Launcher-visible storage holds only closed-set generic mood and greeting tokens.
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("mood", mood).remove("greeting").apply()
            val manager = AppWidgetManager.getInstance(context)
            DesktopPetWidget().onUpdate(context, manager,
                manager.getAppWidgetIds(ComponentName(context, DesktopPetWidget::class.java)))
        }
    }
}
