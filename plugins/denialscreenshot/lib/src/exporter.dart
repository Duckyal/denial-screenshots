import 'dart:io';

import 'package:flutter/services.dart';

/// Which external tool owns image clipboard delivery on this machine.
enum ClipboardImageBackend {
  /// `wl-copy` over `ext/zwlr-data-control`, which Denial advertises.
  wlCopy,

  /// `xclip -t image/png`, used when only X11 (XWayland) is reachable.
  xclip,

  /// No image clipboard available; only text can be published.
  unavailable;

  String get description => switch (this) {
    ClipboardImageBackend.wlCopy => 'wl-copy (image/png)',
    ClipboardImageBackend.xclip => 'xclip (image/png)',
    ClipboardImageBackend.unavailable => '无图片剪贴板，仅复制路径',
  };
}

/// Publishes annotated PNG bytes to the session clipboard.
///
/// Denial's Flutter platform channel only accepts `text/plain`, so image
/// delivery goes through the compositor's data-control protocol using
/// `wl-copy` (preferred) or `xclip` (XWayland fallback). When neither exists
/// the caller falls back to copying the saved file path as text.
final class ImageClipboard {
  ImageClipboard();

  static const String imageMime = 'image/png';

  ClipboardImageBackend? _cached;

  /// Detects and caches the first usable image clipboard tool.
  Future<ClipboardImageBackend> backend() async {
    final cached = _cached;
    if (cached != null) return cached;
    final resolved = await _detect();
    _cached = resolved;
    return resolved;
  }

  Future<ClipboardImageBackend> _detect() async {
    if (_waylandDisplay() != null && await _exists('wl-copy')) {
      return ClipboardImageBackend.wlCopy;
    }
    if (_x11Display() != null && await _exists('xclip')) {
      return ClipboardImageBackend.xclip;
    }
    return ClipboardImageBackend.unavailable;
  }

  /// Copies PNG [bytes]; returns false when no image backend is available.
  Future<bool> copyPng(Uint8List bytes) async {
    final current = await backend();
    switch (current) {
      case ClipboardImageBackend.wlCopy:
        final display = _waylandDisplay();
        if (display == null) return false;
        return _pipeTo(
          'wl-copy',
          <String>['--type', imageMime],
          bytes,
          environment: <String, String>{'WAYLAND_DISPLAY': display},
        );
      case ClipboardImageBackend.xclip:
        final display = _x11Display();
        if (display == null) return false;
        return _pipeTo(
          'xclip',
          <String>['-selection', 'clipboard', '-t', imageMime, '-i'],
          bytes,
          environment: <String, String>{'DISPLAY': display},
        );
      case ClipboardImageBackend.unavailable:
        return false;
    }
  }

  /// Copies plain text through Flutter's platform channel.
  Future<void> copyText(String text) =>
      Clipboard.setData(ClipboardData(text: text));

  Future<bool> _pipeTo(
    String executable,
    List<String> arguments,
    Uint8List bytes, {
    Map<String, String> environment = const <String, String>{},
  }) async {
    try {
      final process = await Process.start(
        executable,
        arguments,
        environment: <String, String>{...Platform.environment, ...environment},
      );
      process.stdin.add(bytes);
      await process.stdin.close();
      return await process.exitCode == 0;
    } on ProcessException {
      return false;
    } on StdinException {
      return false;
    }
  }

  static Future<bool> _exists(String executable) async {
    try {
      final result = await Process.run('command', <String>['-v', executable]);
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  static String? _waylandDisplay() {
    final display = Platform.environment['WAYLAND_DISPLAY'];
    if (display != null && display.isNotEmpty) return display;
    final runtime = _xdgRuntimeDir();
    if (runtime == null) return null;
    final directory = Directory(runtime);
    if (!directory.existsSync()) return null;
    for (final entity in directory.listSync()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name.startsWith('wayland-')) return name;
    }
    return null;
  }

  static String? _xdgRuntimeDir() => Platform.environment['XDG_RUNTIME_DIR'];

  static String? _x11Display() {
    final display = Platform.environment['DISPLAY'];
    if (display == null || display.isEmpty) return null;
    return display;
  }
}
