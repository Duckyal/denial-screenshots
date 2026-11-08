import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'editor/commands.dart';

/// What the editor surface should do next.
enum EditorRequestKind {
  /// Open one file, usually a capture that just landed on disk.
  openPath,

  /// Open an already-encoded frame held in memory, skipping the on-disk
  /// re-read. This is the seam for feeds that already have the bytes in hand —
  /// the plugin's own cropped key frame now, and the compositor's native
  /// cursor-free capture once #218 exposes it.
  openBytes,

  /// Open the newest capture in the compositor's screenshot directory.
  openLatest,

  /// Ask the compositor to start its own capture/selection flow.
  capture,

  /// Start scroll capture mode in the editor.
  scrollCapture,

  /// Dismiss the editor.
  close,
}

@immutable
final class EditorRequest {
  const EditorRequest(this.kind, {this.path, this.bytes});

  final EditorRequestKind kind;
  final String? path;
  final Uint8List? bytes;
}

/// Process-wide link between the contributed actions and the editor surface.
///
/// The composition wires providers at build time, so the actions cannot reach
/// the surface instance directly; this bus keeps both sides decoupled and
/// needs no host registry.
final class DenialScreenshotEditorBus {
  DenialScreenshotEditorBus._();

  static final DenialScreenshotEditorBus instance =
      DenialScreenshotEditorBus._();

  /// 框选流程进行时挂起的标识。打开时截图目录里落地的新图（grim 存的区
  /// 域图）不应触发编辑器自动打开，由框选 surface 收发。
  final ValueNotifier<bool> suppressAutoOpen = ValueNotifier(false);

  /// 编辑器 surface 当前是否可见。框选 Alt+A 用它判断要不要先让编辑器
  /// 让位——两者同在 aboveWindows 层，编辑器开着时新选区会被压在编辑器
  /// 冻结帧背后，要等编辑器关闭才露出来（看着像卡死）。
  final ValueNotifier<bool> editorVisible = ValueNotifier(false);

  /// Alt+A 在全局层被拒（编辑器正开着）的信号。合成器的全局快捷键优先
  /// 于 surface 键盘捕获，这条按键根本不会到达编辑器自己的按键处理，
  /// 只能由框选 surface 转发过来：编辑器收到后关闭自己并接着拉起新
  /// 选区（未交付内容仍先走「放弃编辑？」确认）。
  final StreamController<void> _retriggerCapture =
      StreamController<void>.broadcast();

  Stream<void> get retriggerCaptures => _retriggerCapture.stream;

  void requestRetriggerCapture() => _retriggerCapture.add(null);

  final StreamController<EditorRequest> _controller =
      StreamController<EditorRequest>.broadcast();

  Stream<EditorRequest> get requests => _controller.stream;

  void openPath(String path) =>
      _controller.add(EditorRequest(EditorRequestKind.openPath, path: path));

  void openBytes(Uint8List bytes, {String? path}) => _controller.add(
    EditorRequest(EditorRequestKind.openBytes, path: path, bytes: bytes),
  );

  void openLatest() =>
      _controller.add(const EditorRequest(EditorRequestKind.openLatest));

  void capture() =>
      _controller.add(const EditorRequest(EditorRequestKind.capture));

  void scrollCapture() =>
      _controller.add(const EditorRequest(EditorRequestKind.scrollCapture));

  void close() => _controller.add(const EditorRequest(EditorRequestKind.close));
}

/// 从钉住卡片返回编辑器时的一次恢复请求。
@immutable
final class EditorResumeRequest {
  const EditorResumeRequest({required this.imageBytes, required this.commands});

  final Uint8List imageBytes;
  final List<DrawCommand> commands;
}

/// 钉住卡片 → 编辑器单向通道：携带底图与标注命令重新打开编辑器。
final class EditorReentryBus {
  EditorReentryBus._();

  static final EditorReentryBus instance = EditorReentryBus._();

  final StreamController<EditorResumeRequest> _controller =
      StreamController<EditorResumeRequest>.broadcast();

  Stream<EditorResumeRequest> get resumes => _controller.stream;

  void resume(EditorResumeRequest request) => _controller.add(request);
}

/// System action → editor scroll capture trigger.
/// The editor listens to this and starts scroll capture when notified.
final class EditorScrollCaptureNotifier {
  EditorScrollCaptureNotifier._();

  static final EditorScrollCaptureNotifier instance =
      EditorScrollCaptureNotifier._();

  final StreamController<void> _controller = StreamController<void>.broadcast();

  Stream<void> get notifications => _controller.stream;

  void notify() => _controller.add(null);
}
