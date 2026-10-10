import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'editor/commands.dart';

/// What the editor surface should do next.
enum EditorRequestKind {
  /// Open one file, usually a capture that just landed on disk.
  openPath,

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
  const EditorRequest(this.kind, {this.path});

  final EditorRequestKind kind;
  final String? path;
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

  final StreamController<EditorRequest> _controller =
      StreamController<EditorRequest>.broadcast();

  Stream<EditorRequest> get requests => _controller.stream;

  void openPath(String path) =>
      _controller.add(EditorRequest(EditorRequestKind.openPath, path: path));

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
