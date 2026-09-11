import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/resource_list.dart';
import '../models/skill.dart';
import '../relay/service_call_result.dart';
import 'relay_source.dart';

/// 技能面板的状态。
class SkillsState {
  const SkillsState({
    this.loading = false,
    this.error,
    this.items = const [],
    this.loaded = false,
    this.phase = ResourcePhase.idle,
    this.method,
  });

  final bool loading;
  final String? error;
  final List<SkillEntry> items;

  /// 是否已经成功拉过一次（用于区分"空"与"还没拉"）。
  final bool loaded;
  final ResourcePhase phase;
  final String? method;

  bool get isEmpty => loaded && items.isEmpty;

  SkillsState copyWith({
    bool? loading,
    String? error,
    bool clearError = false,
    List<SkillEntry>? items,
    bool? loaded,
    ResourcePhase? phase,
    String? method,
  }) => SkillsState(
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
    items: items ?? this.items,
    loaded: loaded ?? this.loaded,
    phase: phase ?? this.phase,
    method: method ?? this.method,
  );

  /// 本地切换启用状态（乐观更新，失败时由调用方回滚）。
  SkillsState toggled(String id, bool enabled) => copyWith(
    items: [
      for (final s in items)
        if (s.id == id) s.copyWith(enabled: enabled) else s,
    ],
  );
}

/// 每个「设备 + 工作区」一份技能列表。
class SkillsNotifier extends Notifier<Map<String, SkillsState>> {
  @override
  Map<String, SkillsState> build() => const {};

  static String keyOf(String deviceId, String workspacePath) =>
      '$deviceId|$workspacePath';

  SkillsState stateOf(String deviceId, String workspacePath) =>
      state[keyOf(deviceId, workspacePath)] ?? const SkillsState();

  void _set(String key, SkillsState v) => state = {...state, key: v};

  Future<void> load({
    required String deviceId,
    required String workspacePath,
    bool refresh = false,
  }) async {
    final key = keyOf(deviceId, workspacePath);
    final cur = state[key] ?? const SkillsState();
    if (cur.loading) return;
    if (cur.loaded && !refresh) return;

    _set(
      key,
      cur.copyWith(
        loading: true,
        clearError: true,
        phase: ResourcePhase.loading,
      ),
    );

    final items = await ref
        .read(relaySourceProvider.notifier)
        .fetchSkills(deviceId: deviceId, workspacePath: workspacePath);

    if (items == null) {
      _set(
        key,
        cur.copyWith(
          loading: false,
          error: '未能读取技能列表（原生通道不可用或接口未返回）',
          loaded: true,
          phase: ResourcePhase.error,
        ),
      );
      return;
    }

    _set(
      key,
      SkillsState(
        items: items,
        loaded: true,
        phase: items.isEmpty ? ResourcePhase.empty : ResourcePhase.ready,
        method: 'skills.list',
      ),
    );
  }

  /// 通过已核验的 `skills.setEnabled` 持久化启用状态。
  ///
  /// 成功后重新读取桌面列表，避免用乐观状态掩盖桌面端拒绝或版本差异。
  Future<ServiceCallResult> setEnabled({
    required String deviceId,
    required String workspacePath,
    required String id,
    required bool enabled,
  }) async {
    final key = keyOf(deviceId, workspacePath);
    final cur = state[key];
    final item = cur?.items.where((s) => s.id == id).firstOrNull;
    if (item == null) {
      return const ServiceCallResult.failure('skill_not_found');
    }
    final result = await ref
        .read(relaySourceProvider.notifier)
        .setSkillEnabled(
          deviceId: deviceId,
          workspacePath: workspacePath,
          skill: item,
          enabled: enabled,
        );
    if (result.ok) {
      await load(
        deviceId: deviceId,
        workspacePath: workspacePath,
        refresh: true,
      );
    }
    return result;
  }
}

final skillsProvider =
    NotifierProvider<SkillsNotifier, Map<String, SkillsState>>(
      SkillsNotifier.new,
    );
