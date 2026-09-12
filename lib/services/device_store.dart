import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/device.dart';
import '../models/notification_prefs.dart';

class DeviceStore {
  DeviceStore._();

  static final DeviceStore instance = DeviceStore._();

  static const _indexKey = 'zremote.device.index';
  static const _deviceKeyPrefix = 'zremote.device.';
  static const _biometricKey = 'zremote.biometricEnabled';

  final _secure = const FlutterSecureStorage();

  Future<List<RemoteDevice>> loadAll() async {
    final indexRaw = await _secure.read(key: _indexKey);
    var ids = <String>[];
    if (indexRaw != null) {
      try {
        final rawIds = (jsonDecode(indexRaw) as List).cast<String>();
        // 去重：索引损坏时可能出现重复项，重复设备只加载一次（混沌测试锁定）。
        final seenIds = <String>{};
        ids = [
          for (final id in rawIds)
            if (seenIds.add(id)) id,
        ];
      } catch (_) {
        // 索引损坏自愈：凭据本体仍在 secure storage，逐个解析重建索引，
        // 而不是把"数据损坏"伪装成"用户没有设备"。注意排除索引键自身
        // （它同样匹配设备键前缀），并拒绝解析失败或键值 id 不符的坏数据（D1）。
        try {
          final all = await _secure.readAll();
          final recovered = <RemoteDevice>[];
          final seen = <String>{};
          for (final entry in all.entries) {
            if (entry.key == _indexKey) continue;
            if (!entry.key.startsWith(_deviceKeyPrefix)) continue;
            final id = entry.key.substring(_deviceKeyPrefix.length);
            if (id.isEmpty || seen.contains(id)) continue;
            try {
              final device = RemoteDevice.fromJson(
                jsonDecode(entry.value) as Map<String, dynamic>,
              );
              if (device.id != id) continue;
              recovered.add(device);
              seen.add(id);
            } catch (_) {}
          }
          if (recovered.isEmpty) return [];
          recovered.sort((a, b) {
            final byTime = a.createdAt.compareTo(b.createdAt);
            return byTime != 0 ? byTime : a.id.compareTo(b.id);
          });
          await _secure.write(
            key: _indexKey,
            value: jsonEncode([for (final d in recovered) d.id]),
          );
          return recovered;
        } catch (_) {
          return [];
        }
      }
    }
    final rawDevices = await Future.wait(
      ids.map((id) => _secure.read(key: _deviceKey(id))),
    );
    final devices = <RemoteDevice>[];
    for (var i = 0; i < ids.length; i++) {
      final raw = rawDevices[i];
      if (raw == null) continue;
      try {
        devices.add(
          RemoteDevice.fromJson(jsonDecode(raw) as Map<String, dynamic>),
        );
      } catch (_) {}
    }
    return devices;
  }

  Future<void> add(RemoteDevice device) async {
    final ids = await _readIndex();
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
    final ids = await _readIndex();
    ids.remove(id);
    await _secure.write(key: _indexKey, value: jsonEncode(ids));
  }

  Future<void> saveOrder(List<String> ids) async {
    final current = await _readIndex();
    if (current.length != ids.length) return;
    final idSet = ids.toSet();
    if (idSet.length != ids.length) return;
    if (!current.toSet().containsAll(idSet)) return;
    await _secure.write(key: _indexKey, value: jsonEncode(ids));
  }

  Future<List<String>> _readIndex() async {
    final raw = await _secure.read(key: _indexKey);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List).cast<String>();
    } catch (_) {
      return [];
    }
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

  static String _warmupKey(String id) => 'zremote.warmup.$id';

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
}
