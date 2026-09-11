import 'dart:convert';

import 'relay_frame.dart';

/// 组装器对外产出。
sealed class AssemblyOutcome {
  const AssemblyOutcome();
}

/// 还缺分片，继续等。
class AssemblyIncomplete extends AssemblyOutcome {
  const AssemblyIncomplete();
}

/// 重传的重复消息（seq 不大于已交付的最大值）。已回 ack 后桌面端仍可能补发。
class AssemblyDuplicate extends AssemblyOutcome {
  const AssemblyDuplicate();
}

/// 组装出一条完整逻辑消息。
///
/// 同时保留**原始字节**与 UTF-8 文本：负载可能是 JSON（任务列表那类），
/// 也可能是二进制 agentService RPC（会话正文那类）。只留文本会把后者毁掉。
class AssemblyMessage extends AssemblyOutcome {
  AssemblyMessage({
    required this.bytes,
    required this.identity,
    this.messageSeq,
  }) : text = utf8.decode(bytes, allowMalformed: true);

  final List<int> bytes;
  final String text;
  final RelayIdentity identity;
  final int? messageSeq;
}

/// 收到 ack。
class AssemblyAck extends AssemblyOutcome {
  const AssemblyAck({required this.ackMessageSeq, required this.identity});

  final int? ackMessageSeq;
  final RelayIdentity identity;
}

/// 传输故障（对应协议里的 `bridge-degraded`）。
class AssemblyFault extends AssemblyOutcome {
  const AssemblyFault({
    required this.reason,
    this.seq,
    this.expectedSeq,
    this.droppedCount,
  });

  final String reason;
  final int? seq;
  final int? expectedSeq;
  final int? droppedCount;
}

/// 降级原因字面量，与桌面端枚举一致。
abstract final class RpcFaultReason {
  static const String transportFault = 'rpc-transport-fault';
  static const String frameGap = 'rpc-frame-gap';
  static const String bufferOverflow = 'buffer-overflow';
  static const String bufferTimeout = 'buffer-timeout';
  static const String checksumMismatch = 'checksum-mismatch';
}

class _Slot {
  _Slot({
    required this.total,
    required this.identity,
    required this.at,
    this.messageBytes,
    this.checksum,
  });

  final int total;
  final RelayIdentity identity;
  final int at;
  final int? messageBytes;
  String? checksum;
  final Map<int, List<int>> parts = {};
  int bytes = 0;

  int get got => parts.length;

  bool complete() => parts.length == total;
}

/// `rpc-frame` 分片重组。
///
/// 与上游实现对齐的要点：
/// - 第一条帧锁定 `RelayIdentity`，身份不一致的帧直接拒绝
/// - 单物理帧 ≤ 1 MiB、单逻辑消息 ≤ 16 MiB、单消息 ≤ 64 分片
/// - 槽位超时 30s 自动清理并报 `buffer-timeout`
/// - `messageSeq` 出现跳变时报 `rpc-frame-gap`
class RpcAssembler {
  RpcAssembler({int Function()? clock}) : _clock = clock ?? _defaultClock;

  static int _defaultClock() => DateTime.now().millisecondsSinceEpoch;

  /// 分片帧缺 `seq` 时的兜底槽位键。
  static const int _noSeqKey = -1;

  final int Function() _clock;

  RelayIdentity? _identity;
  final Map<int, _Slot> _slots = {};
  int? _lastSeq;

  /// 已交付的最大消息序号，用于丢弃重传。
  int? _deliveredSeq;

  RelayIdentity? get identity => _identity;

  /// 已锁定的身份是否与给定帧一致；未锁定时会自动锁定。
  bool _acceptIdentity(RelayIdentity incoming) {
    final cur = _identity;
    if (cur == null || cur.isEmpty) {
      _identity = incoming;
      return true;
    }
    return cur.matches(incoming);
  }

  void reset() {
    _identity = null;
    _slots.clear();
    _lastSeq = null;
    _deliveredSeq = null;
  }

  /// 该 seq 是否已经交付过（重传）。
  bool _isDuplicate(int? seq) {
    if (seq == null) return false;
    final done = _deliveredSeq;
    return done != null && seq <= done;
  }

  void _markDelivered(int? seq) {
    if (seq == null) return;
    final done = _deliveredSeq;
    if (done == null || seq > done) _deliveredSeq = seq;
  }

  Map<int, _Slot> get _openSlots => _slots;

  AssemblyOutcome accept(RpcFrame frame) {
    _evictStale();

    if (!_acceptIdentity(frame.identity)) {
      return const AssemblyFault(reason: RpcFaultReason.transportFault);
    }

    if (frame.isAck) {
      return AssemblyAck(
        ackMessageSeq: frame.ackMessageSeq,
        identity: frame.identity,
      );
    }

    if (frame.checksumAlgorithm != null &&
        frame.checksumAlgorithm!.toLowerCase() != 'crc32') {
      return const AssemblyFault(reason: RpcFaultReason.transportFault);
    }

    final seq = frame.messageSeq ?? frame.seq;
    final gap = _checkGap(seq);
    if (gap != null) return gap;

    // 重传：已交付过的消息直接丢弃，且不要污染槽位。
    if (_isDuplicate(seq)) return const AssemblyDuplicate();

    // 单帧消息：直接产出。
    if (frame.fragmentCount <= 1) {
      final bytes = WireBase64.tryDecode(frame.dataBase64 ?? '');
      if (bytes == null || bytes.isEmpty) {
        return const AssemblyFault(reason: RpcFaultReason.transportFault);
      }
      if (bytes.length > RelayLimits.maxPhysicalFrameBytes ||
          (frame.messageBytes != null && frame.messageBytes != bytes.length)) {
        return AssemblyFault(reason: RpcFaultReason.bufferOverflow, seq: seq);
      }
      if (!_checksumMatches(frame.checksum, bytes)) {
        return AssemblyFault(reason: RpcFaultReason.checksumMismatch, seq: seq);
      }
      _markDelivered(seq);
      return AssemblyMessage(
        bytes: bytes,
        identity: frame.identity,
        messageSeq: seq,
      );
    }

    // 逻辑帧 id 必须跨分片稳定。协议里 `seq`(=`messageSeq`) 就是逻辑消息序号，
    // 同一条消息的所有分片共用它。真机上分片帧一定带 seq；
    // 万一缺失，退回同一个兜底槽位，避免各分片被当成独立消息。
    final key = seq ?? _noSeqKey;
    var slot = _slots[key];
    if (slot == null || slot.total != frame.fragmentCount) {
      if (slot != null) _slots.remove(key);
      slot = _Slot(
        total: frame.fragmentCount,
        identity: frame.identity,
        at: _clock(),
        messageBytes: frame.messageBytes,
        checksum: frame.checksum,
      );
      _slots[key] = slot;
    }

    if (frame.messageBytes != null &&
        slot.messageBytes != null &&
        frame.messageBytes != slot.messageBytes) {
      _slots.remove(key);
      return AssemblyFault(reason: RpcFaultReason.transportFault, seq: seq);
    }
    if (frame.checksum != null) {
      if (slot.checksum != null &&
          _normalizeChecksum(slot.checksum) !=
              _normalizeChecksum(frame.checksum)) {
        _slots.remove(key);
        return AssemblyFault(reason: RpcFaultReason.checksumMismatch, seq: seq);
      }
      slot.checksum ??= frame.checksum;
    }

    final bytes = WireBase64.tryDecode(frame.dataBase64 ?? '');
    if (bytes == null) {
      // 坏分片：丢弃整条，避免拼出错误数据。
      _slots.remove(key);
      return const AssemblyFault(reason: RpcFaultReason.transportFault);
    }
    if (bytes.length > RelayLimits.maxPhysicalFrameBytes) {
      _slots.remove(key);
      return AssemblyFault(reason: RpcFaultReason.bufferOverflow, seq: seq);
    }
    if (slot.parts.containsKey(frame.fragmentIndex)) {
      // 重复分片视为损坏。
      _slots.remove(key);
      return const AssemblyFault(reason: RpcFaultReason.transportFault);
    }
    slot.parts[frame.fragmentIndex] = bytes;
    slot.bytes += bytes.length;

    if (slot.bytes > RelayLimits.maxMessageBytes) {
      _slots.remove(key);
      return AssemblyFault(reason: RpcFaultReason.bufferOverflow, seq: seq);
    }

    if (!slot.complete()) return const AssemblyIncomplete();

    _slots.remove(key);
    final merged = <int>[];
    for (var i = 0; i < slot.total; i++) {
      final part = slot.parts[i];
      if (part == null) {
        return AssemblyFault(reason: RpcFaultReason.transportFault, seq: seq);
      }
      merged.addAll(part);
    }
    if (merged.length > RelayLimits.maxMessageBytes) {
      return AssemblyFault(reason: RpcFaultReason.bufferOverflow, seq: seq);
    }
    if (slot.messageBytes != null && slot.messageBytes != merged.length) {
      return AssemblyFault(reason: RpcFaultReason.transportFault, seq: seq);
    }
    if (!_checksumMatches(slot.checksum, merged)) {
      return AssemblyFault(reason: RpcFaultReason.checksumMismatch, seq: seq);
    }
    if (merged.isEmpty) {
      return AssemblyFault(reason: RpcFaultReason.transportFault, seq: seq);
    }
    _markDelivered(seq);
    return AssemblyMessage(
      bytes: merged,
      identity: slot.identity,
      messageSeq: seq,
    );
  }

  bool _checksumMatches(String? expected, List<int> bytes) {
    final normalized = _normalizeChecksum(expected);
    if (normalized == null) return true;
    final actual = Crc32.of(bytes).toRadixString(16).padLeft(8, '0');
    return normalized == actual;
  }

  String? _normalizeChecksum(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    return value.trim().toLowerCase().replaceFirst('0x', '');
  }

  AssemblyFault? _checkGap(int? seq) {
    if (seq == null) return null;
    final last = _lastSeq;
    if (last == null) {
      _lastSeq = seq;
      return null;
    }
    // 重复或乱序回退：不动高水位，否则会把之后的正常 seq 误判成缺口。
    if (seq <= last) return null;
    _lastSeq = seq;
    if (seq > last + 1) {
      return AssemblyFault(
        reason: RpcFaultReason.frameGap,
        seq: seq,
        expectedSeq: last + 1,
        droppedCount: seq - last - 1,
      );
    }
    return null;
  }

  void _evictStale() {
    if (_slots.isEmpty) return;
    final now = _clock();
    final dead = <int>[];
    for (final e in _slots.entries) {
      if (now - e.value.at > RelayLimits.assemblyTimeout.inMilliseconds) {
        dead.add(e.key);
      }
    }
    for (final k in dead) {
      _slots.remove(k);
    }
  }

  /// 供测试与诊断：当前未完成槽位数量。
  int get openSlotCount => _openSlots.length;

  /// 是否有超时槽位（调用后会清理）。用于上报 `buffer-timeout`。
  String? takeTimeoutReason() {
    if (_slots.isEmpty) return null;
    final now = _clock();
    final timedOut = _slots.values.any(
      (s) => now - s.at > RelayLimits.assemblyTimeout.inMilliseconds,
    );
    _evictStale();
    return timedOut ? RpcFaultReason.bufferTimeout : null;
  }
}
