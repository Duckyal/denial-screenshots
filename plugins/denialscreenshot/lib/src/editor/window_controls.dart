import 'package:flutter/foundation.dart';

import 'host_bridge.dart';

/// 插件版窗口控制。
///
/// 原实现通过 MethodChannel 驱动 patched Linux runner 的浮动钉住窗口。
/// 插件没有独立窗口，改为走 [EditorHostBridge]：宿主用 shell surface 显示
/// 钉住卡片时返回 true，否则编辑器退回内置的窗口内卡片。
class ScreenshotWindowControls {
  ScreenshotWindowControls();

  /// 原生卡片的"继续编辑"按钮把编辑器唤回时触发。
  VoidCallback? onPinContinued;

  Future<bool> showPinCard(String pngPath) async {
    final handler = EditorHostBridge.instance.showPinCard;
    if (handler == null) return false;
    return handler(pngPath);
  }

  Future<void> moveBy(double dx, double dy) async {
    EditorHostBridge.instance.movePinCard?.call(dx, dy);
  }

  Future<void> quit() async {
    EditorHostBridge.instance.closeEditor?.call();
  }
}
