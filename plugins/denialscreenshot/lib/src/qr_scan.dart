import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'clipboard.dart' show childProcessEnvironment;

/// 一次扫码的结果条目。二维码/条码都可能不止一个，按 zbar 解出的顺序返回。
class QrCodeResult {
  const QrCodeResult({required this.type, required this.text});

  /// 符号类型（如 `QR-Code`、`EAN-13`），来自 zbar 的 `--xml`/符号前缀。
  final String type;

  /// 解码出的原始文本。
  final String text;
}

/// 扫码失败的原因：用来在结果窗里说清楚"是没找到码"还是"没装工具"。
enum QrScanFailure {
  /// 系统里没有 zbarimg。
  toolMissing,

  /// 图片里没有可识别的二维码/条码。
  nothingFound,

  /// 工具跑起来了但报错（权限、坏图等）。
  toolFailed,
}

sealed class QrScanOutcome {
  const QrScanOutcome();
}

/// 扫描成功，至少一条。
class QrScanFound extends QrScanOutcome {
  const QrScanFound(this.results);
  final List<QrCodeResult> results;
}

/// 扫描失败。
class QrScanError extends QrScanOutcome {
  const QrScanError(this.failure, [this.detail]);
  final QrScanFailure failure;
  final String? detail;
}

/// 用系统 `zbarimg` 解 PNG 里的二维码/条码。
///
/// 为什么走外部命令而不是纯 Dart 解码库：插件目前零原生依赖（grim / wl-copy
/// 同为外部工具），引一个 FFI 解码库会带来构建链负担；zbar 是发行版仓库里
/// 现成的包，缺了也能给出明确提示而不是黑箱失败。
///
/// 走 stdin 喂 PNG（`zbarimg -q --xml -`）：不落临时文件，也不需要把
/// 选区先写到磁盘再读回来。
Future<QrScanOutcome> scanQrCodes(Uint8List png) async {
  if (png.isEmpty) {
    return const QrScanError(QrScanFailure.nothingFound);
  }
  final Process process;
  try {
    process = await Process.start('zbarimg', const [
      '-q',
      '--xml',
      '-',
    ], environment: childProcessEnvironment());
  } on ProcessException catch (error) {
    // 命令不存在 / 不可执行：区分出来，好让 UI 提示"装 zbar"而不是"没扫到码"。
    return QrScanError(QrScanFailure.toolMissing, error.message);
  } on Object catch (error) {
    return QrScanError(QrScanFailure.toolFailed, '$error');
  }

  final stdoutDone = process.stdout
      .transform(utf8.decoder)
      .join()
      .catchError((Object _) => '');
  final stderrDone = process.stderr
      .transform(utf8.decoder)
      .join()
      .catchError((Object _) => '');

  try {
    process.stdin.add(png);
    await process.stdin.close();
  } on Object {
    // 进程可能在读完前就退出（例如立刻报参数错误）；退出码和 stderr 仍能
    // 给出结论，不必在这里中断。
  }

  final code = await process.exitCode.timeout(
    const Duration(seconds: 10),
    onTimeout: () => -1,
  );
  final xml = await stdoutDone;
  final stderrText = (await stderrDone).trim();

  final results = _parseZbarXml(xml);
  if (results.isNotEmpty) return QrScanFound(results);
  if (code == 4) {
    // zbarimg: 4 = 扫完但没有识别到任何符号。这是"没找到码"，不是故障。
    return const QrScanError(QrScanFailure.nothingFound);
  }
  if (code == -1) {
    return const QrScanError(QrScanFailure.toolFailed, 'timeout');
  }
  return QrScanError(
    QrScanFailure.toolFailed,
    stderrText.isEmpty ? 'zbarimg exit=$code' : stderrText,
  );
}

/// 解析 `zbarimg --xml` 的输出。
///
/// zbar 的 XML 形如：
/// ```xml
/// <barcodes xmlns='http://zbar.sourceforge.net/2008/barcode'>
///   <source href='...'>
///     <index num='0'>
///       <symbol type='QR-Code' quality='1' orientation='UP'>
///         <data><![CDATA[https://example.com]]></data>
///       </symbol>
///     </index>
///   </source>
/// </barcodes>
/// ```
///
/// 两个必须处理的细节：
/// 1. `<data>` 可能带属性——非 ASCII 内容时 zbar 会转成
///    `<data format='base64' length='41'>…</data>`，正则必须容忍属性；
/// 2. 看到 `format='base64'` 要真解一次 base64，否则中文/emoji 链接会变乱码。
List<QrCodeResult> _parseZbarXml(String xml) {
  if (xml.trim().isEmpty) return const [];
  final symbolPattern = RegExp(
    r"<symbol\b([^>]*)>(.*?)</symbol>",
    dotAll: true,
  );
  final typePattern = RegExp(r"""type=['"]([^'"]*)['"]""");
  final dataPattern = RegExp(r'<data\b([^>]*)>(.*?)</data>', dotAll: true);
  final formatPattern = RegExp(r"""format=['"]([^'"]*)['"]""");

  final results = <QrCodeResult>[];
  for (final match in symbolPattern.allMatches(xml)) {
    final attrs = match.group(1) ?? '';
    final body = match.group(2) ?? '';
    final type = typePattern.firstMatch(attrs)?.group(1) ?? 'QR-Code';
    final dataMatch = dataPattern.firstMatch(body);
    if (dataMatch == null) continue;
    final dataAttrs = dataMatch.group(1) ?? '';
    final raw = dataMatch.group(2) ?? '';
    var text = _unescapeXml(_stripCdata(raw));
    if (formatPattern.firstMatch(dataAttrs)?.group(1) == 'base64') {
      text = _decodeBase64Utf8(text);
    }
    text = text.trim();
    if (text.isEmpty) continue;
    results.add(QrCodeResult(type: type, text: text));
  }
  return results;
}

/// zbar 的 base64 内容里可能有换行（它按行宽折行），先去掉空白再解码。
String _decodeBase64Utf8(String value) {
  final compact = value.replaceAll(RegExp(r'\s'), '');
  if (compact.isEmpty) return '';
  try {
    return utf8.decode(base64.decode(compact));
  } on Object {
    // 解不开就退回原文，至少不让结果变空字符串。
    return value;
  }
}

String _stripCdata(String value) {
  var text = value.trim();
  if (text.startsWith('<![CDATA[')) {
    text = text.substring('<![CDATA['.length);
  }
  if (text.endsWith(']]>')) {
    text = text.substring(0, text.length - 3);
  }
  return text;
}

String _unescapeXml(String value) => value
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');
