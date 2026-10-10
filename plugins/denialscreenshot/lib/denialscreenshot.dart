/// Denial 截图标注插件。
///
/// 捕获与保存由合成器完成（宿主截图流程写入 `~/Pictures/Screenshots`），
/// 本插件还贡献一套插件自己的框选截图（mark-shot 式）：全屏压暗框选后弹
/// 工具栏（识字/翻译/长截屏/编辑/复制/保存/置顶/关闭），取图走 `grim`。
///
/// 贡献：
/// * 一个 [ShellAction]：插件自有框选截图（截图并标注）；
/// * 一个 [ShellAction]：启动宿主官方截图并在完成后打开标注编辑器；
/// * 一个 [ShellAction]：直接编辑最新一张截图；
/// * 两个 [ShellSurface]：框选/工具栏表面与标注编辑器表面。
///
/// 贡献类必须声明在这个入口 library 中，供组合生成器发现。
@Plugin()
library;

import 'package:denial_flutter_sdk/actions.dart';
import 'package:denial_flutter_sdk/surfaces.dart';
import 'package:denial_sdk/composition.dart';
import 'package:flutter/widgets.dart';

import 'src/capture_flow_bus.dart';
import 'src/editor_bus.dart';
import 'src/editor_surface.dart';
import 'src/pin_surface.dart';
import 'src/selection_surface.dart';

export 'src/capture_flow_bus.dart' show CaptureFlowBus;
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

/// Plugin-owned selection plane: dims the output and hosts the drag-select
/// box plus the toolbar (OCR / translate / scroll / edit / copy / save / pin).
@Provides(ShellSurface)
final class DenialScreenshotCaptureSurface implements ShellSurface {
  const DenialScreenshotCaptureSurface();

  @override
  String get id => 'denialscreenshot.capture';

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
      const CaptureFlowHost();
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

/// Plugin-owned selection: dim the output, drag a box, then act on it from
/// the toolbar. Capture is taken with grim rather than the compositor flow.
@Provides(ShellAction)
final class DenialScreenshotCaptureAction implements ShellAction {
  const DenialScreenshotCaptureAction();

  @override
  String get id => 'denialscreenshot.capture';

  @override
  String get provider => 'Screenshot Tool';

  @override
  String label(BuildContext context) => '框选截图并标注';

  @override
  String description(BuildContext context) =>
      '插件自由框选屏幕区域，框选后可微调并弹工具栏（识字/翻译/长截屏/编辑/复制/保存/置顶）';

  @override
  Future<void> invoke(ShellActionContext context) async {
    CaptureFlowBus.instance.begin();
  }
}

/// Starts the compositor's native capture, then opens the result in the editor.
@Provides(ShellAction)
final class DenialScreenshotCaptureOfficialAction implements ShellAction {
  const DenialScreenshotCaptureOfficialAction();

  @override
  String get id => 'denialscreenshot.captureOfficial';

  @override
  String get provider => 'Screenshot Tool';

  @override
  String label(BuildContext context) => '官方截图进编辑器';

  @override
  String description(BuildContext context) => '启动 Denial 官方截图，捕获完成后在标注编辑器中打开';

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

/// Pins the newest clipboard image (or text) as a floating card, Snipaste
/// style. Bind it to a key (e.g. Super+C) in the shortcut settings; pressing
/// it again pins additional cards.
@Provides(ShellAction)
final class DenialScreenshotPinClipboardAction implements ShellAction {
  const DenialScreenshotPinClipboardAction();

  @override
  String get id => 'denialscreenshot.pinFromClipboard';

  @override
  String get provider => 'Screenshot Tool';

  @override
  String label(BuildContext context) => '钉住剪贴板内容';

  @override
  String description(BuildContext context) =>
      '把剪贴板里最近一张截图或文字钉成桌面置顶悬浮窗（Snipaste 风格，可叠加多张）';

  @override
  Future<void> invoke(ShellActionContext context) async {
    await PinCardBus.instance.pinFromClipboard();
  }
}
