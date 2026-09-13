import '../models/device.dart';
import 'credential_fingerprint.dart';

/// 导入去重（F24）：先比 sid，再退回凭证指纹。
///
/// 旧实现 `candidate.sid.isEmpty → null`：只带 `t`/`token` 的链接（没有 sid）
/// 永远判不了重复，同一条链接扫两次会出现两台设备。现在：
/// * 双方都有 sid 时，sid 相同即视为同一台设备（hash 轮换仍是同一身份，
///   这是"更换链接"与"防重复接入"依赖的语义）；
/// * 有一侧没有 sid（只带 token/t 的链接）时，退回凭证指纹（SHA-256 摘要，
///   顺序无关，不比较明文）；
/// * 两侧都判定不了（无 sid 且无任何凭证字段）时返回 null——宁可不合并，
///   也不误合并两条不同链接；
/// * `exceptId` 用于"更换链接"流程（排除自己）。
RemoteDevice? findDuplicateDevice(
  List<RemoteDevice> existing,
  RemoteDevice candidate, {
  String? exceptId,
}) {
  final sid = candidate.sid;
  final fingerprint = CredentialFingerprint.of(candidate);
  if (sid.isEmpty && fingerprint == null) return null;
  for (final device in existing) {
    if (exceptId != null && device.id == exceptId) continue;
    if (sid.isNotEmpty && device.sid.isNotEmpty && device.sid == sid) {
      return device;
    }
    if (sid.isEmpty || device.sid.isEmpty) {
      final other = CredentialFingerprint.of(device);
      if (fingerprint != null && other != null && other == fingerprint) {
        return device;
      }
    }
  }
  return null;
}

/// 兼容旧调用名：按凭证指纹查重（含 sid-only 的历史行为）。
RemoteDevice? findDuplicateBySid(
  List<RemoteDevice> existing,
  RemoteDevice candidate,
) => findDuplicateDevice(existing, candidate);

RemoteDevice? findDuplicateBySidExcept(
  List<RemoteDevice> existing,
  RemoteDevice candidate,
  String selfId,
) => findDuplicateDevice(existing, candidate, exceptId: selfId);
