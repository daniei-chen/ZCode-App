package com.zcode.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager

class KeepAliveService : Service() {

    companion object {
        @Volatile
        var isRunning = false
            private set

        @Volatile
        var lastStartBlocked = false
            private set

        // Android 会持久化通知通道的用户设置，所以升级时使用新 id，
        // 确保旧版的高存在感配置不会继续影响后台服务。
        private const val CHANNEL_ID = "zr_keep_silent_v3"
        private const val NOTIFICATION_ID = 901
        private const val WAKE_LOCK_TAG = "zcode-control:keepalive"
        private const val RETRY_MS = 2000L
        private const val WAKE_LOCK_MAX_MS = 5 * 60 * 1000L

        fun start(context: Context) {
            context.startForegroundService(
                Intent(context, KeepAliveService::class.java),
            )
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private val handler = Handler(Looper.getMainLooper())
    private val releaseWakeLockRunnable = Runnable { releaseWakeLock() }

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Intent.ACTION_SCREEN_OFF -> holdWakeLockBriefly()
                Intent.ACTION_SCREEN_ON -> releaseWakeLock()
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
        }
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(screenReceiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(screenReceiver, filter)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        isRunning = true
        if (!promoteToForeground()) {
            handler.postDelayed(
                {
                    if (isRunning && !promoteToForeground()) stopSelf()
                },
                RETRY_MS,
            )
        }
        if (!powerManager.isInteractive) holdWakeLockBriefly()
        return START_STICKY
    }

    private fun promoteToForeground(): Boolean = try {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        lastStartBlocked = false
        true
    } catch (e: Exception) {
        lastStartBlocked = true
        false
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        try {
            unregisterReceiver(screenReceiver)
        } catch (e: Exception) {
            // The receiver may already have been removed by the system.
        }
        releaseWakeLock()
        isRunning = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private val powerManager: PowerManager
        get() = getSystemService(POWER_SERVICE) as PowerManager

    private fun buildNotification(): Notification {
        if (Build.VERSION.SDK_INT >= 26) {
            val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "后台连接",
                    // A foreground service must have a notification on modern
                    // Android. MIN keeps background monitoring alive without
                    // placing a ZCode status-bar icon or making a sound.
                    NotificationManager.IMPORTANCE_MIN,
                ).apply {
                    description = "后台消息监控所需的最低可见状态通知"
                    setShowBadge(false)
                    setSound(null, null)
                    enableVibration(false)
                },
            )
        }
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("ZCode")
            .setContentText("后台连接已启用")
            .setSmallIcon(R.drawable.ic_notification)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }

    private fun holdWakeLockBriefly() {
        val lock = wakeLock ?: powerManager
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG)
            .also {
                it.setReferenceCounted(false)
                wakeLock = it
            }
        handler.removeCallbacks(releaseWakeLockRunnable)
        if (!lock.isHeld) lock.acquire(WAKE_LOCK_MAX_MS)
        handler.postDelayed(releaseWakeLockRunnable, WAKE_LOCK_MAX_MS)
    }

    private fun releaseWakeLock() {
        handler.removeCallbacks(releaseWakeLockRunnable)
        wakeLock?.takeIf { it.isHeld }?.release()
    }
}
