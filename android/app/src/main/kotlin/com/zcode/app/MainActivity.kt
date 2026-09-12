package com.zcode.app

import android.app.NotificationManager
import android.app.UiModeManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
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
import androidx.core.content.FileProvider
import java.io.File
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
        // Stop the v1.0.0 foreground service if an older install had enabled
        // it. v1.0.1 no longer declares or starts that service, so no
        // background "ZCode running" notification can remain behind.
        stopService(Intent(this, KeepAliveService::class.java))
        clearLegacyKeepAliveNotification()
        super.onCreate(savedInstanceState)
        // FlutterActivity switches LaunchTheme to NormalTheme inside super.
        // Re-apply the saved surface after that switch and before the first
        // Flutter frame is visible.
        applySavedLaunchSurface(dark)
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
            "zremote/keepalive",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    stopService(Intent(this, KeepAliveService::class.java))
                    result.success(null)
                }
                "stop" -> {
                    stopService(Intent(this, KeepAliveService::class.java))
                    result.success(null)
                }
                "isRunning" -> result.success(false)
                "isBlocked" -> result.success(false)
                "isBatteryIgnored" -> result.success(isBatteryIgnored())
                "requestBatteryIgnore" -> {
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
                else -> result.notImplemented()
            }
        }
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

    // 应用内更新的安装前预校验：读 APK 归档元数据（包名 + versionCode），
    // Dart 侧据此在人话界面里拦下"无法降级安装(-25)"之类的系统错误。
    private fun inspectApk(path: String): Map<String, Any?>? = try {
        val pm = packageManager
        val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.getPackageArchiveInfo(path, PackageManager.PackageInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            pm.getPackageArchiveInfo(path, 0)
        }
        info?.let {
            mapOf(
                "packageName" to it.packageName,
                "versionName" to it.versionName,
                // longVersionCode 需要 API 28+；minSdk 24 的低版本设备退回旧字段，
                // 否则 Android 8.1 及以下在预校验时抛 NoSuchMethodError。
                "versionCode" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    it.longVersionCode
                } else {
                    @Suppress("DEPRECATION")
                    it.versionCode.toLong()
                },
            )
        }
    } catch (_: Exception) {
        null
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
        val miuiCandidates = listOf(
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
        for (intent in miuiCandidates) {
            try {
                startActivity(intent)
                return true
            } catch (e: Exception) {
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
        } catch (e: Exception) {
            false
        }
    }
}
