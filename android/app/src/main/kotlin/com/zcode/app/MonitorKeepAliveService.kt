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
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineGroup
import io.flutter.embedding.engine.dart.DartExecutor.DartEntrypoint
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant

/**
 * 常驻前台服务（v1.2.0，用户要求对齐 DeepSeek-Harness 的常驻模型）。
 *
 * v1.2.x 的形态是"纯保活"：进程活着，但通知逻辑都在 Activity 的 Flutter
 * 引擎里——划掉最近任务/系统回收 Activity 时引擎销毁，通知链路整体断电，
 * 这是用户实测"后台没通知"的根因。
 *
 * v1.3.1 起本服务**宿主一个头无 Flutter 引擎**（入口 `monitorMain`）：
 * 专跑原生监控通道与系统通知，Activity 不在也照常提醒；START_STICKY 重建
 * 服务时 onCreate 重新拉起，监控自愈。原生侧仍然零业务逻辑——网络、事件
 * 解析、通知决策全在 Dart（K1 边界修订：服务可以宿引擎，不许自己联网）。
 *
 * 展示形态（v1.2.1，仿 DeepSeek-Harness）：
 *   标题「远程」 正文三态（已连接到 X / 连接已断开…） 动作「断开连接」。
 *
 * 前后台协调：Activity onResume/onPause 经 setUiActive 推送 UI 是否在前台；
 * 前台时向头无引擎发 suspend（事件归 WebView 路径），离开时发 resume。
 *
 * 生存策略：START_STICKY（系统杀死后重建）；MIUI 等厂商 ROM 的
 * "自启动/无限制省电"仍需用户在系统设置里放行。
 */
class MonitorKeepAliveService : Service() {

    @Volatile
    private var deviceName: String = ""

    // v1.3.0：常驻通知文案三态（在线/断连/无设备），由 Dart 侧经
    // zremote/keepalive 的 status 方法推送；断连时提示恢复后自动继续。
    @Volatile
    private var connected: Boolean = true

    // v1.3.1：头无监控引擎与 UI 前台标记。
    @Volatile
    private var engine: FlutterEngine? = null

    @Volatile
    private var uiActive: Boolean = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        startInForeground()
        ensureMonitorEngine()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_DISCONNECT) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        val name = intent?.getStringExtra(EXTRA_DEVICE_NAME)
        if (name != null && name != deviceName) {
            deviceName = name
        }
        if (intent?.hasExtra(EXTRA_CONNECTED) == true) {
            connected = intent.getBooleanExtra(EXTRA_CONNECTED, true)
        }
        if (intent?.hasExtra(EXTRA_UI_ACTIVE) == true) {
            uiActive = intent.getBooleanExtra(EXTRA_UI_ACTIVE, false)
            pushSuspendState()
        }
        // 引擎失败重试（v1.4.0）：onCreate 时的创建可能因 FlutterLoader 未就绪
        // 失败（开机自启先于任何 Activity），此后每次 onStartCommand（状态
        // 推送/自启重建）都尝试补建，成功即止。
        ensureMonitorEngine()
        // 已在前台时 startForeground 就是刷新内容的最短路径。
        startInForeground()
        return START_STICKY
    }

    override fun onDestroy() {
        engine?.let { e ->
            try {
                e.destroy()
            } catch (_: Exception) {}
        }
        engine = null
        headlessEngine = null
        super.onDestroy()
    }

    /**
     * 拉起头无监控引擎（幂等）。创建失败（个别 ROM/老机型/loader 未就绪）
     * 静默退化并在下次 onStartCommand 重试：前台服务继续保活 WebView 路径，
     * 行为等同 v1.2.x。
     */
    private fun ensureMonitorEngine() {
        if (engine != null) return
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            // loader 可能尚未初始化（开机自启先于任何 Activity）：这里同步
            // 完成初始化再取 bundle 路径，否则 findAppBundlePath 返回空、
            // 引擎起不来且永不重试。
            loader.startInitialization(applicationContext)
            loader.ensureInitialization()
            val entrypoint = DartEntrypoint(loader.findAppBundlePath(), "monitorMain")
            val created = FlutterEngineGroup(this).createAndRunEngine(this, entrypoint)
            // 头无引擎不经过 Activity 的 configureFlutterEngine，插件与
            // 通道处理器都要在这里手工挂上。
            GeneratedPluginRegistrant.registerWith(created)
            val messenger = created.dartExecutor.binaryMessenger
            MethodChannel(messenger, "zremote/keepalive").setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        start(this)
                        result.success(null)
                    }
                    "update" -> {
                        update(this, call.argument<String>("name") ?: "")
                        result.success(null)
                    }
                    "status" -> {
                        status(
                            this,
                            call.argument<String>("name") ?: "",
                            call.argument<Boolean>("connected") ?: true,
                        )
                        result.success(null)
                    }
                    "stop" -> {
                        stop(this)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
            MethodChannel(messenger, "zremote/notification_channels")
                .setMethodCallHandler { call, result ->
                    if (call.method == "ensureChannels") {
                        NotificationChannels.ensure(this, call.argument<String>("mode") ?: "sound")
                        result.success(null)
                    } else {
                        result.notImplemented()
                    }
                }
            engine = created
            headlessEngine = created
            // UI 可能已经在前台（服务先于 Activity 起来）：补一次协调。
            pushSuspendState()
        } catch (_: Exception) {
            engine = null
        }
    }

    private fun pushSuspendState() {
        val e = engine ?: return
        try {
            MethodChannel(e.dartExecutor.binaryMessenger, "zremote/monitor_control")
                .invokeMethod(if (uiActive) "suspend" else "resume", null)
        } catch (_: Exception) {
            // Dart 侧 handler 尚未注册（引擎刚起）时会失败；下一条
            // setUiActive/onStartCommand 会再推。
        }
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
        val connectedText = when {
            !connected -> "连接已断开，恢复后自动继续"
            deviceName.isNotBlank() -> "已连接到 $deviceName"
            else -> "保持连接以接收任务通知"
        }
        builder.setContentTitle(TITLE)
            .setContentText(connectedText)
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
        /** 头无引擎的全局只读引用（诊断/调试用；v1.4.0）。 */
        @Volatile
        var headlessEngine: io.flutter.embedding.engine.FlutterEngine? = null
            private set

        private const val CHANNEL_ID = "zr_keep_monitor_v8"

        // 901 是 v1.0.0 遗留通知的 id（MainActivity 启动时会清一次），
        // 常驻通知用相邻 id 避免升级瞬间互相覆盖。
        private const val NOTIFICATION_ID = 902

        const val TITLE = "远程"
        const val ACTION_DISCONNECT_LABEL = "断开连接"
        private const val ACTION_DISCONNECT = "com.zcode.app.keepalive.DISCONNECT"
        const val EXTRA_DEVICE_NAME = "device_name"
        const val EXTRA_CONNECTED = "connected"
        const val EXTRA_UI_ACTIVE = "ui_active"

        fun start(context: Context) {
            val intent = Intent(context, MonitorKeepAliveService::class.java)
            dispatch(context, intent)
        }

        fun update(context: Context, deviceName: String) {
            val intent = Intent(context, MonitorKeepAliveService::class.java).apply {
                putExtra(EXTRA_DEVICE_NAME, deviceName)
            }
            dispatch(context, intent)
        }

        /** v1.3.0：同步连接状态（文案三态见构建通知处）。 */
        fun status(context: Context, deviceName: String, connected: Boolean) {
            val intent = Intent(context, MonitorKeepAliveService::class.java).apply {
                putExtra(EXTRA_DEVICE_NAME, deviceName)
                putExtra(EXTRA_CONNECTED, connected)
            }
            dispatch(context, intent)
        }

        /** v1.3.1：UI 是否前台（Activity onResume/onPause 推送），驱动头无引擎 suspend/resume。 */
        fun setUiActive(context: Context, active: Boolean) {
            val intent = Intent(context, MonitorKeepAliveService::class.java).apply {
                putExtra(EXTRA_UI_ACTIVE, active)
            }
            dispatch(context, intent)
        }

        private fun dispatch(context: Context, intent: Intent) {
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
