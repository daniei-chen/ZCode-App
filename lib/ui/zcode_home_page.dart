import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/device_import.dart';
import '../services/link_builder.dart';
import '../state/session_pool.dart';
import '../theme.dart';
import 'manage_page.dart';

/// The first-run ZCode surface.
///
/// This is deliberately a native conversation shell rather than the old
/// device-management landing page.  Once a remote link is imported the
/// active device opens [ConversationPage], while this page remains the
/// useful empty/draft state for a fresh install.
class ZCodeHomePage extends ConsumerStatefulWidget {
  const ZCodeHomePage({super.key});

  @override
  ConsumerState<ZCodeHomePage> createState() => _ZCodeHomePageState();
}

class _ZCodeHomePageState extends ConsumerState<ZCodeHomePage> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _composer = TextEditingController();
  String _model = 'GLM-5.3';
  String _thought = '最高';

  @override
  void dispose() {
    _composer.dispose();
    super.dispose();
  }

  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';

  String _t(String zh, String en) => _zh ? zh : en;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: zt.bg,
      drawer: _drawer(context),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _header(context),
            Expanded(child: _welcome(context)),
            _composerBar(context),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final zt = context.zt;
    return Container(
      height: 62,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: zt.bg,
        border: Border(bottom: BorderSide(color: zt.hairline)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: _t('打开菜单', 'Open menu'),
            onPressed: () => _scaffoldKey.currentState?.openDrawer(),
            icon: const Icon(Icons.menu_rounded),
          ),
          Image.asset('assets/brand/mark.png', width: 28, height: 28),
          const SizedBox(width: 10),
          Text(
            'ZCode',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
              color: zt.textHi,
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: _t('连接桌面端', 'Connect desktop'),
            onPressed: () => _openImport(context),
            icon: Icon(Icons.add_rounded, color: zt.textLo),
          ),
          IconButton(
            tooltip: _t('刷新', 'Refresh'),
            onPressed: () => setState(() {}),
            icon: Icon(Icons.refresh_rounded, color: zt.textLo),
          ),
        ],
      ),
    );
  }

  Widget _welcome(BuildContext context) {
    final zt = context.zt;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 24),
            Center(
              child: Image.asset(
                'assets/brand/mark.png',
                width: 64,
                height: 64,
              ),
            ),
            const SizedBox(height: 20),
            Center(
              child: Text(
                _t('开始一个新会话', 'Start a new conversation'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.6,
                  color: zt.textHi,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                _t(
                  '从 ZCode 桌面端继续工作，消息、模型和工具会通过原生通道同步。',
                  'Continue from ZCode desktop. Messages, models and tools sync through the native channel.',
                ),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, height: 1.5, color: zt.textLo),
              ),
            ),
            const SizedBox(height: 30),
            _connectCard(context),
            const SizedBox(height: 14),
            Center(
              child: TextButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const ManagePage()),
                ),
                icon: const Icon(Icons.devices_outlined, size: 17),
                label: Text(_t('查看连接方式', 'View connection options')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _connectCard(BuildContext context) {
    final zt = context.zt;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        color: zt.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: zt.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: zt.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.link_rounded, color: zt.accent, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _t('接入 ZCode 桌面端', 'Connect ZCode desktop'),
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: zt.textHi,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            _t(
              '粘贴 remote/v4 控制链接后，应用会直接拉取会话页和当前工作区。',
              'Paste a remote/v4 control link to pull the conversation and active workspace.',
            ),
            style: TextStyle(fontSize: 12, height: 1.45, color: zt.textLo),
          ),
          const SizedBox(height: 13),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => _openImport(context),
              icon: const Icon(Icons.content_paste_rounded, size: 18),
              label: Text(_t('粘贴链接并连接', 'Paste link and connect')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _composerBar(BuildContext context) {
    final zt = context.zt;
    return Material(
      color: zt.surface,
      child: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: zt.hairline)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _chip(
                      context,
                      Icons.hub_outlined,
                      _model,
                      () => _pickModel(context),
                    ),
                    const SizedBox(width: 6),
                    _chip(
                      context,
                      Icons.psychology_outlined,
                      _thought,
                      () => _pickThought(context),
                    ),
                    const SizedBox(width: 6),
                    _chip(
                      context,
                      Icons.data_usage_outlined,
                      '0 / 1.0m',
                      () => _showContext(context),
                    ),
                    const SizedBox(width: 6),
                    IconButton(
                      tooltip: _t('添加附件', 'Attach'),
                      onPressed: () => _openImport(context),
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.attach_file_rounded, color: zt.textLo),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _composer,
                      minLines: 1,
                      maxLines: 4,
                      decoration: InputDecoration(
                        hintText: _t('输入消息…', 'Message…'),
                        isDense: true,
                        filled: true,
                        fillColor: zt.field,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 11,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(11),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onSubmitted: (_) => _openImport(context),
                    ),
                  ),
                  const SizedBox(width: 2),
                  IconButton(
                    tooltip: _t('先连接桌面端', 'Connect desktop first'),
                    onPressed: () => _openImport(context),
                    icon: Icon(Icons.arrow_upward_rounded, color: zt.textLo),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    final zt = context.zt;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 155),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: zt.field,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: zt.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: zt.textLo),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: zt.textLo),
              ),
            ),
            const SizedBox(width: 2),
            Icon(Icons.expand_more_rounded, size: 14, color: zt.textLo),
          ],
        ),
      ),
    );
  }

  Drawer _drawer(BuildContext context) {
    final zt = context.zt;
    final devices = ref.watch(deviceListProvider);
    return Drawer(
      backgroundColor: zt.surface,
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 16, 20),
              child: Row(
                children: [
                  Image.asset('assets/brand/mark.png', width: 38, height: 38),
                  const SizedBox(width: 10),
                  Text(
                    'ZCode',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: zt.textHi,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.add_comment_outlined),
              title: Text(_t('新建会话', 'New conversation')),
              selected: true,
              onTap: () => Navigator.pop(context),
            ),
            ListTile(
              leading: const Icon(Icons.devices_outlined),
              title: Text(_t('设备与连接', 'Devices & connections')),
              onTap: () {
                Navigator.pop(context);
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const ManagePage()),
                );
              },
            ),
            if (devices.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.forum_outlined),
                title: Text(_t('打开会话', 'Open conversations')),
                onTap: () {
                  Navigator.pop(context);
                  ref.read(activeTabProvider.notifier).set(0);
                },
              ),
            const Divider(height: 24),
            ListTile(
              leading: const Icon(Icons.space_dashboard_outlined),
              title: Text(_t('工作台', 'Workbench')),
              onTap: () {
                Navigator.pop(context);
                ref.read(activeTabProvider.notifier).set(devices.length + 1);
              },
            ),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: Text(_t('设置', 'Settings')),
              onTap: () {
                Navigator.pop(context);
                ref.read(activeTabProvider.notifier).set(devices.length + 3);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openImport(BuildContext context) async {
    final controller = TextEditingController();
    try {
      final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
      if (clipboard?.text?.contains('zcode.z.ai/remote') == true) {
        controller.text = clipboard!.text!;
      }
      if (!context.mounted) return;
      final text = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(_t('连接 ZCode 桌面端', 'Connect ZCode desktop')),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 4,
            decoration: InputDecoration(
              hintText: 'https://zcode.z.ai/remote/v4?sid=...&hash=...',
              helperText: _t(
                '链接只保存在本机安全存储中。',
                'The link is stored locally in secure storage.',
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(_t('取消', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, controller.text),
              child: Text(_t('连接', 'Connect')),
            ),
          ],
        ),
      );
      if (text == null || !context.mounted) return;
      final device = LinkBuilder.parse(text);
      if (device == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _t(
                '链接无效：需要 sid 和 hash 参数。',
                'Invalid link: sid and hash are required.',
              ),
            ),
          ),
        );
        return;
      }
      final existing = ref.read(deviceListProvider);
      final duplicate = findDuplicateBySid(existing, device);
      if (duplicate != null) {
        final index = existing.indexOf(duplicate);
        ref.read(activeTabProvider.notifier).set(index);
        return;
      }
      await ref.read(deviceListProvider.notifier).add(device);
      if (!mounted) return;
      ref.read(activeTabProvider.notifier).set(0);
    } finally {
      controller.dispose();
    }
  }

  Future<void> _pickModel(BuildContext context) async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => _ChoiceSheet(
        title: _t('模型', 'Model'),
        selected: _model,
        options: const [
          'GLM-5.3',
          'GLM-5.3-Flash',
          'deepseek-v4-flash',
          'mimo-v2.5',
        ],
      ),
    );
    if (selected != null && mounted) setState(() => _model = selected);
  }

  Future<void> _pickThought(BuildContext context) async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => _ChoiceSheet(
        title: _t('思考强度', 'Thought level'),
        selected: _thought,
        options: const ['低', '中', '高', '最高'],
      ),
    );
    if (selected != null && mounted) setState(() => _thought = selected);
  }

  Future<void> _showContext(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _t('上下文', 'Context'),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '0 / 1.0m tokens',
                style: TextStyle(fontSize: 15, color: context.zt.textHi),
              ),
              const SizedBox(height: 6),
              Text(
                _t(
                  '连接桌面端后会显示真实用量。',
                  'Live usage appears after connecting to desktop.',
                ),
                style: TextStyle(fontSize: 12, color: context.zt.textLo),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChoiceSheet extends StatelessWidget {
  const _ChoiceSheet({
    required this.title,
    required this.selected,
    required this.options,
  });

  final String title;
  final String selected;
  final List<String> options;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            for (final option in options)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  option == selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: option == selected
                      ? context.zt.accent
                      : context.zt.textLo,
                ),
                title: Text(option),
                onTap: () => Navigator.pop(context, option),
              ),
          ],
        ),
      ),
    );
  }
}
