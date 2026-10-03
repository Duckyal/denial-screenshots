import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../clipboard.dart';
import 'ffi.dart';
import 'file_picker.dart';
import 'host_bridge.dart';
import 'painter.dart';
import 'settings.dart';
import 'translate_service.dart';
import 'tools.dart';
import 'commands.dart';
import 'window_controls.dart';

class ScreenshotTool extends StatefulWidget {
  final Uint8List capturedImage;
  final Rect selectionRect;

  /// 恢复上一次的标注（钉住后"继续编辑"用）。
  final List<DrawCommand> initialCommands;

  const ScreenshotTool({
    super.key,
    required this.capturedImage,
    required this.selectionRect,
    this.initialCommands = const <DrawCommand>[],
  });

  @override
  State<ScreenshotTool> createState() => _ScreenshotToolState();
}

class _ScreenshotToolState extends State<ScreenshotTool> {
  late ScreenshotFFI _ffi;
  final ScreenshotWindowControls _window = ScreenshotWindowControls();
  ScreenshotToolType currentTool = ScreenshotToolType.select;
  Color currentColor = Colors.black;
  Color maskColor = Colors.white;
  double strokeWidth = 3;

  /// 橡皮独立粗细：橡皮按半径整块删除对象（含画笔笔迹），需要比画笔
  /// 大得多的量级才能快速擦除。
  double eraserSize = 24;
  final List<DrawCommand> history = [];
  final List<List<DrawCommand>> _undoSnapshots = [];
  final List<List<DrawCommand>> _redoSnapshots = [];
  int currentStep = -1;
  Rect? selectionRect;
  final TextEditingController _textController = TextEditingController();
  final FocusNode _textFocusNode = FocusNode();
  final GlobalKey _canvasKey = GlobalKey();
  bool _showTextDialog = false;
  Offset _textDialogPosition = Offset.zero;

  /// 弹窗是窗口坐标定位的 UI，而 [_textDialogPosition] 是 world 坐标
  /// （落在命令里）；两者经画布 RenderBox 的变换互转。
  Offset _textDialogWindowAnchor = Offset.zero;
  bool showToolbar = true;
  bool showColorPicker = false;
  bool showSizeSlider = false;
  bool showUndoRedo = true;
  ScreenshotSettings _settings = const ScreenshotSettings();
  final TranslateService _translateService = TranslateService();
  bool _translating = false;
  String _translateStatus = '';
  bool _dockRevealed = false;
  bool _dockHovered = false;
  bool _showHints = false;
  bool _settingsDialogOpen = false;
  Timer? _dockRevealTimer;
  ({
    bool vertical,
    bool atStart,
    bool hidden,
    bool reserved
  })? _lastDockPlacement;
  Uint8List? _pinnedImageBytes;
  bool _pinnedOverlayVisible = false;

  /// Native pin card is showing (the OS editor window is hidden by the
  /// runner); used to skip stale toolbar toggles after 继续编辑.
  bool _nativePinned = false;
  Offset? _cursorPosition;

  /// 指针移动只 bump 这两个通知：预览层与光标环各自重绘，不必重建整棵
  /// 编辑器树（工具栏、色板、快捷键面板都在那棵树上）。
  final ValueNotifier<int> _canvasTick = ValueNotifier<int>(0);
  final ValueNotifier<int> _staticTick = ValueNotifier<int>(0);

  /// `history.take(currentStep + 1)` 的缓存。指针每移动一次都重新复制一遍
  /// 命令列表，命令多了就很贵。
  List<DrawCommand> _visibleCommands = const <DrawCommand>[];
  int _visibleStamp = -1;
  int _commandsVersion = 0;

  /// 底图 widget 缓存：避免每次重建都新建 Image 节点。
  late Widget _imageWidget;
  int? _editingCommandIndex;
  DrawCommand? _movingOriginalCommand;
  Offset? _movingStartPosition;
  int? _selectedCommandIndex;
  ui.Image? _decodedImage;
  late Uint8List _currentImageBytes;
  Offset? _dragStart;
  Offset? _dragEnd;
  Path? _dragPath;

  /// 复制按钮的可视化状态：空闲 / 复制中 / 已复制 / 失败。
  _CopyState _copyState = _CopyState.idle;
  Timer? _copyResetTimer;

  IconData get _copyIcon => switch (_copyState) {
        _CopyState.working => Icons.hourglass_top,
        _CopyState.done => Icons.check_circle,
        _CopyState.failed => Icons.error_outline,
        _CopyState.idle => Icons.content_copy,
      };

  String get _copyTip => switch (_copyState) {
        _CopyState.working => '正在复制…',
        _CopyState.done => '已复制到剪贴板',
        _CopyState.failed => '复制失败，点击重试',
        _CopyState.idle => '复制 (Ctrl+C)',
      };

  Color? get _copyColor => switch (_copyState) {
        _CopyState.done => Colors.green.withOpacity(0.8),
        _CopyState.failed => Colors.red.withOpacity(0.8),
        _ => null,
      };

  /// The canvas hides the system cursor for freehand tools; the drawn ring
  /// in [ToolCursorPainter] becomes the cursor instead.
  MouseCursor get _canvasCursor => currentTool == ScreenshotToolType.brush ||
          currentTool == ScreenshotToolType.eraser
      ? SystemMouseCursors.none
      : MouseCursor.defer;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    _currentImageBytes = widget.capturedImage;
    _imageWidget = _buildImageWidget();
    selectionRect = widget.selectionRect;
    if (widget.initialCommands.isNotEmpty) {
      history.addAll(widget.initialCommands);
    }
    _invalidateCommands();
    _ffi = ScreenshotFFI();
    final bridge = EditorHostBridge.instance;
    bridge.bindEditor(this);
    bridge.exportCommands = () => List<DrawCommand>.unmodifiable(history);
    bridge.sourceBytes = () => _currentImageBytes;
    if (_ffi.isSupported) _ffi.showToolbar();
    _window.onPinContinued = () {
      if (mounted) setState(() => _nativePinned = false);
    };
    ScreenshotSettings.load().then((settings) {
      if (mounted) setState(() => _settings = settings);
    });
    _decodeCapturedImage(_currentImageBytes);
  }

  Widget _buildImageWidget() =>
      Image.memory(_currentImageBytes, fit: BoxFit.fill);

  /// 命令数 + 步骤的廉价指纹，用来判断缓存是否过期。
  int get _commandsStamp => history.length * 1000003 + (currentStep + 1);

  /// 命令列表变化后调用：刷新缓存并让静态层重绘。
  void _invalidateCommands() {
    _visibleStamp = _commandsStamp;
    _visibleCommands =
        List<DrawCommand>.unmodifiable(history.take(currentStep + 1));
    _commandsVersion++;
    _staticTick.value++;
  }

  /// build 期兜底：命令数或步骤变了却没人通知时刷新缓存（这里不 bump
  /// 通知，交给 painter 的引用比较去重绘）。
  void _syncVisibleCommands() {
    final stamp = _commandsStamp;
    if (stamp == _visibleStamp) return;
    _visibleStamp = stamp;
    _visibleCommands =
        List<DrawCommand>.unmodifiable(history.take(currentStep + 1));
    _commandsVersion++;
  }

  /// 橡皮预览必须和已画内容在同一个离屏图层里，clear 混合才擦得动，所以
  /// 橡皮工具下用单一 painter，其余工具才分静态层 + 预览层。
  bool get _eraseToolActive => currentTool == ScreenshotToolType.eraser;

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    EditorHostBridge.instance.unbindEditor(this);
    _dockRevealTimer?.cancel();
    _copyResetTimer?.cancel();
    _canvasTick.dispose();
    _staticTick.dispose();
    _decodedImage?.dispose();
    _textController.dispose();
    _textFocusNode.dispose();
    super.dispose();
  }

  Future<void> _decodeCapturedImage(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    if (!mounted) {
      frame.image.dispose();
      return;
    }
    setState(() {
      _decodedImage?.dispose();
      _decodedImage = frame.image;
    });
  }

  /// 停靠位置解析：vertical（是否竖排）、atStart（上/左侧）、
  /// hidden（贴边隐藏模式）、reserved（画布是否为工具栏预留空间）。
  /// 手动位置：常显 + 预留；自动：留白装得下就常显（不预留），装不下
  /// 就贴边隐藏（不预留，图像保持最大）。
  ({bool vertical, bool atStart, bool hidden, bool reserved})
      _resolveDockPlacement(BoxConstraints constraints) {
    const thickness = 54.0; // 工具栏容器 + 边距
    const reserve = 56.0; // 预留模式下的画布缩进
    final window = Size(constraints.maxWidth, constraints.maxHeight);
    final world = _worldSize;
    if (world.isEmpty || window.isEmpty || _settings.dockPosition != 'auto') {
      switch (_settings.dockPosition) {
        case 'top':
          return (
            vertical: false,
            atStart: true,
            hidden: false,
            reserved: true
          );
        case 'bottom':
          return (
            vertical: false,
            atStart: false,
            hidden: false,
            reserved: true
          );
        case 'left':
          return (vertical: true, atStart: true, hidden: false, reserved: true);
        case 'right':
          return (
            vertical: true,
            atStart: false,
            hidden: false,
            reserved: true
          );
        default: // 窗口尺寸未知时退回底部常显
          return (
            vertical: false,
            atStart: false,
            hidden: false,
            reserved: true
          );
      }
    }

    // 自动模式：图像按整窗适配，看四周留白条带能否装下工具栏。
    final fitScale =
        math.min(window.width / world.width, window.height / world.height);
    final sideFree = (window.width - world.width * fitScale) / 2;
    final topBottomFree = (window.height - world.height * fitScale) / 2;
    final horizontalFits = topBottomFree >= thickness;
    final verticalFits = sideFree >= thickness;
    bool vertical;
    if (horizontalFits && !verticalFits) {
      vertical = false;
    } else if (verticalFits && !horizontalFits) {
      vertical = true;
    } else if (horizontalFits && verticalFits) {
      vertical = sideFree > topBottomFree;
    } else {
      // 都装不下：选预留空间后图像更大的方向（工具栏常显，靠 Tab 收起）。
      final horizontalScale = math.min(window.width / world.width,
          math.max(0, window.height - reserve) / world.height);
      final verticalScale = math.min(
          math.max(0, window.width - reserve) / world.width,
          window.height / world.height);
      vertical = verticalScale > horizontalScale * 1.05;
    }
    // 不再贴边自动隐藏：工具栏常显，需要时用 Tab 收起。留白装得下就浮在
    // 留白上，装不下才预留空间，免得压住图像。
    final fits = vertical ? verticalFits : horizontalFits;
    return (
      vertical: vertical,
      atStart: false,
      hidden: false,
      reserved: !fits
    );
  }

  /// 标注世界的尺寸 = 当前图像的像素尺寸；图像未解码时退回选区尺寸。
  Size get _worldSize {
    final decoded = _decodedImage;
    if (decoded != null && decoded.width > 0 && decoded.height > 0) {
      return Size(decoded.width.toDouble(), decoded.height.toDouble());
    }
    final selection = selectionRect;
    if (selection != null && !selection.size.isEmpty) return selection.size;
    return const Size(1280, 800);
  }

  /// 全局键盘处理：注册在 HardwareKeyboard 上，不依赖焦点树——置顶/
  /// 对话框等流程弄丢主焦点时快捷键依然可用。返回 true 表示已消费。
  bool _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    // While pinned the editor is closed: Esc dismisses the floating card and
    // ends the session; drawing shortcuts would hit a hidden canvas.
    if (_pinnedOverlayVisible) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        _closePin();
        return true;
      }
      return false;
    }
    // 文字弹窗打开时：回车确认、Esc 取消，其余按键交给输入框。
    if (_showTextDialog) {
      if (event.logicalKey == LogicalKeyboardKey.enter) {
        _confirmTextInput();
        return true;
      }
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        _hideTextDialog();
        return true;
      }
      return false;
    }
    // 设置对话框打开时按键全部交给对话框（快捷键捕获等）。
    if (_settingsDialogOpen) return false;

    // 数据驱动的可自定义快捷键：面板/撤销/重做/关闭/提示/工具切换。
    final binding = _bindingOfEvent(event);
    debugPrint('[key] binding="$binding" '
        'hints=${_settings.bindingFor("hints")} showHints=$_showHints');
    if (binding.isNotEmpty) {
      if (binding == _settings.bindingFor('dock')) {
        _toggleDockVisibility();
        return true;
      }
      if (binding == _settings.bindingFor('hints')) {
        setState(() => _showHints = !_showHints);
        return true;
      }
      if (binding == _settings.bindingFor('undo')) {
        _undo();
        return true;
      }
      if (binding == _settings.bindingFor('redo')) {
        _redo();
        return true;
      }
      if (binding == _settings.bindingFor('close')) {
        if (_selectedCommandIndex != null) {
          setState(() => _selectedCommandIndex = null);
        } else {
          _closeEditor();
        }
        return true;
      }
      if (binding == 'ctrl+c') {
        _copy();
        return true;
      }
      for (final entry in _settings.shortcuts.entries) {
        if (entry.value != binding || !entry.key.startsWith('tool.')) {
          continue;
        }
        final tool = ScreenshotToolType.values.firstWhere(
          (type) => 'tool.${type.name}' == entry.key,
          orElse: () => currentTool,
        );
        _switchTool(tool);
        return true;
      }
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.enter:
        _save();
        return true;
      case LogicalKeyboardKey.delete:
      case LogicalKeyboardKey.backspace:
        if (_selectedCommandIndex != null) {
          _eraseCommandAt(_selectedCommandIndex!);
        }
        return _selectedCommandIndex != null;
      default:
        if (event.character == '[') {
          _nudgeSize(-1);
          return true;
        }
        if (event.character == ']') {
          _nudgeSize(1);
          return true;
        }
        return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    _syncVisibleCommands();
    return Focus(
      autofocus: true,
      child: Material(
        type: MaterialType.transparency,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final placement = _resolveDockPlacement(constraints);
            _lastDockPlacement = placement;
            // 预留画布空间只用于手动位置且工具栏可见时；自动模式图像始终
            // 最大，放不下时工具栏隐藏、快捷键（默认 Space）唤出。
            const dockReserve = 56.0;
            final dockShown =
                showToolbar && (!placement.hidden || _dockRevealed);
            final canvasPadding = placement.reserved && dockShown
                ? (placement.vertical
                    ? EdgeInsets.only(
                        left: placement.atStart ? dockReserve : 0,
                        right: placement.atStart ? 0 : dockReserve,
                      )
                    : EdgeInsets.only(
                        top: placement.atStart ? dockReserve : 0,
                        bottom: placement.atStart ? 0 : dockReserve,
                      ))
                : EdgeInsets.zero;
            return Stack(
              children: [
                // Pinned mode replaces the whole editor with the floating card.
                if (_pinnedOverlayVisible && _pinnedImageBytes != null)
                  Positioned.fill(child: _buildPinnedWindow())
                else ...[
                  // 标注坐标系锚定到图像（world）：图像多大，标注空间就多大，
                  // 整个场景经 FittedBox 随窗口等比缩放——窗口放大缩小，
                  // 标注始终钉在图像上。指针事件由 FittedBox 逆变换映射回
                  // world 坐标，手势逻辑无需换算。
                  Positioned.fill(
                    child: ColoredBox(
                      color: const Color(0xFF101418),
                      child: Padding(
                        padding: canvasPadding,
                        child: FittedBox(
                          fit: BoxFit.contain,
                          child: SizedBox(
                            width: _worldSize.width,
                            height: _worldSize.height,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                RepaintBoundary(
                                  key: _canvasKey,
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      _imageWidget,
                                      if (selectionRect != null &&
                                          selectionRect != Rect.zero)
                                        Positioned.fromRect(
                                          rect: selectionRect!,
                                          child: Container(
                                            decoration: BoxDecoration(
                                              border: Border.all(
                                                  color: Colors.red, width: 2),
                                              color:
                                                  Colors.red.withOpacity(0.1),
                                            ),
                                          ),
                                        ),
                                      // 已提交的图形：只在命令变化时重绘
                                      // （橡皮工具除外，它需要和预览同层）。
                                      if (!_eraseToolActive)
                                        Positioned.fill(
                                          child: IgnorePointer(
                                            child: ValueListenableBuilder<int>(
                                              valueListenable: _staticTick,
                                              builder: (context, _, __) =>
                                                  CustomPaint(
                                                painter: StaticDrawPainter(
                                                  commands: _visibleCommands,
                                                  version: _commandsVersion,
                                                  selectedIndex:
                                                      _selectedCommandIndex,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      Positioned.fill(
                                        child: MouseRegion(
                                          onHover: (event) {
                                            _cursorPosition =
                                                event.localPosition;
                                            _canvasTick.value++;
                                          },
                                          onExit: (_) {
                                            _cursorPosition = null;
                                            _canvasTick.value++;
                                          },
                                          cursor: _canvasCursor,
                                          child: GestureDetector(
                                            onPanStart: _onPanStart,
                                            onPanUpdate: _onPanUpdate,
                                            onPanEnd: _onPanEnd,
                                            child: ValueListenableBuilder<int>(
                                              valueListenable: _canvasTick,
                                              builder: (context, _, __) {
                                                final preview =
                                                    _buildPreviewCommand();
                                                return CustomPaint(
                                                  painter: _eraseToolActive
                                                      ? CombinedDrawPainter(
                                                          commands:
                                                              _visibleCommands,
                                                          version:
                                                              _commandsVersion,
                                                          preview: preview,
                                                          selectedIndex:
                                                              _selectedCommandIndex,
                                                        )
                                                      : PreviewDrawPainter(
                                                          preview: preview),
                                                );
                                              },
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                // Pointer ring inside the world (scales with it)
                                // but OUTSIDE the RepaintBoundary so saves and
                                // pins never contain it.
                                if (currentTool == ScreenshotToolType.brush ||
                                    currentTool == ScreenshotToolType.eraser)
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      child: ValueListenableBuilder<int>(
                                        valueListenable: _canvasTick,
                                        builder: (context, _, __) {
                                          final position = _cursorPosition;
                                          if (position == null) {
                                            return const SizedBox.shrink();
                                          }
                                          return CustomPaint(
                                            painter: ToolCursorPainter(
                                              position: position,
                                              isEraser: _eraseToolActive,
                                              color: currentColor,
                                              strokeWidth: _activeSize,
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 自动隐藏模式下：showToolbar && 唤出状态才显示。
                  if (showToolbar && (!placement.hidden || _dockRevealed))
                    _buildToolbarDock(
                      vertical: placement.vertical,
                      atStart: placement.atStart,
                      hidden: placement.hidden,
                    ),
                  if (_translating)
                    Positioned(
                      // 工具栏占哪边，状态浮层就贴另一边，避免重叠。
                      top:
                          !placement.vertical && !placement.atStart ? 12 : null,
                      bottom:
                          !placement.vertical && !placement.atStart ? null : 12,
                      left: 0,
                      right: 0,
                      child: IgnorePointer(
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.82),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  _translateStatus,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (_showHints)
                    Positioned(bottom: 20, right: 20, child: _buildShortcuts()),
                  if (_showTextDialog) _buildTextDialog(),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  /// 文本输入弹窗：左上角锚定在点击插入的位置（可视化定位），紧凑尺寸，
  /// 打开即聚焦可直接打字；确认 = 确定按钮或回车，Esc = 取消。
  Widget _buildTextDialog() {
    final media = MediaQuery.of(context).size;
    const popupWidth = 260.0;
    final popupHeight = 120.0;
    final left = (_textDialogWindowAnchor.dx)
        .clamp(0.0, (media.width - popupWidth - 8).clamp(0.0, double.infinity));
    final top = (_textDialogWindowAnchor.dy).clamp(
        0.0, (media.height - popupHeight - 8).clamp(0.0, double.infinity));

    return Stack(
      children: [
        // 插入点标记：小十字锚点，直观显示文字将从这里开始。
        Positioned(
          left: _textDialogWindowAnchor.dx - 5,
          top: _textDialogWindowAnchor.dy - 5,
          width: 10,
          height: 10,
          child: const IgnorePointer(
            child: Icon(Icons.add, size: 12, color: Colors.red),
          ),
        ),
        Positioned(
          left: left,
          top: top,
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              width: popupWidth,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.35),
                    blurRadius: 12,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _textController,
                    focusNode: _textFocusNode,
                    style: const TextStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      hintText: '输入文字，回车确认',
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    ),
                    maxLines: 1,
                    onSubmitted: (_) => _confirmTextInput(),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          textStyle: const TextStyle(fontSize: 12),
                        ),
                        onPressed: _hideTextDialog,
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 4),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          textStyle: const TextStyle(fontSize: 12),
                        ),
                        onPressed: _confirmTextInput,
                        child: const Text('确定'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _addText(String text) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: currentColor,
          fontSize: strokeWidth * 4,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();

    final command = DrawCommand(
      type: ScreenshotToolType.text,
      start: _textDialogPosition,
      end: _textDialogPosition,
      path: Path(),
      text: text,
      rect: Rect.fromLTWH(
        _textDialogPosition.dx,
        _textDialogPosition.dy,
        textPainter.width,
        textPainter.height,
      ),
      color: currentColor,
      strokeWidth: strokeWidth,
    );

    setState(() => _pushCommand(command));
  }

  void _pushCommand(DrawCommand command) {
    _undoSnapshots.add(List<DrawCommand>.from(history));
    _redoSnapshots.clear();
    if (currentStep + 1 < history.length) {
      history.removeRange(currentStep + 1, history.length);
    }
    history.add(command);
    currentStep = history.length - 1;
    _selectedCommandIndex = null;
    _invalidateCommands();
  }

  void _eraseCommandAt(int index) {
    if (index < 0 || index >= history.length) return;
    _undoSnapshots.add(List<DrawCommand>.from(history));
    _redoSnapshots.clear();
    history.removeAt(index);
    currentStep = history.length - 1;
    _selectedCommandIndex = null;
    setState(() {});
    _invalidateCommands();
  }

  /// 停靠式单行工具栏：图标化塞进一行/列，FittedBox 兜底防溢出。
  /// [hidden] 模式下默认滑出屏幕外，鼠标靠近停靠边缘时滑入。
  Widget _buildToolbarDock({
    required bool vertical,
    required bool atStart,
    required bool hidden,
  }) {
    final revealed = !hidden || _dockRevealed;

    Widget dockButton(IconData icon, String tip, VoidCallback onTap,
        {bool active = false, Color? color}) {
      return Tooltip(
        message: tip,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 34,
            height: 34,
            margin: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: color ??
                  (active
                      ? Colors.blue.withOpacity(0.6)
                      : Colors.white.withOpacity(0.06)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: Colors.white, size: 20),
          ),
        ),
      );
    }

    Widget divider() => Container(
          width: vertical ? 20 : 1,
          height: vertical ? 1 : 20,
          margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
          color: Colors.white24,
        );

    const tools = [
      (ScreenshotToolType.select, Icons.near_me, '光标'),
      (ScreenshotToolType.brush, Icons.brush, '画笔'),
      (ScreenshotToolType.line, Icons.straighten, '直线'),
      (ScreenshotToolType.arrow, Icons.arrow_forward, '箭头'),
      (ScreenshotToolType.rect, Icons.crop_square, '矩形'),
      (ScreenshotToolType.circle, Icons.circle_outlined, '椭圆'),
      (ScreenshotToolType.text, Icons.text_fields, '文字'),
      (ScreenshotToolType.mask, Icons.rectangle, '蒙版'),
      (ScreenshotToolType.eraser, Icons.backspace, '橡皮'),
    ];

    const colors = [
      Colors.black,
      Colors.white,
      Colors.red,
      Colors.green,
      Colors.blue,
    ];

    Widget swatchDot(Color color) {
      final selected = _activeColor == color;
      return GestureDetector(
        onTap: () => _switchColor(color),
        child: Container(
          width: 22,
          height: 22,
          margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? Colors.white : Colors.white38,
              width: selected ? 2 : 1,
            ),
          ),
        ),
      );
    }

    Widget colorCell() => vertical
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [for (final color in colors) swatchDot(color)],
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [for (final color in colors) swatchDot(color)],
          );

    final slider = Slider(
      value: _activeSize.clamp(_activeSizeMin, _activeSizeMax),
      min: _activeSizeMin,
      max: _activeSizeMax,
      activeColor: Colors.blue,
      inactiveColor: Colors.white30,
      onChanged: _adjustSize,
    );
    Widget sliderCell() => vertical
        ? SizedBox(
            width: 34,
            height: 110,
            child: RotatedBox(quarterTurns: 1, child: slider),
          )
        : SizedBox(width: 110, child: slider);

    Widget paletteCell() {
      return Tooltip(
        message: '更多颜色',
        child: GestureDetector(
          onTap: _showColorPalette,
          child: Container(
            width: 34,
            height: 34,
            margin: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.06),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.palette, color: Colors.white70, size: 18),
          ),
        ),
      );
    }

    final cells = <Widget>[
      dockButton(Icons.folder_open, '打开图片', _openImage),
      divider(),
      for (final (type, icon, label) in tools)
        dockButton(icon, label, () => _switchTool(type),
            active: currentTool == type),
      divider(),
      colorCell(),
      paletteCell(),
      sliderCell(),
      divider(),
      dockButton(Icons.undo, '撤销 (Ctrl+Z)', _undo),
      dockButton(Icons.redo, '重做 (Ctrl+Shift+Z)', _redo),
      dockButton(Icons.translate, '翻译', _translate, active: _translating),
      dockButton(Icons.push_pin, '置顶显示', _toggleToolbarPin),
      dockButton(Icons.check, '保存 (Enter)', _save),
      dockButton(Icons.close, '关闭编辑器', _closeEditor),
      dockButton(_copyIcon, _copyTip, _copy,
          active: _copyState == _CopyState.working ||
              _copyState == _CopyState.done,
          color: _copyColor),
      divider(),
      dockButton(Icons.settings_outlined, '设置', _openSettings),
    ];

    final bar = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.82),
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(
            color: Colors.black38,
            blurRadius: 10,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: vertical
          ? Column(mainAxisSize: MainAxisSize.min, children: cells)
          : Row(mainAxisSize: MainAxisSize.min, children: cells),
    );

    final slideOut =
        vertical ? Offset(atStart ? -1 : 1, 0) : Offset(0, atStart ? -1 : 1);
    return Positioned(
      left: vertical ? (atStart ? 0 : null) : 0,
      right: vertical ? (atStart ? null : 0) : 0,
      top: vertical ? 0 : (atStart ? 0 : null),
      bottom: vertical ? 0 : (atStart ? null : 0),
      child: Align(
        alignment: vertical
            ? (atStart ? Alignment.centerLeft : Alignment.centerRight)
            : (atStart ? Alignment.topCenter : Alignment.bottomCenter),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: AnimatedSlide(
            offset: revealed ? Offset.zero : slideOut,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            child: MouseRegion(
              onEnter: (_) {
                _dockHovered = true;
                _dockRevealTimer?.cancel();
              },
              onExit: (_) {
                _dockHovered = false;
                if (hidden) _hideDockTransient();
              },
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: bar,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _setDockRevealed(bool value) {
    if (mounted && _dockRevealed != value) {
      setState(() => _dockRevealed = value);
    }
  }

  /// 唤出工具栏并启动 1 秒自动收起（指针悬在工具栏上时不收）。
  void _startDockTransient() {
    _dockRevealTimer?.cancel();
    _setDockRevealed(true);
    _dockRevealTimer = Timer(const Duration(seconds: 1), () {
      if (!_dockHovered) _hideDockTransient();
    });
  }

  void _hideDockTransient() {
    _dockRevealTimer?.cancel();
    _setDockRevealed(false);
  }

  /// 快捷键切换工具栏显隐。自动隐藏模式下第一次按就是唤出。
  void _toggleDockVisibility() {
    final autoHidden = _lastDockPlacement?.hidden ?? false;
    if (autoHidden) {
      if (_dockRevealed) {
        _hideDockTransient();
      } else {
        _startDockTransient();
        if (!showToolbar) setState(() => showToolbar = true);
      }
      return;
    }
    setState(() => showToolbar = !showToolbar);
  }

  /// 把按键事件规范化成绑定串：ctrl/shift/alt 前缀 + 小写键名。
  String _bindingOfEvent(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    final parts = <String>[
      if (keyboard.isControlPressed) 'ctrl',
      if (keyboard.isShiftPressed) 'shift',
      if (keyboard.isAltPressed) 'alt',
    ];
    // Space 的 keyLabel 是" "（一个空格），trim 后为空，必须特判。
    var label = event.logicalKey == LogicalKeyboardKey.space
        ? 'space'
        : event.logicalKey.keyLabel.trim().toLowerCase();
    if (label.isNotEmpty) parts.add(label);
    return parts.join('+');
  }

  static const _modifierKeys = [
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
  ];

  /// 快捷键提示面板里展示的绑定名（ctrl+z → Ctrl+Z）。
  String _prettyBinding(String action) {
    final binding = _settings.bindingFor(action);
    if (binding.isEmpty) return '未设置';
    return binding
        .split('+')
        .map((part) => part.isEmpty
            ? part
            : '${part[0].toUpperCase()}${part.substring(1)}')
        .join('+');
  }

  Widget _buildShortcuts() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.9),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '快捷键提示',
            style: const TextStyle(
                color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          _buildShortcutRow('保存', 'Enter'),
          _buildShortcutRow('复制', 'Ctrl+C'),
          _buildShortcutRow('撤销', _prettyBinding('undo')),
          _buildShortcutRow('重做', _prettyBinding('redo')),
          _buildShortcutRow('关闭', _prettyBinding('close')),
          _buildShortcutRow('工具栏', _prettyBinding('dock')),
          _buildShortcutRow('光标', _prettyBinding('tool.select')),
          _buildShortcutRow('画笔', _prettyBinding('tool.brush')),
          _buildShortcutRow('直线', _prettyBinding('tool.line')),
          _buildShortcutRow('箭头', _prettyBinding('tool.arrow')),
          _buildShortcutRow('矩形', _prettyBinding('tool.rect')),
          _buildShortcutRow('圆形', _prettyBinding('tool.circle')),
          _buildShortcutRow('文字', _prettyBinding('tool.text')),
          _buildShortcutRow('蒙版', _prettyBinding('tool.mask')),
          _buildShortcutRow('橡皮', _prettyBinding('tool.eraser')),
          _buildShortcutRow('粗细减小', '['),
          _buildShortcutRow('粗细增大', ']'),
        ],
      ),
    );
  }

  Widget _buildShortcutRow(String label, String shortcut) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(width: 8),
          Text(
            shortcut,
            style: const TextStyle(
                color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  void _switchTool(ScreenshotToolType tool) {
    setState(() {
      currentTool = tool;
      showColorPicker = false;
      showSizeSlider = false;
      _selectedCommandIndex = null;
    });
    _ffi.switchTool(tool.toInt());
  }

  /// 光标模式选中对象时，颜色/粗细控件作用于该对象而不是全局工具状态。
  bool get _editingSelectedObject =>
      currentTool == ScreenshotToolType.select && _selectedCommandIndex != null;

  void _mutateSelected(DrawCommand Function(DrawCommand) mutate) {
    final index = _selectedCommandIndex;
    if (index == null || index < 0 || index >= history.length) return;
    _undoSnapshots.add(List<DrawCommand>.from(history));
    _redoSnapshots.clear();
    setState(() {
      var next = mutate(history[index]);
      if (next.type == ScreenshotToolType.text) {
        // 文字字号随粗细变化，包围框按新字号同步，命中判定和高亮框都一致。
        next = next.copyWith(rect: commandDisplayBounds(next));
      }
      history[index] = next;
    });
    _invalidateCommands();
  }

  void _switchColor(Color color) {
    if (_editingSelectedObject) {
      final index = _selectedCommandIndex!;
      final isMask = history[index].type == ScreenshotToolType.mask;
      _mutateSelected(
        (command) => command.copyWith(
          color: isMask ? null : color,
          fillColor: isMask ? color : null,
        ),
      );
      return;
    }
    setState(() {
      currentColor = color;
      maskColor = color;
      showColorPicker = false;
    });
    _ffi.switchColor(color.red, color.green, color.blue);
  }

  /// 选中对象的颜色（光标模式），供色板高亮判断。
  Color get _activeColor {
    if (_editingSelectedObject) {
      final command = history[_selectedCommandIndex!];
      return command.type == ScreenshotToolType.mask
          ? command.fillColor
          : command.color;
    }
    return currentColor;
  }

  double get _activeSize {
    if (_editingSelectedObject) {
      return history[_selectedCommandIndex!].strokeWidth;
    }
    return currentTool == ScreenshotToolType.eraser ? eraserSize : strokeWidth;
  }

  double get _activeSizeMin => currentTool == ScreenshotToolType.eraser ? 8 : 1;
  double get _activeSizeMax =>
      currentTool == ScreenshotToolType.eraser ? 80 : 20;

  void _adjustSize(double size) {
    if (_editingSelectedObject) {
      _mutateSelected(
        (command) => command.copyWith(
          strokeWidth: size.clamp(_activeSizeMin, _activeSizeMax),
        ),
      );
      return;
    }
    setState(() {
      if (currentTool == ScreenshotToolType.eraser) {
        eraserSize = size.clamp(_activeSizeMin, _activeSizeMax);
      } else {
        strokeWidth = size.clamp(_activeSizeMin, _activeSizeMax);
      }
      showSizeSlider = false;
    });
    _ffi.adjustSize(size);
  }

  /// `[` / `]`: eraser steps by 2 so its big range is quick to traverse.
  void _nudgeSize(int direction) {
    _adjustSize(_activeSize +
        direction * (currentTool == ScreenshotToolType.eraser ? 2 : 1));
  }

  void _undo() {
    if (_undoSnapshots.isNotEmpty) {
      setState(() {
        _redoSnapshots.add(List<DrawCommand>.from(history));
        final previous = _undoSnapshots.removeLast();
        history
          ..clear()
          ..addAll(previous);
        currentStep = history.length - 1;
        _selectedCommandIndex = null;
      });
      _invalidateCommands();
      _ffi.undo();
      return;
    }

    if (currentStep >= 0) {
      setState(() {
        currentStep--;
      });
      _invalidateCommands();
    }
    _ffi.undo();
  }

  void _redo() {
    if (_redoSnapshots.isNotEmpty) {
      setState(() {
        _undoSnapshots.add(List<DrawCommand>.from(history));
        final next = _redoSnapshots.removeLast();
        history
          ..clear()
          ..addAll(next);
        currentStep = history.length - 1;
        _selectedCommandIndex = null;
      });
      _invalidateCommands();
      _ffi.redo();
      return;
    }

    if (currentStep < history.length - 1) {
      setState(() {
        currentStep++;
      });
      _invalidateCommands();
    }
    _ffi.redo();
  }

  /// 翻译配色的色板行：一圈圆形色块，点选即应用。
  Widget _colorRow(String label, String current, ValueChanged<String> onPick) {
    const options = [
      ('FFFFFF', '白'),
      ('000000', '黑'),
      ('FFEB3B', '黄'),
      ('90CAF9', '蓝'),
      ('EF5350', '红'),
      ('66BB6A', '绿'),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 12),
          for (final (hex, _) in options)
            GestureDetector(
              onTap: () => onPick(hex),
              child: Container(
                width: 24,
                height: 24,
                margin: const EdgeInsets.only(right: 6),
                decoration: BoxDecoration(
                  color: ScreenshotSettings.colorValueFromHex(hex, 0xFF000000),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: current == hex
                        ? Colors.blue
                        : Colors.black.withOpacity(0.25),
                    width: current == hex ? 2.5 : 1,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 设置对话框里的单行文本配置项。
  Widget _apiField(
    String label,
    String value,
    String hint,
    ValueChanged<String> onChanged, {
    bool obscure = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: TextField(
        controller: TextEditingController(text: value)
          ..selection = TextSelection.collapsed(offset: value.length),
        obscureText: obscure,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
        onChanged: onChanged,
      ),
    );
  }

  /// 本地语言包管理：列出目录里的候选包，已装的给删除，没装的给下载。
  Future<void> _showModelManager() async {
    final service = _translateService;
    final installed = <(String, String), bool>{};
    for (final (from, to, _) in TranslateService.packCatalog) {
      installed[(from, to)] = await service.isPackInstalled(from, to);
    }
    var busyPair = const ('', '');
    var busyMessage = '';

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            Future<void> toggle(String from, String to) async {
              setDialogState(() {
                busyPair = (from, to);
                busyMessage = '';
              });
              try {
                if (installed[(from, to)] ?? false) {
                  await service.deletePack(from, to);
                  installed[(from, to)] = false;
                } else {
                  await service.installPack(
                    from,
                    to,
                    onStatus: (status) =>
                        setDialogState(() => busyMessage = status),
                  );
                  installed[(from, to)] = true;
                }
              } on Object catch (error) {
                setDialogState(() => busyMessage = '$error');
              }
              setDialogState(() => busyPair = const ('', ''));
            }

            return AlertDialog(
              title: const Text('本地翻译模型'),
              content: SizedBox(
                width: 380,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (busyPair != const ('', ''))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                busyMessage,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final (from, to, label)
                                in TranslateService.packCatalog)
                              ListTile(
                                dense: true,
                                visualDensity: VisualDensity.compact,
                                title: Text(label,
                                    style: const TextStyle(fontSize: 13)),
                                trailing: busyPair == (from, to)
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2),
                                      )
                                    : TextButton(
                                        onPressed: () => toggle(from, to),
                                        child: Text(
                                          installed[(from, to)] ?? false
                                              ? '删除'
                                              : '下载',
                                          style: const TextStyle(fontSize: 12),
                                        ),
                                      ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('完成'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  static const _shortcutActions = <(String, String)>[
    ('dock', '显示/隐藏工具栏'),
    ('undo', '撤销'),
    ('redo', '重做'),
    ('close', '关闭编辑器'),
    ('hints', '显示/隐藏快捷键提示'),
    ('tool.select', '光标'),
    ('tool.brush', '画笔'),
    ('tool.line', '直线'),
    ('tool.arrow', '箭头'),
    ('tool.rect', '矩形'),
    ('tool.circle', '椭圆'),
    ('tool.text', '文字'),
    ('tool.mask', '蒙版'),
    ('tool.eraser', '橡皮'),
  ];

  /// 设置：停靠位置、快捷键、翻译接口与外观，全部即时生效并持久化。
  Future<void> _openSettings() async {
    var settings = _settings;
    var capturingAction = '';
    var apiTesting = false;
    var apiTestResult = '';
    final captureFocusNode = FocusNode();
    _settingsDialogOpen = true;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return Focus(
          canRequestFocus: false,
          skipTraversal: true,
          child: StatefulBuilder(
            builder: (dialogContext, setDialogState) {
              void apply(ScreenshotSettings next) {
                setDialogState(() => settings = next);
                setState(() => _settings = next);
                next.save();
              }

              // 快捷键捕获：对话框聚焦时按下的下一个键成为新绑定
              // （纯修饰键忽略，Esc 取消捕获），同名绑定会被顶掉。
              KeyEventResult captureKeyEvent(FocusNode node, KeyEvent event) {
                if (capturingAction.isEmpty || event is! KeyDownEvent) {
                  return KeyEventResult.ignored;
                }
                if (_modifierKeys.contains(event.logicalKey)) {
                  return KeyEventResult.ignored;
                }
                if (event.logicalKey == LogicalKeyboardKey.escape) {
                  setDialogState(() => capturingAction = '');
                  return KeyEventResult.handled;
                }
                final binding = _bindingOfEvent(event);
                if (binding.isEmpty) return KeyEventResult.ignored;
                final next = Map<String, String>.from(settings.shortcuts);
                next.updateAll((action, value) =>
                    value == binding && action != capturingAction ? '' : value);
                next[capturingAction] = binding;
                apply(settings.copyWith(shortcuts: next));
                setDialogState(() => capturingAction = '');
                return KeyEventResult.handled;
              }

              Widget shortcutRow(String action, String label) {
                final capturing = capturingAction == action;
                return ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  title: Text(label, style: const TextStyle(fontSize: 13)),
                  trailing: capturing
                      ? const Text('按新按键…',
                          style: TextStyle(fontSize: 12, color: Colors.blue))
                      : TextButton(
                          onPressed: () {
                            // 焦点收归捕获节点，空格等按键不会被
                            // 按钮/输入框先吃掉。
                            captureFocusNode.requestFocus();
                            setDialogState(() => capturingAction = action);
                          },
                          child: Text(
                            _prettyBinding(action),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                );
              }

              Widget group(
                String title,
                String groupValue,
                List<(String, String)> options,
                ValueChanged<String> onChanged,
              ) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 6, bottom: 0),
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    for (final (value, label) in options)
                      RadioListTile<String>(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        title:
                            Text(label, style: const TextStyle(fontSize: 13)),
                        value: value,
                        groupValue: groupValue,
                        onChanged: (next) {
                          if (next != null) onChanged(next);
                        },
                      ),
                  ],
                );
              }

              Widget apiField(
                String label,
                String value,
                String hint,
                ValueChanged<String> onChanged, {
                bool obscure = false,
              }) {
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: TextField(
                    controller: TextEditingController(text: value)
                      ..selection =
                          TextSelection.collapsed(offset: value.length),
                    obscureText: obscure,
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: label,
                      hintText: hint,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: onChanged,
                  ),
                );
              }

              return Focus(
                focusNode: captureFocusNode,
                onKeyEvent: captureKeyEvent,
                child: AlertDialog(
                  title: const Text('设置'),
                  content: SizedBox(
                    width: 340,
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          group(
                            '工具栏位置',
                            settings.dockPosition,
                            const [
                              ('auto', '自动（空间不足时给工具栏预留位置）'),
                              ('left', '左侧'),
                              ('right', '右侧'),
                              ('top', '顶部'),
                              ('bottom', '底部'),
                            ],
                            (value) =>
                                apply(settings.copyWith(dockPosition: value)),
                          ),
                          SwitchListTile(
                            dense: true,
                            visualDensity: VisualDensity.compact,
                            contentPadding: EdgeInsets.zero,
                            title: const Text('复制后自动关闭编辑器',
                                style: TextStyle(fontSize: 13)),
                            value: settings.closeAfterCopy,
                            onChanged: (value) => apply(
                              settings.copyWith(closeAfterCopy: value),
                            ),
                          ),
                          const Padding(
                            padding: EdgeInsets.only(top: 6),
                            child: Text(
                              '快捷键（点击修改，按 Esc 取消捕获）',
                              style: TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                          ),
                          for (final (action, label) in _shortcutActions)
                            shortcutRow(action, label),
                          group(
                            '翻译接口',
                            settings.translateBackend,
                            const [
                              ('api', '在线翻译 API'),
                              ('local', '本地模型'),
                            ],
                            (value) => apply(
                              settings.copyWith(translateBackend: value),
                            ),
                          ),
                          if (settings.translateBackend == 'api') ...[
                            group(
                              '翻译协议',
                              settings.apiType,
                              const [
                                ('openai', 'OpenAI 兼容（DeepSeek / OpenAI / Ollama…）'),
                                ('baidu', '百度翻译'),
                                ('deepl', 'DeepL'),
                                ('libre', 'LibreTranslate'),
                              ],
                              (value) =>
                                  apply(settings.copyWith(apiType: value)),
                            ),
                            if (settings.apiType == 'openai') ...[
                              apiField(
                                'API 地址',
                                settings.apiEndpoint,
                                'https://api.deepseek.com',
                                (value) => apply(
                                  settings.copyWith(apiEndpoint: value),
                                ),
                              ),
                              apiField(
                                'API 密钥',
                                settings.apiKey,
                                'sk-…',
                                (value) =>
                                    apply(settings.copyWith(apiKey: value)),
                                obscure: true,
                              ),
                              apiField(
                                '模型名',
                                settings.apiModel,
                                'deepseek-chat',
                                (value) =>
                                    apply(settings.copyWith(apiModel: value)),
                              ),
                            ] else if (settings.apiType == 'baidu') ...[
                              apiField(
                                'APP ID',
                                settings.apiAppId,
                                '在 fanyi-api.baidu.com 免费申请',
                                (value) =>
                                    apply(settings.copyWith(apiAppId: value)),
                              ),
                              apiField(
                                '密钥',
                                settings.apiKey,
                                '与 APP ID 配对',
                                (value) =>
                                    apply(settings.copyWith(apiKey: value)),
                                obscure: true,
                              ),
                            ] else if (settings.apiType == 'deepl')
                              apiField(
                                '密钥',
                                settings.apiKey,
                                '…:fx 结尾为免费版',
                                (value) =>
                                    apply(settings.copyWith(apiKey: value)),
                                obscure: true,
                              )
                            else ...[
                              apiField(
                                'API 地址',
                                settings.apiEndpoint,
                                'https://libretranslate.example.com',
                                (value) => apply(
                                  settings.copyWith(apiEndpoint: value),
                                ),
                              ),
                              apiField(
                                'API 密钥',
                                settings.apiKey,
                                '可留空',
                                (value) =>
                                    apply(settings.copyWith(apiKey: value)),
                                obscure: true,
                              ),
                            ],
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: OutlinedButton(
                                onPressed: apiTesting
                                    ? null
                                    : () async {
                                        setDialogState(() {
                                          apiTesting = true;
                                          apiTestResult = '正在测试…';
                                        });
                                        try {
                                          final result = await _translateService
                                              .translateViaApi(
                                            texts: const ['Hello, world'],
                                            target: _resolveTranslateTarget(),
                                            apiType: settings.apiType,
                                            endpoint: settings.apiEndpoint,
                                            apiKey: settings.apiKey,
                                            model: settings.apiModel,
                                            apiAppId: settings.apiAppId,
                                          );
                                          setDialogState(() {
                                            apiTesting = false;
                                            apiTestResult =
                                                '可用：Hello, world → ${result.first}';
                                          });
                                        } on Object catch (error) {
                                          setDialogState(() {
                                            apiTesting = false;
                                            apiTestResult = '失败：$error';
                                          });
                                        }
                                      },
                                child: Text(apiTesting ? '测试中…' : '测试连接'),
                              ),
                            ),
                            if (apiTestResult.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  apiTestResult,
                                  style: const TextStyle(fontSize: 12),
                                  maxLines: 4,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          if (settings.translateBackend == 'local')
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: OutlinedButton(
                                onPressed: _showModelManager,
                                child: const Text('管理本地模型（下载/删除）'),
                              ),
                            ),
                          group(
                            '翻译为',
                            settings.translateTarget,
                            const [
                              ('system', '跟随系统'),
                              ('zh', '中文'),
                              ('en', 'English'),
                              ('ja', '日本語'),
                              ('ko', '한국어'),
                              ('fr', 'Français'),
                              ('de', 'Deutsch'),
                              ('ru', 'Русский'),
                              ('es', 'Español'),
                            ],
                            (value) => apply(
                              settings.copyWith(translateTarget: value),
                            ),
                          ),
                          colorRow(
                              '蒙版颜色',
                              settings.translateMaskColor,
                              (value) => apply(
                                    settings.copyWith(
                                        translateMaskColor: value),
                                  )),
                          colorRow(
                              '文字颜色',
                              settings.translateTextColor,
                              (value) => apply(
                                    settings.copyWith(
                                        translateTextColor: value),
                                  )),
                        ],
                      ),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: const Text('完成'),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
    _settingsDialogOpen = false;
    captureFocusNode.dispose();
  }

  /// 翻译配色的色板行：一圈圆形色块，点选即应用。
  Widget colorRow(String label, String current, ValueChanged<String> onPick) {
    const options = [
      ('FFFFFF', '白'),
      ('000000', '黑'),
      ('FFEB3B', '黄'),
      ('90CAF9', '蓝'),
      ('EF5350', '红'),
      ('66BB6A', '绿'),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 12),
          for (final (hex, _) in options)
            GestureDetector(
              onTap: () => onPick(hex),
              child: Container(
                width: 24,
                height: 24,
                margin: const EdgeInsets.only(right: 6),
                decoration: BoxDecoration(
                  color: ScreenshotSettings.colorValueFromHex(hex, 0xFF000000),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: current == hex
                        ? Colors.blue
                        : Colors.black.withOpacity(0.25),
                    width: current == hex ? 2.5 : 1,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 关闭编辑器：结束本次会话（窗口退出）。
  void _closeEditor() {
    _ffi.cancel();
    _window.quit();
  }

  /// 解析目标语言码：跟随系统时读 UI locale。
  String _resolveTranslateTarget() {
    final configured = _settings.translateTarget;
    if (configured != 'system') return configured;
    return View.of(context).platformDispatcher.locale.languageCode;
  }

  void _setTranslateStatus(String status) {
    if (!mounted) return;
    setState(() {
      _translateStatus = status;
      _translating = true; // 浮层的显示条件，务必随状态一起置位。
    });
  }

  /// 翻译：快照 → sidecar OCR+翻译 → 每个文字块生成蒙版+译文两条命令。
  /// 依赖未就绪时先弹安装向导（在线装一次，之后离线）。
  Future<void> _translate() async {
    if (_translating) return;
    // 立刻给出可视反馈：检查组件/生成快照也要几秒，不能让用户干等。
    _setTranslateStatus('准备翻译…');
    try {
      final useApi = _settings.translateBackend == 'api';
      debugPrint('[translate] backend=${_settings.translateBackend} '
          'target=${_settings.translateTarget}');
      if (useApi && _settings.apiEndpoint.trim().isEmpty) {
        // LLM/API 不默认开启：没配置就引导用户去设置。
        _showMessage('请先在设置中配置翻译 API');
        await _openSettings();
        return;
      }
      if (!useApi) {
        _setTranslateStatus('检查翻译组件…');
        if (!await _translateService.isReady()) {
          await _showTranslateSetup();
          if (!await _translateService.isReady()) return;
        }
      }

      _setTranslateStatus('生成快照…');
      final png = await _renderPinSnapshot();
      if (png == null) {
        _showMessage('生成快照失败，无法翻译');
        return;
      }
      final inputFile =
          File('${Directory.systemTemp.path}/screenshot_tool_translate.png');
      await inputFile.writeAsBytes(png);

      final target = _resolveTranslateTarget();
      if (useApi) {
        await _translateViaApi(inputFile, target);
        return;
      }

      var translatedCount = 0;
      await for (final event in _translateService.run(
        imagePath: inputFile.path,
        target: target,
      )) {
        if (!mounted) return;
        switch (event.type) {
          case 'status':
            _setTranslateStatus(event.message ?? '');
          case 'region':
            if (event.region != null) {
              debugPrint('[translate] region ${event.region!.source} -> '
                  '${event.region!.translated}');
              _applyTranslateRegion(event.region!);
              translatedCount++;
              _setTranslateStatus('已翻译 $translatedCount 块…');
            }
          case 'done':
            final count = event.regions.length;
            debugPrint('[translate] done: $count regions');
            _showMessage(count > 0 ? '翻译完成：$count 个文字块' : '未识别到文字');
          case 'error':
            debugPrint('[translate] error: ${event.message}');
            _showMessage('翻译失败：${event.message ?? ''}');
        }
      }
    } on Object catch (error) {
      _showMessage('翻译出错：$error');
    } finally {
      if (mounted) setState(() => _translating = false);
    }
  }

  /// 侧车返回的坐标基于裁剪后的显示图像，换算回画布坐标并落两条命令：
  /// 蒙版（盖住原文）+ 文字（原位显示译文），颜色取设置里的固定配色。
  void _applyTranslateRegion(TranslateRegion region) {
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    final decoded = _decodedImage;
    if (box == null || !box.hasSize || decoded == null) return;
    final imageRect = displayedImageRect(
      box.size,
      decoded.width.toDouble(),
      decoded.height.toDouble(),
    );
    final onCanvas = region.rect.shift(imageRect.topLeft);

    // 蒙版略大于文字块，彻底盖住原文；译文太长则缩小字号塞回块内。
    final maskRect = onCanvas.inflate(2);
    var fontStroke = (onCanvas.height / 5).clamp(3.0, 40.0);
    final textSpan = TextPainter(
      text: TextSpan(
        text: region.translated,
        style: TextStyle(
          fontSize: fontStroke * 4,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    if (textSpan.width > maskRect.width - 4 && textSpan.width > 0) {
      fontStroke = (fontStroke * (maskRect.width - 4) / textSpan.width)
          .clamp(2.0, fontStroke);
    }

    setState(() {
      _pushCommand(DrawCommand(
        type: ScreenshotToolType.mask,
        start: maskRect.topLeft,
        end: maskRect.bottomRight,
        path: Path(),
        rect: maskRect,
        fillColor: _settings.translateMaskColorValue,
      ));
      _pushCommand(DrawCommand(
        type: ScreenshotToolType.text,
        start: onCanvas.topLeft,
        end: onCanvas.bottomRight,
        path: Path(),
        text: region.translated,
        rect: onCanvas,
        color: _settings.translateTextColorValue,
        strokeWidth: fontStroke,
      ));
    });
  }

  /// 首次使用的依赖安装向导：流式进度，完成后可开始翻译。
  Future<void> _showTranslateSetup() async {
    // 订阅建在 builder 外：写在 StreamBuilder 里会让每次事件重建都重新
    // 订阅一个新流，安装从头跑、按钮状态来回跳（卡死假象）。
    final events = _translateService.install();
    var dialogActive = true;
    var installing = true;
    var ready = false;
    var message = '准备中…';
    StreamSubscription<TranslateSetupEvent>? subscription;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            subscription ??= events.listen(
              (event) {
                if (!dialogActive) return;
                setDialogState(() {
                  message = event.message;
                  if (event.type == 'ready') {
                    installing = false;
                    ready = true;
                  } else if (event.type == 'error') {
                    installing = false;
                  }
                });
              },
              onDone: () {
                if (!dialogActive) return;
                setDialogState(() => installing = false);
              },
            );
            return AlertDialog(
              title: const Text('安装翻译组件'),
              content: SizedBox(
                width: 360,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(message, style: const TextStyle(fontSize: 13)),
                    const SizedBox(height: 12),
                    LinearProgressIndicator(value: installing ? null : 1),
                    const SizedBox(height: 8),
                    Text(
                      '首次安装需要联网下载 OCR 与翻译模型'
                      '（约 150MB，走国内镜像），之后完全离线运行。',
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(dialogContext).hintColor,
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: installing
                      ? null
                      : () => Navigator.of(dialogContext).pop(),
                  child: Text(ready ? '开始翻译' : '关闭'),
                ),
              ],
            );
          },
        );
      },
    );
    dialogActive = false;
    await subscription?.cancel();
  }

  /// API 后端：sidecar 只做 OCR，文本批量交给配置的翻译 API，
  /// 最后统一落蒙版+译文命令。
  Future<void> _translateViaApi(File inputFile, String target) async {
    final regions = <TranslateRegion>[];
    await for (final event in _translateService.run(
      imagePath: inputFile.path,
      target: target,
      mode: 'ocr',
    )) {
      if (!mounted) return;
      switch (event.type) {
        case 'status':
          _setTranslateStatus(event.message ?? '');
        case 'region':
          if (event.region != null) regions.add(event.region!);
        case 'done':
          break;
        case 'error':
          _showMessage('识别失败：${event.message ?? ''}');
          return;
      }
    }
    if (regions.isEmpty) {
      _showMessage('未识别到文字');
      return;
    }

    _setTranslateStatus('调用翻译 API（${regions.length} 块）…');
    final translated = await _translateService.translateViaApi(
      texts: [for (final region in regions) region.source],
      target: target,
      apiType: _settings.apiType,
      endpoint: _settings.apiEndpoint,
      apiKey: _settings.apiKey,
      model: _settings.apiModel,
      apiAppId: _settings.apiAppId,
    );
    for (var i = 0; i < regions.length; i++) {
      _applyTranslateRegion(
        TranslateRegion(
          rect: regions[i].rect,
          source: regions[i].source,
          translated: translated[i],
          background: regions[i].background,
          foreground: regions[i].foreground,
        ),
      );
    }
    _showMessage('翻译完成：${regions.length} 个文字块');
  }

  Future<Uint8List?> _renderCanvas() async {
    final boundary =
        _canvasKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return null;
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data?.buffer.asUint8List();
  }

  /// 置顶快照：画布截图后裁掉图像外的留白（画布跟随平铺窗口比例，图像
  /// contain 居中，留白和选区边框会烙进 PNG），只保留图像 + 标注。
  Future<Uint8List?> _renderPinSnapshot() async {
    final png = await _renderCanvas();
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    final decoded = _decodedImage;
    if (png == null || box == null || !box.hasSize || decoded == null) {
      return png;
    }
    final imageRect = displayedImageRect(
        box.size, decoded.width.toDouble(), decoded.height.toDouble());
    if (imageRect.width < 1 || imageRect.height < 1) return png;

    final codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    codec.dispose();
    final full = frame.image;
    final recorder = ui.PictureRecorder();
    final cropCanvas = Canvas(recorder);
    cropCanvas.drawImageRect(
      full,
      imageRect,
      Offset.zero & imageRect.size,
      Paint()..filterQuality = FilterQuality.medium,
    );
    final cropped = await recorder
        .endRecording()
        .toImage(imageRect.width.round(), imageRect.height.round());
    full.dispose();
    final data = await cropped.toByteData(format: ui.ImageByteFormat.png);
    cropped.dispose();
    return data?.buffer.asUint8List();
  }

  Future<void> _save() async {
    final png = await _renderCanvas();
    if (png == null) return;
    final path = await _choosePath([
      '--file-selection',
      '--save',
      '--confirm-overwrite',
      '--title=保存截图',
      '--filename=Screenshot.png',
      '--file-filter=PNG 图片 | *.png',
    ]);
    if (path == null) return;
    await File(path).writeAsBytes(png);
    _ffi.save();
    _showMessage('已保存：$path');
  }

  Future<void> _copy() async {
    if (_copyState == _CopyState.working) return;
    _setCopyState(_CopyState.working);
    final png = await _renderCanvas();
    if (png == null) {
      recordClipboardNote('render returned null');
      _setCopyState(_CopyState.failed);
      _showMessage('复制失败：画布还没渲染出来');
      return;
    }
    if (await copyPngToClipboard(png)) {
      _ffi.copy();
      _setCopyState(_CopyState.done);
      _showMessage(
        _settings.closeAfterCopy ? '已复制到剪贴板，正在关闭…' : 'PNG 已复制到剪贴板',
        seconds: 2,
      );
      if (_settings.closeAfterCopy) {
        // 让“已复制”先亮一下再退出，否则点了像没反应。
        _copyResetTimer?.cancel();
        _copyResetTimer = Timer(const Duration(milliseconds: 700), () {
          if (mounted) _closeEditor();
        });
      }
      return;
    }
    _setCopyState(_CopyState.failed);
    _showMessage('复制失败，详见 $clipboardLogPath');
  }

  /// 更新复制按钮状态；短暂后自动回到 idle（除非要接着自动关闭窗口）。
  void _setCopyState(_CopyState state) {
    if (!mounted) return;
    setState(() => _copyState = state);
    _copyResetTimer?.cancel();
    final holdUntilClose = state == _CopyState.done && _settings.closeAfterCopy;
    if (holdUntilClose) return;
    _copyResetTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copyState = _CopyState.idle);
    });
  }

  Future<void> _openImage() async {
    final path = await _choosePath([
      '--file-selection',
      '--title=打开图片',
      '--file-filter=图片 | *.png *.jpg *.jpeg *.webp',
    ]);
    if (path == null) return;
    final bytes = await File(path).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    _decodedImage?.dispose();
    setState(() {
      _currentImageBytes = bytes;
      _imageWidget = _buildImageWidget();
      _decodedImage = frame.image;
      history.clear();
      currentStep = -1;
      selectionRect = null;
    });
    _invalidateCommands();
  }

  /// 插件运行在合成器的最上层，zenity 这类外部窗口会被本层盖住，因此改用
  /// shell 内置的对话框（参数仍沿用原来的 zenity 命令行数组）。
  Future<String?> _choosePath(List<String> arguments) =>
      choosePathWithDialog(context: context, arguments: arguments);

  void _showMessage(String message, {int seconds = 3}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: Duration(seconds: seconds)),
    );
  }

  Future<void> _toggleToolbarPin() async {
    if (_pinnedOverlayVisible || _nativePinned) {
      await _continueEditing();
      return;
    }

    final png = await _renderPinSnapshot();
    if (png == null) return;

    // Preferred path: the runner shows the snapshot as a transient floating
    // card (out of the tiling layout) and hides the editor window. The
    // drawing history lives on this State, untouched, until 继续编辑.
    final pinFile =
        File('${Directory.systemTemp.path}/screenshot_tool_pin.png');
    try {
      await pinFile.writeAsBytes(png);
    } on IOException {
      // Fall through to the in-window card below.
    }
    if (await _window.showPinCard(pinFile.path)) {
      setState(() => _nativePinned = true);
      return;
    }

    // Fallback for a stock runner (IDE debugging): full-bleed in-window card.
    setState(() {
      _pinnedImageBytes = png;
      _pinnedOverlayVisible = true;
      showToolbar = false;
      _cursorPosition = null;
    });
  }

  /// 继续编辑: closes the floating card and restores the editor window.
  /// Drawing history, undo/redo snapshots and tool state live on the same
  /// State object, so everything survives the round trip untouched.
  Future<void> _continueEditing() async {
    if (_nativePinned) {
      // The native card's own 继续编辑 button already restored the editor
      // and fired onPinContinued; nothing else to do here.
      return;
    }
    setState(() {
      _pinnedOverlayVisible = false;
      _pinnedImageBytes = null;
      showToolbar = true;
    });
  }

  /// The X button / Esc on the floating card: with the editor closed there is
  /// nothing left to show, so the card dismisses the whole session.
  void _closePin() {
    _ffi.cancel();
    _window.quit();
  }

  Widget _buildPinControlButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.45),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: Colors.white),
            const SizedBox(width: 4),
            Text(label,
                style: const TextStyle(color: Colors.white, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _buildPinnedWindow() {
    return Material(
      type: MaterialType.transparency,
      child: GestureDetector(
        // Window drag: honored on X11; on Wayland the compositor's own window
        // drag moves the card and this call is ignored.
        behavior: HitTestBehavior.translucent,
        onPanUpdate: (details) =>
            _window.moveBy(details.delta.dx, details.delta.dy),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(
              color: const Color(0xFF101418),
              child: Image.memory(
                _pinnedImageBytes!,
                fit: BoxFit.contain,
                gaplessPlayback: true,
              ),
            ),
            Positioned(
              top: 6,
              right: 6,
              child: _buildPinControlButton(
                icon: Icons.close,
                label: '关闭',
                onTap: _closePin,
              ),
            ),
            // Replaces the old resize handle: reopen the editor (with all
            // previous edits) and dismiss this floating card.
            Positioned(
              right: 6,
              bottom: 6,
              child: _buildPinControlButton(
                icon: Icons.edit,
                label: '继续编辑',
                onTap: _continueEditing,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showColorPalette() async {
    final palette = <Color>[
      Colors.red,
      Colors.green,
      Colors.blue,
      Colors.yellow,
      Colors.orange,
      Colors.purple,
      Colors.cyan,
      Colors.pink,
      Colors.deepOrange,
      Colors.teal,
      Colors.indigo,
      Colors.brown,
      Colors.grey,
      Colors.black,
      Colors.white,
    ];

    final color = await showDialog<Color>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('选择颜色'),
          content: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: palette
                .map(
                  (entry) => GestureDetector(
                    onTap: () => Navigator.of(context).pop(entry),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: entry,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _activeColor == entry
                              ? Colors.white
                              : Colors.black.withOpacity(0.2),
                          width: _activeColor == entry ? 3 : 1,
                        ),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        );
      },
    );

    if (color != null) {
      _switchColor(color);
    }
  }

  void _openTextDialog(Offset position) {
    _textDialogPosition = position;
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    _textDialogWindowAnchor = box?.localToGlobal(position) ?? position;
    _textController.clear();
    setState(() {
      _showTextDialog = true;
    });
    // 根 Focus(autofocus) 已持有焦点时 TextField.autofocus 不会生效，
    // 必须显式把焦点交给输入框才能直接打字。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _textFocusNode.requestFocus();
    });
    _ffi.showTextDialog(position.dx.toInt(), position.dy.toInt());
  }

  /// 确认输入（弹窗确定按钮 / 回车）。
  void _confirmTextInput() {
    if (_textController.text.isNotEmpty) {
      _addText(_textController.text);
      _ffi.inputText(_textController.text);
    }
    _hideTextDialog();
  }

  void _hideTextDialog() {
    setState(() {
      _showTextDialog = false;
    });
    _ffi.hideTextDialog();
  }

  Rect _normalizedRect(Offset first, Offset second) => Rect.fromLTRB(
        math.min(first.dx, second.dx),
        math.min(first.dy, second.dy),
        math.max(first.dx, second.dx),
        math.max(first.dy, second.dy),
      );

  DrawCommand? _buildPreviewCommand() {
    final start = _dragStart;
    final end = _dragEnd;
    if (start == null ||
        end == null ||
        currentTool == ScreenshotToolType.text) {
      return null;
    }
    return DrawCommand(
      type: currentTool,
      start: start,
      end: end,
      path: _dragPath ?? Path(),
      rect: _normalizedRect(start, end),
      color: currentColor,
      strokeWidth:
          currentTool == ScreenshotToolType.eraser ? eraserSize : strokeWidth,
      fillColor: maskColor,
    );
  }

  int? _findMovableCommandIndex(Offset position) {
    return findManipulableCommandIndex(history, position);
  }

  void _onPanStart(DragStartDetails details) {
    final position = details.localPosition;
    // 开始绘图就立即收起唤出的工具栏，别挡住落笔区域。
    if (_dockRevealed) _hideDockTransient();
    // Hover events stop during a drag, so the cursor ring must be fed from
    // the pan handlers to keep following the mouse.
    _cursorPosition = position;
    if (currentTool == ScreenshotToolType.eraser) {
      final removableIndex = findEraserTargetIndex(
        history,
        position,
        eraserSize / 2,
      );
      if (removableIndex != null) {
        _eraseCommandAt(removableIndex);
        return;
      }
      // No object under the pick ring: pixel-erase with an eraser stroke.
      _beginDrag(position);
      return;
    }
    if (currentTool == ScreenshotToolType.select) {
      // 光标模式：点谁选中谁（内部空白也能抓住），按住拖动即移动；
      // 点空白取消选中。选中后可用 Delete 删除。
      final target = findManipulableCommandIndex(history, position);
      setState(() => _selectedCommandIndex = target);
      if (target != null) {
        _editingCommandIndex = target;
        _movingOriginalCommand = history[target];
        _movingStartPosition = position;
        _dragStart = null;
        _dragEnd = null;
        _dragPath = null;
      }
      return;
    }
    // 绘图工具：专心绘制，不再隐式抓取移动（移动走光标模式）。
    _beginDrag(position);
  }

  void _beginDrag(Offset position) {
    _dragStart = position;
    _dragEnd = position;
    _dragPath = Path()..moveTo(position.dx, position.dy);
    _editingCommandIndex = null;
    _movingOriginalCommand = null;
    _movingStartPosition = null;
    setState(() {});
  }

  void _onPanUpdate(DragUpdateDetails details) {
    _cursorPosition = details.localPosition;
    if (_editingCommandIndex != null &&
        _movingOriginalCommand != null &&
        _movingStartPosition != null) {
      final delta = details.localPosition - _movingStartPosition!;
      history[_editingCommandIndex!] =
          _movingOriginalCommand!.translated(delta);
      setState(() {});
      _invalidateCommands();
      return;
    }

    final start = _dragStart;
    if (start == null) return;
    final end = details.localPosition;
    if (currentTool == ScreenshotToolType.brush ||
        currentTool == ScreenshotToolType.eraser) {
      _dragPath?.lineTo(end.dx, end.dy);
    }
    _dragEnd = end;
    final rect = _normalizedRect(start, end);
    // 只重绘预览层，不重建整棵编辑器树。
    _canvasTick.value++;
    _ffi.updateSelection(
      rect.left.toInt(),
      rect.top.toInt(),
      rect.width.toInt(),
      rect.height.toInt(),
    );
  }

  void _onPanEnd(DragEndDetails details) {
    if (_editingCommandIndex != null) {
      setState(() {
        _editingCommandIndex = null;
        _movingOriginalCommand = null;
        _movingStartPosition = null;
      });
      return;
    }

    final start = _dragStart;
    final end = _dragEnd ?? start;
    if (start == null || end == null) return;

    if (currentTool == ScreenshotToolType.text) {
      _openTextDialog(start);
    } else {
      final rect = _normalizedRect(start, end);
      final path = _dragPath ?? Path();
      if ((currentTool == ScreenshotToolType.brush ||
              currentTool == ScreenshotToolType.eraser) &&
          path.getBounds().isEmpty) {
        path.lineTo(start.dx + 0.01, start.dy + 0.01);
      }
      final command = DrawCommand(
        type: currentTool,
        start: start,
        end: end,
        path: path,
        rect: rect,
        color: currentColor,
        // 橡皮痕迹的宽度 = 橡皮粗细（像素擦除的扫宽）。
        strokeWidth:
            currentTool == ScreenshotToolType.eraser ? eraserSize : strokeWidth,
        fillColor: maskColor,
      );
      if (currentTool != ScreenshotToolType.brush &&
          currentTool != ScreenshotToolType.eraser &&
          (rect.width == 0 || rect.height == 0)) {
        setState(() {
          _dragStart = null;
          _dragEnd = null;
          _dragPath = null;
        });
        return;
      }
      setState(() {
        _pushCommand(command);
        _dragStart = null;
        _dragEnd = null;
        _dragPath = null;
      });
      _ffi.finishSelection(
        rect.left.toInt(),
        rect.top.toInt(),
        rect.width.toInt(),
        rect.height.toInt(),
      );
      return;
    }

    setState(() {
      _dragStart = null;
      _dragEnd = null;
      _dragPath = null;
    });
  }
}

/// 复制按钮的反馈状态：空闲 / 复制中 / 已复制 / 失败。
enum _CopyState { idle, working, done, failed }
