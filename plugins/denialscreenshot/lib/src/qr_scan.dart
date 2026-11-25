import 'dart:async';
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

/// 扫码结果是不是一个可直接打开的网址。
///
/// 二维码绝大多数场景就是"给我一个链接"，所以结果窗要能一键打开。这里只
/// 认 http/https——`mailto:`、`tel:`、`file:`、`javascript:` 之类不自动变成
/// 可点链接：前者有专门的打开方式，后者是明确的危险协议（扫码内容来自外部，
/// 不能让一个 file:// 或 javascript: 在用户点一下时被执行）。
///
/// 允许没有 scheme 的常见写法（`example.com/path`）：很多码只印域名，
/// 这时补 https:// 视为网址。
Uri? qrUrlFromText(String text) {
  final value = text.trim();
  if (value.isEmpty || value.contains(RegExp(r'\s'))) return null;
  final lower = value.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    final uri = Uri.tryParse(value);
    if (uri != null && uri.host.isNotEmpty) return uri;
    return null;
  }
  // 带其它 scheme 的一律不当网址（mailto/tel/file/javascript…）。
  // 注意 `host:8080/path` 也是"字母开头 + 冒号"，会被这条规则误伤——所以
  // 先排除"冒号后紧跟数字"的写法（那是端口，不是 scheme）。
  final schemePattern = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*):(.*)$');
  final schemeMatch = schemePattern.firstMatch(value);
  if (schemeMatch != null &&
      !RegExp(r'^\d+($|[/?#])').hasMatch(schemeMatch.group(2)!)) {
    return null;
  }
  // 无 scheme：要求像域名（有点、且点后是 2 位以上字母，允许 localhost）。
  final hostPattern = RegExp(
    r'^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}'
    r'(?::\d+)?(?:[/?#].*)?$',
    caseSensitive: false,
  );
  if (hostPattern.hasMatch(value)) {
    return Uri.tryParse('https://$value');
  }
  return null;
}

/// 用系统默认程序打开网址。
///
/// 与插件其它外部工具一致（grim / wl-copy / zbarimg）：不引 url_launcher
/// 这类带平台通道的依赖。位置参数用 `--` 隔开，避免以 `-` 开头的内容被当成
/// 选项（扫码内容是外部输入，不能让它变成命令行参数）。
Future<bool> openUrlExternally(Uri url) async {
  final environment = childProcessEnvironment();
  for (final command in <List<String>>[
    <String>['xdg-open', '--', url.toString()],
    <String>['gio', 'open', '--', url.toString()],
  ]) {
    try {
      final process = await Process.start(
        command.first,
        command.skip(1).toList(growable: false),
        environment: environment,
      );
      // 不关心输出，但要排空管道；否则子进程可能在写满缓冲后挂住。
      unawaited(process.stdout.drain<void>().catchError((Object _) {}));
      unawaited(process.stderr.drain<void>().catchError((Object _) {}));
      final code = await process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () => -1,
      );
      if (code == 0) return true;
    } on Object {
      // 试下一个命令。
    }
  }
  return false;
}
