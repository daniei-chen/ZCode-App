/// 观察面变化自动告警（W-005，MASTER_PLAN"下一阶段"）。
///
/// 上游协议是私有实测（`RELAY-PROTOCOL-VERIFIED.md`），官方页改版会让观察面
/// 静默失效。遥测计数（F18 白名单）已能**事后**发现变化，这里把"发现"变成
/// 诊断页/诊断包上的显式提示。纯函数、无 IO、无状态：
/// * 输入只有计数（`BridgeSchema.acceptStats` 白名单键 + iter1 合并进来的
///   `subFrame*` 三键）与 Dart 侧桥丢弃计数；
/// * 输出只有枚举码 + 触发计数——诊断红线：不出现 URL/host/正文/凭证；
/// * 对敌对输入（负数、超上限、缺键、非白名单键）绝不抛，负数按 0、缺键按 0、
///   未知键忽略——页面能操纵的只是"是否触发"，触发本身就是它想隐藏的信号。
library;

import 'bridge_schema.dart';

/// 告警码：`OB2xx` 段与结构化日志码风格一致，便于在 Issue 里 grep。
enum ObserverAlertCode {
  /// 官方页出现 SSE 通道（实测协议"4 REST + 2 WS，无 SSE"被打破）。
  sseAppeared('OB201'),

  /// WebSocket 白名单未命中率高（未命中数 ≥ [ObserverAlertPolicy.missSampleFloor]
  /// 且占比 >50%）。
  wsMissHigh('OB202'),

  /// fetch 白名单未命中率高。
  fetchMissHigh('OB203'),

  /// 分片重组异常（无效/过期分片累计达阈值）。
  fragmentAnomaly('OB204'),

  /// 预算丢弃（队列/已见集合被迫丢弃）。
  budgetDrop('OB205'),

  /// Dart 侧桥消息丢弃（类型/长度不符）——应用级，不分设备。
  bridgeDrop('OB206'),

  /// 非官方 origin 子 frame 导航被拦截（ADR-002 取证信号）。
  subFrameBlocked('OB207');

  const ObserverAlertCode(this.code);

  final String code;
}

/// 一条告警：码 + 触发它的计数值（只有数字）。
class ObserverAlert {
  const ObserverAlert(this.code, this.value);

  final ObserverAlertCode code;

  /// 触发计数（未命中数 / 异常分片数 / 丢弃数 …），供诊断页展示与断言。
  final int value;

  @override
  bool operator ==(Object other) =>
      other is ObserverAlert && other.code == code && other.value == value;

  @override
  int get hashCode => Object.hash(code, value);

  @override
  String toString() => '${code.code}:$value';
}

abstract final class ObserverAlertPolicy {
  /// 未命中数地板：未命中少于此数时不看占比（页面刚加载时前几条几乎必然
  /// 是未命中，占比没有意义）。地板作用在**未命中数**上，不是总样本。
  static const int missSampleFloor = 20;

  /// 分片异常累计阈值。
  static const int fragmentAnomalyFloor = 5;

  /// 策略消费的计数键。白名单（`BridgeSchema.statsKeys`）或子 frame 三键
  /// 新增时必须在这里做一次有意识的决定：要么消费，要么写进 [ignoredKeys]
  /// ——测试钉住"两集合不交且并集恰好等于全部已知键"，漏掉即红。
  static const Set<String> consumedKeys = {
    'sseIgnored',
    'wsIgnored',
    'wsMessages',
    'fetchSkipped',
    'fetch200',
    'invalidFragments',
    'expiredFragments',
    'queueDropped',
    'seenDropped',
    'subFrameCancelled',
  };

  /// 有意不参与告警的键：字节量、成功/解码计数、子 frame 总数与放行数
  /// 是"量"不是"异常"，只在诊断页原样展示。framesDecoded/fetchCloned
  /// 虽在本集合，但会作为 W-014 分母封顶的上限被读取——它们不产生
  /// 独立告警，故不迁入 consumedKeys。
  ///
  /// `sseMessages` 是占位键（iter12 N-P2-1）：JS 观测面对 SSE 只计
  /// `sseIgnored`、从不 bump `sseMessages`，留在 consumedKeys 会误导
  /// 维护者以为它是活输入；OB201 触发值仍是两者之和（evaluate 的 at()
  /// 依旧读它），将来接入真实 SSE 计数时再迁回。
  static const Set<String> ignoredKeys = {
    'fetchCloned',
    'wsSkippedSize',
    'fetchSkippedSize',
    'framesDecoded',
    'subFrameTotal',
    'subFrameAllowed',
    'sseMessages',
  };

  /// 对单台设备的计数求告警。[counters] 可以含任意键；只读白名单键。
  ///
  /// 未命中率用整数比较 `miss * 2 > total`（>50%），避免浮点与除零。
  /// 取值钳在 `[0, BridgeSchema.maxStatValue]`：遥测通道本就按此上限过滤，
  /// 这里再钳一次，使 `miss * 2` 这类乘法对任何调用方输入都不会溢出。
  static List<ObserverAlert> evaluate(Map<String, int> counters) {
    int at(String key) {
      final value = counters[key];
      if (value == null || value < 0) return 0;
      return value > BridgeSchema.maxStatValue ? BridgeSchema.maxStatValue : value;
    }

    /// 命中数封顶（W-014）：cap<=0 表示封顶计数缺席，退回原始值（不收紧）。
    int cappedHits(int hits, int cap) => cap <= 0 ? hits : (hits > cap ? cap : hits);

    final alerts = <ObserverAlert>[];

    final sse = at('sseMessages') + at('sseIgnored');
    if (sse > 0) alerts.add(ObserverAlert(ObserverAlertCode.sseAppeared, sse));

    final wsMiss = at('wsIgnored');
    // 分母抗伪造（W-014，如实表述）：wsMessages 被灌大来稀释未命中占比是
    // 最廉价的伪造路径，用 framesDecoded（钩子实际解码帧数）作命中数上限
    // 堵住它。**防的是不经脑的灌大**：页面理论上可同帧伪造 framesDecoded
    // 或直接清零 wsIgnored——对抗这类主动伪造超出计数层，触发本身即信号。
    // framesDecoded 缺席（0）时退回旧行为，不引入新告警面；cap 绑定时阈值
    // 语义从"miss > 50% 总量"变为"miss > framesDecoded"（min 只减不增，
    // 不会漏报真实高未命中，只可能更敏感——iter11 复核 F-6）。
    final wsHits = cappedHits(at('wsMessages'), at('framesDecoded'));
    final wsTotal = wsMiss + wsHits;
    if (wsMiss >= missSampleFloor && wsMiss * 2 > wsTotal) {
      alerts.add(ObserverAlert(ObserverAlertCode.wsMissHigh, wsMiss));
    }

    final fetchMiss = at('fetchSkipped');
    // 同口径：fetch200 虚报用 fetchCloned（真正被读取过的响应数）封顶。
    final fetchHits = cappedHits(at('fetch200'), at('fetchCloned'));
    final fetchTotal = fetchMiss + fetchHits;
    if (fetchMiss >= missSampleFloor && fetchMiss * 2 > fetchTotal) {
      alerts.add(ObserverAlert(ObserverAlertCode.fetchMissHigh, fetchMiss));
    }

    final fragments = at('invalidFragments') + at('expiredFragments');
    if (fragments >= fragmentAnomalyFloor) {
      alerts.add(ObserverAlert(ObserverAlertCode.fragmentAnomaly, fragments));
    }

    final drops = at('queueDropped') + at('seenDropped');
    if (drops > 0) alerts.add(ObserverAlert(ObserverAlertCode.budgetDrop, drops));

    final cancelled = at('subFrameCancelled');
    if (cancelled > 0) {
      alerts.add(ObserverAlert(ObserverAlertCode.subFrameBlocked, cancelled));
    }

    return List.unmodifiable(alerts);
  }

  /// 应用级告警（不分设备）：Dart 侧桥消息丢弃计数。
  static List<ObserverAlert> evaluateApp({required int droppedMessages}) {
    if (droppedMessages <= 0) return const [];
    return List.unmodifiable([
      ObserverAlert(ObserverAlertCode.bridgeDrop, droppedMessages),
    ]);
  }

  /// 诊断包用：只把码拼成一行（`OB201,OB204`），空则 `none`。
  static String codesLine(Iterable<ObserverAlert> alerts) {
    final codes = [for (final alert in alerts) alert.code.code];
    return codes.isEmpty ? 'none' : codes.join(',');
  }
}
