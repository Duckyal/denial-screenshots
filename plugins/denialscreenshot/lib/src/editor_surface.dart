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
import 'editor_bus.dart';
import 'pin_surface.dart';
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
  }

  @override
  void dispose() {
    _requests?.cancel();
    _resumes?.cancel();
    _directoryEvents?.cancel();
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
  }

  void _close() {
    if (!mounted) return;
    setState(() {
      _visible = false;
      _session = null;
    });
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
