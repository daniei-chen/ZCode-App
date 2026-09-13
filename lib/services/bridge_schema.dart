import 'dart:convert';

import 'event_observer.dart';

/// Bridge 消息 schema 与尺寸门禁（v1.1.0）。
///
/// `_bridgeAllowed()` 解决"哪个页面可以调用 bridge"；这里解决"页面可以传
/// 什么"：每个 handler 在进入业务逻辑前先过类型与长度校验，超限/类型不符
/// 一律丢弃并计数，绝不进入解析路径。
/// 桥调用来源策略（F03）。
///
/// 原生桥对象对所有 frame 可见，而 `getUrl()` 只能看到顶层文档——仅凭 URL
/// 无法证明这条消息是主 frame 发的。Dart 会用 `evaluateJavascript`（只在主
/// frame 执行）注入一个每代随机令牌，钩子每条消息都带上它；跨域子 frame
/// 读不到主 frame 的变量，因此无法伪造。
abstract final class BridgeAuthPolicy {
  static bool tokenMatches(Object? provided, String? expected) {
    if (expected == null || expected.isEmpty) return false;
    return provided is String && provided.isNotEmpty && provided == expected;
  }
}

abstract final class BridgeSchema {
  static const int maxThemeBytes = 256;
  static const int maxViewStateBytes = 64 * 1024;
  static const int maxSeenBytes = 512 * 1024;
  static const int maxEventBytes = 4 * 1024 * 1024;
  static const int maxWsEventBytes = 4 * 1024 * 1024;
  static const int maxStatsKeys = 32;

  /// 跳转结果回执（F12）：只是一次确认，超过 2 KiB 说明不是本应用的消息。
  static const int maxJumpBytes = 2 * 1024;

  /// 遥测 JSON 的解析前上限（8 KiB 足够；超限在 jsonDecode 之前丢弃）。
  static const int maxStatsChars = 8 * 1024;

  /// 遥测允许的计数键白名单（F18）：与 `EventObserver.hookScript` 里的
  /// `window.__zrStats` 初始字段一一对应。白名单之外一律丢弃——页面不应通过
  /// 遥测通道把任意字符串塞进诊断页。
  static const Set<String> statsKeys = {
    'fetch200',
    'fetchCloned',
    'fetchSkipped',
    'sseMessages',
    'sseIgnored',
    'wsMessages',
    'wsIgnored',
    'wsSkippedSize',
    'fetchSkippedSize',
    'framesDecoded',
    'invalidFragments',
    'expiredFragments',
    'queueDropped',
    'seenDropped',
  };

  /// 单个计数的合理上限：超过说明是伪造/溢出，直接丢弃该键。
  static const int maxStatValue = 1 << 40;

  /// Dart 侧桥消息丢弃计数（类型不符/超长），诊断页可见。
  static int droppedMessages = 0;

  /// 只接受非空且不超长的字符串；类型不符或超长计入丢弃。
  ///
  /// 先做字符数硬上限（避免为超大字符串复制等长字节数组），再按**真实
  /// UTF-8 字节数**判定——`String.length` 是 UTF-16 code unit，不是字节数，
  /// 直接拿它当 Bytes 会让中文/emoji 内容实际超过预算（F04）。
  static String? acceptString(Object? body, {required int maxBytes}) {
    if (body is! String) {
      droppedMessages++;
      return null;
    }
    if (body.isEmpty) return null;
    if (body.length > maxBytes) {
      droppedMessages++;
      return null;
    }
    if (utf8.encode(body).length > maxBytes) {
      droppedMessages++;
      return null;
    }
    return body;
  }

  /// 遥测计数只接受 `Map<String, 非负有限数字>`（F18）：
  /// * 键必须在 [statsKeys] 白名单内（页面不能借遥测通道塞任意字符串）；
  /// * 值必须是有限数（NaN/Infinity 会让 `toInt()` 抛错，旧实现被 catch 吞掉）；
  /// * 值必须是整数、非负、不超过 [maxStatValue]；
  /// * 键数封顶；全部非法时返回 null。
  static Map<String, int>? acceptStats(Object? decoded) {
    if (decoded is! Map) {
      droppedMessages++;
      return null;
    }
    final out = <String, int>{};
    var keys = 0;
    for (final e in decoded.entries) {
      final k = e.key;
      final v = e.value;
      if (k is! String || !statsKeys.contains(k)) continue;
      if (v is! num || !v.isFinite) continue;
      final value = v.toInt();
      if (value < 0 || value > maxStatValue) continue;
      out[k] = value;
      if (++keys >= maxStatsKeys) break;
    }
    return out.isEmpty ? null : out;
  }

  /// 保持事件字节上限与 JS 钩子一致（不同步会被本测试文件锁住）。
  static bool get eventCapMatchesHook => maxEventBytes == kMaxListenBytes;
}
