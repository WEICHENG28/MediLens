package cn.medilens.medilens

import android.app.*
import android.content.*
import android.content.pm.ServiceInfo
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.PixelFormat
import android.os.*
import android.provider.Settings
import android.view.*
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.abs

/** User-started, non-sticky generic companion. Never reads health records or screen contents. */
class FloatingPetService : Service() {
    private var window: WindowManager? = null
    private var root: View? = null
    private var params: WindowManager.LayoutParams? = null
    private var ownSession = -1L
    private var receiverRegistered = false
    private var ops: AppOpsManager? = null
    private var greeting = 0
    private val screenOff = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) { if (intent?.action == Intent.ACTION_SCREEN_OFF) finishPet() }
    }
    private val permissions = AppOpsManager.OnOpChangedListener { operation, pkg ->
        if (pkg == packageName && operation == AppOpsManager.OPSTR_SYSTEM_ALERT_WINDOW && !Settings.canDrawOverlays(this)) {
            Handler(Looper.getMainLooper()).post { finishPet() }
        }
    }
    override fun onBind(intent: Intent?) = null
    override fun onCreate() { super.onCreate(); instance = this }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == STOP) { stop(this); return START_NOT_STICKY }
        val token = intent?.getLongExtra("session", -1) ?: -1
        if (intent?.action != START || !requested || token != session) { if (root == null) stopSelf(); return START_NOT_STICKY }
        ownSession = token
        if (root != null) return START_NOT_STICKY
        try {
            if (!Settings.canDrawOverlays(this) || !notificationsAllowed(this)) error("permissions")
            ensureChannel(this)
            val closeIntent = PendingIntent.getService(this, 4911, Intent(this, FloatingPetService::class.java).setAction(STOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val openIntent = PendingIntent.getActivity(this, 4912, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else Notification.Builder(this)
            val notification = builder.setSmallIcon(R.drawable.ic_reminder)
                .setContentTitle("MediLens 悬浮小兔已开启").setContentText("可拖动小兔；点击关闭或通知中的停止即可结束。")
                .setContentIntent(openIntent).setOngoing(true).setVisibility(Notification.VISIBILITY_PUBLIC)
                .addAction(Notification.Action.Builder(null, "停止悬浮小兔", closeIntent).build()).build()
            if (Build.VERSION.SDK_INT >= 34) startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            else startForeground(NOTIFICATION_ID, notification)
            if (!requested || token != session) { finishPet(); return START_NOT_STICKY }
            attachPet()
            val filter = IntentFilter(Intent.ACTION_SCREEN_OFF)
            if (Build.VERSION.SDK_INT >= 33) registerReceiver(screenOff, filter, RECEIVER_NOT_EXPORTED) else registerReceiver(screenOff, filter)
            receiverRegistered = true
            ops = getSystemService(AppOpsManager::class.java).also { it.startWatchingMode(AppOpsManager.OPSTR_SYSTEM_ALERT_WINDOW, packageName, permissions) }
            running = true
            lastError = null
        } catch (_: Exception) {
            lastError = "悬浮小兔未能开启，请检查悬浮和通知权限后重试。"
            finishPet()
        }
        return START_NOT_STICKY
    }
    @Suppress("DEPRECATION")
    private fun attachPet() {
        val wm = getSystemService(WINDOW_SERVICE) as WindowManager
        window = wm
        fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(4), dp(4), dp(4), dp(4))
            setBackgroundResource(R.drawable.desktop_pet_background)
            contentDescription = "MediLens 悬浮小兔"
        }
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val pet = TextView(this).apply { text = "🐰"; textSize = 34f; gravity = Gravity.CENTER; contentDescription = "小兔，拖动移动，点一下打招呼" }
        val close = TextView(this).apply {
            text = "×"; textSize = 26f; gravity = Gravity.CENTER; setTextColor(Color.rgb(0, 88, 79))
            contentDescription = "关闭悬浮小兔"; setOnClickListener { finishPet() }
        }
        row.addView(pet, LinearLayout.LayoutParams(0, dp(56), 1f))
        row.addView(close, LinearLayout.LayoutParams(dp(48), dp(56)))
        val caption = TextView(this).apply {
            text = "点小兔，打个招呼"; textSize = 12f; gravity = Gravity.CENTER; maxLines = 2
            setTextColor(Color.rgb(0, 88, 79)); contentDescription = "小兔陪伴文字，点一下换一句问候"
        }
        val greetings = arrayOf("你好呀，我在这里。", "慢慢来，也很好。", "可以按自己的节奏来。")
        val hello = View.OnClickListener { caption.text = greetings[greeting++ % greetings.size] }
        pet.setOnClickListener(hello); caption.setOnClickListener(hello)
        layout.addView(row); layout.addView(caption, LinearLayout.LayoutParams(-1, dp(48)))
        val lp = WindowManager.LayoutParams(dp(160), dp(112),
            if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY else WindowManager.LayoutParams.TYPE_PHONE,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT).apply {
            gravity = Gravity.TOP or Gravity.LEFT
            x = dp(12); y = dp(160)
            if (Build.VERSION.SDK_INT >= 30) setFitInsetsTypes(0)
        }
        root = layout; params = lp
        clampPosition()
        var startX = 0; var startY = 0; var rawX = 0f; var rawY = 0f; var dragged = false
        val slop = ViewConfiguration.get(this).scaledTouchSlop
        pet.setOnTouchListener { v, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> { startX = lp.x; startY = lp.y; rawX = event.rawX; rawY = event.rawY; dragged = false; true }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - rawX; val dy = event.rawY - rawY
                    if (abs(dx) > slop || abs(dy) > slop) dragged = true
                    if (dragged) { lp.x = startX + dx.toInt(); lp.y = startY + dy.toInt(); clampPosition(); updatePosition() }
                    true
                }
                MotionEvent.ACTION_UP -> { if (!dragged) v.performClick(); true }
                MotionEvent.ACTION_CANCEL -> true
                else -> false
            }
        }
        wm.addView(layout, lp)
    }
    @Suppress("DEPRECATION")
    private fun clampPosition() {
        val wm = window ?: return; val lp = params ?: return
        var left = 0; var top = 0; var right = resources.displayMetrics.widthPixels; var bottom = resources.displayMetrics.heightPixels
        if (Build.VERSION.SDK_INT >= 30) {
            val metrics = wm.currentWindowMetrics
            val insets = metrics.windowInsets.getInsetsIgnoringVisibility(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            left = insets.left; top = insets.top; right = metrics.bounds.width() - insets.right; bottom = metrics.bounds.height() - insets.bottom
        }
        lp.x = lp.x.coerceIn(left, (right - lp.width).coerceAtLeast(left))
        lp.y = lp.y.coerceIn(top, (bottom - lp.height).coerceAtLeast(top))
    }
    private fun updatePosition() {
        try { if (root != null) window?.updateViewLayout(root, params) } catch (_: Exception) { finishPet() }
    }
    override fun onConfigurationChanged(newConfig: Configuration) { super.onConfigurationChanged(newConfig); clampPosition(); updatePosition() }
    override fun onTaskRemoved(rootIntent: Intent?) { finishPet(); super.onTaskRemoved(rootIntent) }
    private fun removeWindow() {
        root?.let { try { window?.removeViewImmediate(it) } catch (_: Exception) {} }
        root = null; params = null
        if (receiverRegistered) { try { unregisterReceiver(screenOff) } catch (_: Exception) {}; receiverRegistered = false }
        try { ops?.stopWatchingMode(permissions) } catch (_: Exception) {}
        ops = null
    }
    private fun finishPet() {
        if (ownSession == session) { requested = false; running = false }
        removeWindow()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }
    override fun onDestroy() {
        removeWindow()
        if (instance === this) instance = null
        if (ownSession == session) { running = false; requested = false }
        super.onDestroy()
    }
    companion object {
        private const val CHANNEL = "medilens_floating_pet"
        private const val NOTIFICATION_ID = 4911
        private const val START = "cn.medilens.medilens.FLOATING_PET_START"
        private const val STOP = "cn.medilens.medilens.FLOATING_PET_STOP"
        private var instance: FloatingPetService? = null
        private var session = 0L
        private var requested = false
        private var running = false
        private var lastError: String? = null
        fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT >= 26) {
                val channel = NotificationChannel(CHANNEL, "悬浮小兔运行提示", NotificationManager.IMPORTANCE_LOW).apply { setSound(null, null); enableVibration(false) }
                context.getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
            }
        }
        fun notificationsAllowed(context: Context): Boolean {
            val manager = context.getSystemService(NotificationManager::class.java)
            if (!manager.areNotificationsEnabled()) return false
            return Build.VERSION.SDK_INT < 26 || manager.getNotificationChannel(CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE
        }
        fun status(context: Context): Map<String, Any?> {
            ensureChannel(context)
            return mapOf("available" to true, "overlayAllowed" to Settings.canDrawOverlays(context),
                "notificationsAllowed" to notificationsAllowed(context), "running" to running, "starting" to (requested && !running), "error" to lastError)
        }
        fun start(activity: Activity): Map<String, Any?> {
            require(activity.hasWindowFocus()) { "请在APP前台手动开启" }
            require(Settings.canDrawOverlays(activity) && notificationsAllowed(activity)) { "请先开启悬浮及通知权限" }
            if (!running && !requested) {
                session++; requested = true; lastError = null
                val intent = Intent(activity, FloatingPetService::class.java).setAction(START).putExtra("session", session)
                try { if (Build.VERSION.SDK_INT >= 26) activity.startForegroundService(intent) else activity.startService(intent) }
                catch (_: Exception) { requested = false; lastError = "系统未允许开启悬浮小兔，请回到APP重试。" }
            }
            return status(activity)
        }
        fun stop(context: Context): Map<String, Any?> {
            session++; requested = false; running = false; lastError = null
            instance?.finishPet()
            context.stopService(Intent(context, FloatingPetService::class.java))
            return status(context)
        }
    }
}
