import 'dart:io';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/update_installer.dart';
import '../services/update_service.dart';
import '../theme.dart';

Future<bool?> showUpdateDownloadDialog(
  BuildContext context,
  UpdateCheckResult result,
) => showDialog<bool>(
  context: context,
  barrierDismissible: false,
  builder: (_) => UpdateDownloadDialog(result: result),
);

enum _DownloadStage { ready, downloading, downloaded, installing, failed }

/// Compact device-page styled update surface. It deliberately stays inside
/// the app; only the final Android package confirmation belongs to the OS.
class UpdateDownloadDialog extends StatefulWidget {
  const UpdateDownloadDialog({required this.result, super.key});

  final UpdateCheckResult result;

  @override
  State<UpdateDownloadDialog> createState() => _UpdateDownloadDialogState();
}

class _UpdateDownloadDialogState extends State<UpdateDownloadDialog> {
  late _DownloadStage _stage;
  int _received = 0;
  int? _total;
  File? _file;
  String? _error;

  @override
  void initState() {
    super.initState();
    _stage = widget.result.canDownload
        ? _DownloadStage.ready
        : _DownloadStage.failed;
    if (!widget.result.canDownload) _error = 'no_apk';
  }

  bool get _busy =>
      _stage == _DownloadStage.downloading ||
      _stage == _DownloadStage.installing;

  Future<void> _download() async {
    if (_busy || !widget.result.canDownload) return;
    setState(() {
      _stage = _DownloadStage.downloading;
      _received = 0;
      _total = widget.result.downloadSize;
      _error = null;
    });
    try {
      final file = await UpdateService.instance.downloadApk(
        widget.result,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            _total = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _file = file;
        _stage = _DownloadStage.downloaded;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _stage = _DownloadStage.failed;
        _error = 'download';
      });
    }
  }

  Future<void> _install() async {
    final file = _file;
    if (_busy || file == null) return;
    setState(() {
      _stage = _DownloadStage.installing;
      _error = null;
    });
    final opened = await UpdateInstaller.installApk(file.path);
    if (!mounted) return;
    if (opened) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _stage = _DownloadStage.failed;
      _error = 'install';
    });
  }

  void _close() {
    if (_busy) return;
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final palette = context.zt;
    final version = widget.result.latestVersion ?? '';
    final progress = _total != null && _total! > 0
        ? (_received / _total!).clamp(0.0, 1.0)
        : null;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      backgroundColor: Colors.transparent,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: palette.hairline),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: palette.accent.withValues(alpha: 0.10),
                    ),
                    child: Icon(
                      Icons.system_update_alt_outlined,
                      color: palette.accent,
                      size: 21,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.updateDialogTitle,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: palette.textHi,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'v$version',
                          style: TextStyle(fontSize: 12, color: palette.textLo),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _busy ? null : _close,
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.close, color: palette.textLo),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                l10n.updateDialogMessage(version),
                style: TextStyle(
                  fontSize: 14,
                  height: 1.4,
                  color: palette.textHi,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                l10n.updateDownloadFromGithub,
                style: TextStyle(fontSize: 12, color: palette.textLo),
              ),
              if (widget.result.downloadFileName != null) ...[
                const SizedBox(height: 4),
                Text(
                  '${widget.result.downloadFileName} · ${_formatBytes(widget.result.downloadSize)}',
                  style: TextStyle(fontSize: 12, color: palette.textLo),
                ),
              ],
              const SizedBox(height: 18),
              if (_stage == _DownloadStage.downloading) ...[
                LinearProgressIndicator(
                  value: progress,
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(6),
                  color: palette.accent,
                  backgroundColor: palette.surfaceHi,
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.updateDownloadProgress(
                    version,
                    progress == null ? '…' : '${(progress * 100).round()}',
                  ),
                  style: TextStyle(fontSize: 12, color: palette.textLo),
                ),
              ] else if (_stage == _DownloadStage.installing) ...[
                Row(
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: palette.accent,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      l10n.updateInstalling,
                      style: TextStyle(fontSize: 13, color: palette.textLo),
                    ),
                  ],
                ),
              ] else if (_stage == _DownloadStage.downloaded) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: palette.live.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    l10n.updateDownloadReady,
                    style: TextStyle(fontSize: 13, color: palette.live),
                  ),
                ),
              ] else if (_stage == _DownloadStage.failed) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: palette.danger.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _error == 'no_apk'
                        ? l10n.updateNoApk
                        : _error == 'install'
                        ? l10n.updateInstallFailed
                        : l10n.updateDownloadFailed,
                    style: TextStyle(fontSize: 13, color: palette.danger),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (!_busy)
                    TextButton(
                      onPressed: _close,
                      child: Text(l10n.updateDialogLater),
                    ),
                  const SizedBox(width: 8),
                  if (_stage == _DownloadStage.ready ||
                      _stage == _DownloadStage.failed && _error == 'download')
                    FilledButton.icon(
                      onPressed: _download,
                      icon: const Icon(Icons.download_outlined, size: 18),
                      label: Text(l10n.updateDialogDownload),
                    )
                  else if (_stage == _DownloadStage.downloaded)
                    FilledButton.icon(
                      onPressed: _install,
                      icon: const Icon(Icons.install_mobile_outlined, size: 18),
                      label: Text(l10n.updateInstall),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _formatBytes(int? bytes) {
    if (bytes == null || bytes <= 0) return '大小未知';
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
}
