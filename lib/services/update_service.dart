import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
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
  static final latestReleaseApi = Uri.parse('$repositoryUrl/releases/latest');
  static final latestReleasePage = Uri.parse('$repositoryUrl/releases/latest');

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
      final response = await httpClient
          .get(
            Uri.parse(
              'https://api.github.com/repos/2421873411a-rgb/ZCode-App/releases/latest',
            ),
            headers: {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'ZCode-App/$current',
            },
          )
          .timeout(timeout);

      // GitHub returns 404 when the repository has no published release yet.
      if (response.statusCode == 404) {
        return UpdateCheckResult(
          status: UpdateCheckStatus.noRelease,
          currentVersion: current,
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return UpdateCheckResult(
          status: UpdateCheckStatus.failed,
          currentVersion: current,
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return UpdateCheckResult(
          status: UpdateCheckStatus.failed,
          currentVersion: current,
        );
      }
      final rawTag = decoded['tag_name'] ?? decoded['name'];
      final latest = rawTag is String ? normalizeVersion(rawTag) : null;
      if (latest == null) {
        return UpdateCheckResult(
          status: UpdateCheckStatus.noRelease,
          currentVersion: current,
        );
      }

      final releaseUri =
          _safeReleaseUri(decoded['html_url']) ?? latestReleasePage;
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
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.toLowerCase() != 'github.com' ||
        !uri.path.toLowerCase().startsWith('/2421873411a-rgb/zcode-app')) {
      return null;
    }
    return uri;
  }
}
