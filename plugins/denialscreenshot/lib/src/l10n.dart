import 'package:flutter/widgets.dart';

/// 轻量双语取值器，对齐上游 `denial_taskbar` 的做法：不引入 ARB/gen-l10n 管线，
/// 每条文案就地把中文与英文并列，按当前 UI locale 选一个。
///
/// 判定跟随 `Localizations.localeOf(context)`，即壳层（DenialLocalizationScope）
/// 解析出来的语言；中文为基底，其余语言走英文分支。
///
/// 构建期用带 context 的 [pick]；异步回调 / toast / 状态串里 context 可能已失效，
/// 改用无 context 的 [s]，它读构建期缓存的语言（任一 [pick] 在 build 中即刷新）。
class L {
  const L._();

  static String _lang = 'zh';

  /// 当前界面是否为中文（构建期，读实时 locale 并刷新缓存）。
  static bool isChinese(BuildContext context) {
    _lang = Localizations.localeOf(context).languageCode;
    return _lang == 'zh';
  }

  /// 按当前 locale 在中文与英文之间取一（构建期）。
  static String pick(BuildContext context, String zh, String en) =>
      isChinese(context) ? zh : en;

  /// 无 context 版：读构建期缓存的语言，用于异步 / toast / 状态文案。
  static String s(String zh, String en) => _lang == 'zh' ? zh : en;
}
