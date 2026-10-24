package com.zcode.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * 常驻前台服务（v1.2.0，用户要求对齐 DeepSeek-Harness 的常驻模型）。
 *
 * 职责只有一个：把进程保活。WebView 的事件流（wss://zcode.z.ai/ws 中继）
 * 活着，完成/审批/报错通知才能在后台与锁屏期间到达。服务本身不持有任何
 * 业务逻辑——事件解析、通知决策都在 Dart 侧；v1.0.0 的旧常驻实现因自带
 * 轮询与业务逻辑被移除，本类是它的纯保活替代（K1 不变量锁定该边界）。
 *
 * 展示形态（v1.2.1，仿 DeepSeek-Harness）：
 *   标题「远程」 正文「已连接到 <当前设备名>」 动作「断开连接」。
 * Dart 侧在设备切换/改名时经 zremote/keepalive 的 update 方法推送新名字；
 * 「断开连接」= 停止常驻监控（下次打开 App 自动恢复）。
 *
 * 生存策略：START_STICKY（系统杀死后重建）；用户划掉最近任务不算停止监控。
 * MIUI 等厂商 ROM 的"自启动/无限制省电"仍需用户在系统设置里放行。
 */
class MonitorKeepAliveService : Service() {

    @Volatile
    private var deviceName: String = ""

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        startInForeground()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_DISCONNECT) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        intent?.getStringExtra(EXTRA_DEVICE_NAME)?.let { name ->
            if (name != deviceName) {
                deviceName = name
                // 已在前台时 startForeground 就是刷新内容的最短路径。
                startInForeground()
                return START_STICKY
            }
        }
        startInForeground()
        return START_STICKY
    }

    private fun startInForeground() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager?.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    // 渠道名用户可见：说清这条常驻通知是什么。
                    "远程监控常驻",
                    NotificationManager.IMPORTANCE_MIN,
                ).apply { setShowBadge(false) },
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION") Notification.Builder(this)
        }
        val connected = if (deviceName.isBlank()) "保持连接以接收任务通知"
        else "已连接到 $deviceName"
        builder.setContentTitle(TITLE)
            .setContentText(connected)
            .setSmallIcon(R.drawable.ic_notification)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        if (launch != null) {
            builder.setContentIntent(
                PendingIntent.getActivity(
                    this,
                    0,
                    launch,
                    PendingIntent.FLAG_IMMUTABLE,
                ),
            )
        }
        // 「断开连接」动作：停止常驻监控（停止后重开 App 即恢复）。
        val disconnect = PendingIntent.getService(
            this,
            1,
            Intent(this, MonitorKeepAliveService::class.java).apply {
                action = ACTION_DISCONNECT
            },
            PendingIntent.FLAG_IMMUTABLE,
        )
        builder.addAction(
            Notification.Action.Builder(
                null,
                ACTION_DISCONNECT_LABEL,
                disconnect,
            ).build(),
        )
        return builder.build()
    }

    companion object {
        private const val CHANNEL_ID = "zr_keep_monitor_v8"

        // 901 是 v1.0.0 遗留通知的 id（MainActivity 启动时会清一次），
        // 常驻通知用相邻 id 避免升级瞬间互相覆盖。
        private const val NOTIFICATION_ID = 902

        const val TITLE = "远程"
        const val ACTION_DISCONNECT_LABEL = "断开连接"
        private const val ACTION_DISCONNECT = "com.zcode.app.keepalive.DISCONNECT"
        const val EXTRA_DEVICE_NAME = "device_name"

        fun start(context: Context) {
            val intent = Intent(context, MonitorKeepAliveService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun update(context: Context, deviceName: String) {
            val intent = Intent(context, MonitorKeepAliveService::class.java).apply {
                putExtra(EXTRA_DEVICE_NAME, deviceName)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, MonitorKeepAliveService::class.java))
        }
    }
}
