/// A native session's runtime configuration (model / thought / context).
///
/// Field paths marked "verified" were confirmed against the local ZCode
/// desktop bundle on 2026-09-11 (docs/PROTOCOL-DELTA-20260911.md).  Older
/// shapes are still accepted as fallbacks, but the verified paths win.
/// Missing values stay missing and are reported through [ConfigFieldState]
/// instead of being replaced with a made-up model, level or token count.
library;

/// Whether the desktop actually returned a collection-valued field.
enum ConfigFieldState {
  /// The response had no such field: the UI must say "未返回", not "空".
  notReturned,

  /// The field was present and empty.
  empty,

  /// The field was present with entries.
  returned,
}

/// One selectable thought level.  Verified shape: `{value, label, description?}`.
class ThoughtOption {
  const ThoughtOption({required this.value, this.label, this.description});

  final String value;
  final String? label;
  final String? description;

  String get displayName =>
      label?.trim().isNotEmpty == true ? label!.trim() : value;

  static ThoughtOption? tryParse(Object? node) {
    if (node is String) {
      final v = node.trim();
      return v.isEmpty ? null : ThoughtOption(value: v);
    }
    if (node is! Map) return null;
    final m = Map<String, dynamic>.from(node);
    final value = _str(m['value']) ?? _str(m['id']) ?? _str(m['level']);
    if (value == null) return null;
    return ThoughtOption(
      value: value,
      label: _str(m['label']) ?? _str(m['displayName']),
      description: _str(m['description']),
    );
  }

  static String? _str(Object? v) =>
      v is String && v.trim().isNotEmpty ? v.trim() : null;
}

class ConversationModelOption {
  const ConversationModelOption({
    required this.providerId,
    required this.modelId,
    this.label,
    this.providerLabel,
    this.enabled = true,
    this.disabledReason,
    this.contextWindow,
    this.reasoningEnabled,
    this.reasoningLevels = const [],
  });

  final String providerId;
  final String modelId;
  final String? label;
  final String? providerLabel;
  final bool enabled;

  /// Verified `disabledReason`; shown next to a model the user cannot pick.
  final String? disabledReason;

  /// Verified per-model `contextWindow`.
  final int? contextWindow;

  /// Verified `reasoning.enabled` / `reasoning.levels[]`.
  final bool? reasoningEnabled;
  final List<ThoughtOption> reasoningLevels;

  String get displayName => label?.trim().isNotEmpty == true
      ? label!.trim()
      : '$providerId / $modelId';

  String get key => '$providerId:$modelId';
}

class ConversationRuntimeConfig {
  const ConversationRuntimeConfig({
    this.loading = false,
    this.error,
    this.providerId,
    this.modelId,
    this.modelLabel,
    this.thoughtLevel,
    this.thoughtOptions = const [],
    this.thoughtOptionsState = ConfigFieldState.notReturned,
    this.thoughtEnabled,
    this.contextUsedTokens,
    this.contextMaxTokens,
    this.autoCompactThresholdTokens,
    this.revision,
    this.models = const [],
    this.catalogState = ConfigFieldState.notReturned,
    this.fetchedAt,
  });

  final bool loading;
  final String? error;
  final String? providerId;
  final String? modelId;
  final String? modelLabel;

  /// Current thought level value (e.g. `max`).  Independent of the options
  /// list: the desktop may return the value without any catalogue.
  final String? thoughtLevel;

  /// Selectable levels.  Only authoritative when [thoughtOptionsState] is
  /// [ConfigFieldState.returned]; never padded with a hard-coded list.
  final List<ThoughtOption> thoughtOptions;
  final ConfigFieldState thoughtOptionsState;
  final bool? thoughtEnabled;

  final int? contextUsedTokens;
  final int? contextMaxTokens;
  final int? autoCompactThresholdTokens;

  /// `runtime.stateRevision` (verified) or a legacy `revision`.
  final int? revision;
  final List<ConversationModelOption> models;
  final ConfigFieldState catalogState;
  final int? fetchedAt;

  static const empty = ConversationRuntimeConfig();

  bool get hasModel => modelId?.trim().isNotEmpty == true;

  bool get hasContext => contextUsedTokens != null || contextMaxTokens != null;

  /// The user may pick from [thoughtOptions] only when they were returned.
  bool get thoughtSelectable =>
      thoughtOptionsState == ConfigFieldState.returned &&
      thoughtOptions.isNotEmpty;

  ConversationModelOption? get currentModel {
    final id = modelId;
    if (id == null) return null;
    for (final m in models) {
      if (m.modelId == id &&
          (providerId == null || m.providerId == providerId)) {
        return m;
      }
    }
    return null;
  }

  ConversationRuntimeConfig copyWith({
    bool? loading,
    String? error,
    bool clearError = false,
    String? providerId,
    String? modelId,
    String? modelLabel,
    String? thoughtLevel,
    List<ThoughtOption>? thoughtOptions,
    ConfigFieldState? thoughtOptionsState,
    bool? thoughtEnabled,
    int? contextUsedTokens,
    int? contextMaxTokens,
    int? autoCompactThresholdTokens,
    int? revision,
    List<ConversationModelOption>? models,
    ConfigFieldState? catalogState,
    int? fetchedAt,
  }) => ConversationRuntimeConfig(
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
    providerId: providerId ?? this.providerId,
    modelId: modelId ?? this.modelId,
    modelLabel: modelLabel ?? this.modelLabel,
    thoughtLevel: thoughtLevel ?? this.thoughtLevel,
    thoughtOptions: thoughtOptions ?? this.thoughtOptions,
    thoughtOptionsState: thoughtOptionsState ?? this.thoughtOptionsState,
    thoughtEnabled: thoughtEnabled ?? this.thoughtEnabled,
    contextUsedTokens: contextUsedTokens ?? this.contextUsedTokens,
    contextMaxTokens: contextMaxTokens ?? this.contextMaxTokens,
    autoCompactThresholdTokens:
        autoCompactThresholdTokens ?? this.autoCompactThresholdTokens,
    revision: revision ?? this.revision,
    models: models ?? this.models,
    catalogState: catalogState ?? this.catalogState,
    fetchedAt: fetchedAt ?? this.fetchedAt,
  );

  /// Overlay a fresher response on this snapshot: every field the newer
  /// response actually returned replaces the old value, anything it
  /// omitted keeps the old value.  Used when one of the two reads fails
  /// so a partial refresh cannot blank the chips (review P2-1).
  ConversationRuntimeConfig overlay(ConversationRuntimeConfig newer) =>
      ConversationRuntimeConfig(
        loading: newer.loading,
        error: newer.error,
        providerId: newer.providerId ?? providerId,
        modelId: newer.modelId ?? modelId,
        modelLabel: newer.modelLabel ?? modelLabel,
        thoughtLevel: newer.thoughtLevel ?? thoughtLevel,
        thoughtOptions: newer.thoughtOptionsState == ConfigFieldState.returned
            ? newer.thoughtOptions
            : thoughtOptions,
        thoughtOptionsState:
            newer.thoughtOptionsState == ConfigFieldState.notReturned
            ? thoughtOptionsState
            : newer.thoughtOptionsState,
        thoughtEnabled: newer.thoughtEnabled ?? thoughtEnabled,
        contextUsedTokens: newer.contextUsedTokens ?? contextUsedTokens,
        contextMaxTokens: newer.contextMaxTokens ?? contextMaxTokens,
        autoCompactThresholdTokens:
            newer.autoCompactThresholdTokens ?? autoCompactThresholdTokens,
        revision: newer.revision ?? revision,
        models: newer.catalogState == ConfigFieldState.notReturned
            ? models
            : newer.models,
        catalogState: newer.catalogState == ConfigFieldState.notReturned
            ? catalogState
            : newer.catalogState,
        fetchedAt: newer.fetchedAt ?? fetchedAt,
      );

  /// Merge a `readSession` snapshot with a `getTaskTokenUsage` response.
  /// Snapshot fields win; usage only fills context gaps.
  ConversationRuntimeConfig mergeUsage(ConversationRuntimeConfig usage) =>
      ConversationRuntimeConfig(
        providerId: providerId,
        modelId: modelId,
        modelLabel: modelLabel,
        thoughtLevel: thoughtLevel,
        thoughtOptions: thoughtOptions,
        thoughtOptionsState: thoughtOptionsState,
        thoughtEnabled: thoughtEnabled,
        contextUsedTokens: contextUsedTokens ?? usage.contextUsedTokens,
        contextMaxTokens: contextMaxTokens ?? usage.contextMaxTokens,
        autoCompactThresholdTokens:
            autoCompactThresholdTokens ?? usage.autoCompactThresholdTokens,
        revision: revision ?? usage.revision,
        // A snapshot that explicitly returned an empty catalogue keeps that
        // fact; usage only fills in when the snapshot said nothing at all.
        models: catalogState != ConfigFieldState.notReturned
            ? models
            : usage.models,
        catalogState: catalogState != ConfigFieldState.notReturned
            ? catalogState
            : usage.catalogState,
        fetchedAt: fetchedAt ?? usage.fetchedAt,
      );

  /// Parse a `zcode-session.readSession` or `getTaskTokenUsage` response.
  static ConversationRuntimeConfig parse(Object? value, {int? fetchedAt}) {
    if (value is! Map) return empty;
    final root = _map(value);
    final settings = _map(root['settings']);
    final modelSettings = _map(settings['model']);
    final thoughtSettings = _map(settings['thoughtLevel']);

    // --- current model (verified: settings.model.current {providerId, modelId})
    final modelCurrent = modelSettings['current'];
    final modelNode = _map(modelCurrent);
    final provider =
        _firstString(modelNode, const [
          'providerId',
          'provider',
          'providerKey',
        ]) ??
        _firstString(modelSettings, const ['providerId', 'provider']);
    final model =
        _firstString(modelNode, const ['modelId', 'model', 'id', 'name']) ??
        _stringValue(modelCurrent) ??
        _stringValue(root['model']);

    // --- catalogue (verified: settings.model.available[] of Mh)
    var catalogState = ConfigFieldState.notReturned;
    var models = <ConversationModelOption>[];
    final available = modelSettings['available'];
    if (available is List) {
      models = _verifiedCatalog(available);
      catalogState = models.isEmpty
          ? ConfigFieldState.empty
          : ConfigFieldState.returned;
    } else {
      models = _legacyModels(root);
      if (models.isNotEmpty) catalogState = ConfigFieldState.returned;
    }
    ConversationModelOption? current;
    for (final m in models) {
      if (m.modelId == model &&
          (provider == null || m.providerId == provider)) {
        current = m;
        break;
      }
    }
    final modelLabel =
        _firstString(modelNode, const ['displayName', 'label', 'title']) ??
        current?.label;

    // --- thought (verified: settings.thoughtLevel {enabled, current, available[]})
    final thoughtCurrentNode = thoughtSettings['current'];
    final thought = thoughtCurrentNode is Map
        ? _firstString(_map(thoughtCurrentNode), const [
            'value',
            'level',
            'id',
            'name',
          ])
        : _stringValue(thoughtCurrentNode) ??
              _stringValue(root['thoughtLevel']);
    var thoughtOptions = <ThoughtOption>[];
    var thoughtState = ConfigFieldState.notReturned;
    final thoughtAvailable = thoughtSettings['available'];
    if (thoughtAvailable is List) {
      thoughtOptions = [
        for (final o in thoughtAvailable.take(32)) ?ThoughtOption.tryParse(o),
      ];
      thoughtState = thoughtOptions.isEmpty
          ? ConfigFieldState.empty
          : ConfigFieldState.returned;
    }
    // The selected model's own reasoning levels are the second authority.
    if (thoughtState != ConfigFieldState.returned &&
        current != null &&
        current.reasoningLevels.isNotEmpty) {
      thoughtOptions = current.reasoningLevels;
      thoughtState = ConfigFieldState.returned;
    }
    final thoughtEnabled = thoughtSettings['enabled'] is bool
        ? thoughtSettings['enabled'] as bool
        : current?.reasoningEnabled;

    // --- context (verified: projection.contextUsed/contextWindow, runtime.contextUsage)
    final context = _contextFrom(root);
    final revision =
        _asInt(_map(root['runtime'])['stateRevision']) ??
        _asInt(root['revision']) ??
        _asInt(_map(root['session'])['revision']);

    return ConversationRuntimeConfig(
      providerId: provider ?? current?.providerId,
      modelId: model,
      modelLabel: modelLabel,
      thoughtLevel: thought,
      thoughtOptions: thoughtOptions,
      thoughtOptionsState: thoughtState,
      thoughtEnabled: thoughtEnabled,
      contextUsedTokens: context.used,
      contextMaxTokens: context.max,
      autoCompactThresholdTokens: context.threshold,
      revision: revision,
      models: models,
      catalogState: catalogState,
      fetchedAt: fetchedAt,
    );
  }

  // -------------------------------------------------------------------

  static Map<String, dynamic> _map(Object? value) => value is Map
      ? Map<String, dynamic>.from(value)
      : const <String, dynamic>{};

  static String? _firstString(Map<String, dynamic> value, List<String> keys) {
    for (final key in keys) {
      final v = value[key];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }

  static String? _stringValue(Object? value) {
    if (value is String && value.trim().isNotEmpty) return value.trim();
    return null;
  }

  static int? _asInt(Object? value) => value is num ? value.toInt() : null;

  /// Verified `Mh` entries: `{ref:{providerId,modelId}, label, providerLabel?,
  /// contextWindow?, reasoning?:{enabled, levels[]}, disabledReason?}`.
  static List<ConversationModelOption> _verifiedCatalog(List<dynamic> list) {
    final out = <ConversationModelOption>[];
    final seen = <String>{};
    for (final item in list.take(128)) {
      if (item is! Map) continue;
      final m = _map(item);
      final ref = _map(m['ref']);
      final providerId =
          _firstString(ref, const ['providerId', 'provider']) ??
          _firstString(m, const ['providerId', 'provider']);
      final modelId =
          _firstString(ref, const ['modelId', 'model', 'id']) ??
          _firstString(m, const ['modelId', 'model', 'id']);
      if (providerId == null || modelId == null) continue;
      final reasoning = _map(m['reasoning']);
      final levels = reasoning['levels'];
      final disabledReason = _firstString(m, const ['disabledReason']);
      final option = ConversationModelOption(
        providerId: providerId,
        modelId: modelId,
        label: _firstString(m, const ['label', 'displayName', 'title']),
        providerLabel: _firstString(m, const ['providerLabel']),
        enabled:
            disabledReason == null &&
            (m['enabled'] is! bool || m['enabled'] == true),
        disabledReason: disabledReason,
        contextWindow: _asInt(m['contextWindow']),
        reasoningEnabled: reasoning['enabled'] is bool
            ? reasoning['enabled'] as bool
            : null,
        reasoningLevels: levels is List
            ? [for (final l in levels.take(32)) ?ThoughtOption.tryParse(l)]
            : const [],
      );
      if (seen.add(option.key)) out.add(option);
    }
    return out;
  }

  /// Older desktop builds: `modelCatalog` / `providers` / `models` in list,
  /// provider-grouped map or direct record form.  Never treats an arbitrary
  /// map as a model: provider and model ids must both be present.
  static List<ConversationModelOption> _legacyModels(
    Map<String, dynamic> root,
  ) {
    final out = <ConversationModelOption>[];
    final seen = <String>{};

    void add(Object? providerHint, Object? value) {
      if (value is String) {
        final modelId = value.trim();
        final providerId = providerHint?.toString().trim() ?? '';
        if (modelId.isEmpty || providerId.isEmpty) return;
        final option = ConversationModelOption(
          providerId: providerId,
          modelId: modelId,
        );
        if (seen.add(option.key)) out.add(option);
        return;
      }
      if (value is! Map) return;
      final m = _map(value);
      final provider =
          _firstString(m, const ['providerId', 'provider', 'providerKey']) ??
          providerHint?.toString().trim();
      final model = _firstString(m, const ['modelId', 'model', 'id', 'name']);
      if (provider != null && provider.isNotEmpty && model != null) {
        final option = ConversationModelOption(
          providerId: provider,
          modelId: model,
          label: _firstString(m, const ['displayName', 'label', 'title']),
          enabled: m['enabled'] is! bool || m['enabled'] == true,
        );
        if (seen.add(option.key)) out.add(option);
      }
      final nested = m['models'];
      if (nested is List) {
        for (final item in nested.take(64)) {
          add(provider, item);
        }
      }
    }

    void readCatalog(Object? catalog) {
      if (catalog is List) {
        for (final item in catalog.take(64)) {
          add(null, item);
        }
      } else if (catalog is Map) {
        final map = _map(catalog);
        add(null, map);
        if (map['models'] is List) return;
        map.forEach((provider, models) {
          if (models is List) {
            for (final model in models.take(64)) {
              add(provider, model);
            }
          }
        });
      }
    }

    final settings = _map(root['settings']);
    final modelSettings = _map(settings['model']);
    for (final catalog in [
      root['modelCatalog'],
      root['providers'],
      root['models'],
      settings['modelCatalog'],
      modelSettings['models'],
    ]) {
      readCatalog(catalog);
    }
    return out;
  }

  static ({int? used, int? max, int? threshold}) _contextFrom(
    Map<String, dynamic> root,
  ) {
    // Verified: projection.contextUsed / projection.contextWindow are the
    // preferred fields.  Some 3.11.x responses expose the same limit as
    // `max`, `maxTokens`, or `limit` under runtime.contextUsage instead.
    final projection = _map(root['projection']);
    final pUsed = _asInt(projection['contextUsed']);
    final pWindow = _firstInt(projection, const [
      'contextWindow',
      'contextLimit',
      'maxTokens',
    ]);
    // Verified: runtime.contextUsage {used, size} (optional).
    final usage = _map(_map(root['runtime'])['contextUsage']);
    final rUsed = _firstInt(usage, const ['used', 'usedTokens', 'inputTokens']);
    final rSize = _firstInt(usage, const [
      'size',
      'max',
      'maxTokens',
      'limit',
      'window',
      'windowTokens',
    ]);
    if (pUsed != null || pWindow != null || rUsed != null || rSize != null) {
      final window = (pWindow != null && pWindow > 0)
          ? pWindow
          : (rSize != null && rSize > 0 ? rSize : null);
      return (used: pUsed ?? rUsed, max: window, threshold: null);
    }

    // Legacy: a `contextWindow` / `contextUsage` object somewhere shallow.
    Map<String, dynamic>? found;
    void walk(Object? node, int depth) {
      if (found != null || depth > 5 || node is! Map) return;
      for (final entry in node.entries) {
        final key = entry.key.toString().toLowerCase();
        final value = entry.value;
        if (key == 'contextwindow' || key == 'contextusage') {
          final map = _map(value);
          if (map.isNotEmpty) {
            found = map;
            return;
          }
        }
        if (value is Map || value is List) walk(value, depth + 1);
        if (found != null) return;
      }
    }

    walk(root, 0);
    final map = found ?? const <String, dynamic>{};
    int? pick(List<String> keys) {
      for (final key in keys) {
        final value = _asInt(map[key]);
        if (value != null) return value;
      }
      return null;
    }

    return (
      used: pick(const ['usedTokens', 'used', 'inputTokens']),
      max: pick(const ['maxTokens', 'max', 'limit', 'windowTokens', 'size']),
      threshold: pick(const [
        'autoCompactThresholdTokens',
        'compactThresholdTokens',
      ]),
    );
  }

  static int? _firstInt(Map<String, dynamic> value, List<String> keys) {
    for (final key in keys) {
      final parsed = _asInt(value[key]);
      if (parsed != null) return parsed;
    }
    return null;
  }
}
