/// 页面来源文本进入用户界面（会话列表、通知卡、悬浮提醒）前的统一清洗。
///
/// 双向文本控制符（Bidi overrides U+202A–U+202E、isolates U+2066–U+2069）
/// 可以让"看起来是 A 的字符串"在渲染时读作 B——会话标题/摘要来自页面数据，
/// 敌对页面可用它伪装通知内容（iter12 N-P3/W-021）。这里在状态入口
/// （event_feed / session_index）剥掉，渲染层拿到的已是无控制符文本。
abstract final class TextSanitize {
  static final RegExp _bidiControls = RegExp('[\u202A-\u202E\u2066-\u2069]');

  static bool _containsBidi(String value) => value.contains(_bidiControls);

  static String _clean(String value) => value.replaceAll(_bidiControls, '');

  /// 剥离 Bidi 控制符；不改变其余内容（不做截断——截断由各入口自己的
  /// 上限逻辑负责）。null 透传。
  static String? stripBidiControls(String? value) {
    if (value == null) return null;
    if (!_containsBidi(value)) return value;
    return _clean(value);
  }
}
