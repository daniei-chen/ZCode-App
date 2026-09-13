import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/device.dart';
import '../models/notification_prefs.dart';

/// 设备存储的加载结果。
///
/// [unavailable] 表示 secure storage 读取失败：调用方必须把它与"没有设备"
/// 区分开——前者是暂时故障（可重试），后者才是空库。
class DeviceLoadResult {
  const DeviceLoadResult({
    required this.devices,
    this.unavailable = false,
    this.repaired = false,
    this.skippedRecords = 0,
    this.cause,
  });

  final List<RemoteDevice> devices;

  /// secure storage 读取失败（此时 [devices] 恒为空，但语义不是"没有设备"）。
  final bool unavailable;

  /// 索引缺失/损坏/重复/含已消失记录，或存在未入索引的记录——已重建并写回。
  final bool repaired;

  /// 因解析失败或键值 id 不符而被隔离的记录数量。
  final int skippedRecords;

  final Object? cause;
}

/// secure storage 不可用（读取失败）。
class DeviceStoreUnavailableException implements Exception {
  const DeviceStoreUnavailableException([this.cause]);

  final Object? cause;

  @override
  String toString() => 'DeviceStoreUnavailableException($cause)';
}

class DeviceStore {
  DeviceStore._();

  static final DeviceStore instance = DeviceStore._();

  static const _indexKey = 'zremote.device.index';
  static const _deviceKeyPrefix = 'zremote.device.';
  static const _biometricKey = 'zremote.biometricEnabled';

  final _secure = const FlutterSecureStorage();

  /// 索引 + 记录的一致性收敛（F07）。
  ///
  /// 索引缺失、损坏、重复、引用已消失的记录，或存在未入索引的记录（首次 add
  /// 写完设备记录、还没写索引就崩溃）时，都以"设备记录本体"为准重建索引并写回；
  /// 键值与内容 id 不符、无法解析的记录被隔离并计数，不影响其余设备加载。
  /// secure storage 读取失败时返回 unavailable，绝不伪装成空库。
  /// 索引 + 记录的一致性收敛（F07）。
  ///
  /// 主路径逐键读取（索引 + 每条记录），坏记录逐条隔离；随后尽力用 readAll
  /// 发现"索引外"的孤儿记录（add 写完记录、写索引前崩溃），索引缺失/损坏时
  /// 也靠它恢复。readAll 只能**增加**信息，从不减少——因此返回空快照不会
  /// 让已存在的设备消失。存储读取失败返回 unavailable，绝不伪装成空库。
  Future<DeviceLoadResult> loadAllWithStatus() async {
    final String? indexRaw;
    try {
      indexRaw = await _secure.read(key: _indexKey);
    } catch (e) {
      return DeviceLoadResult(devices: const [], unavailable: true, cause: e);
    }

    var repaired = false;
    final indexIds = <String>[];
    if (indexRaw == null) {
      repaired = true;
    } else {
      try {
        indexIds.addAll((jsonDecode(indexRaw) as List).cast<String>());
      } catch (_) {
        repaired = true;
      }
    }

    final records = <String, RemoteDevice>{};
    final ordered = <String>[];
    final seen = <String>{};
    var skipped = 0;
    for (final id in indexIds) {
      if (!seen.add(id)) {
        skipped++;
        continue;
      }
      final String? raw;
      try {
        raw = await _secure.read(key: _deviceKey(id));
      } catch (e) {
        return DeviceLoadResult(devices: const [], unavailable: true, cause: e);
      }
      if (raw == null) {
        skipped++;
        continue;
      }
      try {
        final device = RemoteDevice.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        if (device.id != id) {
          skipped++;
          continue;
        }
        records[id] = device;
        ordered.add(id);
      } catch (_) {
        skipped++;
      }
    }
    if (ordered.length != indexIds.length) repaired = true;

    Map<String, String>? snapshot;
    try {
      snapshot = await _secure.readAll();
    } catch (_) {
      snapshot = null;
    }
    if (snapshot != null) {
      final orphans = <RemoteDevice>[];
      for (final entry in snapshot.entries) {
        if (entry.key == _indexKey) continue;
        if (!entry.key.startsWith(_deviceKeyPrefix)) continue;
        final id = entry.key.substring(_deviceKeyPrefix.length);
        if (id.isEmpty || seen.contains(id)) continue;
        try {
          final device = RemoteDevice.fromJson(
            jsonDecode(entry.value) as Map<String, dynamic>,
          );
          if (device.id != id) {
            skipped++;
            continue;
          }
          orphans.add(device);
          seen.add(id);
        } catch (_) {
          skipped++;
        }
      }
      if (orphans.isNotEmpty) {
        orphans.sort((a, b) {
          final byTime = a.createdAt.compareTo(b.createdAt);
          return byTime != 0 ? byTime : a.id.compareTo(b.id);
        });
        for (final device in orphans) {
          records[device.id] = device;
          ordered.add(device.id);
        }
        repaired = true;
      }
    }

    if (repaired) {
      try {
        await _secure.write(key: _indexKey, value: jsonEncode(ordered));
      } catch (_) {
        // 修复写回失败不阻断读取：下次启动会再次收敛。
      }
    }

    return DeviceLoadResult(
      devices: [for (final id in ordered) records[id]!],
      repaired: repaired,
      skippedRecords: skipped,
    );
  }

  /// 兼容入口：只要设备列表。需要区分"空库"与"存储不可用"时用 [loadAllWithStatus]。
  Future<List<RemoteDevice>> loadAll() async =>
      (await loadAllWithStatus()).devices;

  Future<void> add(RemoteDevice device) async {
    final ids = await _readIndexForMutation();
    if (!ids.contains(device.id)) ids.add(device.id);
    await _secure.write(
      key: _deviceKey(device.id),
      value: jsonEncode(device.toJson()),
    );
    await _secure.write(key: _indexKey, value: jsonEncode(ids));
  }

  Future<void> update(RemoteDevice device) => _secure.write(
    key: _deviceKey(device.id),
    value: jsonEncode(device.toJson()),
  );

  Future<void> remove(String id) async {
    await _secure.delete(key: _deviceKey(id));
    await _secure.delete(key: _warmupKey(id));
    final ids = await _readIndexForMutation();
    ids.remove(id);
    await _secure.write(key: _indexKey, value: jsonEncode(ids));
  }

  Future<void> saveOrder(List<String> ids) async {
    final current = await _readIndexForMutation();
    if (current.length != ids.length) return;
    final idSet = ids.toSet();
    if (idSet.length != ids.length) return;
    if (!current.toSet().containsAll(idSet)) return;
    await _secure.write(key: _indexKey, value: jsonEncode(ids));
  }

  /// 变更前的索引读取：先做一致性收敛再返回，避免"索引损坏 → 空列表 →
  /// 覆盖写回"把其他设备从索引里抹掉（F07）。存储不可用时抛 typed error，
  /// 绝不静默降级为空索引继续写。
  Future<List<String>> _readIndexForMutation() async {
    final result = await loadAllWithStatus();
    if (result.unavailable) {
      throw DeviceStoreUnavailableException(result.cause);
    }
    return [for (final d in result.devices) d.id];
  }

  String _deviceKey(String id) => '$_deviceKeyPrefix$id';

  Future<bool> biometricEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_biometricKey) ?? false;
  }

  Future<void> setBiometricEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_biometricKey, value);
  }

  static const _themeModeKey = 'zremote.themeMode';

  /// 主题模式：`system` / `light` / `dark`。
  Future<String> themeModeSetting() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_themeModeKey) ?? 'system';
  }

  Future<void> setThemeModeSetting(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeModeKey, value);
  }

  static const _lastDeviceKey = 'zremote.lastDevice';

  Future<String?> lastDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_lastDeviceKey);
  }

  Future<void> setLastDeviceId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastDeviceKey, id);
  }

  static const _notifApprovalKey = 'zremote.notify.approval';
  static const _notifCompleteKey = 'zremote.notify.complete';
  static const _notifFailKey = 'zremote.notify.fail';
  static const _notifAlertKey = 'zremote.notify.alertMode';

  Future<NotificationPrefs> notificationPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    return NotificationPrefs(
      approval: prefs.getBool(_notifApprovalKey) ?? true,
      complete: prefs.getBool(_notifCompleteKey) ?? true,
      fail: prefs.getBool(_notifFailKey) ?? true,
      alertMode:
          prefs.getString(_notifAlertKey) ?? NotificationPrefs.kAlertSound,
    );
  }

  Future<void> setNotificationPrefs(NotificationPrefs value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_notifApprovalKey, value.approval);
    await prefs.setBool(_notifCompleteKey, value.complete);
    await prefs.setBool(_notifFailKey, value.fail);
    await prefs.setString(_notifAlertKey, value.alertMode);
  }

  static const _startupTargetKey = 'zremote.startupTarget';

  /// 启动进入页：'lastDevice'（默认，恢复最近设备）或 'launcher'（设备中心）。
  Future<String> startupTarget() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_startupTargetKey) ?? 'lastDevice';
  }

  Future<void> setStartupTarget(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_startupTargetKey, value);
  }

  static const _warmupKeyPrefix = 'zremote.warmup.';

  static String _warmupKey(String id) => '$_warmupKeyPrefix$id';

  /// 面板预热请求的录制存档（warmup 服务用，JSON 数组）。
  ///
  /// 其中可能包含 URL 和请求参数，和设备凭证一样按敏感数据处理，使用
  /// secure storage 而不是普通 SharedPreferences。
  Future<String?> warmupScript(String deviceId) async {
    return _secure.read(key: _warmupKey(deviceId));
  }

  Future<void> setWarmupScript(String deviceId, String? json) async {
    if (json == null) {
      await _secure.delete(key: _warmupKey(deviceId));
    } else {
      await _secure.write(key: _warmupKey(deviceId), value: json);
    }
  }

  /// 清除本机全部远控数据：设备凭证、索引、warmup 脚本与"最近设备"指针。
  ///
  /// 用途是"无法验证身份时的恢复"与后续的清除数据入口：清掉受保护数据本身
  /// 不需要再验证身份（没有数据可暴露了）。主题/通知等非敏感偏好不在此范围。
  /// 返回被删除的 secure storage 键数量，供调用方记录。
  Future<int> clearAll() async {
    var cleared = 0;
    final all = await _secure.readAll();
    for (final key in all.keys) {
      if (key == _indexKey ||
          key.startsWith(_deviceKeyPrefix) ||
          key.startsWith(_warmupKeyPrefix)) {
        await _secure.delete(key: key);
        cleared++;
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastDeviceKey);
    return cleared;
  }
}
