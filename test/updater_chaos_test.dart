import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zremote/services/update_service.dart';

/// v1.3.0 更新器混沌测试：畸形/中断/不一致响应必须安全失败（不崩溃、
/// 正确清理临时文件、绝不把坏包交给安装器）。
class _Client extends http.BaseClient {
  _Client(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

Future<void> deleteDirEventually(Directory directory) async {
  for (var i = 0; i < 10; i++) {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
      return;
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}

void main() {
  final goodBytes = List<int>.generate(1000, (i) => i % 251);
  final goodDigest = 'sha256:${sha256.convert(goodBytes).toString()}';

  UpdateCheckResult result() => UpdateCheckResult(
    status: UpdateCheckStatus.updateAvailable,
    currentVersion: '1.0.0',
    latestVersion: '1.0.1',
    releaseUri: Uri.parse(
      'https://github.com/2421873411a-rgb/ZCode-App/releases/tag/v1.0.1',
    ),
    downloadUri: Uri.parse(
      'https://github.com/2421873411a-rgb/ZCode-App/releases/download/v1.0.1/ZCode-v1.0.1.apk',
    ),
    downloadFileName: 'ZCode-v1.0.1.apk',
    downloadSize: 1000,
    assetDigest: goodDigest,
  );

  group('下载混沌', () {
    test('截断响应（声明 1000 实到 400）→ 摘要不符：删文件并报错', () async {
      final directory = await Directory.systemTemp.createTemp('zcode-chaos-');
      final client = _Client((request) async {
        return http.StreamedResponse(
          Stream<List<int>>.fromIterable([goodBytes.sublist(0, 400)]),
          200,
          contentLength: 1000,
        );
      });
      try {
        await expectLater(
          UpdateService.instance.downloadApk(
            result(),
            client: client,
            directory: directory,
          ),
          throwsA(isA<UpdateDownloadException>()),
        );
        final target = File(
          '${directory.path}${Platform.pathSeparator}updates'
          '${Platform.pathSeparator}ZCode-1.0.1.apk',
        );
        expect(await target.exists(), isFalse);
      } finally {
        await deleteDirEventually(directory);
      }
    });

    test('服务器忽略 Range（断点存在仍返回 200）→ 从头重下并校验通过', () async {
      final directory = await Directory.systemTemp.createTemp('zcode-chaos-');
      final partial = File(
        '${directory.path}${Platform.pathSeparator}updates'
        '${Platform.pathSeparator}ZCode-1.0.1.apk.part',
      );
      await partial.parent.create(recursive: true);
      await partial.writeAsBytes(goodBytes.sublist(0, 100), flush: true);
      final client = _Client((request) async {
        expect(request.headers['Range'], 'bytes=100-');
        return http.StreamedResponse(
          Stream<List<int>>.fromIterable([goodBytes]),
          200,
          contentLength: 1000,
        );
      });
      try {
        final file = await UpdateService.instance.downloadApk(
          result(),
          client: client,
          directory: directory,
        );
        expect(await file.length(), 1000);
        expect(await file.readAsBytes(), goodBytes);
      } finally {
        await deleteDirEventually(directory);
      }
    });

    test('206 Content-Range 起点不符 → 重置断点并报错', () async {
      final directory = await Directory.systemTemp.createTemp('zcode-chaos-');
      final partial = File(
        '${directory.path}${Platform.pathSeparator}updates'
        '${Platform.pathSeparator}ZCode-1.0.1.apk.part',
      );
      await partial.parent.create(recursive: true);
      await partial.writeAsBytes(goodBytes.sublist(0, 100), flush: true);
      final client = _Client((request) async {
        return http.StreamedResponse(
          Stream<List<int>>.fromIterable([goodBytes.sublist(500)]),
          206,
          contentLength: 500,
          headers: {'content-range': 'bytes 500-999/1000'},
        );
      });
      try {
        await expectLater(
          UpdateService.instance.downloadApk(
            result(),
            client: client,
            directory: directory,
          ),
          throwsA(isA<UpdateDownloadException>()),
        );
        expect(await partial.exists(), isFalse);
      } finally {
        await deleteDirEventually(directory);
      }
    });

    test('416 但断点小于声明大小 → 报错', () async {
      final directory = await Directory.systemTemp.createTemp('zcode-chaos-');
      final partial = File(
        '${directory.path}${Platform.pathSeparator}updates'
        '${Platform.pathSeparator}ZCode-1.0.1.apk.part',
      );
      await partial.parent.create(recursive: true);
      await partial.writeAsBytes(goodBytes.sublist(0, 100), flush: true);
      final client = _Client((request) async {
        return http.StreamedResponse(
          const Stream<List<int>>.empty(),
          416,
          contentLength: 0,
        );
      });
      try {
        await expectLater(
          UpdateService.instance.downloadApk(
            result(),
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

  group('版本号解析模糊输入', () {
    test('normalizeVersion 对畸形输入返回 null 或规范化值，绝不抛异常', () {
      const inputs = [
        '',
        '   ',
        'v',
        'v1',
        'V1.2.3-alpha',
        '1.2.3.4.5',
        'abc',
        '99999999999999999999.0.0',
        '-1.0.0',
        'v.1.2',
      ];
      for (final input in inputs) {
        final out = UpdateService.normalizeVersion(input);
        expect(out, anyOf(isNull, isA<String>()), reason: input);
      }
      expect(UpdateService.normalizeVersion('v1.2'), '1.2.0');
      expect(UpdateService.normalizeVersion('1.2.3'), '1.2.3');
    });

    test('compareVersions 对补位与相同版本有确定行为', () {
      expect(UpdateService.compareVersions('1.2', '1.2.0'), 0);
      expect(UpdateService.compareVersions('1.2.0', '1.2'), 0);
      expect(UpdateService.compareVersions('1.10.0', '1.9.9'), greaterThan(0));
      expect(UpdateService.compareVersions('2.0.0', '1.99.99'), greaterThan(0));
    });
  });
}
