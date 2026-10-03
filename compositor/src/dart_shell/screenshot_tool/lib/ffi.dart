import 'dart:ffi';
import 'package:ffi/ffi.dart';

/// FFI 绑定到 denialwm 截图工具
///
/// 这些函数通过 FFI 调用 Rust 端的函数
class ScreenshotFFI {
  late DynamicLibrary _lib;
  dynamic _screenshotToolStart;
  dynamic _screenshotToolCancel;
  dynamic _screenshotToolSave;
  dynamic _screenshotToolCopy;
  dynamic _screenshotToolSwitchTool;
  dynamic _screenshotToolSwitchColor;
  dynamic _screenshotToolAdjustSize;
  dynamic _screenshotToolUndo;
  dynamic _screenshotToolRedo;
  dynamic _screenshotToolInputText;
  dynamic _screenshotToolFinishSelection;
  dynamic _screenshotToolUpdateSelection;
  dynamic _screenshotToolShowTextDialog;
  dynamic _screenshotToolHideTextDialog;
  dynamic _screenshotToolShowToolbar;
  dynamic _screenshotToolHideToolbar;
  dynamic _screenshotToolSetToolbarVisible;

  ScreenshotFFI() {
    try {
      // 尝试加载 denialwm 的动态库
      _lib = DynamicLibrary.open('libdenialscreenshot.so');

      _screenshotToolStart =
          _lib.lookupFunction<Int32 Function(), int Function()>(
              'screenshot_tool_start');
      _screenshotToolCancel =
          _lib.lookupFunction<Int32 Function(), int Function()>(
              'screenshot_tool_cancel');
      _screenshotToolSave =
          _lib.lookupFunction<Int32 Function(), int Function()>(
              'screenshot_tool_save');
      _screenshotToolCopy =
          _lib.lookupFunction<Int32 Function(), int Function()>(
              'screenshot_tool_copy');
      _screenshotToolSwitchTool =
          _lib.lookupFunction<Int32 Function(Int32), int Function(int)>(
              'screenshot_tool_switch_tool');
      _screenshotToolSwitchColor = _lib.lookupFunction<
          Int32 Function(Uint8, Uint8, Uint8),
          int Function(int, int, int)>('screenshot_tool_switch_color');
      _screenshotToolAdjustSize =
          _lib.lookupFunction<Int32 Function(Double), int Function(double)>(
              'screenshot_tool_adjust_size');
      _screenshotToolUndo =
          _lib.lookupFunction<Int32 Function(), int Function()>(
              'screenshot_tool_undo');
      _screenshotToolRedo =
          _lib.lookupFunction<Int32 Function(), int Function()>(
              'screenshot_tool_redo');
      _screenshotToolInputText = _lib.lookupFunction<
          Int32 Function(Pointer<Uint8>),
          int Function(Pointer<Uint8>)>('screenshot_tool_input_text');
      _screenshotToolFinishSelection = _lib.lookupFunction<
          Int32 Function(Int32, Int32, Int32, Int32),
          int Function(int, int, int, int)>('screenshot_tool_finish_selection');
      _screenshotToolUpdateSelection = _lib.lookupFunction<
          Int32 Function(Int32, Int32, Int32, Int32),
          int Function(int, int, int, int)>('screenshot_tool_update_selection');
      _screenshotToolShowTextDialog = _lib.lookupFunction<
          Int32 Function(Int32, Int32),
          int Function(int, int)>('screenshot_tool_show_text_dialog');
      _screenshotToolHideTextDialog =
          _lib.lookupFunction<Int32 Function(), int Function()>(
              'screenshot_tool_hide_text_dialog');
      _screenshotToolShowToolbar =
          _lib.lookupFunction<Int32 Function(), int Function()>(
              'screenshot_tool_show_toolbar');
      _screenshotToolHideToolbar =
          _lib.lookupFunction<Int32 Function(), int Function()>(
              'screenshot_tool_hide_toolbar');
      _screenshotToolSetToolbarVisible =
          _lib.lookupFunction<Int32 Function(Int32), int Function(int)>(
              'screenshot_tool_set_toolbar_visible');

      print('ScreenshotFFI: Successfully loaded library');
    } catch (e) {
      print('ScreenshotFFI: Failed to load library: $e');
      print('ScreenshotFFI: Running in demo mode');
    }
  }

  /// 启动截图工具
  int start() {
    if (_screenshotToolStart != null) {
      return _screenshotToolStart();
    }
    return 0;
  }

  /// 取消截图
  int cancel() {
    if (_screenshotToolCancel != null) {
      return _screenshotToolCancel();
    }
    return 0;
  }

  /// 保存截图
  int save() {
    if (_screenshotToolSave != null) {
      return _screenshotToolSave();
    }
    return 0;
  }

  /// 复制截图
  int copy() {
    if (_screenshotToolCopy != null) {
      return _screenshotToolCopy();
    }
    return 0;
  }

  /// 切换工具
  int switchTool(int toolType) {
    if (_screenshotToolSwitchTool != null) {
      return _screenshotToolSwitchTool(toolType);
    }
    return 0;
  }

  /// 切换颜色
  int switchColor(int r, int g, int b) {
    if (_screenshotToolSwitchColor != null) {
      return _screenshotToolSwitchColor(r, g, b);
    }
    return 0;
  }

  /// 调整粗细
  int adjustSize(double size) {
    if (_screenshotToolAdjustSize != null) {
      return _screenshotToolAdjustSize(size);
    }
    return 0;
  }

  /// 撤销
  int undo() {
    if (_screenshotToolUndo != null) {
      return _screenshotToolUndo();
    }
    return 0;
  }

  /// 重做
  int redo() {
    if (_screenshotToolRedo != null) {
      return _screenshotToolRedo();
    }
    return 0;
  }

  /// 输入文字
  int inputText(String text) {
    if (_screenshotToolInputText != null) {
      final textPtr = text.toNativeUtf8();
      final result = _screenshotToolInputText(textPtr.cast<Uint8>());
      malloc.free(textPtr);
      return result;
    }
    return 0;
  }

  /// 完成选区
  int finishSelection(int x, int y, int width, int height) {
    if (_screenshotToolFinishSelection != null) {
      return _screenshotToolFinishSelection(x, y, width, height);
    }
    return 0;
  }

  /// 更新选区
  int updateSelection(int x, int y, int width, int height) {
    if (_screenshotToolUpdateSelection != null) {
      return _screenshotToolUpdateSelection(x, y, width, height);
    }
    return 0;
  }

  /// 显示文字输入对话框
  int showTextDialog(int x, int y) {
    if (_screenshotToolShowTextDialog != null) {
      return _screenshotToolShowTextDialog(x, y);
    }
    return 0;
  }

  /// 隐藏文字输入对话框
  int hideTextDialog() {
    if (_screenshotToolHideTextDialog != null) {
      return _screenshotToolHideTextDialog();
    }
    return 0;
  }

  /// 显示工具栏
  int showToolbar() {
    if (_screenshotToolShowToolbar != null) {
      return _screenshotToolShowToolbar();
    }
    return 0;
  }

  /// 隐藏工具栏
  int hideToolbar() {
    if (_screenshotToolHideToolbar != null) {
      return _screenshotToolHideToolbar();
    }
    return 0;
  }

  /// 设置工具栏可见性
  int setToolbarVisible(int visible) {
    if (_screenshotToolSetToolbarVisible != null) {
      return _screenshotToolSetToolbarVisible(visible);
    }
    return 0;
  }

  /// 检查是否支持 FFI
  bool get isSupported => _screenshotToolStart != null;
}

/// 工具类型枚举
