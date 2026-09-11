import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

enum UpdateCheckStatus { upToDate, updateAvailable, noRelease, failed }

class UpdateCheckResult {
  const UpdateCheckResult({
    required this.status,
    required this.currentVersion,
    this.latestVersion,
    this.releaseUri,
  });

  final UpdateCheckStatus status;
  final String currentVersion;
  final String? latestVersion;
  final Uri? releaseUri;

  bool get hasUpdate =>
      status == UpdateCheckStatus.updateAvailable && releaseUri != null;
}

/// Reads the public GitHub release marker without coupling the UI to GitHub.
///
/// A missing release is a normal state while the project is still being
/// prepared for publication. Network failures are intentionally silent for
/// the launch-time check and are surfaced only by the manual Settings action.
class UpdateService {
  UpdateService._();

  static final instance = UpdateService._();

  static const repositoryUrl = 'https://github.com/2421873411a-rgb/ZCode-App';
  static final latestReleasePage = Uri.parse('$repositoryUrl/releases/latest');
  static const _promptedVersionKey = 'zremote.update.promptedVersion';

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
      // The REST API is rate-limited for anonymous mobile clients. The public
      // /releases/latest page is intentionally requested without following
      // redirects; its Location header is the canonical latest release tag.
      final request = http.Request('GET', latestReleasePage)
        ..followRedirects = false
        ..maxRedirects = 0
        ..headers.addAll({
          'Accept': 'text/html,application/xhtml+xml',
          'User-Agent': 'ZCode-App/$current',
        });
      final response = await http.Response.fromStream(
        await httpClient.send(request).timeout(timeout),
      ).timeout(timeout);

      if (response.statusCode == 404) {
        return UpdateCheckResult(
          status: UpdateCheckStatus.noRelease,
          currentVersion: current,
        );
      }
      final releaseUri = response.statusCode >= 300 && response.statusCode < 400
          ? _safeReleaseUri(response.headers['location'])
          : _releaseUriFromHtml(response.body);
      final latest = releaseUri == null
          ? null
          : normalizeVersion(releaseUri.pathSegments.last);
      if (latest == null) {
        if (response.statusCode >= 200 && response.statusCode < 300) {
          // A 200 page with no /releases/tag/... link is GitHub's empty
          // releases page, not a transient network error.
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
      final hasUpdate = compareVersions(latest, current) > 0;
      return UpdateCheckResult(
        status: hasUpdate
            ? UpdateCheckStatus.updateAvailable
            : UpdateCheckStatus.upToDate,
        currentVersion: current,
        latestVersion: latest,
        releaseUri: releaseUri,
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
        !uri.path.toLowerCase().startsWith('/2421873411a-rgb/zcode-app')) {
      return null;
    }
    return uri;
  }

  static Uri? _releaseUriFromHtml(String html) {
    final match = RegExp(
      r'https://github\.com/2421873411a-rgb/ZCode-App/releases/tag/[^"\s<]+',
      caseSensitive: false,
    ).firstMatch(html);
    return _safeReleaseUri(match?.group(0));
  }
}
