import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// ITERATION 8 UI 层审计（U-1/U-2/U-3/U-7）的 source-pin 回归。
/// 部分行为需真机/复杂 harness，沿用仓库既有 source-invariant 风格：
/// 把关键结构钉在源码上，改坏即红（变异见 tools/iteration/mutations/iter8.json）。
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('U-1：更新下载对话框内容可滚动（200% 字体下主操作不得被裁切）', () {
    final src = read('lib/ui/update_download_dialog.dart');
    expect(
      src.contains('SingleChildScrollView('),
      isTrue,
      reason: '对话框是大字体重灾区：barrierDismissible=false + 底部主按钮被裁即死路',
    );
  });

  test('U-2：设置行不再使用固定高度（200% 字体折行标题被裁）', () {
    final src = read('lib/ui/settings_page.dart');
    expect(
      src.contains('minHeight: _settingsRowHeight'),
      isTrue,
      reason: '行高必须是下限而非定高',
    );
    final sizedRow = RegExp(
      r'SizedBox\(\s*height: _settingsRowHeight',
    ).hasMatch(src);
    expect(sizedRow, isFalse, reason: '不得残留定高行');
  });

  test('U-3：通知偏好启动加载失败必须留痕（不得 unhandled zone error）', () {
    final src = read('lib/state/notification_prefs.dart');
    expect(src.contains('catchError'), isTrue);
    expect(src.contains('prefs_load_failed'), isTrue);
  });

  test('U-7：扫码错误日志按错误码去重（持续故障不得刷环形缓冲）', () {
    final src = read('lib/ui/manage_page.dart');
    expect(src.contains('_cameraError != error.errorCode'), isTrue);
  });

  test('iter10 F-1：reorder 的 Future 不再被丢弃（catchError 兜底）', () {
    final src = read('lib/ui/manage_page.dart');
    final at = src.indexOf('onReorderItem:');
    expect(at, greaterThanOrEqualTo(0));
    final body = src.substring(at, src.indexOf('children: [', at));
    expect(
      body.contains('catchError'),
      isTrue,
      reason: 'ReorderCallback 是 void 型：异常必须就地兜住并给用户反馈',
    );
  });

  test('iter10 F-2：擦除事务覆盖连通性探测 Provider', () {
    final src = read('lib/state/protected_wipe.dart');
    expect(src.contains("'deviceConnectivityProvider'"), isTrue);
    expect(
      src.contains('deviceConnectivityProvider.notifier).clear()'),
      isTrue,
    );
  });
}
