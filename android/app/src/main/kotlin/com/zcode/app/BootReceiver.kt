package com.zcode.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 开机自启（v1.3.0）：系统启动完成后拉起常驻监控前台服务，让"重启手机后
 * 忘了开 App"不再成为通知断档的原因。服务本身只保活进程、无业务逻辑
 * （K1 边界不变）；设备名/连接状态由 Dart 侧启动后推送。
 *
 * ROM 说明：MIUI/华为等的"自启动"权限仍需用户在系统设置里放行一次
 * （设置页的保活引导负责这一步）；本接收器只覆盖标准 Android 行为。
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_LOCKED_BOOT_COMPLETED &&
            action != "android.intent.action.QUICKBOOT_POWERON"
        ) {
            return
        }
        try {
            MonitorKeepAliveService.start(context)
        } catch (_: Exception) {
            // 个别 ROM 拒绝开机拉起前台服务：静默放弃，用户打开 App 后恢复。
        }
    }
}
