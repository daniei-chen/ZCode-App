import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/device.dart';
import '../models/notification_prefs.dart';
import 'app_log.dart';
import 'structured_log.dart';

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
    Object? enumerationError;
    try {
      snapshot = await _secure.readAll();
    } catch (e) {
      snapshot = null;
      enumerationError = e;
    }

    // R-05：枚举失败 + 逐键读取后仍无任何记录 = 无法证明"快照完整且为空"。
    //
    // 索引缺失/损坏时，孤儿发现是唯一能把记录找回来的路径（indexRaw == null
    // 或解析失败 → _readIndex 走不到；这里靠 readAll）；枚举再失败，"空列表"
    // 只说明这次读不到，不说明没有凭证。此时必须：
    //   * 报告 unavailable（UI 显示可重试故障，而不是"没有设备"）；
    //   * **不写回索引**——写空索引会把尚未发现的记录从索引里抹掉，
    //     把一次暂时故障变成永久数据丢失（审计复现 R-05）。
    if (enumerationError != null && ordered.isEmpty) {
      AppLog.failure(
        LogEvent.deviceStoreUnavailable,
        enumerationError,
        fields: {LogField.reason: 'enumerate_incomplete'},
      );
      return DeviceLoadResult(
        devices: const [],
        unavailable: true,
        cause: enumerationError,
      );
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

  /// 写操作串行队列（F09）：add/update/remove/saveOrder 都是"读-改-写"，
  /// 并发调用会各自基于旧索引计算、后写覆盖前写（例如两个 add 同时进行时
  /// 只有一个能留在索引里）。读操作不受影响。
  Future<void> _writeQueue = Future<void>.value();

  /// 写入代际（R-04/M1）：擦除事务让代际 +1，作废此前入队的一切写入。
  ///
  /// 场景：擦除（clearAll）与一条在途命令（warmup 延时写入、并发设备更新）
  /// 交错时，旧命令若在擦除之后落盘，会把已删除的凭证写回安全存储，下次
  /// 启动经孤儿发现"复活"设备。代际号在命令**入队时**捕获，真正执行时若
  /// 已换代则静默丢弃——擦除之后的新命令（用户重新导入）属于新代际，
  /// 不受影响。
  int _epoch = 0;

  Future<void> _serialized(Future<void> Function() action) {
    final epochAtEnqueue = _epoch;
    final result = _writeQueue.then((_) async {
      if (epochAtEnqueue != _epoch) return; // 已被擦除事务作废
      await action();
    });
    _writeQueue = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<void> add(RemoteDevice device) => _serialized(() async {
    final ids = await _readIndexForMutation();
    if (!ids.contains(device.id)) ids.add(device.id);
    await _secure.write(
      key: _deviceKey(device.id),
      value: jsonEncode(device.toJson()),
    );
    await _secure.write(key: _indexKey, value: jsonEncode(ids));
  });

  Future<void> update(RemoteDevice device) => _serialized(
    () => _secure.write(
      key: _deviceKey(device.id),
      value: jsonEncode(device.toJson()),
    ),
  );

  Future<void> remove(String id) => _serialized(() async {
    await _secure.delete(key: _deviceKey(id));
    await _secure.delete(key: _warmupKey(id));
    final ids = await _readIndexForMutation();
    ids.remove(id);
    await _secure.write(key: _indexKey, value: jsonEncode(ids));
  });

  Future<void> saveOrder(List<String> ids) => _serialized(() async {
    final current = await _readIndexForMutation();
    if (current.length != ids.length) return;
    final idSet = ids.toSet();
    if (idSet.length != ids.length) return;
    if (!current.toSet().containsAll(idSet)) return;
    await _secure.write(key: _indexKey, value: jsonEncode(ids));
  });

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

  /// 安全设置读取失败时的用户确认标记（v1.1.8）。
  ///
  /// 存在**独立后端**（安全存储，与 SharedPreferences 不同的文件与密钥）：
  /// 当 SharedPreferences 损坏导致读不到门禁偏好时，用户在锁屏明确确认
  /// "清除安全设置并继续"后写入此标记；启动读取失败时凭它放行，避免
  /// fail-closed 把用户永久锁在门外。用户在设置里重新写入门禁开关时清除。
  static const _securityResetKey = 'zremote.securityResetAck';

  Future<bool> securityResetAcknowledged() async {
    try {
      final raw = await _secure.read(key: _securityResetKey);
      return raw == 'true';
    } catch (_) {
      return false;
    }
  }

  Future<void> setSecurityResetAcknowledged(bool value) async {
    if (value) {
      await _secure.write(key: _securityResetKey, value: 'true');
    } else {
      await _secure.delete(key: _securityResetKey);
    }
  }

  Future<bool> biometricEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_biometricKey) ?? false;
    } catch (e) {
      AppLog.failure(
        LogEvent.securityPrefReadFailed,
        e,
        fields: {LogField.reason: 'shared_preferences'},
      );
      rethrow;
    }
  }

  Future<void> setBiometricEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_biometricKey, value);
    // 写入成功 = prefs 后端可用：清掉重置标记，避免以后一次读取失败
    // 被旧标记静默放行（标记只在用户确认过且后端不可用时才有意义）。
    try {
      await setSecurityResetAcknowledged(false);
    } catch (_) {}
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

  Future<void> setWarmupScript(String deviceId, String? json) =>
      _serialized(() async {
        // 走写队列（M1）：与擦除事务同队列才能被代际号作废，否则在途
        // warmup 写入可能在 clearAll 之后落盘，把已删设备的脚本写回。
        if (json == null) {
          await _secure.delete(key: _warmupKey(deviceId));
        } else {
          await _secure.write(key: _warmupKey(deviceId), value: json);
        }
      });

  /// 清除本机全部远控数据：设备凭证、索引、warmup 脚本与"最近设备"指针。
  ///
  /// 用途是"无法验证身份时的恢复"与后续的清除数据入口：清掉受保护数据本身
  /// 不需要再验证身份（没有数据可暴露了）。主题/通知等非敏感偏好不在此范围。
  /// 返回被删除的 secure storage 键数量，供调用方记录。
  ///
  /// M1：本操作走同一写队列，并在开始时让代际 +1——此后**执行**的旧命令
  /// （入队时代际落后）一律作废；本操作自身排在队列尾部，前面已入队的写入
  /// 先完成，然后才是删除，保证不会出现"擦除完成后又被写回"。
  Future<int> clearAll() async {
    // 先自增（作废在途命令），再把自己排进队列等待前面的写入结束。
    _epoch++;
    final epochAtCall = _epoch;
    var cleared = 0;
    await _serialized(() async {
      if (epochAtCall != _epoch) return;
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
    });
    return cleared;
  }
}
