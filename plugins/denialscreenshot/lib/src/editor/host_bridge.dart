import 'dart:typed_data';

import 'commands.dart';

/// 编辑器与插件宿主之间的动作桥。
///
/// 编辑器原本依赖两样插件里不存在的东西：Rust 工具栏进程（dart:ffi）和
/// 独立的 patched runner 窗口（MethodChannel）。这两者在 shell surface 里
/// 没有对应物，因此把需要宿主参与的动作收敛到这里，由挂载编辑器的
/// surface 填充实现。
final class EditorHostBridge {
  EditorHostBridge._();

  static final EditorHostBridge instance = EditorHostBridge._();

  /// 当前持有 surface 侧回调的实例（用于安全解绑）。
  Object? _surfaceOwner;

  /// 当前持有编辑器侧回调的实例。
  Object? _editorOwner;

  /// 关闭编辑器（对应原 FFI 的 cancel 与窗口 quit）。
  void Function()? closeEditor;

  /// 把渲染好的快照显示为浮动钉住卡片。
  Future<bool> Function(String path)? showPinCard;

  /// 拖动钉住卡片。
  void Function(double dx, double dy)? movePinCard;

  /// 关闭钉住卡片。
  void Function()? hidePinCard;

  /// 编辑器当前的标注命令：钉住后"继续编辑"用它恢复。
  List<DrawCommand> Function()? exportCommands;

  /// 编辑器当前的底图字节：继续编辑时的画布底图。
  Uint8List Function()? sourceBytes;

  void bindSurface(Object owner) => _surfaceOwner = owner;

  void bindEditor(Object owner) => _editorOwner = owner;

  /// 仅当调用者仍是持有者时才清理。
  ///
  /// Flutter 重建 widget 时会先 initState 新实例、再 dispose 旧实例，无差别
  /// 清理会把刚装好的回调重新清空，导致"关闭"按钮失效。
  void unbindSurface(Object owner) {
    if (!identical(_surfaceOwner, owner)) return;
    _surfaceOwner = null;
    closeEditor = null;
    showPinCard = null;
    movePinCard = null;
    hidePinCard = null;
  }

  void unbindEditor(Object owner) {
    if (!identical(_editorOwner, owner)) return;
    _editorOwner = null;
    exportCommands = null;
    sourceBytes = null;
  }
}
