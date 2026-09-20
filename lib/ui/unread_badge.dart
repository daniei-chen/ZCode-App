import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/device_label.dart'; // l10nZh 兜底（本地化未就绪时）
import '../state/event_feed.dart';
import '../theme.dart';

/// 未读计数徽标 + 「待批准」常显红点（iter14 W-032）。
///
/// 两个信号的语义必须分离：
/// - 未读数（unread）是"看过就清"的提醒量——打开设备即 markRead；
/// - 待批准（permPending）是**权威状态**（pendingByTask 按剩余计数记账），
///   不因"看过"消失，只在任务真正解决时落下。
///
/// 旧实现 unread<=0 时整个徽标隐身——打开设备后仍在等待的审批红点被
/// 一并抹掉（前台又无系统通知，用户再也看不到"有东西在等"）。现在：
/// 有未读 → 计数徽标；仅剩待批准 → 红点常显（无数字）；都没有 → 不渲染。
class UnreadBadge extends StatelessWidget {
  const UnreadBadge({super.key, required this.feed});

  final DeviceFeed? feed;

  @override
  Widget build(BuildContext context) {
    final unread = feed?.unread ?? 0;
    final alert = feed?.permPending ?? false;
    if (unread <= 0) {
      if (!alert) return const SizedBox.shrink();
      // 仅剩待批准：常显红点（无数字）——"有东西在等你"不随已读消失。
      final l10n = AppLocalizations.of(context) ?? l10nZh;
      return Semantics(
        label: l10n.badgePendingApproval,
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: context.zt.danger,
            shape: BoxShape.circle,
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: alert ? context.zt.danger : context.zt.accent,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        unread >= 99 ? '99+' : '$unread',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          color: alert ? Colors.white : context.zt.onAccent,
        ),
      ),
    );
  }
}
