import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_log.dart';
import 'outbound_url_policy.dart';
import 'structured_log.dart';
import 'update_installer.dart';

enum UpdateCheckStatus { upToDate, updateAvailable, noRelease, failed }

class UpdateCheckResult {
  const UpdateCheckResult({
    required this.status,
    required this.currentVersion,
    this.latestVersion,
    this.releaseUri,
    this.downloadUri,
    this.downloadFileName,
    this.downloadSize,
    this.releaseBody,
    this.assetDigest,
  });

  final UpdateCheckStatus status;
  final String currentVersion;
  final String? latestVersion;
  final Uri? releaseUri;
  final Uri? downloadUri;
  final String? downloadFileName;
  final int? downloadSize;

  /// Release 说明原文（Markdown），供更新弹窗展示"本次更新内容"。
  final String? releaseBody;

  /// GitHub 提供的资产校验和（形如 `sha256:...`），下载完成后比对。
  final String? assetDigest;

  bool get hasUpdate =>
      status == UpdateCheckStatus.updateAvailable && releaseUri != null;

  /// 仅当拿到可校验的资产摘要时才允许应用内下载（fail-closed）：没有
  /// digest 就没有完整性结论，此时只引导用户到 GitHub Release 页手动下载。
  bool get canDownload =>
      hasUpdate &&
      downloadUri != null &&
      assetDigest != null &&
      assetDigest!.isNotEmpty;
}

class UpdateDownloadException implements Exception {
  const UpdateDownloadException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => cause == null ? message : '$message: $cause';
}

/// 用户主动取消下载；不是错误，弹窗应回到可重新下载的状态。
class UpdateDownloadCancelled implements Exception {
  const UpdateDownloadCancelled();

  @override
  String toString() => '下载已取消';
}

/// 安装前预校验发现的问题类型。
enum ApkPrecheckIssue {
  /// APK 读不出元数据（下载不完整或文件损坏）。
  unreadable,

  /// APK 包名与本应用不符（张冠李戴的包）。
  wrongPackage,

  /// 设备上已装更高 versionCode——系统会拒绝并报
  /// INSTALL_FAILED_VERSION_DOWNGRADE(-25)，必须在交给系统前拦下。
  downgrade,

  /// 下载包签名证书与已装应用不一致（U3）——放给系统安装器只会得到一句
  /// "签名不一致"，这里提前用人话拦下。
  signerMismatch,
}

/// 安装前预校验（纯函数，输入都是普通值，可直接单测）。
/// 返回 null 表示通过，允许交给系统安装器。
ApkPrecheckIssue? precheckApk({
  required ApkArchiveInfo? archive,
  required String expectedPackage,
  required int installedVersionCode,
  String? installedSignerSha256,
}) {
  if (archive == null) return ApkPrecheckIssue.unreadable;
  if (archive.packageName != expectedPackage) {
    return ApkPrecheckIssue.wrongPackage;
  }
  if (archive.versionCode < installedVersionCode) {
    return ApkPrecheckIssue.downgrade;
  }
  // 双方签名都读到且不一致 → 拦下；任一缺失时保留系统安装器兜底。
  final archiveSigner = archive.signerSha256?.toLowerCase();
  if (installedSignerSha256 != null && archiveSigner != null) {
    if (archiveSigner != installedSignerSha256.toLowerCase()) {
      return ApkPrecheckIssue.signerMismatch;
    }
  }
  return null;
}

/// Reads GitHub release metadata and downloads the APK without opening a
/// browser page. GitHub's API is preferred because it exposes the exact asset
/// URL; the public release page remains a fallback for API rate limiting.
class UpdateService {
  UpdateService._();

  static final instance = UpdateService._();

  static const repositoryUrl = 'https://github.com/2421873411a-rgb/ZCode-App';
  static final latestReleasePage = Uri.parse('$repositoryUrl/releases/latest');

  /// 非 Android 平台的更新入口：直接打开最新发布页。
  static Future<void> openReleasePage() async {
    try {
      await launchUrl(latestReleasePage, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }
  static final latestReleaseApi = Uri.parse(
    'https://api.github.com/repos/2421873411a-rgb/ZCode-App/releases/latest',
  );
  static const _promptedVersionKey = 'zremote.update.promptedVersion';

  /// 安装包体积硬上限：正常 release 约 30-70 MB，超限视为异常响应。
  static const int _maxApkBytes = 200 * 1024 * 1024;

  /// Returns whether the foreground update prompt has already been shown for
  /// this exact release. A newer release naturally gets a new prompt.
  Future<bool> wasPrompted(String version) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_promptedVersionKey) == version;
    } catch (_) {
      // A storage failure must not hide an available update forever.
      return false;
    }
  }

  Future<void> markPrompted(String version) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_promptedVersionKey, version);
    } catch (_) {}
  }

  Future<UpdateCheckResult> checkForUpdate({
    http.Client? client,
    String? currentVersion,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final current = currentVersion ?? await _platformVersion();
    if (current == null || current.isEmpty) {
      return const UpdateCheckResult(
        status: UpdateCheckStatus.failed,
        currentVersion: '',
      );
    }

    final httpClient = client ?? http.Client();
    final ownsClient = client == null;
    try {
      final apiResponse = await _get(
        httpClient,
        latestReleaseApi,
        current,
        timeout,
      );
      if (apiResponse.statusCode == 404) {
        return UpdateCheckResult(
          status: UpdateCheckStatus.noRelease,
          currentVersion: current,
        );
      }
      if (apiResponse.statusCode >= 200 && apiResponse.statusCode < 300) {
        final apiResult = _resultFromApi(apiResponse.body, current);
        if (apiResult != null) return apiResult;
      }

      // Anonymous API requests can be rate-limited. The public page redirect
      // still gives us the release tag, from which the canonical APK URL can
      // be formed without opening a browser.
      return await _checkReleasePageOrFailed(
        httpClient,
        current: current,
        timeout: timeout,
      );
    } on TimeoutException {
      // F13/R-10：API 的 DNS/连接超时/断流不代表"检查更新失败"——网页回退是另一条
      // 独立通道，异常路径同样要有界地试一次（总预算 ≤ 2×timeout）。
      // **必须 await**：不 await 时 finally 会在回退 Future 完成前关闭 owned
      // client（审计复现：fallback ObservedClosed，下载无法完成）。
      return await _checkReleasePageOrFailed(
        httpClient,
        current: current,
        timeout: timeout,
      );
    } catch (_) {
      return await _checkReleasePageOrFailed(
        httpClient,
        current: current,
        timeout: timeout,
      );
    } finally {
      if (ownsClient) httpClient.close();
    }
  }

  /// 回退到发布页；回退本身也失败时返回 failed（绝不假装"已是最新版"）。
  Future<UpdateCheckResult> _checkReleasePageOrFailed(
    http.Client client, {
    required String current,
    required Duration timeout,
  }) async {
    try {
      return await _checkReleasePage(client, current: current, timeout: timeout);
    } catch (_) {
      return UpdateCheckResult(
        status: UpdateCheckStatus.failed,
        currentVersion: current,
      );
    }
  }

  Future<http.Response> _get(
    http.Client client,
    Uri uri,
    String current,
    Duration timeout, {
    bool followRedirects = true,
  }) async {
    final reason = OutboundUrlPolicy.rejectionReason(uri);
    if (reason != null) {
      AppLog.event(LogEvent.updateOutboundBlocked, level: LogLevel.warn, fields: {
        LogField.reason: reason,
      });
      throw StateError('blocked outbound url: $reason');
    }
    // 客户端自动跟随重定向会绕过白名单（只校验了第一跳）：这里改为手动逐跳校验。
    var hopUri = uri;
    for (var hop = 0; hop <= OutboundUrlPolicy.maxRedirects; hop++) {
      final request = http.Request('GET', hopUri)
        ..headers.addAll({
          'Accept': 'application/vnd.github+json',
          'User-Agent': 'ZCode-App/$current',
        })
        ..followRedirects = false
        ..maxRedirects = 0;
      final response = await http.Response.fromStream(
        await client.send(request).timeout(timeout),
      ).timeout(timeout);
      final isRedirect = response.statusCode >= 300 && response.statusCode < 400;
      if (!isRedirect || !followRedirects) return response;
      final next = OutboundUrlPolicy.resolveRedirect(
        hopUri,
        response.headers['location'],
      );
      if (next == null) {
        AppLog.event(LogEvent.updateOutboundBlocked, level: LogLevel.warn, fields: {
          LogField.reason: 'redirect_not_allowed',
        });
        throw StateError('blocked redirect target');
      }
      hopUri = next;
    }
    throw StateError('too many redirects');
  }

  Future<UpdateCheckResult> _checkReleasePage(
    http.Client client, {
    required String current,
    required Duration timeout,
  }) async {
    final response = await _get(
      client,
      latestReleasePage,
      current,
      timeout,
      followRedirects: false,
    );
    if (response.statusCode == 404) {
      return UpdateCheckResult(
        status: UpdateCheckStatus.noRelease,
        currentVersion: current,
      );
    }

    final releaseUri = response.statusCode >= 300 && response.statusCode < 400
        ? _safeReleaseUri(response.headers['location'])
        : _releaseUriFromHtml(response.body);
    final tag = releaseUri == null
        ? null
        : releaseUri.pathSegments.isEmpty
        ? null
        : releaseUri.pathSegments.last;
    final latest = tag == null ? null : normalizeVersion(tag);
    if (tag == null || latest == null || releaseUri == null) {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return UpdateCheckResult(
          status: UpdateCheckStatus.noRelease,
          currentVersion: current,
        );
      }
      return UpdateCheckResult(
        status: UpdateCheckStatus.failed,
        currentVersion: current,
      );
    }

    // API 限流时的兜底：发布契约保证每个 Release 都有 ZCode-v<版本>.apk
    // 与同名 .sha256 伴随资产，因此先取回 sidecar 摘要——拿到 digest 才
    // 允许自动下载，仍然 fail-closed（U1）；拿不到（404/网络失败/摘要不
    // 合格式）就退回"引导 GitHub 页"的老行为，绝不盲猜下载地址。
    final assetName = 'ZCode-v$latest.apk';
    final sidecarUri = _safeDownloadUri(
      '$repositoryUrl/releases/download/$tag/$assetName.sha256',
      allowedExtension: '.sha256',
    );
    String? assetDigest;
    if (sidecarUri != null) {
      assetDigest = await _fetchSidecarDigest(
        sidecarUri,
        client,
        current: current,
        expectedFileName: assetName,
        timeout: timeout,
      );
    }
    return _result(
      current: current,
      latest: latest,
      releaseUri: releaseUri,
      downloadUri: assetDigest == null
          ? null
          : _safeDownloadUri('$repositoryUrl/releases/download/$tag/$assetName'),
      downloadFileName: assetDigest == null ? null : assetName,
      assetDigest: assetDigest,
    );
  }

  /// 下载 .sha256 伴随资产并解析摘要。内容为 sha256sum 输出格式：
  /// `<64 位十六进制>  <文件名>`。文件名必须与契约资产完全一致，
  /// 防止把别的文件的摘要当成安装包的。
  ///
  /// R-11：必须复用 [_get] 的**逐跳校验路径**——旧实现用 `client.get(uri)`
  /// 让客户端自动跟随重定向（审计受控测试确认 `sidecarFollowsRedirects ==
  /// true`），白名单只挡得住第一跳。
  ///
  /// 注意参数语义：`_get` 的 `followRedirects` 含义是"是否跟随"，而 `_get`
  /// 内部本来就是对每一跳做 `resolveRedirect` 白名单校验的手动跟随。因此这里
  /// **不能传 `followRedirects: false`**——那等于"遇到 302 直接返回"，而
  /// GitHub release 资产的首跳必是 302 到 `release-assets.githubusercontent.com`
  /// （白名单内），sidecar 将永远取不到摘要、API 限流回退路径的自动下载失效。
  /// 默认（true）才是"逐跳校验后跟随"。
  Future<String?> _fetchSidecarDigest(
    Uri uri,
    http.Client client, {
    required String current,
    required String expectedFileName,
    required Duration timeout,
  }) async {
    try {
      final response = await _get(
        client,
        uri,
        current,
        timeout,
      );
      if (response.statusCode != 200) return null;
      final match = RegExp(
        r'^([0-9a-fA-F]{64})\s+\*?(.+)$',
      ).firstMatch(response.body.trim());
      if (match == null) return null;
      if (match.group(2)!.trim() != expectedFileName) return null;
      return 'sha256:${match.group(1)!.toLowerCase()}';
    } catch (_) {
      return null;
    }
  }

  UpdateCheckResult? _resultFromApi(String body, String current) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final tagValue = decoded['tag_name'];
      if (tagValue is! String || normalizeVersion(tagValue) == null) {
        return null;
      }
      final tag = tagValue;
      final latest = normalizeVersion(tag)!;
      final releaseUri =
          _safeReleaseUri(decoded['html_url']) ?? _releaseUriForTag(tag);
      if (releaseUri == null) return null;

      final releaseBody =
          decoded['body'] is String ? decoded['body'] as String : null;
      Uri? downloadUri;
      String? downloadFileName;
      int? downloadSize;
      String? assetDigest;
      final assets = decoded['assets'];
      if (assets is List) {
        Map? selected;
        for (final entry in assets) {
          if (entry is! Map) continue;
          final name = entry['name'];
          if (name is! String) continue;
          // 命名契约：只认 ZCode-v<版本>.apk 精确名。不回退到 ZCode.apk
          // 或任意 .apk——多资产发布时选错包比选不到更危险（U2）。
          if (name.toLowerCase() == 'zcode-v$latest.apk') {
            selected = entry;
            break;
          }
        }
        if (selected != null) {
          downloadUri = _safeDownloadUri(selected['browser_download_url']);
          downloadFileName = selected['name'] is String
              ? selected['name'] as String
              : null;
          final size = selected['size'];
          downloadSize = size is num ? size.toInt() : null;
          final digestValue = selected['digest'];
          if (digestValue is String && digestValue.isNotEmpty) {
            assetDigest = digestValue;
          }
        }
      }

      return _result(
        current: current,
        latest: latest,
        releaseUri: releaseUri,
        downloadUri: downloadUri,
        downloadFileName: downloadFileName,
        downloadSize: downloadSize,
        releaseBody: releaseBody,
        assetDigest: assetDigest,
      );
    } catch (_) {
      return null;
    }
  }

  UpdateCheckResult _result({
    required String current,
    required String latest,
    required Uri releaseUri,
    Uri? downloadUri,
    String? downloadFileName,
    int? downloadSize,
    String? releaseBody,
    String? assetDigest,
  }) {
    final hasUpdate = compareVersions(latest, current) > 0;
    return UpdateCheckResult(
      status: hasUpdate
          ? UpdateCheckStatus.updateAvailable
          : UpdateCheckStatus.upToDate,
      currentVersion: current,
      latestVersion: latest,
      releaseUri: releaseUri,
      downloadUri: downloadUri,
      downloadFileName: downloadFileName,
      downloadSize: downloadSize,
      releaseBody: releaseBody,
      assetDigest: assetDigest,
    );
  }

  /// Downloads the APK into the app cache and reports byte progress. The
  /// caller can then invoke [UpdateInstaller.installApk] with the returned
  /// file path; no browser or GitHub page is opened.
  ///
  /// 网络健壮性：数据流间隔超过 [stallTimeout] 判为停顿；失败保留 `.part`
  /// 并用 `Range` 断点续传（最多 [maxAttempts] 次）；提供 `assetDigest`
  /// 时下载完成后强制 SHA256 比对。
  Future<File> downloadApk(
    UpdateCheckResult result, {
    http.Client? client,
    Directory? directory,
    void Function(int received, int? total)? onProgress,
    bool Function()? isCancelled,
    Duration timeout = const Duration(seconds: 8),
    Duration stallTimeout = const Duration(seconds: 30),
    int maxAttempts = 4,
  }) async {
    final uri = result.downloadUri;
    if (uri == null) {
      throw const UpdateDownloadException('该版本没有可下载的 APK');
    }
    // 服务入口自身强校验（F14/U04）：安全不能依赖"按钮先做过 canDownload
    // 检查"——直接调用下载服务时同样只接受官方仓库 HTTPS 发布路径（默认
    // 端口、无 userInfo）且带非空摘要的资产。
    if (_safeDownloadUri(uri.toString()) == null ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443 ||
        OutboundUrlPolicy.rejectionReason(uri) != null) {
      throw const UpdateDownloadException('下载地址不在官方发布路径内，已拒绝');
    }
    final digest = result.assetDigest;
    if (digest == null || digest.isEmpty) {
      throw const UpdateDownloadException('缺少摘要，拒绝下载未经验证的安装包');
    }
    final declared = result.downloadSize;
    if (declared != null && declared > _maxApkBytes) {
      throw UpdateDownloadException(
        '安装包体积 ${(declared / 1024 / 1024).round()} MB 超过上限，已拒绝下载',
      );
    }

    final httpClient = client ?? http.Client();
    final ownsClient = client == null;
    try {
      final baseDirectory = directory ?? await getTemporaryDirectory();
      // 与 FileProvider 的 file_paths（updates/ 子目录）保持一致，避免
      // 把整个 cache 目录暴露给安装器。
      final targetDirectory = Directory(
        '${baseDirectory.path}${Platform.pathSeparator}updates',
      );
      await targetDirectory.create(recursive: true);
      final version = normalizeVersion(result.latestVersion ?? '') ?? 'latest';
      final target = File(
        '${targetDirectory.path}${Platform.pathSeparator}ZCode-$version.apk',
      );
      final partial = File('${target.path}.part');

      // 断点续传：`.part` 保留已下载字节，失败后从断点继续。
      var received = 0;
      if (await partial.exists()) {
        received = await partial.length();
      }

      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        try {
          if (isCancelled?.call() ?? false) {
            throw const UpdateDownloadCancelled();
          }
          // 每次尝试前按 `.part` 的真实字节数续传：上一次失败可能发生在
          // 已写入若干字节之后（此时 received 尚未回传）。
          received = await partial.exists() ? await partial.length() : 0;
          received = await _downloadChunk(
            result: result,
            httpClient: httpClient,
            uri: uri,
            partial: partial,
            received: received,
            onProgress: onProgress,
            isCancelled: isCancelled,
            timeout: timeout,
            stallTimeout: stallTimeout,
          );
          break;
        } on UpdateDownloadCancelled {
          // 用户取消：清理半成品，避免留下永远续不上的断点。
          if (await partial.exists()) {
            try {
              await partial.delete();
            } catch (_) {}
          }
          rethrow;
        } catch (e) {
          if (attempt >= maxAttempts) rethrow;
          // 退避后重试：`.part` 保留，下一次从断点继续。
          await Future<void>.delayed(Duration(seconds: 2 * attempt));
        }
      }

      if (await target.exists()) await target.delete();
      final file = await partial.rename(target.path);

      // 完整性校验：GitHub 提供 sha256 digest 时强制比对，坏包不进安装器。
      final expected = result.assetDigest;
      if (expected != null && expected.isNotEmpty) {
        final expectedHex = expected.replaceFirst('sha256:', '').toLowerCase();
        final actual = (await sha256.bind(file.openRead()).first).toString();
        if (actual != expectedHex) {
          try {
            await file.delete();
          } catch (_) {
            // Windows 上刚读完的文件句柄可能短暂残留；下一次下载会覆盖
            // 同名文件，不因删除失败而阻塞报错。
          }
          throw const UpdateDownloadException(
            '安装包校验失败（SHA256 不匹配），请重新下载',
          );
        }
      }
      onProgress?.call(received, received);
      return file;
    } on UpdateDownloadCancelled {
      rethrow;
    } on UpdateDownloadException {
      rethrow;
    } catch (e) {
      // `.part` 保留：用户点重试时从断点继续，不从头再来。
      throw UpdateDownloadException('网络下载失败，已保留下载进度', e);
    } finally {
      if (ownsClient) httpClient.close();
    }
  }

  Future<int> _downloadChunk({
    required UpdateCheckResult result,
    required http.Client httpClient,
    required Uri uri,
    required File partial,
    required int received,
    required void Function(int, int?)? onProgress,
    required bool Function()? isCancelled,
    required Duration timeout,
    required Duration stallTimeout,
  }) async {
    final request = http.Request('GET', uri)
      ..headers['User-Agent'] = 'ZCode-App/${result.currentVersion}'
      ..headers['Accept'] = 'application/vnd.android.package-archive'
      // 重定向由下面的逐跳校验处理。
      ..followRedirects = false;
    final resume = received > 0;
    if (resume) {
      request.headers['Range'] = 'bytes=$received-';
    }
    var response = await httpClient.send(request).timeout(timeout);

    // 重定向逐跳校验：自动跟随会绕过 host 白名单与私网地址检查。
    var hops = 0;
    var requestUri = uri;
    while (response.statusCode >= 300 &&
        response.statusCode < 400 &&
        hops < OutboundUrlPolicy.maxRedirects) {
      final next = OutboundUrlPolicy.resolveRedirect(
        requestUri,
        response.headers['location'],
      );
      if (next == null) {
        AppLog.event(LogEvent.updateOutboundBlocked, level: LogLevel.warn, fields: {
          LogField.reason: 'redirect_not_allowed',
        });
        throw const UpdateDownloadException('下载被重定向到非官方地址，已拒绝');
      }
      requestUri = next;
      hops++;
      final hopRequest = http.Request('GET', requestUri)
        ..headers['User-Agent'] = 'ZCode-App/${result.currentVersion}'
        ..headers['Accept'] = 'application/vnd.android.package-archive'
        ..followRedirects = false;
      if (resume) {
        hopRequest.headers['Range'] = 'bytes=$received-';
      }
      response = await httpClient.send(hopRequest).timeout(timeout);
    }

    // 服务器不支持 Range（整包 200）→ 从头开始；416 → 断点已到文件尾。
    var offset = received;
    if (response.statusCode == 416) {
      final expected = result.downloadSize;
      if (expected != null && received == expected) return received;
      throw UpdateDownloadException(
        '下载服务器返回 HTTP ${response.statusCode}',
      );
    }
    if (response.statusCode == 200) {
      offset = 0;
      if (await partial.exists()) await partial.delete();
    } else if (response.statusCode == 206) {
      // 续传必须校验服务器返回的起点与本地断点一致，防止错位拼接。
      final rangeHeader = response.headers['content-range'];
      final match = rangeHeader == null
          ? null
          : RegExp(r'bytes (\d+)-').firstMatch(rangeHeader);
      final start = match == null ? null : int.tryParse(match.group(1)!);
      if (start != received) {
        if (await partial.exists()) await partial.delete();
        throw UpdateDownloadException(
          '续传区间不符（服务器起点 $start，本地 $received），已重置下载',
        );
      }
    } else if (response.statusCode != 200) {
      throw UpdateDownloadException(
        '下载服务器返回 HTTP ${response.statusCode}',
      );
    }

    final remaining = response.contentLength;
    final total = remaining != null ? offset + remaining : result.downloadSize;
    final sink = partial.openWrite(
      mode: offset > 0 ? FileMode.append : FileMode.write,
    );
    var local = offset;
    var oversized = false;
    var cancelled = false;
    IOSink? openSink;
    try {
      openSink = sink;
      await for (final chunk in response.stream.timeout(stallTimeout)) {
        if (isCancelled?.call() ?? false) {
          cancelled = true;
          break;
        }
        sink.add(chunk);
        local += chunk.length;
        if (local > _maxApkBytes) {
          oversized = true;
          break;
        }
        onProgress?.call(local, total);
      }
      await sink.flush();
    } finally {
      await openSink?.close();
    }
    if (cancelled) {
      if (await partial.exists()) await partial.delete();
      throw const UpdateDownloadCancelled();
    }
    if (oversized) {
      if (await partial.exists()) await partial.delete();
      throw const UpdateDownloadException(
        '下载数据超过大小上限，已中断并清理',
      );
    }
    return local;
  }


  Future<bool> openRelease(Uri uri) async {
    if (uri.scheme.toLowerCase() != 'https' ||
        uri.host.toLowerCase() != 'github.com') {
      return false;
    }
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  static Future<String?> _platformVersion() async {
    try {
      return (await PackageInfo.fromPlatform()).version.trim();
    } catch (_) {
      return null;
    }
  }

  /// Removes a leading `v` and normalizes a GitHub tag to `major.minor.patch`.
  ///
  /// iter12 N-P2-6：匹配**必须吃掉整个 tag**（结尾锚定）。此前 `v1.2.3-rc.1`
  /// 会归一成 `1.2.3`（预发布与正式版同值）、`v1.2.3-malicious` 会被当成
  /// 正常版本号参与比较——tag 契约是 `vMAJOR.MINOR.PATCH`，任何带后缀的
  /// 形态一律按"非法 tag"处理（fail-closed：更新检查直接跳过它）。
  static String? normalizeVersion(String raw) {
    final match = RegExp(
      r'^\s*[vV]?(\d+)(?:\.(\d+))?(?:\.(\d+))?\s*$',
    ).firstMatch(raw);
    if (match == null) return null;
    return '${match.group(1)}.${match.group(2) ?? '0'}.${match.group(3) ?? '0'}';
  }

  static int compareVersions(String left, String right) {
    final a = _versionParts(left);
    final b = _versionParts(right);
    for (var i = 0; i < 3; i++) {
      final comparison = a[i].compareTo(b[i]);
      if (comparison != 0) return comparison;
    }
    return 0;
  }

  static List<int> _versionParts(String raw) {
    final match = RegExp(
      r'^\s*[vV]?(\d+)(?:\.(\d+))?(?:\.(\d+))?',
    ).firstMatch(raw);
    if (match == null) return const [0, 0, 0];
    return [
      int.tryParse(match.group(1) ?? '') ?? 0,
      int.tryParse(match.group(2) ?? '') ?? 0,
      int.tryParse(match.group(3) ?? '') ?? 0,
    ];
  }

  static Uri? _safeReleaseUri(Object? raw) {
    if (raw is! String) return null;
    final parsed = Uri.tryParse(raw);
    final uri = parsed == null
        ? null
        : parsed.hasScheme
        ? parsed
        : latestReleasePage.resolve(raw);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.toLowerCase() != 'github.com' ||
        !uri.path.toLowerCase().startsWith(
          '/2421873411a-rgb/zcode-app/releases/tag/',
        )) {
      return null;
    }
    return uri;
  }

  static Uri? _safeDownloadUri(Object? raw, {String allowedExtension = '.apk'}) {
    if (raw is! String) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.toLowerCase() != 'github.com' ||
        !uri.path.toLowerCase().startsWith(
          '/2421873411a-rgb/zcode-app/releases/download/',
        ) ||
        !uri.path.toLowerCase().endsWith(allowedExtension)) {
      return null;
    }
    return uri;
  }

  static Uri? _releaseUriForTag(String tag) {
    if (!RegExp(r'^\s*[vV]?\d+(?:\.\d+){0,2}\s*$').hasMatch(tag)) {
      return null;
    }
    return _safeReleaseUri(
      '$repositoryUrl/releases/tag/${Uri.encodeComponent(tag.trim())}',
    );
  }


  static Uri? _releaseUriFromHtml(String html) {
    final match = RegExp(
      r'https://github\.com/2421873411a-rgb/ZCode-App/releases/tag/[^"\s<]+',
      caseSensitive: false,
    ).firstMatch(html);
    return _safeReleaseUri(match?.group(0));
  }
}
