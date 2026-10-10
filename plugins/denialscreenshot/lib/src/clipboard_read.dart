import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'clipboard.dart';

/// 剪贴板里可钉住的内容：图片（原始编码字节，交给 Flutter 解码）或文本。
sealed class ClipboardPinContent {
  const ClipboardPinContent();
}

final class ClipboardImage extends ClipboardPinContent {
  const ClipboardImage(this.bytes);

  /// 图片的原始编码字节（png/jpeg/webp/…），解码交给 Image.memory。
  final Uint8List bytes;
}

final class ClipboardText extends ClipboardPinContent {
  const ClipboardText(this.text);

  final String text;
}

/// 图片类型的优先级：png 最常见无损；其余交给 Flutter 解码器兜底。
const _imageTypes = [
  'image/png',
  'image/jpeg',
  'image/webp',
  'image/bmp',
  'image/gif',
];

/// 文本类型的优先级：wl 剪贴板用 mime，X11 TARGETS 里常见 UTF8_STRING。
const _textTypes = [
  'text/plain;charset=utf-8',
  'text/plain',
  'UTF8_STRING',
  'STRING',
];

/// 读取剪贴板里可钉住的内容：图片优先，其次文本。
///
/// 类型探测用 `wl-paste --list-types`（X11 兜底 `xclip -t TARGETS -o`），
/// 逐个候选类型取字节，失败或空内容继续下一个；都没有就返回 null。
Future<ClipboardPinContent?> readClipboardPinContent() async {
  final environment = childProcessEnvironment();
  final types = await _clipboardTypes(environment);
  final candidates = [
    ..._imageTypes.where(types.contains),
    // 类型列表没给 mime 时，按前缀兜底扫描（比如 image/jxl 之类交给解码器试）。
    ...types.where(
      (type) => type.startsWith('image/') && !_imageTypes.contains(type),
    ),
    ..._textTypes.where(types.contains),
  ];
  for (final type in candidates) {
    final bytes = await _pasteType(type, environment);
    if (bytes == null || bytes.isEmpty) continue;
    if (type.startsWith('image/')) {
      return ClipboardImage(bytes);
    }
    final text = utf8.decode(bytes, allowMalformed: true).trim();
    if (text.isNotEmpty) {
      return ClipboardText(text);
    }
  }
  return null;
}

/// 列出剪贴板当前提供的类型；探测不出来就返回空（随后按候选类型盲取）。
Future<List<String>> _clipboardTypes(Map<String, String> environment) async {
  final raw = await _run(const [
    ['wl-paste', '--list-types'],
    ['xclip', '-selection', 'clipboard', '-t', 'TARGETS', '-o'],
  ], environment);
  if (raw == null) return const [];
  return utf8
      .decode(raw, allowMalformed: true)
      .split(RegExp(r'[\r\n]+'))
      .map((line) => line.trim())
      .where(
        (line) => line.isNotEmpty && line != 'TARGETS' && line != 'TIMESTAMP',
      )
      .toSet()
      .toList();
}

/// 按类型取剪贴板字节；命令失败或超时返回 null。
Future<Uint8List?> _pasteType(
  String type,
  Map<String, String> environment,
) async {
  return _run([
    ['wl-paste', '--type', type],
    ['xclip', '-selection', 'clipboard', '-t', type, '-o'],
  ], environment);
}

/// 依次尝试命令直到有一个成功，返回它的 stdout。
Future<Uint8List?> _run(
  List<List<String>> commands,
  Map<String, String> environment,
) async {
  for (final command in commands) {
    try {
      final process = await Process.start(
        command.first,
        command.skip(1).toList(growable: false),
        environment: environment,
      );
      final stdout = await process.stdout
          .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk))
          .timeout(
            const Duration(seconds: 3),
            onTimeout: () {
              process.kill();
              return const [];
            },
          );
      final code = await process.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () => -1,
      );
      if (code == 0 && stdout.isNotEmpty) {
        return Uint8List.fromList(stdout);
      }
    } on Object {
      continue;
    }
  }
  return null;
}
