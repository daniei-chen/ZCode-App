package com.zcode.app

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.drawable.ColorDrawable
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.Uri
import android.os.Bundle
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.view.View
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {

    private var previewRingtone: Ringtone? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // Flutter's NormalTheme is selected from Android's system night
        // resources. Read the app-owned preference before that hand-off so a
        // saved "日间"/"夜间" choice does not flash through the opposite color.
        val dark = savedThemeIsDark()
        applySavedSplashTheme(dark)
        applySavedLaunchSurface(dark)
        super.onCreate(savedInstanceState)
        // FlutterActivity switches LaunchTheme to NormalTheme inside super.
        // Re-apply the saved surface after that switch and before the first
        // Flutter frame is visible.
        applySavedLaunchSurface(dark)
    }

    private fun savedThemeIsDark(): Boolean {
        val mode = getSharedPreferences(
            "FlutterSharedPreferences",
            Context.MODE_PRIVATE,
        ).getString("flutter.zremote.themeMode", "system")
        return when (mode) {
            "dark" -> true
            "light" -> false
            else -> isSystemDark()
        }
    }

    @Suppress("NewApi")
    private fun applySavedSplashTheme(dark: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        // Android 12 creates a separate system splash surface before the
        // Activity window. Select its light/dark theme from the same saved
        // preference so it does not briefly use the system's opposite mode.
        getSplashScreen().setSplashScreenTheme(
            if (dark) R.style.SavedDarkSplashTheme
            else R.style.SavedLightSplashTheme,
        )
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "zremote/keepalive",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    try {
                        KeepAliveService.start(this)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("start_failed", e.message, null)
                    }
                }
                "stop" -> {
                    stopService(Intent(this, KeepAliveService::class.java))
                    result.success(null)
                }
                "isRunning" -> result.success(KeepAliveService.isRunning)
                "isBlocked" -> result.success(KeepAliveService.lastStartBlocked)
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
            "zremote/notification_sound",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "list" -> result.success(notificationSoundOptions())
                "play" -> {
                    playNotificationSound(call.arguments as? String)
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
    }

    private fun notificationSoundOptions(): List<Map<String, String>> {
        val options = mutableListOf<Map<String, String>>()
        options += mapOf("id" to "default", "title" to "系统默认", "uri" to "")

        val manager = RingtoneManager(this).apply {
            setType(RingtoneManager.TYPE_NOTIFICATION)
        }
        val cursor = manager.cursor
        val defaultUri = RingtoneManager
            .getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            ?.toString()
        try {
            while (cursor.moveToNext() && options.size < 6) {
                val uri = manager.getRingtoneUri(cursor.position)?.toString() ?: continue
                if (uri == defaultUri || options.any { it["uri"] == uri }) continue
                val title = try {
                    cursor.getString(RingtoneManager.TITLE_COLUMN_INDEX)
                } catch (_: Exception) {
                    null
                }?.trim().orEmpty()
                if (title.isEmpty()) continue
                options += mapOf(
                    "id" to "system_${uri.hashCode().toUInt().toString(16)}",
                    "title" to title,
                    "uri" to uri,
                )
            }
        } finally {
            cursor.close()
        }
        return options
    }

    private fun playNotificationSound(uriString: String?) {
        previewRingtone?.stop()
        val uri = uriString
            ?.takeIf { it.isNotBlank() }
            ?.let(Uri::parse)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
        previewRingtone = uri?.let { RingtoneManager.getRingtone(this, it) }
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
