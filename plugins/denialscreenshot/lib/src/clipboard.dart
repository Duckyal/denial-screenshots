import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// 复制诊断日志（失败时看这里）。
const String clipboardLogPath = '/tmp/denial-screenshot-clipboard.log';

void _log(String message) {
  try {
    File(clipboardLogPath).writeAsStringSync(
      '${DateTime.now().toIso8601String()} $message\n',
      mode: FileMode.append,
    );
  } on Object {
    // 日志写不进去也不该影响复制流程。
  }
}

/// 记录一条与剪贴板相关的说明（例如画布还没渲染出来）。
void recordClipboardNote(String message) => _log(message);

/// 插件进程里常常拿不到 WAYLAND_DISPLAY / DISPLAY（Flutter shell 启动时没
/// 把它们传进来），子进程因此连不上 Wayland（wl-copy 会退回 wayland-0）。
/// 这里按 XDG_RUNTIME_DIR 里的 socket 把它们补上。
Map<String, String> childProcessEnvironment() {
  final env = <String, String>{...Platform.environment};
  final runtimeDir = env['XDG_RUNTIME_DIR'] ?? '';

  var wayland = env['WAYLAND_DISPLAY'];
  if (wayland == null || wayland.isEmpty) {
    wayland = _discoverWaylandDisplay(runtimeDir);
  }
  if (wayland != null && wayland.isNotEmpty) {
    env['WAYLAND_DISPLAY'] = wayland;
  }

  var display = env['DISPLAY'];
  if (display == null || display.isEmpty) {
    display = _discoverXDisplay();
  }
  if (display != null && display.isNotEmpty) {
    env['DISPLAY'] = display;
  }
  return env;
}

/// 在 [runtimeDir] 里找编号最大的 `wayland-N`。
String? _discoverWaylandDisplay(String runtimeDir) {
  if (runtimeDir.isEmpty) return null;
  try {
    final found = <int, String>{};
    for (final entity in Directory(runtimeDir).listSync(followLinks: false)) {
      final name = entity.path.split(Platform.pathSeparator).last;
      final match = RegExp(r'^wayland-(\d+)$').firstMatch(name);
      if (match != null) {
        found[int.parse(match.group(1)!)] = name;
      }
    }
    if (found.isEmpty) return null;
    return found[found.keys.reduce(math.max)];
  } on Object {
    return null;
  }
}

/// 在 /tmp/.X11-unix 里找编号最大的 X socket，兜底给 xclip 用。
String? _discoverXDisplay() {
  try {
    final directory = Directory('/tmp/.X11-unix');
    if (!directory.existsSync()) return null;
    final found = <int>[];
    for (final entity in directory.listSync(followLinks: false)) {
      final name = entity.path.split(Platform.pathSeparator).last;
      final match = RegExp(r'^X(\d+)$').firstMatch(name);
      if (match != null) {
        found.add(int.parse(match.group(1)!));
      }
    }
    if (found.isEmpty) return null;
    return ':${found.reduce(math.max)}';
  } on Object {
    return null;
  }
}

/// 把纯文本写入系统剪贴板（识字结果复制用）。
///
/// 与 PNG 走同一批命令：wl-copy（声明 text/plain）优先，失败后退回 xclip。
Future<bool> copyTextToClipboard(String text) async {
  if (text.isEmpty) {
    _log('empty text, nothing to copy');
    return false;
  }
  _log('copy text ${text.length} chars');
  final environment = childProcessEnvironment();
  final bytes = utf8.encode(text);
  for (final command in <List<String>>[
    <String>['wl-copy', '--type', 'text/plain'],
    <String>['wl-copy'],
    <String>['xclip', '-selection', 'clipboard', '-t', 'text/plain', '-i'],
  ]) {
    try {
      final process = await Process.start(
        command.first,
        command.skip(1).toList(growable: false),
        environment: environment,
      );
      final errors = process.stderr
          .transform(utf8.decoder)
          .join()
          .catchError((Object _) => '');
      process.stdin.add(bytes);
      await process.stdin.close();
      final code = await process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () => -1,
      );
      final message = await errors.timeout(
        const Duration(seconds: 1),
        onTimeout: () => '',
      );
      _log('  ${command.join(' ')} -> exit=$code stderr=${message.trim()}');
      if (code == 0) return true;
    } on Object catch (error) {
      _log('  ${command.join(' ')} -> error=$error');
    }
  }
  return false;
}

/// 把 PNG 写入系统剪贴板。
///
/// wl-copy 优先（多种参数写法都试一遍，兼容不同版本的 wl-clipboard），
/// 最后退回 xclip。每一步都把退出码和标准错误写进日志，便于排查。
Future<bool> copyPngToClipboard(Uint8List png) async {
  if (png.isEmpty) {
    _log('empty png, nothing to copy');
    return false;
  }
  _log(
    'copy ${png.lengthInBytes} bytes; '
    'WAYLAND_DISPLAY=${Platform.environment['WAYLAND_DISPLAY']} '
    'XDG_RUNTIME_DIR=${Platform.environment['XDG_RUNTIME_DIR']} '
    'DISPLAY=${Platform.environment['DISPLAY']}',
  );

  final environment = childProcessEnvironment();
  _log(
    'resolved WAYLAND_DISPLAY=${environment['WAYLAND_DISPLAY']} '
    'DISPLAY=${environment['DISPLAY']}',
  );
  for (final command in <List<String>>[
    <String>['wl-copy', '--type', 'image/png'],
    <String>['wl-copy', '-t', 'image/png'],
    <String>['wl-copy'],
    <String>['xclip', '-selection', 'clipboard', '-t', 'image/png', '-i'],
  ]) {
    try {
      final process = await Process.start(
        command.first,
        command.skip(1).toList(growable: false),
        environment: environment,
      );
      final errors = process.stderr
          .transform(utf8.decoder)
          .join()
          .catchError((Object _) => '');
      process.stdin.add(png);
      await process.stdin.close();
      final code = await process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () => -1,
      );
      final message = await errors.timeout(
        const Duration(seconds: 1),
        onTimeout: () => '',
      );
      _log('  ${command.join(' ')} -> exit=$code stderr=${message.trim()}');
      if (code == 0) return true;
    } on Object catch (error) {
      _log('  ${command.join(' ')} -> error=$error');
    }
  }
  return false;
}
