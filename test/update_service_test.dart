import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
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


/// Windows 下新文件可能被杀软短暂占用，删除临时目录时重试几次。
Future<void> deleteDirEventually(Directory dir) async {
  for (var i = 0; i < 6; i++) {
    try {
      await dir.delete(recursive: true);
      return;
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }
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
        '"assets":[{"name":"ZCode-v1.0.2.apk",'
        '"size":1234,'
        '"browser_download_url":"https://github.com/2421873411a-rgb/ZCode-App/releases/download/v1.0.2/ZCode-v1.0.2.apk",'
        '"digest":"sha256:abc"}]}',
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
      'https://github.com/2421873411a-rgb/ZCode-App/releases/download/v1.0.2/ZCode-v1.0.2.apk',
    );
    expect(result.downloadFileName, 'ZCode-v1.0.2.apk');
    expect(result.downloadSize, 1234);
  });

  test('资产不符合命名契约 → 有更新但不自动下载（U2 fail-closed）', () async {
    final client = MockClient((request) async {
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
    expect(result.canDownload, isFalse);
  });

  test('API 限流时从发布页取版本，并经 sidecar 摘要恢复自动下载', () async {
    final client = MockClient((request) async {
      if (request.url == UpdateService.latestReleaseApi) {
        return http.Response('rate limited', 403);
      }
      if (request.url == UpdateService.latestReleasePage) {
        return http.Response(
          '',
          302,
          headers: {
            'location':
                'https://github.com/2421873411a-rgb/ZCode-App/releases/tag/v1.0.1',
          },
        );
      }
      // sidecar：契约资产 ZCode-v1.0.1.apk 的摘要文件。
      expect(
        request.url.toString(),
        'https://github.com/2421873411a-rgb/ZCode-App/releases/download/v1.0.1/ZCode-v1.0.1.apk.sha256',
      );
      return http.Response(
        '${'a' * 64}  ZCode-v1.0.1.apk\n',
        200,
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
      'https://github.com/2421873411a-rgb/ZCode-App/releases/download/v1.0.1/ZCode-v1.0.1.apk',
    );
    expect(result.downloadFileName, 'ZCode-v1.0.1.apk');
    expect(result.assetDigest, 'sha256:${'a' * 64}');
    expect(result.canDownload, isTrue);
  });

  test('sidecar 拿不到（404）→ 回退为只引导 GitHub 页（fail-closed）', () async {
    final client = MockClient((request) async {
      if (request.url == UpdateService.latestReleaseApi) {
        return http.Response('rate limited', 403);
      }
      if (request.url == UpdateService.latestReleasePage) {
        return http.Response(
          '',
          302,
          headers: {
            'location':
                'https://github.com/2421873411a-rgb/ZCode-App/releases/tag/v1.0.1',
          },
        );
      }
      return http.Response('not found', 404);
    });

    final result = await UpdateService.instance.checkForUpdate(
      client: client,
      currentVersion: '1.0.0',
    );

    expect(result.status, UpdateCheckStatus.updateAvailable);
    expect(result.latestVersion, '1.0.1');
    expect(result.downloadUri, isNull);
    expect(result.assetDigest, isNull);
    expect(result.canDownload, isFalse);
  });

  test('sidecar 文件名与契约资产不符 → 拒绝自动下载（防张冠李戴）', () async {
    final client = MockClient((request) async {
      if (request.url == UpdateService.latestReleaseApi) {
        return http.Response('rate limited', 403);
      }
      if (request.url == UpdateService.latestReleasePage) {
        return http.Response(
          '',
          302,
          headers: {
            'location':
                'https://github.com/2421873411a-rgb/ZCode-App/releases/tag/v1.0.1',
          },
        );
      }
      return http.Response('${'b' * 64}  something-else.apk\n', 200);
    });

    final result = await UpdateService.instance.checkForUpdate(
      client: client,
      currentVersion: '1.0.0',
    );

    expect(result.canDownload, isFalse);
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
      await deleteDirEventually(directory);
    }
  });

  group('downloadApk 断点续传与完整性校验', () {
    test('中断后重试带 Range 续传，最终文件完整', () async {
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
      final rangeHeaders = <String?>[];
      var calls = 0;
      final client = _StreamingClient((request) async {
        calls++;
        rangeHeaders.add(request.headers['Range']);
        if (calls == 1) {
          // 第一次：给了 2 字节后流中断。
          return http.StreamedResponse(
            () async* {
              yield [1, 2];
              throw StateError('reset');
            }(),
            200,
            contentLength: 5,
          );
        }
        // 第二次：带 Range 的续传请求 → 206 返回剩余字节。
        return http.StreamedResponse(
          Stream<List<int>>.fromIterable([
            [3, 4, 5],
          ]),
          206,
          contentLength: 3,
          headers: {'content-range': 'bytes 2-4/5'},
        );
      });

      try {
        final file = await UpdateService.instance.downloadApk(
          result,
          client: client,
          directory: directory,
          maxAttempts: 2,
        );
        expect(await file.readAsBytes(), [1, 2, 3, 4, 5]);
        expect(rangeHeaders.last, 'bytes=2-');
      } finally {
        await deleteDirEventually(directory);
      }
    });

    test('assetDigest 缺失 → canDownload 为 false（fail-closed，不自动下载）', () {
      final result = UpdateCheckResult(
        status: UpdateCheckStatus.updateAvailable,
        currentVersion: '1.0.6',
        latestVersion: '1.0.7',
        releaseUri: Uri.parse(
          'https://github.com/2421873411a-rgb/ZCode-App/releases/tag/v1.0.7',
        ),
        downloadUri: Uri.parse(
          'https://github.com/2421873411a-rgb/ZCode-App/releases/download/v1.0.7/ZCode-v1.0.7.apk',
        ),
        downloadFileName: 'ZCode-v1.0.7.apk',
      );
      expect(result.canDownload, isFalse);
    });

    test('请求取消后中止下载并清理 .part（U5）', () async {
      final directory = await Directory.systemTemp.createTemp('zcode-update-');
      final result = UpdateCheckResult(
        status: UpdateCheckStatus.updateAvailable,
        currentVersion: '1.0.0',
        latestVersion: '1.0.2',
        releaseUri: Uri.parse(
          'https://github.com/2421873411a-rgb/ZCode-App/releases/tag/v1.0.2',
        ),
        downloadUri: Uri.parse(
          'https://github.com/2421873411a-rgb/ZCode-App/releases/download/v1.0.2/ZCode-v1.0.2.apk',
        ),
        downloadFileName: 'ZCode-v1.0.2.apk',
        downloadSize: 1000,
        assetDigest: 'sha256:${'0' * 64}',
      );
      final client = _StreamingClient((request) async {
        return http.StreamedResponse(
          Stream<List<int>>.fromIterable([
            List.filled(100, 1),
            List.filled(100, 2),
            List.filled(100, 3),
            List.filled(100, 4),
            List.filled(100, 5),
            List.filled(100, 6),
            List.filled(100, 7),
            List.filled(100, 8),
            List.filled(100, 9),
            List.filled(100, 10),
          ]),
          200,
          contentLength: 1000,
        );
      });
      var cancelled = false;
      try {
        await expectLater(
          UpdateService.instance.downloadApk(
            result,
            client: client,
            directory: directory,
            onProgress: (_, _) => cancelled = true,
            isCancelled: () => cancelled,
          ),
          throwsA(isA<UpdateDownloadCancelled>()),
        );
        expect(
          await File(
            '${directory.path}${Platform.pathSeparator}updates'
            '${Platform.pathSeparator}ZCode-1.0.2.apk.part',
          ).exists(),
          isFalse,
        );
      } finally {
        await deleteDirEventually(directory);
      }
    });

    test('assetDigest 匹配时通过，不匹配时删除文件并报错', () async {
      final directory = await Directory.systemTemp.createTemp('zcode-update-');
      final bytes = [1, 2, 3, 4, 5];
      final good = sha256.convert(bytes).toString();
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
        assetDigest: 'sha256:$good',
      );
      final client = _StreamingClient((request) async {
        return http.StreamedResponse(
          Stream<List<int>>.fromIterable([bytes]),
          200,
          contentLength: 5,
        );
      });
      try {
        final file = await UpdateService.instance.downloadApk(
          result,
          client: client,
          directory: directory,
        );
        expect(await file.readAsBytes(), bytes);

        // 不匹配 → 删除文件并抛出校验失败。
        final bad = UpdateCheckResult(
          status: UpdateCheckStatus.updateAvailable,
          currentVersion: '1.0.0',
          latestVersion: '1.0.2',
          releaseUri: result.releaseUri,
          downloadUri: result.downloadUri,
          downloadFileName: 'ZCode.apk',
          downloadSize: 5,
          assetDigest: 'sha256:${'0' * 64}',
        );
        await expectLater(
          UpdateService.instance.downloadApk(
            bad,
            client: client,
            directory: directory,
          ),
          throwsA(isA<UpdateDownloadException>()),
        );
      } finally {
        await deleteDirEventually(directory);
      }
    });
  });

  test('API 抛异常（DNS/超时/断流）也要走网页回退（F13）', () async {
    final client = MockClient((request) async {
      if (request.url == UpdateService.latestReleaseApi) {
        throw TimeoutException('api down');
      }
      if (request.url == UpdateService.latestReleasePage) {
        return http.Response(
          '',
          302,
          headers: {
            'location':
                'https://github.com/2421873411a-rgb/ZCode-App/releases/tag/v1.0.1',
          },
        );
      }
      return http.Response('${'b' * 64}  ZCode-v1.0.1.apk\n', 200);
    });

    final result = await UpdateService.instance.checkForUpdate(
      client: client,
      currentVersion: '1.0.0',
    );

    expect(
      result.status,
      UpdateCheckStatus.updateAvailable,
      reason: 'API 异常不应让检查直接失败——网页回退是独立通道',
    );
    expect(result.latestVersion, '1.0.1');
    expect(result.canDownload, isTrue, reason: '回退路径同样要能恢复自动下载');
  });

  test('API 与发布页都不可达 → failed，绝不显示“已是最新版”（F13）', () async {
    final client = MockClient((request) async {
      throw const SocketException('offline');
    });

    final result = await UpdateService.instance.checkForUpdate(
      client: client,
      currentVersion: '1.0.0',
    );

    expect(result.status, UpdateCheckStatus.failed);
  });
}
