package com.zcode.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context

/**
 * 告警/状态/常驻渠道的统一定义（v1.3.1 自 MainActivity 抽出）：
 * MainActivity（UI 引擎）与 MonitorKeepAliveService（头无监控引擎）都会
 * 收到 ensureChannels 调用，两侧必须产出完全一致的渠道集。
 */
object NotificationChannels {
    const val CONN_CHANNEL = "zr_conn_v8"
    const val KEEP_MONITOR_CHANNEL = "zr_keep_monitor_v8"

    fun ensure(context: Context, mode: String) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val defs = listOf(
            Triple("zr_perm_alert_v7", "需要你的操作", NotificationManager.IMPORTANCE_HIGH),
            Triple("zr_fail_alert_v7", "失败", NotificationManager.IMPORTANCE_HIGH),
            Triple("zr_done_alert_v7", "完成通知", NotificationManager.IMPORTANCE_HIGH),
        )
        val keep = mutableSetOf(KEEP_MONITOR_CHANNEL, CONN_CHANNEL)
        for ((base, name, importance) in defs) {
            val id = "${base}_$mode"
            keep.add(id)
            manager.createNotificationChannel(
                NotificationChannel(id, name, importance).apply { setShowBadge(true) },
            )
        }
        // 连接状态（v1.3.0）：断连/恢复通知走静默低优先级渠道，不随提醒方式变化。
        manager.createNotificationChannel(
            NotificationChannel(
                CONN_CHANNEL,
                "连接状态",
                NotificationManager.IMPORTANCE_LOW,
            ).apply { setShowBadge(false) },
        )
        for (channel in manager.notificationChannels) {
            if (channel.id.startsWith("zr_") && channel.id !in keep) {
                manager.deleteNotificationChannel(channel.id)
            }
        }
    }
}
