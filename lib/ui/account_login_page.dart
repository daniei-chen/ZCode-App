import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../services/link_builder.dart';
import '../services/relay_credentials.dart';
import '../state/account_label.dart';
import '../theme.dart';
import '../services/app_log.dart';
import '../services/structured_log.dart';

/// 账号登录页（v1.5.0）：内嵌官方 `/remote/v4` 登录流（OAuth → 回调 →
/// 设备选择页），登录令牌落盘即返回原生首页。这是"开局添加账号"的入口。
///
/// 登录本体完全复用官方页面（OAuth 提供方、风控、设备确认一概不碰），
/// App 只做两件事：导航白名单（与远控页同一策略）+ 轮询 localStorage
/// 里的 `zcodejwttoken`（捕获即入安全存储并 pop）。
class AccountLoginPage extends ConsumerStatefulWidget {
  const AccountLoginPage({super.key});

  @override
  ConsumerState<AccountLoginPage> createState() => _AccountLoginPageState();
}

class _AccountLoginPageState extends ConsumerState<AccountLoginPage> {
  InAppWebViewController? _controller;
  Timer? _poll;
  bool _done = false;
  int _progress = 0;

  static const _loginUrl = 'https://zcode.z.ai/remote/v4';

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _pollToken() async {
    if (_done) return;
    try {
      final url = await _controller?.getUrl();
      // 只有回到官方域后才可能写入了令牌（OAuth 中转域没有）。
      if (url != null && LinkBuilder.isTrustedRemotePage(url)) {
        final result = await _controller?.evaluateJavascript(
          source: AccountLabel.probeScript,
        );
        final token = AccountLabel.extractToken(result?.toString() ?? '');
        if (token != null && token.isNotEmpty) {
          _done = true;
          _poll?.cancel();
          await RelayCredentials.storeJwt(token);
          final label = AccountLabel.displayNameFromToken(
            result?.toString() ?? '',
          );
          if (label != null) {
            ref.read(accountLabelProvider.notifier).report(label);
          }
          if (mounted) Navigator.of(context).pop(true);
        }
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: context.zt.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: l10n.commonBack,
                  onPressed: () => Navigator.of(context).pop(false),
                  icon: Icon(Icons.close, color: context.zt.textLo),
                ),
                Expanded(
                  child: Text(
                    l10n.accountLoginTitle,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: context.zt.textHi,
                    ),
                  ),
                ),
              ],
            ),
            if (_progress < 100)
              LinearProgressIndicator(
                value: _progress == 0 ? null : _progress / 100,
                minHeight: 2,
                color: context.zt.accent,
                backgroundColor: context.zt.hairline,
              ),
            Expanded(
              child: InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri(_loginUrl)),
                initialSettings: InAppWebViewSettings(
                  useShouldOverrideUrlLoading: true,
                  javaScriptEnabled: true,
                  domStorageEnabled: true,
                  thirdPartyCookiesEnabled: false,
                  supportZoom: false,
                ),
                onWebViewCreated: (controller) {
                  _controller = controller;
                  // 登录完成没有任何页面事件可订阅——固定节流轮询令牌。
                  _poll?.cancel();
                  _poll = Timer.periodic(
                    const Duration(milliseconds: 1500),
                    (_) => unawaited(_pollToken()),
                  );
                },
                onLoadStop: (controller, uri) {
                  AppLog.event(
                    LogEvent.webviewLoadStop,
                    level: LogLevel.debug,
                    fields: {LogField.route: uri?.toString()},
                  );
                  unawaited(_pollToken());
                },
                shouldOverrideUrlLoading: (_, action) async {
                  final uri = action.request.url;
                  if (action.isForMainFrame != true) {
                    return LinkBuilder.isTrustedOrigin(uri)
                        ? NavigationActionPolicy.ALLOW
                        : NavigationActionPolicy.CANCEL;
                  }
                  // 与远控页同一导航白名单：官方域 + 登录中转域。
                  return LinkBuilder.isTrustedSignInTarget(uri)
                      ? NavigationActionPolicy.ALLOW
                      : NavigationActionPolicy.CANCEL;
                },
                onProgressChanged: (_, progress) {
                  if (mounted) setState(() => _progress = progress);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
