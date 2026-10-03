import 'host_bridge.dart';

/// 插件版 ScreenshotFFI。
///
/// 保留与原 dart:ffi 实现完全一致的调用签名，编辑器代码无需改动。
/// 宿主（deniald）已经负责截屏、选区与落盘，编辑器只负责绘制，因此
/// 大部分"通知 Rust 工具栏"的调用降级为空操作；只有 cancel 需要真正
/// 关闭编辑器 surface，交给 [EditorHostBridge]。
class ScreenshotFFI {
  ScreenshotFFI();

  EditorHostBridge get _host => EditorHostBridge.instance;

  /// 插件内始终可用：不再依赖 librust 是否加载成功。
  bool get isSupported => true;

  int start() => 0;

  /// 取消本次编辑：关闭编辑器 surface。
  int cancel() {
    _host.closeEditor?.call();
    return 0;
  }

  /// 保存由编辑器自己用 dart:io 完成，这里只是原通道的占位。
  int save() => 0;

  /// 复制由编辑器自己走 wl-copy / xclip 完成。
  int copy() => 0;

  int switchTool(int toolType) => 0;

  int switchColor(int r, int g, int b) => 0;

  int adjustSize(double size) => 0;

  int undo() => 0;

  int redo() => 0;

  int inputText(String text) => 0;

  int finishSelection(int x, int y, int width, int height) => 0;

  int updateSelection(int x, int y, int width, int height) => 0;

  int showTextDialog(int x, int y) => 0;

  int hideTextDialog() => 0;

  int showToolbar() => 0;

  int hideToolbar() => 0;

  int setToolbarVisible(int visible) => 0;
}
