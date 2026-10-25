package com.zcode.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.UiModeManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.content.res.Configuration
import android.graphics.drawable.ColorDrawable
import android.media.AudioAttributes
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.Uri
import android.os.Bundle
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.view.View
import android.view.WindowManager
import androidx.core.content.FileProvider
import java.io.File
import java.security.MessageDigest
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {

    private var previewRingtone: Ringtone? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // Flutter's NormalTheme is selected from Android's system night
        // resources. Read the app-owned preference before that hand-off so a
        // saved "日间"/"夜间" choice does not flash through the opposite color.
        val mode = savedThemeMode()
        syncApplicationNightMode(mode)
        val dark = savedThemeIsDark()
        applySavedLaunchSurface(dark)
        // v1.0.0 的前台服务在新版本里已不存在（类已删除）：用组件名停一次，
        // 清掉旧安装可能的运行实例与常驻通知，不需要保留整套 Service 实现。
        stopService(
            Intent().setClassName(packageName, "com.zcode.app.KeepAliveService"),
        )
        clearLegacyKeepAliveNotification()
        super.onCreate(savedInstanceState)
        // FlutterActivity switches LaunchTheme to NormalTheme inside super.
        // Re-apply the saved surface after that switch and before the first
        // Flutter frame is visible.
        applySavedLaunchSurface(dark)
    }

    // 最近任务隐私遮罩（P1）：生物识别开启时，切后台瞬间用 FLAG_SECURE 遮住
    // 应用快照（最近任务/多任务卡片看不到 WebView 内容），回前台立即恢复，
    // 前台截图不受影响。与生物识别的 10 秒重锁是两个独立概念。
    private var recentsCoverEnabled = false

    override fun onPause() {
        super.onPause()
        if (recentsCoverEnabled) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
        // UI 离开前台 → 头无监控引擎 resume（v1.3.1：接管事件与通知）。
        MonitorKeepAliveService.setUiActive(this, false)
    }

    override fun onResume() {
        super.onResume()
        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        // UI 回到前台 → 头无监控引擎 suspend（事件归 WebView 路径，避免双源）。
        MonitorKeepAliveService.setUiActive(this, true)
    }

    private fun savedThemeMode(): String = getSharedPreferences(
        "FlutterSharedPreferences",
        Context.MODE_PRIVATE,
    ).getString("flutter.zremote.themeMode", "system") ?: "system"

    private fun savedThemeIsDark(): Boolean {
        return when (savedThemeMode()) {
            "dark" -> true
            "light" -> false
            else -> isSystemDark()
        }
    }

    @Suppress("NewApi")
    private fun syncApplicationNightMode(mode: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        val uiModeManager = getSystemService(UiModeManager::class.java) ?: return
        val requested = when (mode) {
            "dark" -> UiModeManager.MODE_NIGHT_YES
            "light" -> UiModeManager.MODE_NIGHT_NO
            else -> UiModeManager.MODE_NIGHT_AUTO
        }
        try {
            uiModeManager.setApplicationNightMode(requested)
        } catch (_: Exception) {
            // Older Android 12 builds may expose the API but reject an
            // application-level override; the Flutter theme still works.
        }
    }

    private fun applySavedLaunchSurface(dark: Boolean) {
        val background = getColor(
            if (dark) R.color.launch_background_dark
            else R.color.launch_background_light,
        )

        window.setBackgroundDrawable(ColorDrawable(background))
        window.statusBarColor = background
        window.navigationBarColor = background
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.navigationBarDividerColor = background
        }

        var flags = window.decorView.systemUiVisibility
        flags = flags and View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR.inv()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            flags = flags and View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR.inv()
        }
        if (!dark) {
            flags = flags or View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                flags = flags or View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR
            }
        }
        window.decorView.systemUiVisibility = flags
    }

    private fun isSystemDark(): Boolean =
        (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
            Configuration.UI_MODE_NIGHT_YES

    private fun clearLegacyKeepAliveNotification() {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        // v1.0.0 used this fixed foreground-service id. Clear it during the
        // first v1.0.1 launch so an upgrade cannot leave a stale resident row.
        manager.cancel(901)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.deleteNotificationChannel("zr_keep_silent_v3")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "zremote/battery",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isIgnoringBatteryOptimizations" -> result.success(isBatteryIgnored())
                // 厂商 ROM 且未进电池白名单 = 需要引导（v1.3.0 前恒 false，
                // 设置页的红色警示从未生效过）。
                "isVendorBlocked" -> result.success(isVendorRestrictive() && !isBatteryIgnored())
                "requestIgnoreBatteryOptimizations" -> {
                    if (requestBatteryIgnore()) result.success(null)
                    else result.error("battery_ignore_failed", null, null)
                }
                "requestVendorExemption" -> {
                    if (requestVendorExemption()) result.success(null)
                    else result.error("vendor_exemption_failed", null, null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "zremote/app",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "openAppSettings" -> {
                    try {
                        startActivity(
                            Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.parse("package:$packageName"),
                            ),
                        )
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("open_failed", e.message, null)
                    }
                }
                "openNotificationSettings" -> {
                    try {
                        val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                            .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                        startActivity(intent)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("open_failed", e.message, null)
                    }
                }
                "areNotificationsEnabled" -> {
                    val nm = getSystemService(NotificationManager::class.java)
                    result.success(nm?.areNotificationsEnabled() ?: true)
                }
                "androidInfo" -> {
                    val ua = try {
                        android.webkit.WebSettings.getDefaultUserAgent(this)
                    } catch (_: Exception) {
                        ""
                    }
                    val chrome = Regex("Chrome/([0-9.]+)")
                        .find(ua)?.groupValues?.get(1) ?: ""
                    result.success(
                        mapOf(
                            "release" to Build.VERSION.RELEASE,
                            "sdkInt" to Build.VERSION.SDK_INT,
                            "webViewChrome" to chrome,
                        ),
                    )
                }
                "setRecentsCover" -> {
                    recentsCoverEnabled = call.arguments as? Boolean ?: false
                    if (!recentsCoverEnabled) {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "zremote/notification_channels",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "ensureChannels" -> {
                    ensureAlertChannels(call.argument<String>("mode") ?: "sound")
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "zremote/keepalive",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    MonitorKeepAliveService.start(this)
                    result.success(null)
                }
                "update" -> {
                    val name = call.argument<String>("name") ?: ""
                    MonitorKeepAliveService.update(this, name)
                    result.success(null)
                }
                "status" -> {
                    val name = call.argument<String>("name") ?: ""
                    val connected = call.argument<Boolean>("connected") ?: true
                    MonitorKeepAliveService.status(this, name, connected)
                    result.success(null)
                }
                "pushDevices" -> {
                    // UI 引擎推送权威设备清单（v1.6.3）：转发给头无监控引擎。
                    @Suppress("UNCHECKED_CAST")
                    val devices = call.argument<List<Map<String, String>>>("devices")
                        ?: emptyList()
                    MonitorKeepAliveService.pushDevices(devices)
                    result.success(null)
                }
                "stop" -> {
                    MonitorKeepAliveService.stop(this)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "zremote/theme",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setMode" -> {
                    syncApplicationNightMode(call.arguments as? String ?: "system")
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "zremote/notification_sound",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "playDefault" -> {
                    playDefaultNotificationSound()
                    result.success(null)
                }
                "stop" -> {
                    previewRingtone?.stop()
                    previewRingtone = null
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "zremote/update",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path == null || !installApk(path)) {
                        result.error(
                            "install_failed",
                            "Unable to open the Android package installer",
                            null,
                        )
                    } else {
                        result.success(true)
                    }
                }
                "inspectApk" -> {
                    val path = call.argument<String>("path")
                    val info = path?.let { inspectApk(it) }
                    if (info == null) {
                        result.error(
                            "inspect_failed",
                            "Unable to read the Android package",
                            null,
                        )
                    } else {
                        result.success(info)
                    }
                }
                "installedSignerSha256" -> result.success(installedSignerSha256())
                "canRequestInstall" -> result.success(canRequestPackageInstalls())
                "requestInstallPermission" -> {
                    if (requestUnknownSourceSettings()) result.success(null)
                    else {
                        result.error(
                            "open_failed",
                            "Unable to open install-permission settings",
                            null,
                        )
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * 预建告警渠道（v1.2.2，对齐 DeepSeek-Harness 的"通知类别"形态）：
     * 渠道定义已抽出 NotificationChannels（v1.3.1）——UI 引擎与头无监控
     * 引擎两侧必须产出完全一致的渠道集。
     */
    private fun ensureAlertChannels(mode: String) {
        NotificationChannels.ensure(this, mode)
    }

    private fun installApk(path: String): Boolean {
        val apk = File(path)
        if (!apk.exists() || !apk.isFile) return false
        return try {
            val uri = FileProvider.getUriForFile(
                this,
                "${applicationContext.packageName}.fileprovider",
                apk,
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    // 应用内更新的安装前预校验：读 APK 归档元数据（包名 + versionCode + 签名
    // 证书），Dart 侧据此在人话界面里拦下"无法降级安装(-25)"、签名不符之类
    // 的错误，而不是让系统安装器弹裸错误。
    private fun inspectApk(path: String): Map<String, Any?>? = try {
        val pm = packageManager
        val api28 = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P
        val flags =
            if (api28) PackageManager.GET_SIGNING_CERTIFICATES
            else @Suppress("DEPRECATION") PackageManager.GET_SIGNATURES
        val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.getPackageArchiveInfo(
                path,
                PackageManager.PackageInfoFlags.of(flags.toLong()),
            )
        } else {
            @Suppress("DEPRECATION")
            pm.getPackageArchiveInfo(path, flags)
        }
        info?.let {
            mapOf(
                "packageName" to it.packageName,
                "versionName" to it.versionName,
                // longVersionCode 需要 API 28+；minSdk 24 的低版本设备退回旧字段，
                // 否则 Android 8.1 及以下在预校验时抛 NoSuchMethodError。
                "versionCode" to if (api28) {
                    it.longVersionCode
                } else {
                    @Suppress("DEPRECATION")
                    it.versionCode.toLong()
                },
                "signerSha256" to signerSha256Of(
                    if (api28) it.signingInfo?.apkContentsSigners
                    else @Suppress("DEPRECATION") it.signatures,
                ),
            )
        }
    } catch (_: Exception) {
        null
    }

    // 已安装应用自身的签名证书 SHA256，供 Dart 侧与下载包比对（U3）。
    private fun installedSignerSha256(): String? = try {
        val pm = packageManager
        val api28 = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P
        val flags =
            if (api28) PackageManager.GET_SIGNING_CERTIFICATES
            else @Suppress("DEPRECATION") PackageManager.GET_SIGNATURES
        val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.getPackageInfo(
                packageName,
                PackageManager.PackageInfoFlags.of(flags.toLong()),
            )
        } else {
            @Suppress("DEPRECATION")
            pm.getPackageInfo(packageName, flags)
        }
        signerSha256Of(
            if (api28) info.signingInfo?.apkContentsSigners
            else @Suppress("DEPRECATION") info.signatures,
        )
    } catch (_: Exception) {
        null
    }

    private fun signerSha256Of(signers: Array<Signature>?): String? {
        val first = signers?.firstOrNull() ?: return null
        return try {
            MessageDigest.getInstance("SHA-256")
                .digest(first.toByteArray())
                .joinToString("") { "%02x".format(it) }
        } catch (_: Exception) {
            null
        }
    }

    private fun canRequestPackageInstalls(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            packageManager.canRequestPackageInstalls()
        } else true

    private fun requestUnknownSourceSettings(): Boolean = try {
        startActivity(
            Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName"),
            ),
        )
        true
    } catch (_: Exception) {
        false
    }

    private fun playDefaultNotificationSound() {
        previewRingtone?.stop()
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
        previewRingtone = uri?.let { RingtoneManager.getRingtone(this, it) }?.also {
            // The preview is an in-app notification, not a phone-call ring.
            // Keep the same system URI while routing it through the
            // notification stream, so a muted ringtone stream cannot make an
            // in-app alert appear silent on tablets.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                it.audioAttributes = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            }
        }
        previewRingtone?.play()
    }

    private fun isBatteryIgnored(): Boolean =
        (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .isIgnoringBatteryOptimizations(packageName)

    // v1.3.0：真实厂商检测。这些 ROM 对后台进程/自启动有额外限制，
    // 白名单之外时常驻服务会被静默回收——设置页据此把保活入口染红并
    // 直接跳厂商专属页面，而不是让用户对着标准 Android 白名单以为万事大吉。
    private fun isVendorRestrictive(): Boolean {
        val manufacturer = Build.MANUFACTURER.lowercase().replace("\\s".toRegex(), "")
        return manufacturer in setOf(
            "xiaomi", "redmi", "poco",        // MIUI / HyperOS
            "huawei",                         // EMUI / HarmonyOS
            "honor",                          // Magic OS
            "oppo", "realme", "oneplus",      // ColorOS
            "vivo", "iqoo",                   // OriginOS / FuntouchOS
            "meizu",                          // Flyme
            "samsung",                        // One UI 的休眠应用
        )
    }

    private fun requestBatteryIgnore(): Boolean = try {
        startActivity(
            Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:$packageName"),
            ),
        )
        true
    } catch (e: Exception) {
        false
    }

    private fun requestVendorExemption(): Boolean {
        // 候选按厂商分组，命中哪个厂商就先试哪组；所有组件名来自各 ROM 的
        // 公开设置页，缺失/改名时逐个回退，最终兜底应用详情页。
        val manufacturer = Build.MANUFACTURER.lowercase()
        val candidates = mutableListOf<Intent>()
        when {
            manufacturer.contains("xiaomi") || manufacturer.contains("redmi") ||
                manufacturer.contains("poco") -> {
                candidates += listOf(
                    Intent().setClassName(
                        "com.miui.powerkeeper",
                        "com.miui.powerkeeper.powersettings.PowerSettingsActivity",
                    ),
                    Intent().setClassName(
                        "com.miui.powerkeeper",
                        "com.miui.powerkeeper.ui.HiddenAppsConfigActivity",
                    )
                        .putExtra("package_name", packageName)
                        .putExtra("power_keeper_activity", "PowerKeeperActivityCustom"),
                    Intent().setClassName(
                        "com.miui.securitycenter",
                        "com.miui.permcenter.autostart.AutoStartManagementActivity",
                    ),
                )
            }
            manufacturer.contains("huawei") || manufacturer.contains("honor") -> {
                candidates += listOf(
                    Intent().setClassName(
                        "com.huawei.systemmanager",
                        "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
                    ),
                    Intent().setClassName(
                        "com.huawei.systemmanager",
                        "com.huawei.systemmanager.optimize.process.ProtectActivity",
                    ),
                    Intent().setClassName(
                        "com.huawei.systemmanager",
                        "com.huawei.systemmanager.appcontrol.activity.StartupAppControlActivity",
                    ),
                )
            }
            manufacturer.contains("oppo") || manufacturer.contains("realme") ||
                manufacturer.contains("oneplus") -> {
                candidates += listOf(
                    Intent().setClassName(
                        "com.coloros.safecenter",
                        "com.coloros.safecenter.permission.startup.StartupAppListActivity",
                    ),
                    Intent().setClassName(
                        "com.coloros.safecenter",
                        "com.coloros.safecenter.startupapp.StartupAppListActivity",
                    ),
                    Intent().setClassName(
                        "com.oplus.battery",
                        "com.oplus.battery.OplusBatteryActivity",
                    ),
                )
            }
            manufacturer.contains("vivo") || manufacturer.contains("iqoo") -> {
                candidates += listOf(
                    Intent().setClassName(
                        "com.iqoo.secure",
                        "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager",
                    ),
                    Intent().setClassName(
                        "com.iqoo.secure",
                        "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity",
                    ),
                )
            }
            manufacturer.contains("meizu") -> {
                candidates += Intent().setClassName(
                    "com.meizu.safe",
                    "com.meizu.safe.security.SHOW_APPSEC",
                ).putExtra("packageName", packageName)
            }
            else -> {
                // 三星等：直接进应用详情页，让用户手动关"让应用休眠"。
            }
        }
        for (intent in candidates) {
            try {
                startActivity(intent)
                return true
            } catch (_: Exception) {
                // Try the next vendor-specific settings screen.
            }
        }
        return try {
            startActivity(
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:$packageName"),
                ),
            )
            true
        } catch (_: Exception) {
            false
        }
    }
}
