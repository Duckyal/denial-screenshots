/// Denial 截图标注插件。
///
/// 捕获与保存由合成器完成（宿主截图流程写入 `~/Pictures/Screenshots`），
/// 本插件还贡献一套插件自己的框选截图（mark-shot 式）：全屏压暗框选后弹
/// 工具栏（识字/翻译/长截屏/编辑/复制/保存/置顶/关闭），取图走 `grim`。
///
/// 贡献：
/// * 一个 [ShellAction]：插件自有框选截图（推荐入口）；
/// * 一个 [ShellAction]：长截图（框选区域后自动滚动连拍拼接）；
/// * 一个 [ShellAction]：把剪贴板内容钉成悬浮窗；
/// * 三个 [ShellSurface]：框选/工具栏表面、标注编辑器表面与置顶表面。
///
/// 贡献类必须声明在这个入口 library 中，供组合生成器发现。
@Plugin()
library;

import 'package:denial_flutter_sdk/actions.dart';
import 'package:denial_flutter_sdk/surfaces.dart';
import 'package:denial_sdk/composition.dart';
import 'package:flutter/widgets.dart';

import 'src/capture_flow_bus.dart';
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
  String label(BuildContext context) => '截图选区-推荐入口';

  @override
  String description(BuildContext context) =>
      '插件自由框选屏幕区域，框选后可微调并弹工具栏（识字/翻译/长截屏/编辑/复制/保存/置顶）';

  @override
  Future<void> invoke(ShellActionContext context) async {
    CaptureFlowBus.instance.begin();
  }
}

/// Framing mode for a long scroll capture: select the scrollable region, then
/// the session auto-scrolls and stitches frames without showing the toolbar.
@Provides(ShellAction)
final class DenialScreenshotLongCaptureAction implements ShellAction {
  const DenialScreenshotLongCaptureAction();

  @override
  String get id => 'denialscreenshot.longCapture';

  @override
  String get provider => 'Screenshot Tool';

  @override
  String label(BuildContext context) => '长截图';

  @override
  String description(BuildContext context) =>
      '框选要截的区域后自动滚动连拍并拼成一张长图（自动/手动滚动方式可在设置里切换）';

  @override
  Future<void> invoke(ShellActionContext context) async {
    CaptureFlowBus.instance.begin(scrollMode: true);
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
