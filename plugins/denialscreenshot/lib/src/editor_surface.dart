import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'editor/commands.dart';
import 'editor/host_bridge.dart';
import 'editor/screenshot_tool.dart';
import 'editor/settings.dart';
import 'editor_bus.dart';
import 'pin_surface.dart';
import 'open_with_integration.dart';
import 'screenshot_store.dart';

/// One open editor session: the encoded frame plus its optional annotations.
final class EditorSession {
  const EditorSession({
    required this.bytes,
    required this.path,
    this.commands = const <DrawCommand>[],
  });

  final Uint8List bytes;
  final String path;
  final List<DrawCommand> commands;
}

/// Host widget mounted by the contributed [ShellSurface].
///
/// It owns the editor lifetime, forwards action requests from the bus, and
/// asks the compositor to start its own capture when requested. The editor
/// itself is the original QQ-style tool; it only talks to this surface
/// through [EditorHostBridge].
///
/// The surface is transparent, so the widget paints the frozen frame
/// full-bleed itself: the editor's canvas extends the just-captured image to
/// the whole output (blurred and dimmed) with the sharp, annotatable image
/// centered on top. Opening the editor therefore reads as staying on the
/// captured frame rather than switching to a separate window.
class EditorSurfaceHost extends ConsumerStatefulWidget {
  const EditorSurfaceHost({super.key});

  @override
  ConsumerState<EditorSurfaceHost> createState() => _EditorSurfaceHostState();
}

class _EditorSurfaceHostState extends ConsumerState<EditorSurfaceHost> {
  final ScreenshotStore _store = const ScreenshotStore();

  StreamSubscription<EditorRequest>? _requests;
  StreamSubscription<EditorResumeRequest>? _resumes;
  StreamSubscription<FileSystemEvent>? _directoryEvents;
  StreamSubscription<FileSystemEvent>? _openRequestEvents;

  EditorSession? _session;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _requests = DenialScreenshotEditorBus.instance.requests.listen(
      _handleRequest,
    );
    _resumes = EditorReentryBus.instance.resumes.listen(_handleResume);
    EditorHostBridge.instance
      ..bindSurface(this)
      ..closeEditor = _close
      ..showPinCard = _showPinCard;
    _watchCaptureDirectory();
    _watchOpenRequests();
    // 装好插件即注册"打开方式"：平台没有 post-install hook，由插件
    // 启动时自己幂等落盘（见 open_with_integration.dart）。开关在
    // 设置面板「常规」页；关掉时这里会反向撤销。
    unawaited(_syncOpenWithIntegration());
  }

  @override
  void dispose() {
    _requests?.cancel();
    _resumes?.cancel();
    _directoryEvents?.cancel();
    _openRequestEvents?.cancel();
    // surface 没了编辑器必然不可见：不重置的话 editorVisible 卡在 true，
    // Alt+A 会被"编辑器开着"分支永远吞掉（转发给不存在的编辑器）。
    DenialScreenshotEditorBus.instance.editorVisible.value = false;
    EditorHostBridge.instance.unbindSurface(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return ShellInputRegion(
      debugLabel: 'Denial screenshot editor',
      active: _visible,
      pointerPolicy: ShellPointerPolicy.fullScene,
      keyboardPolicy: ShellKeyboardPolicy.capture,
      compositorPolicy: ShellCompositorPolicy.exclusive,
      child: Focus(
        autofocus: _visible,
        onKeyEvent: (FocusNode node, KeyEvent event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            _close();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: _visible && session != null
            ? MaterialApp(
                debugShowCheckedModeBanner: false,
                // 跟随壳层 locale：MaterialApp 默认只认 en，会把内层
                // Localizations.localeOf 落回英文，导致编辑器/设置的双语文案
                // （L.pick）不跟随系统语言。这里显式沿用外层 scope 的 locale。
                locale:
                    Localizations.maybeLocaleOf(context) ??
                    View.of(context).platformDispatcher.locale,
                supportedLocales: const [Locale('zh'), Locale('en')],
                // 非英文 locale 必须挂 Global*Localizations，否则 TextField 内部
                // MaterialLocalizations.of 空断言崩成灰块 ErrorWidget。
                localizationsDelegates: GlobalMaterialLocalizations.delegates,
                theme: ThemeData(
                  colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
                  useMaterial3: true,
                ),
                home: ScreenshotTool(
                  capturedImage: session.bytes,
                  selectionRect: Rect.zero,
                  initialCommands: session.commands,
                ),
              )
            : const SizedBox.shrink(),
      ),
    );
  }

  void _handleRequest(EditorRequest request) {
    switch (request.kind) {
      case EditorRequestKind.openPath:
        final path = request.path;
        if (path != null) unawaited(_open(File(path)));
      case EditorRequestKind.openBytes:
        _openBytes(request.bytes, request.path);
      case EditorRequestKind.openLatest:
        unawaited(_openNewest());
      case EditorRequestKind.capture:
        _startCapture();
      case EditorRequestKind.scrollCapture:
        _triggerScrollCapture();
      case EditorRequestKind.close:
        _close();
    }
  }

  void _handleResume(EditorResumeRequest request) {
    setState(() {
      _session = EditorSession(
        bytes: request.imageBytes,
        path: _session?.path ?? '',
        commands: request.commands,
      );
      _visible = true;
    });
    DenialScreenshotEditorBus.instance.editorVisible.value = true;
  }

  void _startCapture() {
    ref.read(denialBridgeProvider).takeScreenshot();
  }

  void _triggerScrollCapture() {
    // Scroll capture only works when the editor is open and visible.
    if (!_visible || _session == null) return;
    // Notify the active editor session to start scroll capture.
    // The actual scroll capture logic is in ScreenshotTool.
    EditorScrollCaptureNotifier.instance.notify();
  }

  /// 外部"打开图片"请求通道：`.desktop` 关联脚本把图片绝对路径写进
  /// `~/.config/denial-screenshot-editor-open/`（标准 freedesktop 集成
  /// 的桥接——文件管理器双击图片经 mimeapps 默认应用走到脚本，脚本
  /// 投递、这里消费）。读后即删：请求文件是一次性的，避免目录堆积、
  /// 也避免重放。
  /// 投递目录：与桥接脚本同规则——尊重 `XDG_CONFIG_HOME`（须为绝对
  /// 路径，否则按 freedesktop 规范忽略），回落 `$HOME/.config`。硬编码
  /// `$HOME/.config` 会在用户设了 XDG_CONFIG_HOME 时和脚本错位、功能
  /// 静默失效。
  static Directory _openRequestDirFromEnv() {
    final env = Platform.environment;
    final xdg = env['XDG_CONFIG_HOME'] ?? '';
    final base = xdg.startsWith('/') ? xdg : '${env['HOME'] ?? ''}/.config';
    return Directory('$base/denial-screenshot-editor-open');
  }

  static final Directory _openRequestDir = _openRequestDirFromEnv();

  void _watchOpenRequests() {
    if (!_openRequestDir.existsSync()) {
      try {
        _openRequestDir.createSync(recursive: true);
      } on FileSystemException {
        return;
      }
    }
    _openRequestEvents = _openRequestDir
        .watch(events: FileSystemEvent.create | FileSystemEvent.move)
        .listen((event) {
          final name = event.path.split(Platform.pathSeparator).last;
          if (!name.endsWith('.open')) return;
          unawaited(_consumeOpenRequest(event.path));
        });
    // 启动前排空积压：投递时插件没跑，请求会静静等着。
    unawaited(_drainOpenRequests());
  }

  Future<void> _drainOpenRequests() async {
    try {
      for (final entity in _openRequestDir.listSync()) {
        if (entity is! File) continue;
        final name = entity.path.split(Platform.pathSeparator).last;
        if (!name.endsWith('.open')) continue;
        await _consumeOpenRequest(entity.path);
      }
    } on FileSystemException {
      // 目录刚被外部删掉：监听已挂上，新请求会重新触发 create。
    }
  }

  Future<void> _consumeOpenRequest(String path) async {
    final request = File(path);
    // IN_CREATE 在 open 时就触发，此刻内容可能还没写：短重试直到拿到
    // 路径或次数用尽（消费即删，不会重放）。
    var target = '';
    for (var attempt = 0; attempt < 8 && target.isEmpty; attempt++) {
      try {
        target = (await request.readAsString()).trim();
      } catch (_) {
        return;
      }
      if (target.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    }
    // 消费即删：无论成败都不重放（失败文件留着会被下次 watch 再触发）。
    try {
      await request.delete();
    } catch (_) {}
    if (target.isEmpty) {
      try {
        await request.delete();
      } catch (_) {}
      return;
    }
    final file = File(target);
    final ext = target.split('.').last.toLowerCase();
    if (!const ['png', 'jpg', 'jpeg', 'webp', 'bmp'].contains(ext)) return;
    if (!file.existsSync()) return;
    final bytes = await _store.readStable(file);
    if (bytes == null || !mounted) return;
    if (_visible && _session?.path == file.path) return;
    setState(() {
      _session = EditorSession(bytes: bytes, path: file.path);
      _visible = true;
    });
    DenialScreenshotEditorBus.instance.editorVisible.value = true;
  }

  Future<void> _syncOpenWithIntegration() async {
    final settings = await ScreenshotSettings.load();
    await OpenWithIntegration.sync(enabled: settings.openWith);
  }

  void _watchCaptureDirectory() {
    final directory = _store.directory;
    if (directory == null || !directory.existsSync()) return;
    _directoryEvents?.cancel();
    _directoryEvents = directory.watch(events: FileSystemEvent.create).listen((
      FileSystemEvent event,
    ) {
      if (DenialScreenshotEditorBus.instance.suppressAutoOpen.value) return;
      if (!event.path.endsWith('.png')) return;
      final name = event.path.split(Platform.pathSeparator).last;
      if (!name.startsWith('Screenshot-')) return;
      unawaited(_open(File(event.path)));
    });
  }

  Future<void> _openNewest() async {
    final newest = _store.newest();
    if (newest == null) return;
    await _open(newest);
  }

  Future<void> _open(File file) async {
    if (!file.existsSync()) return;
    // An in-memory open for this exact frame already won; don't let a late
    // directory-watch event re-read the same file through readStable and
    // clobber it.
    if (_visible && _session?.path == file.path) return;
    final bytes = await _store.readStable(file);
    if (bytes == null || !mounted) return;
    // Re-check after the await: an openBytes may have landed while polling.
    if (_visible && _session?.path == file.path) return;
    setState(() {
      _session = EditorSession(bytes: bytes, path: file.path);
      _visible = true;
    });
    DenialScreenshotEditorBus.instance.editorVisible.value = true;
  }

  /// Open a frame that is already in memory, bypassing the on-disk
  /// [ScreenshotStore.readStable] poll. The optional [path] keeps save/pin
  /// provenance but is not read from.
  void _openBytes(Uint8List? bytes, String? path) {
    if (bytes == null || bytes.isEmpty || !mounted) return;
    setState(() {
      _session = EditorSession(bytes: bytes, path: path ?? '');
      _visible = true;
    });
    DenialScreenshotEditorBus.instance.editorVisible.value = true;
  }

  void _close() {
    if (!mounted) return;
    setState(() {
      _visible = false;
      _session = null;
    });
    DenialScreenshotEditorBus.instance.editorVisible.value = false;
  }

  /// 钉住的快照：交给 [PinCardBus]，由钉住 surface 画成桌面上的浮动小窗
  /// （surface 占满输出，但只有卡片本身注册输入）。
  Future<bool> _showPinCard(String path) async {
    final file = File(path);
    if (!file.existsSync()) return false;
    final bytes = await file.readAsBytes();
    final bridge = EditorHostBridge.instance;
    final source =
        bridge.sourceBytes?.call() ?? _session?.bytes ?? Uint8List(0);
    PinCardBus.instance.add(
      PinImage(
        bytes: bytes,
        commands: bridge.exportCommands?.call() ?? const <DrawCommand>[],
        sourceBytes: source,
      ),
    );
    _close();
    return true;
  }
}
