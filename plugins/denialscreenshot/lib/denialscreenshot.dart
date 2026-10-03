/// Denial 截图标注插件。
///
/// 捕获与保存由合成器完成（宿主截图流程写入 `~/Pictures/Screenshots`），
/// 本插件只贡献：
/// * 一个 [ShellAction]：启动宿主截图并在完成后打开标注编辑器；
/// * 一个 [ShellAction]：直接编辑最新一张截图；
/// * 一个 [ShellSurface]：在 shell 场景内承载标注编辑器。
///
/// 贡献类必须声明在这个入口 library 中，供组合生成器发现。
@Plugin()
library;

import 'package:denial_flutter_sdk/actions.dart';
import 'package:denial_flutter_sdk/surfaces.dart';
import 'package:denial_sdk/composition.dart';
import 'package:flutter/widgets.dart';

import 'src/editor_bus.dart';
import 'src/editor_surface.dart';
import 'src/pin_surface.dart';

export 'src/editor_bus.dart'
    show DenialScreenshotEditorBus, EditorRequest, EditorRequestKind;
export 'src/editor_surface.dart' show EditorSession, EditorSurfaceHost;
export 'src/exporter.dart' show ClipboardImageBackend, ImageClipboard;
export 'src/screenshot_store.dart' show ScreenshotStore;

/// Full-output editor plane, mounted above application windows.
@Provides(ShellSurface)
final class DenialScreenshotEditorSurface implements ShellSurface {
  const DenialScreenshotEditorSurface();

  @override
  String get id => 'denialscreenshot.editor';

  @override
  ShellSurfaceLayer get layer => ShellSurfaceLayer.aboveWindows;

  @override
  ShellSurfacePlacement? place(ShellSurfaceEnvironment environment) {
    final bounds = environment.output.logicalRect;
    // A zero-sized placement breaks the host layout pass.
    if (bounds.isEmpty) return null;
    return ShellSurfacePlacement(
      bounds: bounds,
      visible: !environment.locked && !environment.wallpaperSelectorVisible,
    );
  }

  @override
  Widget build(BuildContext context, {required ShellSurfaceContext surface}) =>
      const EditorSurfaceHost();
}

/// Floating pin plane: the annotated snapshot as a small draggable card.
///
/// The plane covers the output so the card can be dragged anywhere, but only
/// the card itself registers input, so the rest of the desktop stays usable.
@Provides(ShellSurface)
final class DenialScreenshotPinSurface implements ShellSurface {
  const DenialScreenshotPinSurface();

  @override
  String get id => 'denialscreenshot.pin';

  @override
  ShellSurfaceLayer get layer => ShellSurfaceLayer.aboveWindows;

  @override
  ShellSurfacePlacement? place(ShellSurfaceEnvironment environment) {
    final bounds = environment.output.logicalRect;
    if (bounds.isEmpty) return null;
    return ShellSurfacePlacement(
      bounds: bounds,
      visible: !environment.locked && !environment.wallpaperSelectorVisible,
    );
  }

  @override
  Widget build(BuildContext context, {required ShellSurfaceContext surface}) =>
      const PinnedShotHost();
}

/// Starts the compositor's capture, then opens the result in the editor.
@Provides(ShellAction)
final class DenialScreenshotCaptureAction implements ShellAction {
  const DenialScreenshotCaptureAction();

  @override
  String get id => 'denialscreenshot.capture';

  @override
  String get provider => 'Screenshot Tool';

  @override
  String label(BuildContext context) => '截图并标注';

  @override
  String description(BuildContext context) => '启动 Denial 截图，捕获完成后在标注编辑器中打开';

  @override
  Future<void> invoke(ShellActionContext context) async {
    DenialScreenshotEditorBus.instance.capture();
  }
}

/// Opens the newest capture without taking a new one.
@Provides(ShellAction)
final class DenialScreenshotEditLatestAction implements ShellAction {
  const DenialScreenshotEditLatestAction();

  @override
  String get id => 'denialscreenshot.editLatest';

  @override
  String get provider => 'Screenshot Tool';

  @override
  String label(BuildContext context) => '编辑最新截图';

  @override
  String description(BuildContext context) => '用标注编辑器打开最新一张 denial 截图';

  @override
  Future<void> invoke(ShellActionContext context) async {
    DenialScreenshotEditorBus.instance.openLatest();
  }
}
