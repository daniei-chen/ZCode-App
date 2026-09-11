import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/device.dart';
import 'conversation_page.dart';

/// The native device tab is the unified conversation shell.
///
/// It opens as a draft (no session yet): header, drawer, status line and
/// composer are the same widgets an existing session uses.  Sending the first
/// message creates the session on the desktop and the shell updates its
/// identity in place; there is no separate "new conversation" page.
class NativeDeviceView extends ConsumerWidget {
  const NativeDeviceView({super.key, required this.device});

  final RemoteDevice device;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      ConversationPage(deviceId: device.id);
}
