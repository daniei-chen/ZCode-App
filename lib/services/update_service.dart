import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

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
  });

  final UpdateCheckStatus status;
  final String currentVersion;
  final String? latestVersion;
  final Uri? releaseUri;
  final Uri? downloadUri;
  final String? downloadFileName;
  final int? downloadSize;

  bool get hasUpdate =>
      status == UpdateCheckStatus.updateAvailable && releaseUri != null;

  bool get canDownload => hasUpdate && downloadUri != null;
}

class UpdateDownloadException implements Exception {
  const UpdateDownloadException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => cause == null ? message : '$message: $cause';
}

/// Reads GitHub release metadata and downloads the APK without opening a
/// browser page. GitHub's API is preferred because it exposes the exact asset
/// URL; the public release page remains a fallback for API rate limiting.
class UpdateService {
  UpdateService._();

  static final instance = UpdateService._();

  static const repositoryUrl = 'https://github.com/2421873411a-rgb/ZCode-App';
  static final latestReleasePage = Uri.parse('$repositoryUrl/releases/latest');
  static final latestReleaseApi = Uri.parse(
    'https://api.github.com/repos/2421873411a-rgb/ZCode-App/releases/latest',
  );
  static const _promptedVersionKey = 'zremote.update.promptedVersion';
  static const _apkName = 'ZCode.apk';

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
      return await _checkReleasePage(
        httpClient,
        current: current,
        timeout: timeout,
      );
    } on TimeoutException {
      return UpdateCheckResult(
        status: UpdateCheckStatus.failed,
        currentVersion: current,
      );
    } catch (_) {
      return UpdateCheckResult(
        status: UpdateCheckStatus.failed,
        currentVersion: current,
      );
    } finally {
      if (ownsClient) httpClient.close();
    }
  }

  Future<http.Response> _get(
    http.Client client,
    Uri uri,
    String current,
    Duration timeout, {
    bool followRedirects = true,
  }) async {
    final request = http.Request('GET', uri)
      ..headers.addAll({
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'ZCode-App/$current',
      })
      ..followRedirects = followRedirects
      ..maxRedirects = followRedirects ? 5 : 0;
    return http.Response.fromStream(
      await client.send(request).timeout(timeout),
    ).timeout(timeout);
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

    return _result(
      current: current,
      latest: latest,
      releaseUri: releaseUri,
      downloadUri: _downloadUriForTag(tag),
      downloadFileName: _apkName,
    );
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

      Uri? downloadUri;
      String? downloadFileName;
      int? downloadSize;
      final assets = decoded['assets'];
      if (assets is List) {
        Map? selected;
        for (final entry in assets) {
          if (entry is! Map) continue;
          final name = entry['name'];
          if (name is! String) continue;
          if (name.toLowerCase() == _apkName.toLowerCase()) {
            selected = entry;
            break;
          }
          selected ??= name.toLowerCase().endsWith('.apk') ? entry : null;
        }
        if (selected != null) {
          downloadUri = _safeDownloadUri(selected['browser_download_url']);
          downloadFileName = selected['name'] is String
              ? selected['name'] as String
              : null;
          final size = selected['size'];
          downloadSize = size is num ? size.toInt() : null;
        }
      }

      return _result(
        current: current,
        latest: latest,
        releaseUri: releaseUri,
        downloadUri: downloadUri,
        downloadFileName: downloadFileName,
        downloadSize: downloadSize,
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
    );
  }

  /// Downloads the APK into the app cache and reports byte progress. The
  /// caller can then invoke [UpdateInstaller.installApk] with the returned
  /// file path; no browser or GitHub page is opened.
  Future<File> downloadApk(
    UpdateCheckResult result, {
    http.Client? client,
    Directory? directory,
    void Function(int received, int? total)? onProgress,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    final uri = result.downloadUri;
    if (uri == null) {
      throw const UpdateDownloadException('该版本没有可下载的 APK');
    }

    final httpClient = client ?? http.Client();
    final ownsClient = client == null;
    File? partial;
    try {
      final targetDirectory = directory ?? await getTemporaryDirectory();
      await targetDirectory.create(recursive: true);
      final version = normalizeVersion(result.latestVersion ?? '') ?? 'latest';
      final target = File(
        '${targetDirectory.path}${Platform.pathSeparator}ZCode-$version.apk',
      );
      partial = File('${target.path}.part');
      if (await partial.exists()) await partial.delete();

      final request = http.Request('GET', uri)
        ..headers['User-Agent'] = 'ZCode-App/${result.currentVersion}'
        ..headers['Accept'] = 'application/vnd.android.package-archive';
      final response = await httpClient.send(request).timeout(timeout);
      if (response.statusCode != 200) {
        throw UpdateDownloadException('下载服务器返回 HTTP ${response.statusCode}');
      }

      final total = response.contentLength ?? result.downloadSize;
      var received = 0;
      final sink = partial.openWrite();
      try {
        await for (final chunk in response.stream.timeout(timeout)) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      if (await target.exists()) await target.delete();
      final file = await partial.rename(target.path);
      onProgress?.call(received, total);
      return file;
    } on UpdateDownloadException {
      rethrow;
    } on TimeoutException catch (error) {
      throw UpdateDownloadException('下载更新超时', error);
    } catch (error) {
      throw UpdateDownloadException('下载更新失败', error);
    } finally {
      if (partial != null && await partial.exists()) {
        try {
          await partial.delete();
        } catch (_) {}
      }
      if (ownsClient) httpClient.close();
    }
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
  static String? normalizeVersion(String raw) {
    final match = RegExp(
      r'^\s*[vV]?(\d+)(?:\.(\d+))?(?:\.(\d+))?',
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

  static Uri? _safeDownloadUri(Object? raw) {
    if (raw is! String) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.toLowerCase() != 'github.com' ||
        !uri.path.toLowerCase().startsWith(
          '/2421873411a-rgb/zcode-app/releases/download/',
        ) ||
        !uri.path.toLowerCase().endsWith('.apk')) {
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

  static Uri? _downloadUriForTag(String tag) {
    final release = _releaseUriForTag(tag);
    if (release == null) return null;
    return _safeDownloadUri(
      '$repositoryUrl/releases/download/${Uri.encodeComponent(tag.trim())}/$_apkName',
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
