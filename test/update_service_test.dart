import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:zremote/services/update_service.dart';

class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

void main() {
  test('normalizes GitHub tags and compares release versions', () {
    expect(UpdateService.normalizeVersion('v1.6.0'), '1.6.0');
    expect(UpdateService.normalizeVersion('release-2026'), isNull);
    expect(UpdateService.compareVersions('v1.6.0', '1.5.0'), greaterThan(0));
    expect(UpdateService.compareVersions('1.5', '1.5.0'), 0);
    expect(UpdateService.compareVersions('1.4.9', '1.5.0'), lessThan(0));
  });

  test('reads the exact APK asset URL from the GitHub release API', () async {
    final client = MockClient((request) async {
      expect(request.url, UpdateService.latestReleaseApi);
      return http.Response(
        '{"tag_name":"v1.0.2",'
        '"html_url":"https://github.com/2421873411a-rgb/ZCode-App/releases/tag/v1.0.2",'
        '"assets":[{"name":"ZCode.apk",'
        '"size":1234,'
        '"browser_download_url":"https://github.com/2421873411a-rgb/ZCode-App/releases/download/v1.0.2/ZCode.apk"}]}',
        200,
      );
    });

    final result = await UpdateService.instance.checkForUpdate(
      client: client,
      currentVersion: '1.0.0',
    );

    expect(result.status, UpdateCheckStatus.updateAvailable);
    expect(result.latestVersion, '1.0.2');
    expect(result.canDownload, isTrue);
    expect(
      result.downloadUri.toString(),
      'https://github.com/2421873411a-rgb/ZCode-App/releases/download/v1.0.2/ZCode.apk',
    );
    expect(result.downloadFileName, 'ZCode.apk');
    expect(result.downloadSize, 1234);
  });

  test('API 限流时从公开发布页获取版本并构造 APK 下载地址', () async {
    final client = MockClient((request) async {
      if (request.url == UpdateService.latestReleaseApi) {
        return http.Response('rate limited', 403);
      }
      expect(request.url, UpdateService.latestReleasePage);
      return http.Response(
        '',
        302,
        headers: {
          'location':
              'https://github.com/2421873411a-rgb/ZCode-App/releases/tag/v1.0.1',
        },
      );
    });

    final result = await UpdateService.instance.checkForUpdate(
      client: client,
      currentVersion: '1.0.0',
    );

    expect(result.status, UpdateCheckStatus.updateAvailable);
    expect(result.latestVersion, '1.0.1');
    expect(
      result.releaseUri.toString(),
      'https://github.com/2421873411a-rgb/ZCode-App/releases/tag/v1.0.1',
    );
    expect(
      result.downloadUri.toString(),
      'https://github.com/2421873411a-rgb/ZCode-App/releases/download/v1.0.1/ZCode.apk',
    );
  });

  test('empty GitHub releases page is reported as no release', () async {
    final client = MockClient((request) async {
      if (request.url == UpdateService.latestReleaseApi) {
        return http.Response('rate limited', 403);
      }
      expect(request.url, UpdateService.latestReleasePage);
      return http.Response('No releases', 200);
    });
    final result = await UpdateService.instance.checkForUpdate(
      client: client,
      currentVersion: '1.0.0',
    );

    expect(result.status, UpdateCheckStatus.noRelease);
  });

  test('downloads APK bytes into the app cache and reports progress', () async {
    final directory = await Directory.systemTemp.createTemp('zcode-update-');
    final result = UpdateCheckResult(
      status: UpdateCheckStatus.updateAvailable,
      currentVersion: '1.0.0',
      latestVersion: '1.0.2',
      releaseUri: Uri.parse(
        'https://github.com/2421873411a-rgb/ZCode-App/releases/tag/v1.0.2',
      ),
      downloadUri: Uri.parse(
        'https://github.com/2421873411a-rgb/ZCode-App/releases/download/v1.0.2/ZCode.apk',
      ),
      downloadFileName: 'ZCode.apk',
      downloadSize: 5,
    );
    final progress = <int>[];
    final client = _StreamingClient((request) async {
      expect(request.url, result.downloadUri);
      return http.StreamedResponse(
        Stream<List<int>>.fromIterable([
          [1, 2],
          [3, 4, 5],
        ]),
        200,
        contentLength: 5,
      );
    });

    try {
      final file = await UpdateService.instance.downloadApk(
        result,
        client: client,
        directory: directory,
        onProgress: (received, _) => progress.add(received),
      );
      expect(await file.readAsBytes(), [1, 2, 3, 4, 5]);
      expect(progress.last, 5);
      expect(file.path, endsWith('ZCode-1.0.2.apk'));
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
