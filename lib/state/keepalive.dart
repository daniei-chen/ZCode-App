import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/device_store.dart';
import '../services/keepalive.dart';
import 'app_lifecycle.dart';
import 'session_pool.dart';

/// Legacy compatibility state for the removed persistent-connection switch.
///
/// Android requires a visible foreground-service notification for reliable
/// long-running background work. ZCode App deliberately does not start that
/// service, so this state is retained only for safe upgrades of old installs.
class KeepAliveEnabledNotifier extends Notifier<bool> {
  KeepAliveEnabledNotifier({this.initial = false});

  final bool initial;

  @override
  bool build() {
    _load();
    return initial;
  }

  Future<void> _load() async {
    state = await DeviceStore.instance.keepAliveEnabled();
  }

  Future<void> set(bool value) async {
    await DeviceStore.instance.setKeepAliveEnabled(value);
    state = value;
  }
}

final keepAliveEnabledProvider =
    NotifierProvider<KeepAliveEnabledNotifier, bool>(
      KeepAliveEnabledNotifier.new,
    );

enum KeepAliveDecision { run, stop }

KeepAliveDecision keepAliveDecision({
  required bool enabled,
  required bool hasDevices,
}) => KeepAliveDecision.stop;

final keepAliveControllerProvider = Provider<void>((ref) {
  void sync() => _syncService(ref);
  ref.listen(keepAliveEnabledProvider, (_, _) => sync(), fireImmediately: true);
  ref.listen(deviceListProvider, (_, _) => sync());
  ref.listen(appLifecycleProvider, (_, next) {
    if (next == AppLifecycleState.resumed) sync();
  });
});

int _syncGeneration = 0;

Future<void> _syncService(Ref ref) async {
  final generation = ++_syncGeneration;
  final decision = keepAliveDecision(
    enabled: ref.read(keepAliveEnabledProvider),
    hasDevices: ref.read(deviceListProvider).isNotEmpty,
  );
  if (generation != _syncGeneration) return;
  if (decision == KeepAliveDecision.run) {
    await KeepAliveService.instance.start();
  } else {
    await KeepAliveService.instance.stop();
  }
}
