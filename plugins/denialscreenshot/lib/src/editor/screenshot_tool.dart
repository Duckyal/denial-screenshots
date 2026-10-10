import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart'
    show PointerSignalEvent, PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../clipboard.dart';
import '../editor_bus.dart';
import '../scroll_capture.dart';
import 'dialog_style.dart';
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

  /// 直线/箭头/矩形/椭圆/蒙版归到一个「形状」按钮里，点开展开二级图标。

  /// 停靠工具栏上各工具按钮的 Key，展开选项行以此为锚居中定位。
  final Map<ScreenshotToolType, GlobalKey> _dockToolKeys = {
    for (final type in ScreenshotToolType.values) type: GlobalKey(),
  };
  final GlobalKey _dockBarKey = GlobalKey();
  final GlobalKey _optionsPanelKey = GlobalKey();
  Offset? _optionsPanelBottomOffset;
  bool _optionsPanelVisible = false;

  /// 选项行色板：10 个 Office 标准色（与取色板主题网格的色相列一致），
  /// 更多颜色走调色板三级面板（只放主题颜色网格）。
  static const _dockColors = [
    Color(0xFF000000),
    Color(0xFFC00000),
    Color(0xFFFF0000),
    Color(0xFFFFC000),
    Color(0xFFFFFF00),
    Color(0xFF92D050),
    Color(0xFF00B050),
    Color(0xFF00B0F0),
    Color(0xFF0070C0),
    Color(0xFF002060),
    Color(0xFF7030A0),
  ];

  /// 形状组折叠时显示的图标 = 最近一次用过的形状。
  Color currentColor = Colors.black;
  Color maskColor = Colors.white;
  double strokeWidth = 3;

  /// 橡皮独立粗细：橡皮按半径整块删除对象（含画笔笔迹），需要比画笔
  /// 大得多的量级才能快速擦除。
  double eraserSize = 24;

  /// 文字工具独立字号。
  double textFontSize = 16;
  String textFontFamily = '';
  final List<DrawCommand> history = [];
  final List<List<DrawCommand>> _undoSnapshots = [];
  final List<List<DrawCommand>> _redoSnapshots = [];

  /// 撤销分组：翻译落画布会一次产生"蒙版+译文"两条命令 × 多个文字块，
  /// 分组期间不逐条压撤销快照，整组结束后压一条——一次撤销回退整个
  /// 翻译步骤。
  int _undoGroupDepth = 0;
  List<DrawCommand>? _pendingGroupSnapshot;
  int currentStep = -1;
  Rect? selectionRect;
  final TextEditingController _textController = TextEditingController();
  final FocusNode _textFocusNode = FocusNode();
  final GlobalKey _canvasKey = GlobalKey();
  bool _showTextDialog = false;

  /// 弹窗改的是哪条文字命令（null = 新建）。
  int? _editingTextIndex;
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

  /// 与 [apiTimeoutSeconds] 保持一致，超时提示里告诉用户等了多久。
  static const int _apiTimeoutSeconds = apiTimeoutSeconds;

  bool _translating = false;

  /// 识字与翻译是两条独立的链路，按钮各自点亮，别再共用一个标志。
  bool _recognizing = false;
  String _translateStatus = '';
  Timer? _apiElapsedTimer;
  String _apiNote = '';

  /// 识字同样是「模型加载 → 逐段识别」的慢过程，用秒数 + 已识别段数把它
  /// 变成看得见的进度，别停在「正在识别文字…」。
  Timer? _ocrElapsedTimer;
  int _ocrSeconds = 0;
  int _ocrRegions = 0;
  String _ocrBaseStatus = '正在识别文字…';
  bool _dockRevealed = false;
  bool _dockHovered = false;
  bool _showHints = false;
  Timer? _dockRevealTimer;
  StreamSubscription<void>? _scrollCaptureSubscription;
  ({bool vertical, bool atStart, bool hidden, bool reserved})?
  _lastDockPlacement;
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

  /// 已提交命令的栅格化位图（世界尺寸）：静态层直接 blit，不再每帧重放
  /// 命令；橡皮擦除在其中烘焙成透明洞，透出下层 Image 即原图。
  ui.Image? _annotationImage;

  /// 橡皮拖动擦除的增量状态：[_pendingEraseSegment] 是尚未烘进位图的
  /// 新笔画段，[_eraseTail] 是上一段的终点（段间圆头衔接无缝）。
  Path? _pendingEraseSegment;
  Offset? _eraseTail;
  bool _eraseApplyScheduled = false;

  /// 底图 widget 缓存：避免每次重建都新建 Image 节点。
  late Widget _imageWidget;

  /// 冻结帧背景 widget 缓存，理由同上。
  late Widget _frozenBackdrop;
  int? _editingCommandIndex;
  DrawCommand? _movingOriginalCommand;
  Offset? _movingStartPosition;
  int? _selectedCommandIndex;

  /// 当前正在拖拽的缩放手柄；非空表示这次拖动是改大小而不是整体移动。
  ResizeHandle? _resizeHandle;

  /// world → 屏幕的显示比例，由画布布局阶段刷新，用于把缩放手柄的屏幕
  /// 像素尺寸换算成 world 单位。
  double _canvasDisplayScale = 1.0;
  ui.Image? _decodedImage;

  /// 文本工具拖拽圈定的文本框（约束换行宽度）；null = 点击创建的单行文本。
  Rect? _textBoxRect;

  /// 手动蒙版的填充方式，在蒙版的展开选项里切换；默认模糊背景。
  MaskStyle currentMaskStyle = MaskStyle.blur;
  late Uint8List _currentImageBytes;
  Offset? _dragStart;
  Offset? _dragEnd;
  Path? _dragPath;

  /// 本次按下的指针是否已被 pan 回调接管。pan 的启动时机随 Flutter 版本
  /// 可能在按下瞬间或滑过阈值之后，用这个标志保证点删/点选/画点只走
  /// 一条路径，不会同时被 [_onPanStart] 和 [_onCanvasTapUp] 执行两次。
  bool _pointerHandledByPan = false;

  /// 后台 OCR：打开图片后异步识别（模型已装才跑，不弹安装向导），
  /// 文字块按画布坐标常驻——光标模式下可跨块框选复制（WPS 式）；翻译也
  /// 复用这批结果，不再临时识别第二次。
  ///
  /// 列表已按阅读顺序（先上下、再左右）排好，跨块选区就是这段有序列表上的
  /// 一个连续区间。
  List<({Rect rect, TranslateRegion region})> _ocrBlocks = const [];
  Future<List<TranslateRegion>>? _ocrTask;
  int _ocrGeneration = 0;

  /// WPS 式跨块文字选区：起点/终点都是 (块下标, 块内字符偏移) 的有序区间。
  /// 起止块相同且偏移相同 = 空选区（没选中）。自定义选择层直接按字符比例
  /// 在这套坐标上算高亮矩形，拖动跨过块间空隙也不会断。
  int? _ocrSelAnchorBlock;
  int? _ocrSelAnchorOffset;
  int? _ocrSelFocusBlock;
  int? _ocrSelFocusOffset;
  bool _ocrSelecting = false;

  /// 当前是否有选中的 OCR 文字：决定 Ctrl+C 是复制所选文字还是复制整图。
  bool _hasTextSelection = false;

  /// The canvas hides the system cursor for freehand tools; the drawn ring
  /// in [ToolCursorPainter] becomes the cursor instead.
  /// 只有画笔/橡皮用指针环替代系统光标（环本身就是笔迹粗细预览）；
  /// 形状/文本用系统光标，与 QQ 截图、mark-shot 等成熟工具一致。
  bool get _usesPointerRing =>
      !_showTextDialog &&
      (currentTool == ScreenshotToolType.brush ||
          currentTool == ScreenshotToolType.eraser);

  MouseCursor get _canvasCursor {
    if (_usesPointerRing) return SystemMouseCursors.none;
    if (_showTextDialog) return MouseCursor.defer;
    switch (currentTool) {
      case ScreenshotToolType.text:
        return SystemMouseCursors.text;
      case ScreenshotToolType.line:
      case ScreenshotToolType.arrow:
      case ScreenshotToolType.rect:
      case ScreenshotToolType.circle:
      case ScreenshotToolType.mask:
        return SystemMouseCursors.precise;
      default:
        return MouseCursor.defer;
    }
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    _currentImageBytes = widget.capturedImage;
    _imageWidget = _buildImageWidget();
    _frozenBackdrop = _buildFrozenBackdrop();
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
    // Listen for system-level scroll capture trigger.
    _scrollCaptureSubscription = EditorScrollCaptureNotifier
        .instance
        .notifications
        .listen((_) {
          if (mounted) _startScrollCapture();
        });
  }

  Widget _buildImageWidget() =>
      Image.memory(_currentImageBytes, fit: BoxFit.fill);

  /// 冻结帧背景：把刚截下的整帧铺满整个 surface（[BoxFit.cover]）再虚化压暗，
  /// 让编辑器没有纯色留白——视觉上像是仍停在截图那一帧上，而不是另开了一个
  /// 编辑窗口。真正可标注的画布依然 `contain` 居中叠在上面；导出只取画布
  /// （`_canvasKey` 的 RepaintBoundary 不含这层背景）。
  Widget _buildFrozenBackdrop() {
    return Stack(
      fit: StackFit.expand,
      children: [
        ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: Image.memory(
            _currentImageBytes,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.low,
          ),
        ),
        // 压暗，让居中的清晰画布成为视觉焦点，同时保证整屏不透明。
        const ColoredBox(color: Color(0xB30B0F13)),
      ],
    );
  }

  /// 命令数 + 步骤的廉价指纹，用来判断缓存是否过期。
  int get _commandsStamp => history.length * 1000003 + (currentStep + 1);

  /// 命令列表变化后调用：刷新缓存并让静态层重绘。
  void _invalidateCommands() {
    _visibleStamp = _commandsStamp;
    _visibleCommands = List<DrawCommand>.unmodifiable(
      history.take(currentStep + 1),
    );
    _commandsVersion++;
    _rebuildAnnotationImage();
    _staticTick.value++;
  }

  /// 位图更新的串行队列：录制（UI 线程，便宜）→ toImage（光栅在线程外
  /// 完成）→ 换图。删除/提交/撤销触发的全量重光栅化不再阻塞当前帧——
  /// 此前同步 toImageSync 全量重画所有笔迹，按下删除形状那一下就明显
  /// 卡一下。重建任务可被更新的重建顶替跳过；增量擦除任务永不跳过。
  final List<Future<void> Function()> _bitmapQueue = [];
  bool _bitmapQueueRunning = false;
  int _queuedRebuilds = 0;

  void _enqueueBitmapTask(Future<void> Function() task) {
    _bitmapQueue.add(task);
    if (_bitmapQueueRunning) return;
    _bitmapQueueRunning = true;
    () async {
      while (_bitmapQueue.isNotEmpty) {
        final next = _bitmapQueue.removeAt(0);
        try {
          await next();
        } catch (_) {
          // 单个任务失败不阻塞后续位图更新。
        }
      }
      _bitmapQueueRunning = false;
    }();
  }

  /// 把已提交命令重栅格化到 [_annotationImage]（异步，不阻塞 UI）。
  ///
  /// 只在命令变化时触发（提交/删除/撤销/重做/底图解码完成），不在指针
  /// 移动路径上。单个 picture 内 BlendMode.clear 天然擦得动先画的内容，
  /// 不需要 saveLayer——这张与画布等大的离屏图层在 4K 截图下是几十 MB，
  /// 此前每个指针事件都扛一张正是橡皮卡顿、拖动时画面不动的根因。
  void _rebuildAnnotationImage() {
    // 光标模式拖动对象期间命令每帧都在变：静态层走逐条重放，位图等
    // 松手后的 invalidate 再重建，免得每帧双重光栅化。
    if (_editingCommandIndex != null) return;
    _queuedRebuilds++;
    _enqueueBitmapTask(() async {
      // 排队期间又有更新的重建排队：本次输出必然立刻过时，直接跳过，
      // 省一次全量光栅化（增量擦除任务不受影响，按序叠加）。
      if (--_queuedRebuilds > 0) return;
      final size = _worldSize;
      final width = size.width.round();
      final height = size.height.round();
      if (width <= 0 || height <= 0 || !mounted) return;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Offset.zero & size);
      for (final command in _visibleCommands) {
        drawCommand(canvas, command, backgroundImage: _decodedImage);
      }
      final picture = recorder.endRecording();
      final image = await picture.toImage(width, height);
      picture.dispose();
      if (!mounted) {
        image.dispose();
        return;
      }
      _annotationImage?.dispose();
      _annotationImage = image;
      _staticTick.value++;
    });
  }

  /// 橡皮拖动期间每帧至多烘一次新笔画段进位图（指针事件频率远高于
  /// 帧率，不能每个事件都重光栅化）。
  void _scheduleEraseApply() {
    if (_eraseApplyScheduled) return;
    _eraseApplyScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _eraseApplyScheduled = false;
      _applyPendingErase();
    });
  }

  void _applyPendingErase() {
    final segment = _pendingEraseSegment;
    if (segment == null) return;
    // 段交给队列后立即从尾部另起新段：圆头 + clear 幂等，段间衔接与
    // 整条路径一致。
    final tail = _eraseTail;
    _pendingEraseSegment = tail == null
        ? null
        : (Path()..moveTo(tail.dx, tail.dy));
    _enqueueBitmapTask(() async {
      // 基底在执行时取最新位图，保证排在它前面的重建/擦除都已生效。
      final base = _annotationImage;
      if (base == null || !mounted) return;
      final size = _worldSize;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Offset.zero & size);
      canvas.drawImage(base, Offset.zero, Paint());
      canvas.drawPath(
        segment,
        Paint()
          ..color = Colors.transparent
          ..blendMode = BlendMode.clear
          ..strokeWidth = eraserSize
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(
        size.width.round(),
        size.height.round(),
      );
      picture.dispose();
      if (!mounted) {
        image.dispose();
        return;
      }
      _annotationImage?.dispose();
      _annotationImage = image;
      _staticTick.value++;
    });
  }

  /// build 期兜底：命令数或步骤变了却没人通知时刷新缓存（这里不 bump
  /// 通知，交给 painter 的引用比较去重绘）。
  void _syncVisibleCommands() {
    final stamp = _commandsStamp;
    if (stamp == _visibleStamp) return;
    _visibleStamp = stamp;
    _visibleCommands = List<DrawCommand>.unmodifiable(
      history.take(currentStep + 1),
    );
    _commandsVersion++;
  }

  /// 橡皮工具下静态层照常在场：擦除效果直接增量烘进静态层的标注
  /// 位图（扫过即真洞，透出下层原图），不必撤掉静态层整幅重放。
  bool get _eraseToolActive => currentTool == ScreenshotToolType.eraser;

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _scrollCaptureSubscription?.cancel();
    _settingsCaptureFocus.dispose();
    // 关掉常驻翻译/OCR 进程，避免留下孤儿 python。
    _translateService.dispose();
    EditorHostBridge.instance.unbindEditor(this);
    _dockRevealTimer?.cancel();
    _ocrElapsedTimer?.cancel();
    _apiElapsedTimer?.cancel();
    _canvasTick.dispose();
    _staticTick.dispose();
    _decodedImage?.dispose();
    _annotationImage?.dispose();
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
      // 换图回到刚进编辑器的 contain 尺寸。
      _canvasZoom = 1.0;
      _canvasPan = Offset.zero;
    });
    // 模糊蒙版/世界尺寸都依赖解码结果，位图按新底图重烘。
    _rebuildAnnotationImage();
    // 后台静默 OCR：文字块常驻供光标模式框选、翻译复用。
    _startBackgroundOcr();
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
            reserved: true,
          );
        case 'bottom':
          return (
            vertical: false,
            atStart: false,
            hidden: false,
            reserved: true,
          );
        case 'left':
          return (vertical: true, atStart: true, hidden: false, reserved: true);
        case 'right':
          return (
            vertical: true,
            atStart: false,
            hidden: false,
            reserved: true,
          );
        default: // 窗口尺寸未知时退回底部常显
          return (
            vertical: false,
            atStart: false,
            hidden: false,
            reserved: true,
          );
      }
    }

    // 自动模式：图像按整窗适配，看四周留白条带能否装下工具栏。
    final fitScale = math.min(
      window.width / world.width,
      window.height / world.height,
    );
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
      final horizontalScale = math.min(
        window.width / world.width,
        math.max(0, window.height - reserve) / world.height,
      );
      final verticalScale = math.min(
        math.max(0, window.width - reserve) / world.width,
        window.height / world.height,
      );
      vertical = verticalScale > horizontalScale * 1.05;
    }
    // 不再贴边自动隐藏：工具栏常显，需要时用 Tab 收起。留白装得下就浮在
    // 留白上，装不下才预留空间，免得压住图像。
    final fits = vertical ? verticalFits : horizontalFits;
    return (vertical: vertical, atStart: false, hidden: false, reserved: !fits);
  }

  /// Alt+滚轮：以指针为锚点缩放画布（1.0 = 刚进编辑器的 contain 尺寸，
  /// 只能放大）；放大后普通滚轮上下平移、Shift+滚轮左右平移。
  void _onCanvasScroll(PointerSignalEvent event, Size viewport) {
    if (event is! PointerScrollEvent) return;
    final world = _worldSize;
    if (world.isEmpty || viewport.isEmpty) return;
    if (HardwareKeyboard.instance.isAltPressed) {
      _zoomCanvasAt(event.localPosition, viewport, event.scrollDelta.dy);
    } else if (_canvasZoom > 1) {
      final shift = HardwareKeyboard.instance.isShiftPressed;
      final delta = Offset(
        shift ? -event.scrollDelta.dy : 0,
        shift ? 0 : -event.scrollDelta.dy,
      );
      _panCanvas(_canvasPan + delta, viewport);
    }
  }

  /// 缩放后画布在视口里的绘制矩形（未加平移）：FittedBox 的 contain 缩放
  /// 系数 k 加居中偏移 o，再叠加画布缩放 z。
  ({double k, Offset o, Rect rect}) _canvasLayout(
    double zoom,
    Size viewport,
    Size world,
  ) {
    final k = math.min(
      viewport.width / world.width,
      viewport.height / world.height,
    );
    final o = Offset(
      (viewport.width - world.width * k) / 2,
      (viewport.height - world.height * k) / 2,
    );
    return (
      k: k,
      o: o,
      rect: Rect.fromLTWH(
        o.dx,
        o.dy,
        world.width * k * zoom,
        world.height * k * zoom,
      ),
    );
  }

  /// 平移夹取：图像盖满视口时允许在 [视口-图像] 范围内移动；没盖满时居中。
  Offset _clampCanvasPan(Offset pan, double zoom, Size viewport, Size world) {
    final layout = _canvasLayout(zoom, viewport, world);
    double clampAxis(double value, double start, double extent, double view) {
      if (extent >= view) {
        return value.clamp(view - (start + extent), -start);
      }
      return (view - extent) / 2 - start;
    }

    return Offset(
      clampAxis(pan.dx, layout.rect.left, layout.rect.width, viewport.width),
      clampAxis(pan.dy, layout.rect.top, layout.rect.height, viewport.height),
    );
  }

  void _zoomCanvasAt(Offset cursor, Size viewport, double scrollDelta) {
    final layout = _canvasLayout(_canvasZoom, viewport, _worldSize);
    // 指针下的图像点（世界坐标）：V = o + k*(pan + z*W)。
    final c = (cursor - layout.o) / layout.k;
    final worldPoint = (c - _canvasPan) / _canvasZoom;
    final factor = scrollDelta < 0 ? 1.1 : 1 / 1.1;
    final nextZoom = (_canvasZoom * factor).clamp(1.0, 8.0);
    if (nextZoom == _canvasZoom) return;
    // 锚定：缩放前后指针下的图像点不动。
    final pan = _clampCanvasPan(
      c - worldPoint * nextZoom,
      nextZoom,
      viewport,
      _worldSize,
    );
    setState(() {
      _canvasZoom = nextZoom;
      _canvasPan = pan;
    });
  }

  void _panCanvas(Offset pan, Size viewport) {
    final clamped = _clampCanvasPan(pan, _canvasZoom, viewport, _worldSize);
    if ((clamped - _canvasPan).distance < 0.5) return;
    setState(() => _canvasPan = clamped);
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
    // 调色板三级面板开着：Esc 先收起面板，其余键照常。
    if (_paletteVisible) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        setState(() => _paletteVisible = false);
        return true;
      }
    }
    // 设置面板打开时：Esc 先关闭设置面板（连带模型管理/API 配置浮层），其余键照常。
    if (_settingsOpen) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        setState(() {
          _settingsOpen = false;
          _modelManagerOpen = false;
          _apiConfigOpen = false;
        });
        return true;
      }
      return false;
    }
    // 文件面板打开时：Esc 先关闭文件面板，其余键照常。
    if (_filePanelOpen) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        setState(() => _filePanelOpen = false);
        return true;
      }
      return false;
    }

    // 数据驱动的可自定义快捷键：面板/撤销/重做/关闭/提示/工具切换。
    final binding = _bindingOfEvent(event);
    debugPrint(
      '[key] binding="$binding" '
      'hints=${_settings.bindingFor("hints")} showHints=$_showHints',
    );
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
          // Esc 只关窗不复制：复制走 Ctrl+C 或「复制并关闭」按钮，避免
          // 覆盖用户刚复制的文字。关窗时剪贴板保持原样。
          _closeEditor();
        }
        return true;
      }
      if (binding == 'ctrl+c') {
        // 选中了 OCR 文字就复制所选文字，不触发整图复制。
        if (_hasTextSelection) {
          _copyOcrSelection();
          return true;
        }
        _copy();
        return true;
      }
      if (binding == _settings.bindingFor('scrollCapture')) {
        _startScrollCapture();
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
        _saveFilePanel();
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
            // 每帧布局后重新测量展开选项行的锚点位置（工具切换/窗口变化后对齐）。
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _updateOptionsPlacement(placement);
              _updatePalettePlacement(placement);
              _updateFontFamilyPlacement(placement);
              _updateSettingsPanelPlacement(placement);
              _updateFilePanelPlacement(placement);
              _updateModelManagerPlacement(placement);
              _updateApiConfigPlacement(placement);
            });
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
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // 全屏不透明冻结帧：整个 surface 都是刚截的那帧的
                        // 延伸，不再有纯色留白，观感与 QQ 截图一致。
                        // 必须隔离重绘边界：sigma-22 的全屏模糊一旦被指针环
                        // 的每次重绘拖累，橡皮拖动就会整屏重糊、明显卡顿。
                        RepaintBoundary(child: _frozenBackdrop),
                        Padding(
                          padding: canvasPadding,
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final viewport = constraints.biggest;
                              // world → 屏幕的显示比例（FittedBox contain ×
                              // 用户缩放）：缩放手柄要按屏幕像素保持恒定
                              // 大小，绘制/命中前用它把像素换算成 world 单位。
                              if (_worldSize.width > 0 &&
                                  _worldSize.height > 0 &&
                                  viewport.width > 0 &&
                                  viewport.height > 0) {
                                final fit = math.min(
                                  viewport.width / _worldSize.width,
                                  viewport.height / _worldSize.height,
                                );
                                _canvasDisplayScale = fit * _canvasZoom;
                              }
                              return Listener(
                                behavior: HitTestBehavior.translucent,
                                onPointerSignal: (event) =>
                                    _onCanvasScroll(event, viewport),
                                child: FittedBox(
                                  fit: BoxFit.contain,
                                  clipBehavior: Clip.hardEdge,
                                  child: Transform(
                                    transform: Matrix4.identity()
                                      ..translate(_canvasPan.dx, _canvasPan.dy)
                                      ..scale(_canvasZoom, _canvasZoom, 1),
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
                                                          color: Colors.red,
                                                          width: 2,
                                                        ),
                                                        color: Colors.red
                                                            .withValues(
                                                              alpha: 0.1,
                                                            ),
                                                      ),
                                                    ),
                                                  ),
                                                // 已提交的图形：有栅格化位图时只
                                                // blit 位图（橡皮擦除已烘焙成真洞，
                                                // 透出下层原图）；拖动移动对象期间
                                                // 位图停更，退回逐条重放。
                                                Positioned.fill(
                                                  child: IgnorePointer(
                                                    child: ValueListenableBuilder<int>(
                                                      valueListenable:
                                                          _staticTick,
                                                      builder: (context, _, __) => CustomPaint(
                                                        painter: StaticDrawPainter(
                                                          commands:
                                                              _visibleCommands,
                                                          version:
                                                              _commandsVersion,
                                                          backgroundImage:
                                                              _decodedImage,
                                                          annotationImage:
                                                              _editingCommandIndex ==
                                                                  null
                                                              ? _annotationImage
                                                              : null,
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
                                                    child: Listener(
                                                      // 纯点击不会触发 pan 回调
                                                      // （pan 要先滑过位移阈值），
                                                      // 用原始指针事件补齐"点一下"
                                                      // 的交互：橡皮点删、光标点选、
                                                      // 画笔点个点。拖动时 pan 已
                                                      // 接手（_dragStart 等非空），
                                                      // 这里直接跳过。
                                                      onPointerUp: (event) =>
                                                          _onCanvasTapUp(
                                                            event.localPosition,
                                                          ),
                                                      child: GestureDetector(
                                                        // 画布必须 opaque：橡皮悬停
                                                        // （未落笔）时预览层 painter
                                                        // 为 null，CustomPaint 不参与
                                                        // 命中，缺了这条整个画布收不到
                                                        // 指针事件，橡皮完全失灵。
                                                        behavior:
                                                            HitTestBehavior
                                                                .opaque,
                                                        // 光标模式下双击文字就地改字。
                                                        onDoubleTapDown:
                                                            (
                                                              details,
                                                            ) => _onCanvasDoubleTap(
                                                              details
                                                                  .localPosition,
                                                            ),
                                                        onPanStart: _onPanStart,
                                                        onPanUpdate:
                                                            _onPanUpdate,
                                                        onPanEnd: _onPanEnd,
                                                        onPanCancel:
                                                            _onPanCancel,
                                                        child: ValueListenableBuilder<int>(
                                                          valueListenable:
                                                              _canvasTick,
                                                          builder: (context, _, __) {
                                                            final preview =
                                                                _buildPreviewCommand();
                                                            // 橡皮（拖动或悬停）时预览层
                                                            // 为空：擦除效果由静态层的
                                                            // 位图增量烘焙直接呈现，扫过
                                                            // 即真洞，透出下层原图。
                                                            return CustomPaint(
                                                              painter:
                                                                  _eraseToolActive
                                                                  ? null
                                                                  : PreviewDrawPainter(
                                                                      preview:
                                                                          preview,
                                                                      backgroundImage:
                                                                          _decodedImage,
                                                                    ),
                                                            );
                                                          },
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          // 常驻文字选择层：世界坐标跟随图像缩放，
                                          // 但在 RepaintBoundary 之外，保存和置顶
                                          // 快照都不会带上它。只在光标模式吃指针
                                          // 事件，其它工具正常画图不受影响。
                                          if (_ocrBlocks.isNotEmpty)
                                            Positioned.fill(
                                              child: IgnorePointer(
                                                ignoring:
                                                    currentTool !=
                                                    ScreenshotToolType.select,
                                                child:
                                                    _buildTextSelectOverlay(),
                                              ),
                                            ),
                                          // 选中对象高亮框 + 缩放手柄：同样
                                          // 在世界坐标里、但在 RepaintBoundary
                                          // 之外，保存/置顶不会带上，也不会
                                          // 因为进光标模式而被烙进图片。
                                          if (currentTool ==
                                                  ScreenshotToolType.select &&
                                              _selectedCommandIndex != null &&
                                              _selectedCommandIndex! <
                                                  _visibleCommands.length)
                                            Positioned.fill(
                                              child: IgnorePointer(
                                                child: CustomPaint(
                                                  painter: SelectionPainter(
                                                    command:
                                                        _visibleCommands[_selectedCommandIndex!],
                                                    handleSize:
                                                        _resizeHandleWorldSize,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          // Pointer ring inside the world (scales with it)
                                          // but OUTSIDE the RepaintBoundary so saves and
                                          // pins never contain it.
                                          if (_usesPointerRing)
                                            Positioned.fill(
                                              child: IgnorePointer(
                                                // 指针环每帧都动，独立成层避免拖累
                                                // 兄弟子树的重绘。
                                                child: RepaintBoundary(
                                                  child: ValueListenableBuilder<int>(
                                                    valueListenable:
                                                        _canvasTick,
                                                    builder: (context, _, __) {
                                                      final position =
                                                          _cursorPosition;
                                                      if (position == null) {
                                                        return const SizedBox.shrink();
                                                      }
                                                      return CustomPaint(
                                                        painter:
                                                            ToolCursorPainter(
                                                              position:
                                                                  position,
                                                              tool: currentTool,
                                                              color:
                                                                  currentColor,
                                                              strokeWidth:
                                                                  _activeSize,
                                                            ),
                                                      );
                                                    },
                                                  ),
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 自动隐藏模式下：showToolbar && 唤出状态才显示。
                  if (showToolbar && (!placement.hidden || _dockRevealed))
                    _buildToolbarDock(
                      vertical: placement.vertical,
                      atStart: placement.atStart,
                      hidden: placement.hidden,
                    ),
                  // 选中绘图工具时在对应按钮旁展开的选项行（颜色/粗细/蒙版
                  // 模式），随停靠位置贴正确的一侧。
                  _buildOptionsOverlay(dockShown: showToolbar),
                  // 调色板三级面板：锚在调色板按钮上，内容见
                  // _buildPalettePanel。
                  _buildPaletteOverlay(dockShown: showToolbar),
                  // 字体选择三级面板。
                  _buildFontFamilyOverlay(dockShown: showToolbar),
                  // 设置面板：锚在停靠条的设置按钮旁，分页见
                  // _buildSettingsPanel。
                  _buildSettingsPanelOverlay(dockShown: showToolbar),
                  // 文件面板：锚在打开/保存按钮旁，替代弹窗。
                  _buildFilePanelOverlay(dockShown: showToolbar),
                  // 本地翻译模型管理：贴着设置面板弹出的三级浮层。
                  _buildModelManagerOverlay(dockShown: showToolbar),
                  // 在线翻译 API 配置：同款式贴设置面板的三级浮层。
                  _buildApiConfigOverlay(dockShown: showToolbar),
                  // 识字和翻译都要显示过程浮层，否则点了像没反应。
                  if (_translating || _recognizing)
                    Positioned(
                      // 工具栏占哪边，状态浮层就贴另一边，避免重叠。
                      top: !placement.vertical && !placement.atStart
                          ? 12
                          : null,
                      bottom: !placement.vertical && !placement.atStart
                          ? null
                          : 12,
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
                              color: Colors.black.withValues(alpha: 0.82),
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
    final left = (_textDialogWindowAnchor.dx).clamp(
      0.0,
      (media.width - popupWidth - 8).clamp(0.0, double.infinity),
    );
    final top = (_textDialogWindowAnchor.dy).clamp(
      0.0,
      (media.height - popupHeight - 8).clamp(0.0, double.infinity),
    );

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
                    color: Colors.black.withValues(alpha: 0.35),
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
                    decoration: InputDecoration(
                      isDense: true,
                      border: const OutlineInputBorder(),
                      hintText: _editingTextIndex == null
                          ? '输入文字，回车确认'
                          : '修改文字，回车确认（清空即删除）',
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
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
    // 拖拽圈定的是 PPT 式文本框：内容按框宽换行、字号随框自适应、框内
    // 水平垂直居中；点击创建的是自由单行文字。
    final box = _textBoxRect;
    final maxWidth = box == null
        ? double.infinity
        : math.max(12.0, box.width - 8);
    final origin = box?.topLeft ?? _textDialogPosition;
    Rect rect;
    if (box != null) {
      rect = box;
    } else {
      final textPainter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: currentColor,
            fontSize: textFontSize,
            fontFamily: textFontFamily.isEmpty ? null : textFontFamily,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: maxWidth);
      rect = Rect.fromLTWH(
        origin.dx,
        origin.dy,
        textPainter.width,
        textPainter.height,
      );
    }

    final command = DrawCommand(
      type: ScreenshotToolType.text,
      start: origin,
      end: origin,
      path: Path(),
      text: text,
      rect: rect,
      color: currentColor,
      strokeWidth: textFontSize,
      textMaxWidth: maxWidth,
      textBox: box,
      fontFamily: textFontFamily,
    );
    _textBoxRect = null;

    setState(() => _pushCommand(command));
  }

  void _pushCommand(DrawCommand command) {
    if (_undoGroupDepth == 0) {
      _undoSnapshots.add(List<DrawCommand>.from(history));
      _redoSnapshots.clear();
    }
    if (currentStep + 1 < history.length) {
      history.removeRange(currentStep + 1, history.length);
    }
    history.add(command);
    currentStep = history.length - 1;
    _selectedCommandIndex = null;
    _invalidateCommands();
  }

  /// 开始一段撤销分组：调用后到 [_endUndoGroup] 之间的所有命令共享
  /// 一条撤销快照。支持嵌套，只有最外层结束才真正落快照。
  void _beginUndoGroup() {
    _undoGroupDepth++;
    if (_undoGroupDepth == 1) {
      _pendingGroupSnapshot = List<DrawCommand>.from(history);
    }
  }

  /// 结束最外层撤销分组：本次新增过命令才落一条撤销快照。
  void _endUndoGroup() {
    if (_undoGroupDepth > 0) _undoGroupDepth--;
    if (_undoGroupDepth == 0) {
      final snapshot = _pendingGroupSnapshot;
      _pendingGroupSnapshot = null;
      if (snapshot != null && history.length > snapshot.length) {
        _undoSnapshots.add(snapshot);
        _redoSnapshots.clear();
      }
    }
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

    Widget dockButton(
      IconData icon,
      String tip,
      VoidCallback onTap, {
      bool active = false,
      Color? color,
      Key? key,
      Widget? child,
    }) {
      return Tooltip(
        message: tip,
        child: GestureDetector(
          key: key,
          onTap: onTap,
          child: Container(
            width: 34,
            height: 34,
            margin: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color:
                  color ??
                  (active
                      ? Colors.blue.withValues(alpha: 0.6)
                      : Colors.white.withValues(alpha: 0.06)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: child ?? Icon(icon, color: Colors.white, size: 20),
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

    // 平铺的独立工具；形状类（直线/箭头/矩形/椭圆/蒙版）同样平铺。
    const standaloneTools = [
      (ScreenshotToolType.select, Icons.near_me, '光标（双击文字可修改）'),
      (ScreenshotToolType.brush, Icons.brush, '画笔'),
      (ScreenshotToolType.text, Icons.text_fields, '文字'),
    ];
    const shapeTools = [
      (ScreenshotToolType.line, Icons.straighten, '直线'),
      (ScreenshotToolType.arrow, Icons.arrow_forward, '箭头'),
      (ScreenshotToolType.rect, Icons.crop_square, '矩形'),
      (ScreenshotToolType.circle, Icons.circle_outlined, '椭圆'),
      (ScreenshotToolType.mask, Icons.rectangle, '蒙版'),
    ];

    // 颜色/粗细/调色板移进展开选项行（_buildOptionsPanelContent），停靠条
    // 只保留工具与动作；形状类工具直接平铺，不再收起进「形状」。
    final cells = <Widget>[
      dockButton(
        Icons.folder_open,
        '打开图片',
        _openFilePanel,
        key: _dockFileOpenKey,
      ),
      divider(),
      for (final (type, icon, label) in [...standaloneTools, ...shapeTools])
        dockButton(
          icon,
          label,
          () => _switchTool(type),
          active: currentTool == type,
          key: _dockToolKeys[type],
        ),
      // 橡皮收尾工具组：自绘橡皮图标（图标库里没有现成的），紧邻撤销
      // 分割线。
      dockButton(
        Icons.backspace,
        '橡皮',
        () => _switchTool(ScreenshotToolType.eraser),
        active: currentTool == ScreenshotToolType.eraser,
        key: _dockToolKeys[ScreenshotToolType.eraser],
        child: const _EraserGlyph(),
      ),
      divider(),
      dockButton(Icons.undo, '撤销 (Ctrl+Z)', _undo),
      dockButton(Icons.redo, '重做 (Ctrl+Shift+Z)', _redo),
      dockButton(Icons.translate, '翻译', _translate, active: _translating),
      // 复制与关闭合并：编辑成果的最终归宿就是剪贴板，一键收工；复制
      // 期间沙漏、成功亮绿勾、失败亮红叹号留在原地可重试。想放弃不复制
      // 时用 Esc。
      dockButton(
        _copyIcon,
        _copyTip,
        _copyAndClose,
        active:
            _copyState == _CopyState.working || _copyState == _CopyState.done,
        color: _copyColor,
      ),
      dockButton(
        Icons.save,
        '保存 (Enter)',
        _saveFilePanel,
        key: _dockFileSaveKey,
      ),
      dockButton(Icons.push_pin, '置顶显示', _toggleToolbarPin),
      divider(),
      dockButton(
        Icons.settings_outlined,
        '设置',
        _openSettings,
        key: _dockSettingsKey,
      ),
    ];

    final dockDecoration = BoxDecoration(
      color: Colors.black.withValues(alpha: 0.82),
      borderRadius: BorderRadius.circular(12),
      boxShadow: const [
        BoxShadow(color: Colors.black38, blurRadius: 10, offset: Offset(0, 2)),
      ],
    );
    const dockPadding = EdgeInsets.symmetric(horizontal: 6, vertical: 4);

    final bar = Container(
      key: _dockBarKey,
      padding: dockPadding,
      decoration: dockDecoration,
      child: vertical
          ? Column(mainAxisSize: MainAxisSize.min, children: cells)
          : Row(mainAxisSize: MainAxisSize.min, children: cells),
    );

    final dock = bar;

    final slideOut = vertical
        ? Offset(atStart ? -1 : 1, 0)
        : Offset(0, atStart ? -1 : 1);
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
              child: FittedBox(fit: BoxFit.scaleDown, child: dock),
            ),
          ),
        ),
      ),
    );
  }

  /// 当前工具对应的展开选项行锚点按钮：形状类平铺后各有各的键，
  /// 都锚在各自按钮上；光标模式编辑选中对象时锚在光标按钮。
  GlobalKey? _optionsAnchorKey() {
    return _dockToolKeys[currentTool];
  }

  /// 展开选项行的内容：随工具变化（颜色/粗细/蒙版填充方式）。
  /// 光标模式选中对象时展示该对象的可编辑项。返回 null 表示不展开。
  Widget? _buildOptionsPanelContent() {
    // 设置/文件面板打开时收起工具二级菜单及其三级面板（调色板/字体），
    // 一次只跟随一个按钮展开。
    if (_settingsOpen || _filePanelOpen) return null;
    final editingSelected = _editingSelectedObject;
    if (currentTool == ScreenshotToolType.select && !editingSelected) {
      return null;
    }

    final vertical = _lastDockPlacement?.vertical ?? false;

    Widget divider() => Container(
      width: vertical ? 20 : 1,
      height: vertical ? 1 : 20,
      margin: EdgeInsets.symmetric(
        horizontal: vertical ? 0 : 3,
        vertical: vertical ? 3 : 0,
      ),
      color: Colors.white24,
    );

    List<Widget> colorCells() => [
      for (final color in [Color(0xFF000000), ..._dockColors])
        _optionSwatchDot(color),
      _optionPaletteButton(),
    ];

    List<Widget> standardColorCells() => [
      for (final color in _dockColors) _optionSwatchDot(color),
    ];

    List<Widget> children;
    if (editingSelected) {
      children = [...colorCells(), divider(), _optionSizeSlider()];
    } else if (currentTool == ScreenshotToolType.mask) {
      // 蒙版：填充方式（模糊/纯色）+ 标准色 + 调色板按钮（纯色模式取用，模糊模式
      // 也可先选定颜色再切换）。
      children = [
        _maskModeButton(MaskStyle.blur, '模糊'),
        _maskModeButton(MaskStyle.solid, '纯色'),
        divider(),
        ...standardColorCells(),
        _optionPaletteButton(),
      ];
    } else if (currentTool == ScreenshotToolType.eraser) {
      children = [_optionSizeSlider()];
    } else if (currentTool == ScreenshotToolType.text) {
      children = [
        ...standardColorCells(),
        _optionPaletteButton(),
        _optionFontFamilyButton(),
        divider(),
        _optionFontSizeControl(),
      ];
    } else {
      children = [
        ...standardColorCells(),
        _optionPaletteButton(),
        divider(),
        _optionSizeSlider(),
      ];
    }
    if (children.isEmpty) return null;

    return Container(
      key: _optionsPanelKey,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(10),
        boxShadow: const [
          BoxShadow(
            color: Colors.black38,
            blurRadius: 10,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: vertical
          ? Column(mainAxisSize: MainAxisSize.min, children: children)
          : Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }

  /// 展开选项行浮层：绝对定位在停靠条旁，锚定到当前工具按钮居中；
  /// 停靠条隐藏或没有可展示的内容时随之淡出。
  Widget _buildOptionsOverlay({required bool dockShown}) {
    final content = _buildOptionsPanelContent();
    if (content == null) {
      return const SizedBox.shrink();
    }
    final visible = dockShown && _optionsPanelVisible;
    return Positioned(
      left: _optionsPanelBottomOffset?.dx ?? 0,
      top: _optionsPanelBottomOffset?.dy ?? 0,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 120),
          child: content,
        ),
      ),
    );
  }

  /// 布局后测量锚点按钮与停靠条的位置，把选项行放到正确的一侧并居中：
  /// 横向停靠在条的上/下方，纵向停靠在条的左/右侧。
  void _updateOptionsPlacement(
    ({bool vertical, bool atStart, bool hidden, bool reserved}) placement,
  ) {
    if (!mounted) return;
    final shouldShow =
        showToolbar &&
        (!placement.hidden || _dockRevealed) &&
        _buildOptionsPanelContent() != null;
    if (!shouldShow) {
      if (_optionsPanelVisible) {
        setState(() => _optionsPanelVisible = false);
      }
      return;
    }
    final barBox = _dockBarKey.currentContext?.findRenderObject() as RenderBox?;
    final anchorKey = _optionsAnchorKey();
    final anchorBox =
        anchorKey?.currentContext?.findRenderObject() as RenderBox?;
    final panelBox =
        _optionsPanelKey.currentContext?.findRenderObject() as RenderBox?;
    if (barBox == null ||
        anchorBox == null ||
        !barBox.attached ||
        !anchorBox.attached ||
        !barBox.hasSize) {
      return;
    }
    final anchorCenter = anchorBox.localToGlobal(
      anchorBox.size.center(Offset.zero),
    );
    final barOrigin = barBox.localToGlobal(Offset.zero);
    final barSize = barBox.size;
    final panelSize =
        (panelBox != null && panelBox.attached && panelBox.hasSize)
        ? panelBox.size
        : (placement.vertical ? const Size(46, 320) : const Size(320, 46));
    final window = MediaQuery.sizeOf(context);

    double left;
    double top;
    if (!placement.vertical) {
      left = (anchorCenter.dx - panelSize.width / 2).clamp(
        8.0,
        math.max(8.0, window.width - panelSize.width - 8),
      );
      top = placement.atStart
          ? barOrigin.dy + barSize.height + 6
          : barOrigin.dy - panelSize.height - 6;
    } else {
      top = (anchorCenter.dy - panelSize.height / 2).clamp(
        8.0,
        math.max(8.0, window.height - panelSize.height - 8),
      );
      left = placement.atStart
          ? barOrigin.dx + barSize.width + 6
          : barOrigin.dx - panelSize.width - 6;
    }

    final next = Offset(left, top);
    final changed =
        !_optionsPanelVisible ||
        _optionsPanelBottomOffset == null ||
        (next - _optionsPanelBottomOffset!).distance > 0.5;
    if (changed) {
      setState(() {
        _optionsPanelBottomOffset = next;
        _optionsPanelVisible = true;
      });
    }
  }

  /// 调色板三级面板浮层：布局后测量调色板按钮与选项行的位置，把面板放到
  /// 选项行外侧一层；选项行隐藏时面板跟着收起。
  Widget _buildPaletteOverlay({required bool dockShown}) {
    final visible =
        dockShown && _paletteVisible && _buildOptionsPanelContent() != null;
    if (_palettePanelVisible != visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _palettePanelVisible != visible) {
          setState(() => _palettePanelVisible = visible);
        }
      });
    }
    return Positioned(
      left: _palettePanelOffset?.dx ?? 0,
      top: _palettePanelOffset?.dy ?? 0,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 120),
          child: _buildPalettePanel(),
        ),
      ),
    );
  }

  Widget _buildPalettePanel() {
    Widget label(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        style: const TextStyle(fontSize: 11, color: Colors.white60),
      ),
    );
    Widget row(Iterable<Widget> cells) =>
        Row(mainAxisSize: MainAxisSize.min, children: [...cells]);
    return Container(
      key: _palettePanelKey,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(10),
        boxShadow: const [
          BoxShadow(
            color: Colors.black38,
            blurRadius: 10,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_recentPaletteColors.isNotEmpty) ...[
            label('最近使用'),
            row([
              for (final color in _recentPaletteColors)
                _SwatchCell(
                  color: color,
                  onTap: () => _pickPaletteColor(color),
                ),
            ]),
            const SizedBox(height: 6),
          ],
          // 标准色在选项行里常驻，面板里只放主题颜色网格。
          label('主题颜色'),
          for (var i = 0; i < _paletteLightness.length; i++)
            row([
              // 首列：与明暗阶梯对应的灰阶（白 → 黑）。
              _SwatchCell(
                color: HSLColor.fromAHSL(
                  1,
                  0,
                  0,
                  _paletteLightness[i],
                ).toColor(),
                onTap: () => _pickPaletteColor(
                  HSLColor.fromAHSL(1, 0, 0, _paletteLightness[i]).toColor(),
                ),
              ),
              for (final hue in _paletteHues)
                _SwatchCell(
                  color: HSLColor.fromAHSL(
                    1,
                    hue,
                    0.72,
                    _paletteLightness[i],
                  ).toColor(),
                  onTap: () => _pickPaletteColor(
                    HSLColor.fromAHSL(
                      1,
                      hue,
                      0.72,
                      _paletteLightness[i],
                    ).toColor(),
                  ),
                ),
            ]),
        ],
      ),
    );
  }

  Widget _buildFontFamilyOverlay({required bool dockShown}) {
    final visible =
        dockShown && _fontFamilyVisible && _buildOptionsPanelContent() != null;
    if (_fontFamilyPanelVisible != visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _fontFamilyPanelVisible != visible) {
          setState(() => _fontFamilyPanelVisible = visible);
        }
      });
    }
    return Positioned(
      left: _fontFamilyPanelOffset?.dx ?? 0,
      top: _fontFamilyPanelOffset?.dy ?? 0,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 120),
          child: _buildFontFamilyPanel(),
        ),
      ),
    );
  }

  Widget _buildFontFamilyPanel() {
    // 查询系统可用字体。
    final fontFamilies = <String>['系统默认'];
    // Flutter 没有直接查询系统字体的 API，这里列出常见的中英文字体。
    final commonFonts = [
      'Noto Sans',
      'Noto Sans CJK SC',
      'Noto Serif',
      'Noto Serif CJK SC',
      'WenQuanYi Micro Hei',
      'WenQuanYi Zen Hei',
      'Source Han Sans SC',
      'Source Han Serif SC',
      'Microsoft YaHei',
      'SimSun',
      'SimHei',
      'KaiTi',
      'FangSong',
      'Arial',
      'Times New Roman',
      'Courier New',
      'Verdana',
      'Georgia',
    ];
    fontFamilies.addAll(commonFonts);

    return Container(
      key: _fontFamilyPanelKey,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(10),
        boxShadow: const [
          BoxShadow(
            color: Colors.black38,
            blurRadius: 10,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '选择字体',
              style: const TextStyle(fontSize: 11, color: Colors.white60),
            ),
          ),
          for (final font in fontFamilies)
            GestureDetector(
              onTap: () {
                setState(() {
                  textFontFamily = font == '系统默认' ? '' : font;
                  _fontFamilyVisible = false;
                });
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                margin: const EdgeInsets.symmetric(vertical: 1),
                decoration: BoxDecoration(
                  color:
                      (font == '系统默认' && textFontFamily.isEmpty) ||
                          font == textFontFamily
                      ? Colors.blue.withValues(alpha: 0.6)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  font,
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.white,
                    fontFamily: font == '系统默认' ? null : font,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 布局后测量调色板面板的位置：贴在选项行外侧一层（横向停靠在选项行
  /// 上/下方，纵向停靠在选项行左/右侧）；选项行不可见时贴停靠条。
  void _updatePalettePlacement(
    ({bool vertical, bool atStart, bool hidden, bool reserved}) placement,
  ) {
    if (!mounted) return;
    final shouldShow =
        showToolbar &&
        (!placement.hidden || _dockRevealed) &&
        _paletteVisible &&
        _buildOptionsPanelContent() != null;
    if (!shouldShow) {
      if (_palettePanelVisible) {
        setState(() => _palettePanelVisible = false);
      }
      return;
    }
    final barBox = _dockBarKey.currentContext?.findRenderObject() as RenderBox?;
    final anchorBox =
        _paletteButtonKey.currentContext?.findRenderObject() as RenderBox?;
    final panelBox =
        _palettePanelKey.currentContext?.findRenderObject() as RenderBox?;
    final optionsBox =
        _optionsPanelKey.currentContext?.findRenderObject() as RenderBox?;
    if (barBox == null ||
        anchorBox == null ||
        !barBox.attached ||
        !anchorBox.attached ||
        !barBox.hasSize) {
      return;
    }
    // 调色板按钮在选项行里，锚点框的全局坐标已含选项行偏移。
    final anchorCenter = anchorBox.localToGlobal(
      anchorBox.size.center(Offset.zero),
    );
    final barOrigin = barBox.localToGlobal(Offset.zero);
    final barSize = barBox.size;
    final panelSize =
        (panelBox != null && panelBox.attached && panelBox.hasSize)
        ? panelBox.size
        : const Size(352, 220);
    final window = MediaQuery.sizeOf(context);

    // 选项行可见时以它为基准再往外一层，否则以停靠条为基准。
    final optionsVisible =
        _optionsPanelVisible &&
        optionsBox != null &&
        optionsBox.attached &&
        optionsBox.hasSize;
    final optionsOrigin = optionsVisible
        ? optionsBox.localToGlobal(Offset.zero)
        : Offset.zero;
    final optionsSize = optionsVisible ? optionsBox.size : Size.zero;

    double left;
    double top;
    if (!placement.vertical) {
      left = (anchorCenter.dx - panelSize.width / 2).clamp(
        8.0,
        math.max(8.0, window.width - panelSize.width - 8),
      );
      if (placement.atStart) {
        // 停靠条在上：选项行在其下，调色板再往下一层。
        final base = optionsVisible
            ? optionsOrigin.dy + optionsSize.height
            : barOrigin.dy + barSize.height;
        top = base + 6;
      } else {
        // 停靠条在下：选项行在其上，调色板再往上一层。
        final base = optionsVisible ? optionsOrigin.dy : barOrigin.dy;
        top = base - panelSize.height - 6;
      }
    } else {
      top = (anchorCenter.dy - panelSize.height / 2).clamp(
        8.0,
        math.max(8.0, window.height - panelSize.height - 8),
      );
      if (placement.atStart) {
        final base = optionsVisible
            ? optionsOrigin.dx + optionsSize.width
            : barOrigin.dx + barSize.width;
        left = base + 6;
      } else {
        final base = optionsVisible ? optionsOrigin.dx : barOrigin.dx;
        left = base - panelSize.width - 6;
      }
    }

    final next = Offset(left, top);
    final changed =
        !_palettePanelVisible ||
        _palettePanelOffset == null ||
        (next - _palettePanelOffset!).distance > 0.5;
    if (changed) {
      setState(() {
        _palettePanelOffset = next;
        _palettePanelVisible = true;
      });
    }
  }

  void _updateFontFamilyPlacement(
    ({bool vertical, bool atStart, bool hidden, bool reserved}) placement,
  ) {
    if (!mounted) return;
    final shouldShow =
        showToolbar &&
        (!placement.hidden || _dockRevealed) &&
        _fontFamilyVisible &&
        _buildOptionsPanelContent() != null;
    if (!shouldShow) {
      if (_fontFamilyPanelVisible) {
        setState(() => _fontFamilyPanelVisible = false);
      }
      return;
    }
    final barBox = _dockBarKey.currentContext?.findRenderObject() as RenderBox?;
    final anchorBox =
        _fontFamilyButtonKey.currentContext?.findRenderObject() as RenderBox?;
    final panelBox =
        _fontFamilyPanelKey.currentContext?.findRenderObject() as RenderBox?;
    final optionsBox =
        _optionsPanelKey.currentContext?.findRenderObject() as RenderBox?;
    if (barBox == null ||
        anchorBox == null ||
        !barBox.attached ||
        !anchorBox.attached ||
        !barBox.hasSize) {
      return;
    }
    final anchorCenter = anchorBox.localToGlobal(
      anchorBox.size.center(Offset.zero),
    );
    final barOrigin = barBox.localToGlobal(Offset.zero);
    final barSize = barBox.size;
    final panelSize =
        (panelBox != null && panelBox.attached && panelBox.hasSize)
        ? panelBox.size
        : const Size(200, 400);
    final window = MediaQuery.sizeOf(context);

    final optionsVisible =
        _optionsPanelVisible &&
        optionsBox != null &&
        optionsBox.attached &&
        optionsBox.hasSize;
    final optionsOrigin = optionsVisible
        ? optionsBox.localToGlobal(Offset.zero)
        : Offset.zero;
    final optionsSize = optionsVisible ? optionsBox.size : Size.zero;

    double left;
    double top;
    if (!placement.vertical) {
      left = (anchorCenter.dx - panelSize.width / 2).clamp(
        8.0,
        math.max(8.0, window.width - panelSize.width - 8),
      );
      if (placement.atStart) {
        final base = optionsVisible
            ? optionsOrigin.dy + optionsSize.height
            : barOrigin.dy + barSize.height;
        top = base + 6;
      } else {
        final base = optionsVisible ? optionsOrigin.dy : barOrigin.dy;
        top = base - panelSize.height - 6;
      }
    } else {
      top = (anchorCenter.dy - panelSize.height / 2).clamp(
        8.0,
        math.max(8.0, window.height - panelSize.height - 8),
      );
      if (placement.atStart) {
        final base = optionsVisible
            ? optionsOrigin.dx + optionsSize.width
            : barOrigin.dx + barSize.width;
        left = base + 6;
      } else {
        final base = optionsVisible ? optionsOrigin.dx : barOrigin.dx;
        left = base - panelSize.width - 6;
      }
    }

    final next = Offset(left, top);
    final changed =
        !_fontFamilyPanelVisible ||
        _fontFamilyPanelOffset == null ||
        (next - _fontFamilyPanelOffset!).distance > 0.5;
    if (changed) {
      setState(() {
        _fontFamilyPanelOffset = next;
        _fontFamilyPanelVisible = true;
      });
    }
  }

  Widget _optionSwatchDot(Color color) {
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

  Widget _optionPaletteButton() {
    return Tooltip(
      message: '更多颜色',
      child: GestureDetector(
        key: _paletteButtonKey,
        onTap: () => setState(() => _paletteVisible = !_paletteVisible),
        child: Container(
          width: 34,
          height: 34,
          margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: _paletteVisible
                ? Colors.blue.withValues(alpha: 0.6)
                : Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(Icons.palette, color: Colors.white70, size: 18),
        ),
      ),
    );
  }

  Widget _optionSizeSlider() {
    final vertical = _lastDockPlacement?.vertical ?? false;
    final slider = SizedBox(
      width: vertical ? 110 : 110,
      child: Slider(
        value: _activeSize.clamp(_activeSizeMin, _activeSizeMax),
        min: _activeSizeMin,
        max: _activeSizeMax,
        activeColor: Colors.blue,
        inactiveColor: Colors.white30,
        onChanged: _adjustSize,
      ),
    );
    if (vertical) {
      return RotatedBox(quarterTurns: 1, child: slider);
    }
    return slider;
  }

  Widget _optionFontSizeControl() {
    final vertical = _lastDockPlacement?.vertical ?? false;
    final fontSize = _activeSize.round();
    final children = [
      // 减小字号按钮
      Tooltip(
        message: '减小字号',
        child: GestureDetector(
          onTap: () => _adjustSize(-2),
          child: Container(
            width: 28,
            height: 28,
            margin: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Icon(Icons.remove, color: Colors.white70, size: 16),
          ),
        ),
      ),
      // 字号输入框
      SizedBox(
        width: 50,
        height: 28,
        child: TextField(
          key: ValueKey('fontSize_$fontSize'),
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          decoration: InputDecoration(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 4,
              vertical: 6,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide.none,
            ),
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.06),
          ),
          controller: TextEditingController(text: fontSize.toString()),
          onSubmitted: (value) {
            final parsed = double.tryParse(value);
            if (parsed != null &&
                parsed >= _activeSizeMin &&
                parsed <= _activeSizeMax) {
              _adjustSize(parsed);
            }
          },
          onEditingComplete: () => FocusScope.of(context).unfocus(),
        ),
      ),
      // 增大字号按钮
      Tooltip(
        message: '增大字号',
        child: GestureDetector(
          onTap: () => _adjustSize(2),
          child: Container(
            width: 28,
            height: 28,
            margin: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Icon(Icons.add, color: Colors.white70, size: 16),
          ),
        ),
      ),
    ];
    if (vertical) {
      return Column(mainAxisSize: MainAxisSize.min, children: children);
    }
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }

  Widget _optionFontFamilyButton() {
    return Tooltip(
      message: '选择字体',
      child: GestureDetector(
        key: _fontFamilyButtonKey,
        onTap: () => setState(() => _fontFamilyVisible = !_fontFamilyVisible),
        child: Container(
          width: 34,
          height: 34,
          margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: _fontFamilyVisible
                ? Colors.blue.withValues(alpha: 0.6)
                : Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(
            Icons.font_download,
            color: Colors.white70,
            size: 18,
          ),
        ),
      ),
    );
  }

  Widget _maskModeButton(MaskStyle style, String label) {
    final selected = currentMaskStyle == style;
    return Tooltip(
      message: switch (style) {
        MaskStyle.blur => '把背景糊掉',
        MaskStyle.solid => '用调色板里的固定颜色',
      },
      child: GestureDetector(
        onTap: () => setState(() => currentMaskStyle = style),
        child: Container(
          height: 34,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: selected
                ? Colors.blue.withValues(alpha: 0.6)
                : Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : Colors.white70,
              fontSize: 12,
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
      if (keyboard.isMetaPressed) 'super',
      if (keyboard.isControlPressed) 'ctrl',
      if (keyboard.isShiftPressed) 'shift',
      if (keyboard.isAltPressed) 'alt',
    ];
    // Space 的 keyLabel 是" "（一个空格），trim 后为空，必须特判。
    final label = event.logicalKey == LogicalKeyboardKey.space
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
        .map(
          (part) => part.isEmpty
              ? part
              : '${part[0].toUpperCase()}${part.substring(1)}',
        )
        .join('+');
  }

  Widget _buildShortcuts() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            '快捷键提示',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
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
          _buildShortcutRow('长截图', _prettyBinding('scrollCapture')),
          _buildShortcutRow('粗细减小', '['),
          _buildShortcutRow('粗细增大', ']'),
          const Divider(height: 12, color: Colors.white24),
          _buildShortcutRow('钉住剪贴板（全局）', 'Super+S'),
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
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  void _switchTool(ScreenshotToolType tool) {
    // 切换工具时丢弃进行中的手势：否则预览命令按新工具类型重画，
    // 松手还会落成新类型——画到一半的形状"自己变了"。
    _cancelActiveGesture();
    setState(() {
      currentTool = tool;
      showColorPicker = false;
      showSizeSlider = false;
      _paletteVisible = false;
      _fontFamilyVisible = false;
      // 一次只跟随一个按钮展开：切工具就收起设置/文件面板。
      _settingsOpen = false;
      _filePanelOpen = false;
      _modelManagerOpen = false;
      _apiConfigOpen = false;
      _selectedCommandIndex = null;
      // 离开光标模式就把文字选区清掉，别让高亮残留在画笔/形状模式下。
      _resetOcrSelectionState();
    });
    _ffi.switchTool(tool.toInt());
  }

  /// 光标模式选中对象时，颜色/粗细控件作用于该对象而不是全局工具状态。
  bool get _editingSelectedObject =>
      currentTool == ScreenshotToolType.select && _selectedCommandIndex != null;

  /// 缩放手柄的 world 尺寸：按屏幕约 10px 恒定大小换算，避免大图/缩放后
  /// 手柄小到抓不住。
  double get _resizeHandleWorldSize =>
      10.0 / (_canvasDisplayScale <= 0 ? 1.0 : _canvasDisplayScale);

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
          // 明确指定了颜色就不再是自动取色/模糊。
          maskStyle: isMask ? MaskStyle.solid : null,
        ),
      );
      return;
    }
    setState(() {
      currentColor = color;
      maskColor = color;
      showColorPicker = false;
    });
    _ffi.switchColor(
      (color.r * 255.0).round().clamp(0, 255).toInt(),
      (color.g * 255.0).round().clamp(0, 255).toInt(),
      (color.b * 255.0).round().clamp(0, 255).toInt(),
    );
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
    if (currentTool == ScreenshotToolType.eraser) return eraserSize;
    if (currentTool == ScreenshotToolType.text) return textFontSize;
    return strokeWidth;
  }

  double get _activeSizeMin {
    if (currentTool == ScreenshotToolType.eraser) return 8;
    if (currentTool == ScreenshotToolType.text) return 8;
    return 1;
  }

  double get _activeSizeMax {
    if (currentTool == ScreenshotToolType.eraser) return 80;
    if (currentTool == ScreenshotToolType.text) return 72;
    return 20;
  }

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
      } else if (currentTool == ScreenshotToolType.text) {
        textFontSize = size.clamp(_activeSizeMin, _activeSizeMax);
      } else {
        strokeWidth = size.clamp(_activeSizeMin, _activeSizeMax);
      }
      showSizeSlider = false;
    });
    _ffi.adjustSize(size);
  }

  /// `[` / `]`: eraser steps by 2 so its big range is quick to traverse.
  void _nudgeSize(int direction) {
    _adjustSize(
      _activeSize +
          direction * (currentTool == ScreenshotToolType.eraser ? 2 : 1),
    );
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
                        : Colors.black.withValues(alpha: 0.25),
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

  /// 打开本地语言包管理浮层：列出目录里的候选包，已装的给删除，没装的给下载。
  Future<void> _showModelManager() async {
    setState(() {
      _modelManagerOpen = true;
      _apiConfigOpen = false;
    });
    final service = _translateService;
    final installed = <(String, String), bool>{};
    for (final (from, to, _) in TranslateService.packCatalog) {
      installed[(from, to)] = await service.isPackInstalled(from, to);
    }
    if (mounted) setState(() => _modelInstalled = installed);
  }

  Future<void> _toggleModelPack(String from, String to) async {
    final service = _translateService;
    setState(() {
      _modelBusyPair = (from, to);
      _modelBusyMessage = '';
    });
    try {
      if (_modelInstalled[(from, to)] ?? false) {
        await service.deletePack(from, to);
      } else {
        await service.installPack(
          from,
          to,
          onStatus: (status) {
            if (mounted) setState(() => _modelBusyMessage = status);
          },
        );
      }
      if (mounted) {
        setState(() {
          _modelInstalled = {
            ..._modelInstalled,
            (from, to): !(_modelInstalled[(from, to)] ?? false),
          };
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _modelBusyMessage = '$error');
    }
    if (mounted) setState(() => _modelBusyPair = const ('', ''));
  }

  /// 模型管理浮层：锚在设置面板旁（右侧放不下就翻到左侧），随设置一起收起。
  Widget _buildModelManagerOverlay({required bool dockShown}) {
    final visible = dockShown && _settingsOpen && _modelManagerOpen;
    if (_modelManagerPanelVisible != visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _modelManagerPanelVisible != visible) {
          setState(() => _modelManagerPanelVisible = visible);
        }
      });
    }
    return Positioned(
      left: _modelManagerPanelOffset?.dx ?? 0,
      top: _modelManagerPanelOffset?.dy ?? 0,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 120),
          child: _buildModelManagerPanel(),
        ),
      ),
    );
  }

  void _updateModelManagerPlacement(
    ({bool vertical, bool atStart, bool hidden, bool reserved}) placement,
  ) {
    if (!mounted) return;
    final shouldShow =
        showToolbar &&
        (!placement.hidden || _dockRevealed) &&
        _settingsOpen &&
        _modelManagerOpen;
    if (!shouldShow) {
      if (_modelManagerPanelVisible) {
        setState(() => _modelManagerPanelVisible = false);
      }
      return;
    }
    final settingsBox =
        _settingsPanelKey.currentContext?.findRenderObject() as RenderBox?;
    final panelBox =
        _modelManagerPanelKey.currentContext?.findRenderObject() as RenderBox?;
    if (settingsBox == null || !settingsBox.attached || !settingsBox.hasSize) {
      return;
    }
    final origin = settingsBox.localToGlobal(Offset.zero);
    final panelSize =
        (panelBox != null && panelBox.attached && panelBox.hasSize)
        ? panelBox.size
        : const Size(340, 420);
    final window = MediaQuery.sizeOf(context);
    var left = origin.dx + settingsBox.size.width + 6;
    if (left + panelSize.width > window.width - 8) {
      left = origin.dx - panelSize.width - 6;
    }
    left = left
        .clamp(8.0, math.max(8.0, window.width - panelSize.width - 8))
        .toDouble();
    final top = origin.dy
        .clamp(8.0, math.max(8.0, window.height - panelSize.height - 8))
        .toDouble();
    final next = Offset(left, top);
    final changed =
        !_modelManagerPanelVisible ||
        _modelManagerPanelOffset == null ||
        (next - _modelManagerPanelOffset!).distance > 0.5;
    if (changed) {
      setState(() {
        _modelManagerPanelOffset = next;
        _modelManagerPanelVisible = true;
      });
    }
  }

  Widget _buildModelManagerPanel() {
    return Theme(
      data: ThemeData.dark(useMaterial3: true),
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: Colors.white),
        child: Container(
          key: _modelManagerPanelKey,
          width: 340,
          constraints: const BoxConstraints(maxHeight: 460),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.82),
            borderRadius: BorderRadius.circular(12),
            boxShadow: const [
              BoxShadow(
                color: Colors.black38,
                blurRadius: 10,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 10, 6),
                child: Row(
                  children: [
                    const Text(
                      '本地翻译模型',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Tooltip(
                      message: '关闭',
                      child: GestureDetector(
                        onTap: () => setState(() => _modelManagerOpen = false),
                        child: const Icon(
                          Icons.close,
                          size: 18,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_modelBusyPair != const ('', ''))
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 12, 6),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _modelBusyMessage,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final (from, to, label)
                          in TranslateService.packCatalog)
                        ListTile(
                          dense: true,
                          visualDensity: VisualDensity.compact,
                          title: Text(
                            label,
                            style: const TextStyle(fontSize: 13),
                          ),
                          trailing: _modelBusyPair == (from, to)
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : TextButton(
                                  onPressed: () => _toggleModelPack(from, to),
                                  child: Text(
                                    (_modelInstalled[(from, to)] ?? false)
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
      ),
    );
  }

  /// 翻译页里「在线翻译」的当前接口摘要：最近一次改动即本次持久化后的
  /// 配置，点「配置」按钮进三级面板微调。
  String _apiTypeLabel(String type) => switch (type) {
    'openai' => 'OpenAI 兼容',
    'baidu' => '百度翻译',
    'deepl' => 'DeepL',
    'libre' => 'LibreTranslate',
    _ => type,
  };

  Widget _apiConfigSummary() {
    final details = <String>[
      _apiTypeLabel(_settings.apiType),
      if (_settings.apiEndpoint.trim().isNotEmpty) _settings.apiEndpoint.trim(),
      if (_settings.apiModel.trim().isNotEmpty) _settings.apiModel.trim(),
      if (_settings.apiType == 'baidu' && _settings.apiAppId.trim().isNotEmpty)
        'APP ID ${_settings.apiAppId.trim()}',
      _settings.apiKey.trim().isNotEmpty ? '密钥已填' : '密钥未填',
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '当前接口：${details.join(' · ')}',
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
          if (_apiTestResult.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '上次测试：$_apiTestResult',
                style: const TextStyle(fontSize: 12),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _runApiTest() async {
    if (_apiTesting) return;
    setState(() {
      _apiTesting = true;
      _apiTestResult = '正在测试…';
    });
    final sw = Stopwatch()..start();
    try {
      final result = await _translateService.translateViaApi(
        texts: const ['Hello, world'],
        target: _resolveTranslateTarget(),
        apiType: _settings.apiType,
        endpoint: _settings.apiEndpoint,
        apiKey: _settings.apiKey,
        model: _settings.apiModel,
        apiAppId: _settings.apiAppId,
      );
      setState(() {
        _apiTesting = false;
        _apiTestResult =
            '可用（${sw.elapsedMilliseconds}ms）：'
            'Hello, world → ${result.first}';
      });
    } on Object catch (error) {
      setState(() {
        _apiTesting = false;
        _apiTestResult = _describeApiError(error);
      });
    }
  }

  /// 在线翻译 API 配置的三级浮层：锚在设置面板旁，样式与模型管理一致。
  Widget _buildApiConfigOverlay({required bool dockShown}) {
    final visible =
        dockShown &&
        _settingsOpen &&
        _apiConfigOpen &&
        _settings.translateBackend == 'api';
    if (_apiConfigPanelVisible != visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _apiConfigPanelVisible != visible) {
          setState(() => _apiConfigPanelVisible = visible);
        }
      });
    }
    return Positioned(
      left: _apiConfigPanelOffset?.dx ?? 0,
      top: _apiConfigPanelOffset?.dy ?? 0,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 120),
          child: _buildApiConfigPanel(),
        ),
      ),
    );
  }

  void _updateApiConfigPlacement(
    ({bool vertical, bool atStart, bool hidden, bool reserved}) placement,
  ) {
    if (!mounted) return;
    final shouldShow =
        showToolbar &&
        (!placement.hidden || _dockRevealed) &&
        _settingsOpen &&
        _apiConfigOpen &&
        _settings.translateBackend == 'api';
    if (!shouldShow) {
      if (_apiConfigPanelVisible) {
        setState(() => _apiConfigPanelVisible = false);
      }
      return;
    }
    final settingsBox =
        _settingsPanelKey.currentContext?.findRenderObject() as RenderBox?;
    final panelBox =
        _apiConfigPanelKey.currentContext?.findRenderObject() as RenderBox?;
    if (settingsBox == null || !settingsBox.attached || !settingsBox.hasSize) {
      return;
    }
    final origin = settingsBox.localToGlobal(Offset.zero);
    final panelSize =
        (panelBox != null && panelBox.attached && panelBox.hasSize)
        ? panelBox.size
        : const Size(380, 460);
    final window = MediaQuery.sizeOf(context);
    var left = origin.dx + settingsBox.size.width + 6;
    if (left + panelSize.width > window.width - 8) {
      left = origin.dx - panelSize.width - 6;
    }
    left = left
        .clamp(8.0, math.max(8.0, window.width - panelSize.width - 8))
        .toDouble();
    final top = origin.dy
        .clamp(8.0, math.max(8.0, window.height - panelSize.height - 8))
        .toDouble();
    final next = Offset(left, top);
    final changed =
        !_apiConfigPanelVisible ||
        _apiConfigPanelOffset == null ||
        (next - _apiConfigPanelOffset!).distance > 0.5;
    if (changed) {
      setState(() {
        _apiConfigPanelOffset = next;
        _apiConfigPanelVisible = true;
      });
    }
  }

  Widget _buildApiConfigPanel() {
    return Theme(
      data: ThemeData.dark(useMaterial3: true),
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: Colors.white),
        child: Container(
          key: _apiConfigPanelKey,
          width: 380,
          constraints: const BoxConstraints(maxHeight: 460),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.82),
            borderRadius: BorderRadius.circular(12),
            boxShadow: const [
              BoxShadow(
                color: Colors.black38,
                blurRadius: 10,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    '翻译 API 配置',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  Tooltip(
                    message: '关闭',
                    child: GestureDetector(
                      onTap: () => setState(() => _apiConfigOpen = false),
                      child: const Icon(
                        Icons.close,
                        size: 18,
                        color: Colors.white70,
                      ),
                    ),
                  ),
                ],
              ),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _settingsGroup(
                        '翻译协议',
                        _settings.apiType,
                        const [
                          ('openai', 'OpenAI 兼容（DeepSeek / OpenAI / Ollama…）'),
                          ('baidu', '百度翻译'),
                          ('deepl', 'DeepL'),
                          ('libre', 'LibreTranslate'),
                        ],
                        (value) =>
                            _applySettings(_settings.copyWith(apiType: value)),
                      ),
                      if (_settings.apiType == 'openai') ...[
                        _settingsApiField(
                          'API 地址',
                          _settings.apiEndpoint,
                          'https://api.deepseek.com',
                          (value) => _applySettings(
                            _settings.copyWith(apiEndpoint: value),
                          ),
                        ),
                        _settingsApiField(
                          'API 密钥',
                          _settings.apiKey,
                          'sk-…',
                          (value) =>
                              _applySettings(_settings.copyWith(apiKey: value)),
                          obscure: true,
                        ),
                        _settingsApiField(
                          '模型名',
                          _settings.apiModel,
                          'deepseek-chat',
                          (value) => _applySettings(
                            _settings.copyWith(apiModel: value),
                          ),
                        ),
                        // 模型名写错是最常见的「调了没反应」，按厂商给几个
                        // 可直接点的预设，省得手抄。
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              for (final preset in _modelPresets(
                                _settings.apiEndpoint,
                              ))
                                ActionChip(
                                  visualDensity: VisualDensity.compact,
                                  label: Text(
                                    preset,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                  onPressed: () => _applySettings(
                                    _settings.copyWith(apiModel: preset),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ] else if (_settings.apiType == 'baidu') ...[
                        _settingsApiField(
                          'APP ID',
                          _settings.apiAppId,
                          '在 fanyi-api.baidu.com 免费申请',
                          (value) => _applySettings(
                            _settings.copyWith(apiAppId: value),
                          ),
                        ),
                        _settingsApiField(
                          '密钥',
                          _settings.apiKey,
                          '与 APP ID 配对',
                          (value) =>
                              _applySettings(_settings.copyWith(apiKey: value)),
                          obscure: true,
                        ),
                      ] else if (_settings.apiType == 'deepl')
                        _settingsApiField(
                          '密钥',
                          _settings.apiKey,
                          '…:fx 结尾为免费版',
                          (value) =>
                              _applySettings(_settings.copyWith(apiKey: value)),
                          obscure: true,
                        )
                      else ...[
                        _settingsApiField(
                          'API 地址',
                          _settings.apiEndpoint,
                          'https://libretranslate.example.com',
                          (value) => _applySettings(
                            _settings.copyWith(apiEndpoint: value),
                          ),
                        ),
                        _settingsApiField(
                          'API 密钥',
                          _settings.apiKey,
                          '可留空',
                          (value) =>
                              _applySettings(_settings.copyWith(apiKey: value)),
                          obscure: true,
                        ),
                      ],
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: OutlinedButton(
                          onPressed: _apiTesting ? null : _runApiTest,
                          child: Text(_apiTesting ? '测试中…' : '测试连接'),
                        ),
                      ),
                      if (_apiTestResult.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            _apiTestResult,
                            style: const TextStyle(fontSize: 12),
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static const _shortcutActions = <(String, String)>[
    ('dock', '显示/隐藏工具栏'),
    ('scrollCapture', '长截图'),
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

  /// 设置面板：锚在停靠条的设置按钮旁（常规/快捷键/翻译/识字分页），
  /// 配色与工具栏一致；全部改动即时生效并持久化。
  bool _settingsOpen = false;
  final GlobalKey _dockSettingsKey = GlobalKey();
  final GlobalKey _settingsPanelKey = GlobalKey();
  Offset? _settingsPanelOffset;
  bool _settingsPanelVisible = false;

  bool _filePanelOpen = false;
  bool _filePanelSave = false;
  final GlobalKey _dockFileOpenKey = GlobalKey();
  final GlobalKey _dockFileSaveKey = GlobalKey();
  final GlobalKey _filePanelKey = GlobalKey();
  Offset? _filePanelOffset;
  bool _filePanelVisible = false;
  Uint8List? _filePanelPendingBytes;

  /// 本地翻译模型管理：贴着设置面板弹出的三级浮层。
  bool _modelManagerOpen = false;
  final GlobalKey _modelManagerPanelKey = GlobalKey();
  Offset? _modelManagerPanelOffset;
  bool _modelManagerPanelVisible = false;
  Map<(String, String), bool> _modelInstalled = const {};
  (String, String) _modelBusyPair = const ('', '');
  String _modelBusyMessage = '';

  /// 翻译配色里正在展开主题色网格的行（''=都收起，'mask'/'text'=对应行）。
  String _settingsColorGridOpen = '';

  /// 在线翻译 API 配置：与本地模型管理同款式，贴着设置面板弹出的三级浮层。
  bool _apiConfigOpen = false;
  final GlobalKey _apiConfigPanelKey = GlobalKey();
  Offset? _apiConfigPanelOffset;
  bool _apiConfigPanelVisible = false;

  /// 画布缩放（Alt+滚轮）：1.0 = 刚进编辑器的 contain 尺寸，只能放大；
  /// 普通滚轮在放大后平移画面。换图时复位。
  double _canvasZoom = 1.0;
  Offset _canvasPan = Offset.zero;

  /// 调色板三级面板：锚在选项行的调色板按钮上，不再用弹窗。
  bool _paletteVisible = false;
  final GlobalKey _paletteButtonKey = GlobalKey();
  final GlobalKey _palettePanelKey = GlobalKey();
  Offset? _palettePanelOffset;
  bool _palettePanelVisible = false;

  /// 字体选择三级面板。
  bool _fontFamilyVisible = false;
  final GlobalKey _fontFamilyButtonKey = GlobalKey();
  final GlobalKey _fontFamilyPanelKey = GlobalKey();
  Offset? _fontFamilyPanelOffset;
  bool _fontFamilyPanelVisible = false;

  /// 会话内最近使用的调色板颜色（新选中的排最前）。
  final List<Color> _recentPaletteColors = <Color>[];

  /// 主题网格的色相列（首列灰阶不算）。
  static const _paletteHues = <double>[
    0,
    25,
    45,
    90,
    140,
    170,
    200,
    230,
    270,
    310,
  ];

  /// 明暗阶梯：上浅下深，第 4 行接近标准浓度。
  static const _paletteLightness = <double>[0.90, 0.78, 0.64, 0.50, 0.36, 0.22];
  String _settingsTab = 'general';
  String _settingsCapturingAction = '';
  final FocusNode _settingsCaptureFocus = FocusNode();

  /// API 连通性测试状态（翻译页）。
  bool _apiTesting = false;
  String _apiTestResult = '';

  /// 识字模型的安装状态缓存（进设置时刷新）与下载进度。
  Map<String, bool> _ocrInstalled = const {};
  String _ocrBusyKey = '';
  String _ocrBusyMessage = '';

  /// 设置面板浮层：随停靠条位置锚在设置按钮旁（横向停靠时在条的上/下
  /// 方，纵向停靠时在条的左/右侧），打开/关闭带淡入淡出。
  Widget _buildSettingsPanelOverlay({required bool dockShown}) {
    final visible = dockShown && _settingsOpen;
    if (_settingsPanelVisible != visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _settingsPanelVisible != visible) {
          setState(() => _settingsPanelVisible = visible);
        }
      });
    }
    return Positioned(
      left: _settingsPanelOffset?.dx ?? 0,
      top: _settingsPanelOffset?.dy ?? 0,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 120),
          child: _buildSettingsPanel(),
        ),
      ),
    );
  }

  /// 布局后把设置面板摆到设置按钮旁边，必要时夹回窗口内。
  void _updateSettingsPanelPlacement(
    ({bool vertical, bool atStart, bool hidden, bool reserved}) placement,
  ) {
    if (!mounted) return;
    final shouldShow =
        showToolbar && (!placement.hidden || _dockRevealed) && _settingsOpen;
    if (!shouldShow) {
      if (_settingsPanelVisible) {
        setState(() => _settingsPanelVisible = false);
      }
      return;
    }
    final barBox = _dockBarKey.currentContext?.findRenderObject() as RenderBox?;
    final anchorBox =
        _dockSettingsKey.currentContext?.findRenderObject() as RenderBox?;
    final panelBox =
        _settingsPanelKey.currentContext?.findRenderObject() as RenderBox?;
    if (barBox == null ||
        anchorBox == null ||
        !barBox.attached ||
        !anchorBox.attached ||
        !barBox.hasSize) {
      return;
    }
    final anchorCenter = anchorBox.localToGlobal(
      anchorBox.size.center(Offset.zero),
    );
    final barOrigin = barBox.localToGlobal(Offset.zero);
    final barSize = barBox.size;
    final panelSize =
        (panelBox != null && panelBox.attached && panelBox.hasSize)
        ? panelBox.size
        : const Size(380, 520);
    final window = MediaQuery.sizeOf(context);

    double left;
    double top;
    if (!placement.vertical) {
      left = (anchorCenter.dx - panelSize.width / 2).clamp(
        8.0,
        math.max(8.0, window.width - panelSize.width - 8),
      );
      if (placement.atStart) {
        top = barOrigin.dy + barSize.height + 6;
      } else {
        top = barOrigin.dy - panelSize.height - 6;
      }
      top = top.clamp(8.0, math.max(8.0, window.height - panelSize.height - 8));
    } else {
      top = (anchorCenter.dy - panelSize.height / 2).clamp(
        8.0,
        math.max(8.0, window.height - panelSize.height - 8),
      );
      if (placement.atStart) {
        left = barOrigin.dx + barSize.width + 6;
      } else {
        left = barOrigin.dx - panelSize.width - 6;
      }
      left = left.clamp(8.0, math.max(8.0, window.width - panelSize.width - 8));
    }

    final next = Offset(left, top);
    final changed =
        !_settingsPanelVisible ||
        _settingsPanelOffset == null ||
        (next - _settingsPanelOffset!).distance > 0.5;
    if (changed) {
      setState(() {
        _settingsPanelOffset = next;
        _settingsPanelVisible = true;
      });
    }
  }

  /// 打开文件面板（打开模式）。
  void _openFilePanel() {
    setState(() {
      _filePanelSave = false;
      _filePanelPendingBytes = null;
      _filePanelOpen = true;
      _settingsOpen = false;
      _modelManagerOpen = false;
      _apiConfigOpen = false;
    });
  }

  /// 打开文件面板（保存模式）：先渲染画布再展开面板。
  Future<void> _saveFilePanel() async {
    final png = await _renderCanvas();
    if (png == null || !mounted) return;
    setState(() {
      _filePanelSave = true;
      _filePanelPendingBytes = png;
      _filePanelOpen = true;
      _settingsOpen = false;
      _modelManagerOpen = false;
      _apiConfigOpen = false;
    });
  }

  /// 文件面板确认路径后的回调。
  Future<void> _onFilePanelSelected(String path) async {
    setState(() => _filePanelOpen = false);
    if (_filePanelSave) {
      final bytes = _filePanelPendingBytes;
      if (bytes == null) return;
      await File(path).writeAsBytes(bytes);
      _ffi.save();
      _showMessage('已保存：$path');
    } else {
      final bytes = await File(path).readAsBytes();
      if (!mounted) return;
      setState(() {
        _currentImageBytes = bytes;
        _imageWidget = _buildImageWidget();
        _frozenBackdrop = _buildFrozenBackdrop();
        history.clear();
        currentStep = -1;
        selectionRect = null;
        _ocrBlocks = const [];
        _hasTextSelection = false;
        _ocrGeneration++;
      });
      _invalidateCommands();
      await _decodeCapturedImage(bytes);
    }
  }

  /// 文件面板浮层：锚在打开/保存按钮旁，与设置面板风格一致。
  Widget _buildFilePanelOverlay({required bool dockShown}) {
    final visible = dockShown && _filePanelOpen;
    if (_filePanelVisible != visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _filePanelVisible != visible) {
          setState(() => _filePanelVisible = visible);
        }
      });
    }
    return Positioned(
      left: _filePanelOffset?.dx ?? 0,
      top: _filePanelOffset?.dy ?? 0,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 120),
          child: _buildFilePanel(),
        ),
      ),
    );
  }

  Widget _buildFilePanel() {
    final home = Platform.environment['HOME'] ?? '/';
    return Theme(
      data: ThemeData.dark(useMaterial3: true),
      child: Container(
        key: _filePanelKey,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(12),
          boxShadow: const [
            BoxShadow(
              color: Colors.black38,
              blurRadius: 10,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: PathChooserPanel(
          title: _filePanelSave ? '保存截图' : '打开图片',
          save: _filePanelSave,
          initialDirectory: _filePanelSave
              ? '$home/Pictures/Screenshots'
              : '$home/Pictures',
          initialFileName: _filePanelSave ? 'Screenshot.png' : '',
          patterns: _filePanelSave
              ? const ['.png']
              : const ['.png', '.jpg', '.jpeg', '.webp'],
          onSelected: _onFilePanelSelected,
          onCancel: () => setState(() => _filePanelOpen = false),
        ),
      ),
    );
  }

  /// 布局后把文件面板摆到对应按钮旁边。
  void _updateFilePanelPlacement(
    ({bool vertical, bool atStart, bool hidden, bool reserved}) placement,
  ) {
    if (!mounted) return;
    final shouldShow =
        showToolbar && (!placement.hidden || _dockRevealed) && _filePanelOpen;
    if (!shouldShow) {
      if (_filePanelVisible) {
        setState(() => _filePanelVisible = false);
      }
      return;
    }
    final barBox = _dockBarKey.currentContext?.findRenderObject() as RenderBox?;
    final anchorKey = _filePanelSave ? _dockFileSaveKey : _dockFileOpenKey;
    final anchorBox =
        anchorKey.currentContext?.findRenderObject() as RenderBox?;
    final panelBox =
        _filePanelKey.currentContext?.findRenderObject() as RenderBox?;
    if (barBox == null ||
        anchorBox == null ||
        !barBox.attached ||
        !anchorBox.attached ||
        !barBox.hasSize) {
      return;
    }
    final anchorCenter = anchorBox.localToGlobal(
      anchorBox.size.center(Offset.zero),
    );
    final barOrigin = barBox.localToGlobal(Offset.zero);
    final barSize = barBox.size;
    final panelSize =
        (panelBox != null && panelBox.attached && panelBox.hasSize)
        ? panelBox.size
        : const Size(480, 400);
    final window = MediaQuery.sizeOf(context);

    double left;
    double top;
    if (!placement.vertical) {
      left = (anchorCenter.dx - panelSize.width / 2).clamp(
        8.0,
        math.max(8.0, window.width - panelSize.width - 8),
      );
      if (placement.atStart) {
        top = barOrigin.dy + barSize.height + 6;
      } else {
        top = barOrigin.dy - panelSize.height - 6;
      }
      top = top.clamp(8.0, math.max(8.0, window.height - panelSize.height - 8));
    } else {
      top = (anchorCenter.dy - panelSize.height / 2).clamp(
        8.0,
        math.max(8.0, window.height - panelSize.height - 8),
      );
      if (placement.atStart) {
        left = barOrigin.dx + barSize.width + 6;
      } else {
        left = barOrigin.dx - panelSize.width - 6;
      }
      left = left.clamp(8.0, math.max(8.0, window.width - panelSize.width - 8));
    }

    final next = Offset(left, top);
    final changed =
        !_filePanelVisible ||
        _filePanelOffset == null ||
        (next - _filePanelOffset!).distance > 0.5;
    if (changed) {
      setState(() {
        _filePanelOffset = next;
        _filePanelVisible = true;
      });
    }
  }

  Future<void> _openSettings() async {
    setState(() {
      _settingsOpen = true;
      _settingsTab = 'general';
      _paletteVisible = false;
      _fontFamilyVisible = false;
      _filePanelOpen = false;
      _modelManagerOpen = false;
      _apiConfigOpen = false;
      _settingsColorGridOpen = '';
    });
    unawaited(_refreshOcrInstalled());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _settingsCaptureFocus.requestFocus();
    });
  }

  void _applySettings(ScreenshotSettings next) {
    setState(() => _settings = next);
    next.save();
  }

  Future<void> _refreshOcrInstalled() async {
    final installed = <String, bool>{};
    for (final (key, _, _) in TranslateService.ocrModelCatalog) {
      installed[key] = await _translateService.isOcrModelInstalled(key);
    }
    if (mounted) setState(() => _ocrInstalled = installed);
  }

  /// 设置面板的按键：捕获快捷键绑定；Esc 先取消捕获、再关面板。
  KeyEventResult _settingsKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final capturing = _settingsCapturingAction.isNotEmpty;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (capturing) {
        setState(() => _settingsCapturingAction = '');
      } else {
        setState(() {
          _settingsOpen = false;
          _modelManagerOpen = false;
          _apiConfigOpen = false;
        });
      }
      return KeyEventResult.handled;
    }
    if (!capturing || _modifierKeys.contains(event.logicalKey)) {
      return KeyEventResult.ignored;
    }
    final binding = _bindingOfEvent(event);
    if (binding.isEmpty) return KeyEventResult.ignored;
    final next = Map<String, String>.from(_settings.shortcuts);
    next.updateAll(
      (action, value) =>
          value == binding && action != _settingsCapturingAction ? '' : value,
    );
    next[_settingsCapturingAction] = binding;
    _applySettings(_settings.copyWith(shortcuts: next));
    setState(() => _settingsCapturingAction = '');
    return KeyEventResult.handled;
  }

  Widget _buildSettingsPanel() {
    const tabs = [
      ('general', '常规'),
      ('keys', '快捷键'),
      ('translate', '翻译'),
      ('ocr', '识字'),
    ];
    final content = switch (_settingsTab) {
      'keys' => _buildSettingsKeysTab(),
      'translate' => _buildSettingsTranslateTab(),
      'ocr' => _buildSettingsOcrTab(),
      _ => _buildSettingsGeneralTab(),
    };
    // 面板底色与工具栏一致；套暗色 Theme 让开关/单选/输入框可读。编辑器
    // 外层是浅色 MaterialApp，光靠 Theme 改不掉 Text 的 DefaultTextStyle
    // （分组标题、色板标签等无显式颜色的文字会继承浅色主题的深色，落在黑
    // 底面板上几乎看不见），所以再显式压一层浅色 DefaultTextStyle。
    return Theme(
      data: ThemeData.dark(useMaterial3: true),
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: Colors.white),
        child: Focus(
          focusNode: _settingsCaptureFocus,
          onKeyEvent: _settingsKeyEvent,
          child: Container(
            key: _settingsPanelKey,
            width: 380,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.82),
              borderRadius: BorderRadius.circular(12),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black38,
                  blurRadius: 10,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
                    child: content,
                  ),
                ),
                const Divider(height: 10, color: Colors.white24),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                  child: Row(
                    children: [
                      for (final (key, label) in tabs)
                        _settingsTabButton(key, label),
                      const Spacer(),
                      Tooltip(
                        message: '关闭设置',
                        child: GestureDetector(
                          onTap: () => setState(() {
                            _settingsOpen = false;
                            _modelManagerOpen = false;
                            _apiConfigOpen = false;
                          }),
                          child: const Icon(
                            Icons.close,
                            size: 18,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _settingsTabButton(String key, String label) {
    final selected = _settingsTab == key;
    return GestureDetector(
      onTap: () => setState(() {
        _settingsTab = key;
        // 模型管理/API 配置/配色网格是翻译页的三级浮层，离开翻译页即收起。
        _modelManagerOpen = false;
        _apiConfigOpen = false;
        _settingsColorGridOpen = '';
      }),
      child: Container(
        height: 30,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        margin: const EdgeInsets.only(right: 6),
        decoration: BoxDecoration(
          color: selected
              ? Colors.blue.withValues(alpha: 0.6)
              : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: selected ? Colors.white : Colors.white70,
          ),
        ),
      ),
    );
  }

  Widget _buildSettingsGeneralTab() {
    return _settingsGroup('工具栏位置', _settings.dockPosition, const [
      ('auto', '自动（空间不足时给工具栏预留位置）'),
      ('left', '左侧'),
      ('right', '右侧'),
      ('top', '顶部'),
      ('bottom', '底部'),
    ], (value) => _applySettings(_settings.copyWith(dockPosition: value)));
  }

  Widget _buildSettingsKeysTab() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 2),
          child: Text(
            '快捷键（点击修改，按 Esc 取消捕获）',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        for (final (action, label) in _shortcutActions)
          _settingsShortcutRow(action, label),
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text(
            '固定键：Enter 保存 · Ctrl+C 仅复制 · Esc 复制并关闭 · '
            'Super+S 钉住剪贴板（系统快捷键里改）',
            style: TextStyle(fontSize: 12, color: Colors.white60),
          ),
        ),
      ],
    );
  }

  Widget _buildSettingsTranslateTab() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _settingsGroup(
          '翻译接口',
          _settings.translateBackend,
          const [('api', '在线翻译 API'), ('local', '本地模型')],
          (value) {
            // 只展开当前方式对应的三级浮层，另一侧的一起收起。
            if (value == 'local') _apiConfigOpen = false;
            if (value == 'api') _modelManagerOpen = false;
            return _applySettings(_settings.copyWith(translateBackend: value));
          },
        ),
        if (_settings.translateBackend == 'api') ...[
          _apiConfigSummary(),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton(
              onPressed: () => setState(() => _apiConfigOpen = true),
              child: const Text('配置在线翻译 API'),
            ),
          ),
        ],
        if (_settings.translateBackend == 'local')
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: OutlinedButton(
              onPressed: _showModelManager,
              child: const Text('管理本地翻译模型（下载/删除）'),
            ),
          ),
        _settingsGroup(
          '翻译为',
          _settings.translateTarget,
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
          (value) => _applySettings(_settings.copyWith(translateTarget: value)),
        ),
        _settingsGroup(
          '蒙版模式',
          _settings.translateMaskMode,
          const [('blur', '模糊背景'), ('solid', '固定颜色')],
          (value) =>
              _applySettings(_settings.copyWith(translateMaskMode: value)),
        ),
        if (_settings.translateMaskMode == 'solid')
          colorRow(
            '蒙版颜色',
            _settings.translateMaskColor,
            (value) =>
                _applySettings(_settings.copyWith(translateMaskColor: value)),
            gridKey: 'mask',
            indent: true,
          ),
        _settingsGroup(
          '文字颜色模式',
          _settings.translateTextColorMode,
          const [('auto', '提取图片里的文字颜色'), ('fixed', '固定颜色')],
          (value) =>
              _applySettings(_settings.copyWith(translateTextColorMode: value)),
        ),
        if (_settings.translateTextColorMode == 'fixed')
          colorRow(
            '文字颜色',
            _settings.translateTextColor,
            (value) =>
                _applySettings(_settings.copyWith(translateTextColor: value)),
            gridKey: 'text',
            indent: true,
          ),
      ],
    );
  }

  Widget _buildSettingsOcrTab() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 4),
          child: Text(
            '识字模型（截图取字与翻译共用，CPU 推理）',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        RadioGroup<String>(
          groupValue: _settings.ocrModel,
          onChanged: (next) {
            if (next != null) {
              _applySettings(_settings.copyWith(ocrModel: next));
            }
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (key, label, note) in TranslateService.ocrModelCatalog)
                RadioListTile<String>(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  contentPadding: EdgeInsets.zero,
                  title: Text(label, style: const TextStyle(fontSize: 13)),
                  subtitle: Text(
                    key == 'builtin'
                        ? note
                        : '$note · ${_ocrInstalled[key] ?? false ? '已下载' : '未下载'}',
                    style: const TextStyle(fontSize: 11, color: Colors.white60),
                  ),
                  value: key,
                ),
            ],
          ),
        ),
        if (_ocrBusyKey.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _ocrBusyMessage,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                if (_settings.ocrModel != 'builtin')
                  OutlinedButton(
                    onPressed: () => _toggleOcrModel(_settings.ocrModel),
                    child: Text(
                      _ocrInstalled[_settings.ocrModel] ?? false
                          ? '删除模型'
                          : '下载模型',
                    ),
                  ),
              ],
            ),
          ),
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text(
            '高精度模型来自 RapidOCR 官方 ModelScope 仓库；下载完成后下一次'
            '识字/翻译即生效。服务器版在 CPU 上速度明显更慢，截图很大时建议'
            '先用移动版。',
            style: TextStyle(fontSize: 11, color: Colors.white60),
          ),
        ),
      ],
    );
  }

  Future<void> _toggleOcrModel(String key) async {
    setState(() {
      _ocrBusyKey = key;
      _ocrBusyMessage = '';
    });
    try {
      if (_ocrInstalled[key] ?? false) {
        await _translateService.deleteOcrModel(key);
      } else {
        await _translateService.installOcrModel(
          key,
          onStatus: (status) => setState(() => _ocrBusyMessage = status),
        );
      }
      await _refreshOcrInstalled();
    } on Object catch (error) {
      setState(() => _ocrBusyMessage = '$error');
    }
    if (mounted) setState(() => _ocrBusyKey = '');
  }

  Widget _settingsShortcutRow(String action, String label) {
    final capturing = _settingsCapturingAction == action;
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: EdgeInsets.zero,
      title: Text(label, style: const TextStyle(fontSize: 13)),
      trailing: capturing
          ? const Text(
              '按新按键…',
              style: TextStyle(fontSize: 12, color: Colors.blue),
            )
          : TextButton(
              onPressed: () {
                // 焦点收归捕获节点，空格等按键不会被按钮/输入框先吃掉。
                _settingsCaptureFocus.requestFocus();
                setState(() => _settingsCapturingAction = action);
              },
              child: Text(
                _prettyBinding(action),
                style: const TextStyle(fontSize: 12),
              ),
            ),
    );
  }

  Widget _settingsGroup(
    String title,
    String groupValue,
    List<(String, String)> options,
    ValueChanged<String> onChanged,
  ) {
    return RadioGroup<String>(
      groupValue: groupValue,
      onChanged: (next) {
        if (next != null) onChanged(next);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 0),
            child: Text(
              title,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          for (final (value, label) in options)
            RadioListTile<String>(
              dense: true,
              visualDensity: VisualDensity.compact,
              contentPadding: EdgeInsets.zero,
              title: Text(label, style: const TextStyle(fontSize: 13)),
              value: value,
            ),
        ],
      ),
    );
  }

  Widget _settingsApiField(
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

  /// 颜色值转 RRGGBB 十六进制（大写）。
  static String _hexFromColor(Color color) => (color.toARGB32() & 0xFFFFFF)
      .toRadixString(16)
      .padLeft(6, '0')
      .toUpperCase();

  /// 翻译配色的色板行：常用色块 + 「更多颜色」按钮，点按钮在下方内联展开
  /// 主题色网格（与工具栏调色板同一套色）。
  Widget colorRow(
    String label,
    String current,
    ValueChanged<String> onPick, {
    required String gridKey,
    bool indent = false,
  }) {
    const options = [
      ('FFFFFF', '白'),
      ('000000', '黑'),
      ('FFEB3B', '黄'),
      ('90CAF9', '蓝'),
      ('EF5350', '红'),
      ('66BB6A', '绿'),
    ];
    final gridOpen = _settingsColorGridOpen == gridKey;
    final customColor = ScreenshotSettings.colorValueFromHex(
      current,
      0xFF000000,
    );
    final isCustom = !options.any((option) => option.$1 == current);
    return Padding(
      padding: EdgeInsets.only(top: 6, left: indent ? 16 : 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
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
                      color: ScreenshotSettings.colorValueFromHex(
                        hex,
                        0xFF000000,
                      ),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: current == hex
                            ? Colors.blue
                            : Colors.black.withValues(alpha: 0.25),
                        width: current == hex ? 2.5 : 1,
                      ),
                    ),
                  ),
                ),
              // 当前颜色（可能是主题网格里选的任意色）。
              Container(
                width: 24,
                height: 24,
                margin: const EdgeInsets.only(right: 6),
                decoration: BoxDecoration(
                  color: customColor,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isCustom
                        ? Colors.blue
                        : Colors.black.withValues(alpha: 0.25),
                    width: isCustom ? 2.5 : 1,
                  ),
                ),
              ),
              GestureDetector(
                onTap: () => setState(
                  () => _settingsColorGridOpen = gridOpen ? '' : gridKey,
                ),
                child: Container(
                  width: 24,
                  height: 24,
                  margin: const EdgeInsets.only(right: 6),
                  decoration: BoxDecoration(
                    color: gridOpen
                        ? Colors.blue.withValues(alpha: 0.6)
                        : Colors.white.withValues(alpha: 0.06),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white38),
                  ),
                  child: Icon(
                    gridOpen ? Icons.expand_less : Icons.palette,
                    size: 15,
                    color: Colors.white70,
                  ),
                ),
              ),
            ],
          ),
          if (gridOpen)
            Padding(
              padding: const EdgeInsets.only(top: 6, right: 6),
              child: _settingsColorGrid(onPick),
            ),
        ],
      ),
    );
  }

  /// 设置面板里内联展开的主题色网格：最近使用 + 灰阶/色相阶梯。
  Widget _settingsColorGrid(ValueChanged<String> onPick) {
    Widget cell(Color color) => _SwatchCell(
      color: color,
      onTap: () => _pickSettingsColor(color, onPick),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_recentPaletteColors.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.only(bottom: 3),
            child: Text(
              '最近使用',
              style: TextStyle(fontSize: 11, color: Colors.white60),
            ),
          ),
          Wrap(
            children: [for (final color in _recentPaletteColors) cell(color)],
          ),
          const SizedBox(height: 4),
        ],
        const Padding(
          padding: EdgeInsets.only(bottom: 3),
          child: Text(
            '主题颜色',
            style: TextStyle(fontSize: 11, color: Colors.white60),
          ),
        ),
        for (var i = 0; i < _paletteLightness.length; i++)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              cell(HSLColor.fromAHSL(1, 0, 0, _paletteLightness[i]).toColor()),
              for (final hue in _paletteHues)
                cell(
                  HSLColor.fromAHSL(
                    1,
                    hue,
                    0.72,
                    _paletteLightness[i],
                  ).toColor(),
                ),
            ],
          ),
      ],
    );
  }

  /// 选中设置面板色网格里的颜色：记录最近使用并写回设置。
  void _pickSettingsColor(Color color, ValueChanged<String> onPick) {
    _recentPaletteColors
      ..remove(color)
      ..insert(0, color);
    if (_recentPaletteColors.length > 8) {
      _recentPaletteColors.removeRange(8, _recentPaletteColors.length);
    }
    onPick(_hexFromColor(color));
    setState(() => _settingsColorGridOpen = '');
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

  /// [recognizing] 为 true 时点亮「识字」按钮而非「翻译」按钮；两者互斥，
  /// 否则点一个另一个也跟着亮。
  void _setTranslateStatus(String status, {bool recognizing = false}) {
    if (!mounted) return;
    setState(() {
      _translateStatus = status;
      // 浮层的显示条件，务必随状态一起置位。
      _translating = !recognizing;
      _recognizing = recognizing;
    });
  }

  /// API 调用往往要等好几秒（长文本更久），光一句「调用翻译 API」看不出是
  /// 在跑还是卡死了，所以每秒把已用秒数刷进状态浮层。
  void _startApiElapsed(int blocks) {
    _apiElapsedTimer?.cancel();
    var elapsed = 0;
    _apiElapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      elapsed++;
      final label = _settings.apiModel.trim().isEmpty
          ? _settings.apiType
          : _settings.apiModel.trim();
      setState(
        () => _translateStatus =
            '调用翻译 API（$blocks 块 · $label）…'
            ' 已用 ${elapsed}s${_apiNote.isEmpty ? '' : ' · $_apiNote'}',
      );
    });
  }

  void _stopApiElapsed() {
    _apiElapsedTimer?.cancel();
    _apiElapsedTimer = null;
    _apiNote = '';
  }

  void _startRecognizeElapsed() {
    _ocrElapsedTimer?.cancel();
    _ocrSeconds = 0;
    _ocrRegions = 0;
    _ocrBaseStatus = '正在识别文字…';
    _ocrElapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _ocrSeconds++;
      _updateRecognizeStatus();
    });
  }

  void _stopRecognizeElapsed() {
    _ocrElapsedTimer?.cancel();
    _ocrElapsedTimer = null;
  }

  /// 秒表每秒刷新一次，收到 OCR 段落时也立刻刷新，避免进度只按秒跳。
  /// 翻译进行时浮层优先给翻译，后台 OCR 不抢状态。
  void _updateRecognizeStatus() {
    if (!mounted || _translating) return;
    _setTranslateStatus(
      '$_ocrBaseStatus'
      '${_ocrRegions > 0 ? ' 已找到 $_ocrRegions 段' : ''}'
      '（${_ocrSeconds}s）',
      recognizing: true,
    );
  }

  /// 按 API 地址猜厂商，给出该厂商常用的模型名，点一下就填进设置。
  static List<String> _modelPresets(String endpoint) {
    final host = Uri.tryParse(endpoint)?.host ?? '';
    if (host.endsWith('bigmodel.cn') || host.endsWith('z.ai')) {
      return const [
        'glm-4-flash',
        'glm-4.5-air',
        'glm-4.6',
        'glm-4.7',
        'glm-5',
      ];
    }
    if (host.contains('deepseek')) {
      return const ['deepseek-chat', 'deepseek-reasoner'];
    }
    if (host.contains('siliconflow')) {
      return const ['Qwen/Qwen2.5-7B-Instruct', 'THUDM/glm-4-9b-chat'];
    }
    if (host.contains('moonshot')) {
      return const ['moonshot-v1-8k', 'moonshot-v1-32k'];
    }
    if (host.contains('dashscope') || host.contains('aliyuncs')) {
      return const ['qwen-plus', 'qwen-turbo'];
    }
    if (host.contains('openai')) return const ['gpt-4o-mini'];
    return const ['gpt-4o-mini', 'deepseek-chat'];
  }

  /// 把 API/网络的失败翻译成人能看懂的原因（超时、连不上、鉴权、限流…）。
  String _describeApiError(Object error) {
    final text = error.toString();
    if (error is ApiTranslateException) {
      // 服务端给的原因（限流、余额不足、模型不存在…）比状态码有用得多。
      final detail = error.serverMessage.isNotEmpty
          ? error.serverMessage
          : error.raw;
      final hint = switch (error.statusCode) {
        401 || 403 => '密钥无效或没权限',
        429 => '请求太频繁或免费额度用尽，稍后再试或换个模型',
        404 => '接口地址或模型名不对',
        400 => '请求参数有问题，检查模型名是否正确',
        >= 500 => '对方服务暂时不可用',
        _ => '请求被拒绝',
      };
      final short = detail.length > 120
          ? '${detail.substring(0, 120)}…'
          : detail;
      return '翻译失败（HTTP ${error.statusCode}·$hint）'
          '${short.isEmpty ? '' : '：$short'}';
    }
    if (error is TimeoutException) {
      return '翻译超时：API ${_apiTimeoutSeconds}s 没有响应，检查网络或换成更快的模型';
    }
    if (error is SocketException) {
      return '连不上 API：${error.address?.host ?? _settings.apiEndpoint}'
          '（检查地址、网络或代理）';
    }
    if (error is HandshakeException) {
      return 'HTTPS 握手失败：检查地址是否是 https、证书是否有效';
    }
    if (text.contains('HTTP 401') || text.contains('HTTP 403')) {
      return 'API 鉴权失败（401/403）：密钥无效或没权限';
    }
    if (text.contains('HTTP 429')) {
      return 'API 限流（429）：稍后再试，或换额度更高的 key';
    }
    if (text.contains('HTTP 5')) {
      return 'API 服务端错误：对方服务暂时不可用，稍后再试';
    }
    if (text.contains('HTTP ')) {
      return '翻译失败：$text';
    }
    return '翻译出错：$error';
  }

  /// 打开图片后的后台 OCR：模型已装才静默跑，不弹安装向导打扰；
  /// 识别期间复用状态浮层给个轻提示，结束后文字块常驻。
  void _startBackgroundOcr() {
    final generation = ++_ocrGeneration;
    setState(() {
      _ocrBlocks = const [];
      _hasTextSelection = false;
    });
    final task = _runBackgroundOcr(generation);
    _ocrTask = task;
    task.then((regions) {
      if (!mounted || generation != _ocrGeneration) return;
      _ocrTask = null;
      _mapOcrRegions(regions);
    });
  }

  Future<List<TranslateRegion>> _runBackgroundOcr(int generation) async {
    if (!await _translateService.isReady()) return const [];
    _startRecognizeElapsed();
    try {
      final file = File(
        '${Directory.systemTemp.path}/screenshot_tool_bgocr.png',
      );
      await file.writeAsBytes(_currentImageBytes);
      await for (final event in _translateService.run(
        imagePath: file.path,
        target: _resolveTranslateTarget(),
        mode: 'ocr',
        ocrModel: _settings.ocrModel,
      )) {
        if (!mounted || generation != _ocrGeneration) return const [];
        if (event.type == 'region') {
          _ocrRegions++;
          _updateRecognizeStatus();
        }
        // done 汇总里每个块都带背景/前景色（region 事件没有），收它。
        if (event.type == 'done') return event.regions;
      }
      return const [];
    } on Object {
      return const [];
    } finally {
      _stopRecognizeElapsed();
      if (mounted && generation == _ocrGeneration) {
        setState(() => _recognizing = false);
      }
    }
  }

  /// OCR 完成：按视觉阅读顺序排序并换算到画布坐标，常驻供选中/翻译。
  void _mapOcrRegions(List<TranslateRegion> regions) {
    if (regions.isEmpty) return;
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    final decoded = _decodedImage;
    if (box == null || !box.hasSize || decoded == null) return;
    final imageRect = displayedImageRect(
      box.size,
      decoded.width.toDouble(),
      decoded.height.toDouble(),
    );
    // 图片像素坐标 → 画布坐标的缩放比。
    final scaleX = imageRect.width / decoded.width;
    final scaleY = imageRect.height / decoded.height;
    debugPrint(
      '[OCR] canvas=${box.size}, image=${decoded.width}x${decoded.height}, imageRect=$imageRect, scale=($scaleX, $scaleY)',
    );
    regions.sort((a, b) {
      final tolerance = math.min(a.rect.height, b.rect.height) * 0.5;
      if ((a.rect.top - b.rect.top).abs() > tolerance) {
        return a.rect.top.compareTo(b.rect.top);
      }
      return a.rect.left.compareTo(b.rect.left);
    });
    setState(() {
      _ocrBlocks = [
        for (final region in regions)
          (
            rect: Rect.fromLTRB(
              region.rect.left * scaleX + imageRect.left,
              region.rect.top * scaleY + imageRect.top,
              region.rect.right * scaleX + imageRect.left,
              region.rect.bottom * scaleY + imageRect.top,
            ),
            region: region,
          ),
      ];
      _resetOcrSelectionState();
    });
    if (_ocrBlocks.isNotEmpty) {
      debugPrint(
        '[OCR] first block: src=${_ocrBlocks[0].region.rect}, dst=${_ocrBlocks[0].rect}',
      );
    }
  }

  /// 常驻的 OCR 文字选择层（WPS 式跨块框选）：
  /// - 高亮由 [OcrSelectionPainter] 按选区逐块画出，矩形直接由 OCR 框和
  ///   字符比例算得，和图片里的文字一一对应；
  /// - 每块文字各自压一个透明 [GestureDetector]，指针落在哪块就从哪块起
  ///   拖；拖动更新里用全局坐标反算 (块, 字符偏移)，所以能一路跨过块间
  ///   空隙选到下一块，不像逐块原生选择那样在空隙里断掉。
  ///
  /// 只在光标模式吃指针事件（外层 IgnorePointer 控制），块外的空白仍透给
  /// 画布，选中对象/移动不受影响。
  Widget _buildTextSelectOverlay() {
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: OcrSelectionPainter(rects: _ocrSelectionRects()),
            ),
          ),
        ),
        for (var i = 0; i < _ocrBlocks.length; i++)
          Positioned.fromRect(
            rect: _ocrBlocks[i].rect,
            child: MouseRegion(
              cursor: SystemMouseCursors.text,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _clearOcrSelection,
                onPanStart: (details) =>
                    _beginOcrSelection(details.globalPosition),
                onPanUpdate: (details) =>
                    _updateOcrSelection(details.globalPosition),
                onPanEnd: (_) => _finishOcrSelection(),
                onPanCancel: _finishOcrSelection,
                child: const SizedBox.expand(),
              ),
            ),
          ),
      ],
    );
  }

  /// 全局坐标 → 画布 world 坐标。world 就是图像像素坐标系，[_canvasKey]
  /// 的重绘边界与它同尺寸、同原点，用它做逆变换即可抵消 FittedBox 与缩放。
  Offset? _ocrToWorld(Offset globalPosition) {
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.globalToLocal(globalPosition);
  }

  /// 块内字符偏移：文字被当作等宽铺满整块宽度，按 x 落在第几个字符上取整。
  int _ocrOffsetInBlock(int block, double dx) {
    final block0 = _ocrBlocks[block];
    final length = block0.region.source.length;
    if (length == 0 || block0.rect.width <= 0) return 0;
    final ratio = ((dx - block0.rect.left) / block0.rect.width).clamp(0.0, 1.0);
    return (ratio * length).round().clamp(0, length);
  }

  /// 命中检测：优先落在哪个块里；都不在时（拖到块间空隙）取最近的块，
  /// 这样选区的终点能平滑地从一个块延伸到相邻块。
  (int, int)? _ocrIndexAt(Offset globalPosition, {bool nearest = false}) {
    final world = _ocrToWorld(globalPosition);
    if (world == null) return null;
    for (var i = 0; i < _ocrBlocks.length; i++) {
      if (_ocrBlocks[i].rect.contains(world)) {
        return (i, _ocrOffsetInBlock(i, world.dx));
      }
    }
    if (!nearest) return null;
    var best = -1;
    var bestDistance = double.infinity;
    for (var i = 0; i < _ocrBlocks.length; i++) {
      final rect = _ocrBlocks[i].rect;
      final dx = world.dx < rect.left
          ? rect.left - world.dx
          : (world.dx > rect.right ? world.dx - rect.right : 0.0);
      final dy = world.dy < rect.top
          ? rect.top - world.dy
          : (world.dy > rect.bottom ? world.dy - rect.bottom : 0.0);
      final distance = dx * dx + dy * dy;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = i;
      }
    }
    if (best < 0) return null;
    return (best, _ocrOffsetInBlock(best, world.dx));
  }

  /// 规范化选区：保证 (anchorBlock, anchorOffset) <= (focusBlock, focusOffset)，
  /// 列表本身已按阅读顺序排列，直接比下标即可。
  void _beginOcrSelection(Offset globalPosition) {
    final index = _ocrIndexAt(globalPosition, nearest: true);
    if (index == null) return;
    _ocrSelecting = true;
    setState(() {
      _ocrSelAnchorBlock = index.$1;
      _ocrSelAnchorOffset = index.$2;
      _ocrSelFocusBlock = index.$1;
      _ocrSelFocusOffset = index.$2;
      _hasTextSelection = false;
    });
  }

  void _updateOcrSelection(Offset globalPosition) {
    if (!_ocrSelecting) return;
    final index = _ocrIndexAt(globalPosition, nearest: true);
    if (index == null) return;
    setState(() {
      _ocrSelFocusBlock = index.$1;
      _ocrSelFocusOffset = index.$2;
      _hasTextSelection = _ocrSelectionRange() != null;
    });
  }

  void _finishOcrSelection() {
    _ocrSelecting = false;
    setState(() => _hasTextSelection = _ocrSelectionRange() != null);
  }

  void _clearOcrSelection() {
    if (!_hasTextSelection &&
        _ocrSelAnchorBlock == null &&
        _ocrSelFocusBlock == null) {
      return;
    }
    setState(_resetOcrSelectionState);
  }

  void _resetOcrSelectionState() {
    _ocrSelAnchorBlock = null;
    _ocrSelAnchorOffset = null;
    _ocrSelFocusBlock = null;
    _ocrSelFocusOffset = null;
    _hasTextSelection = false;
  }

  /// 有序选区 (起始块, 起始偏移, 结束块, 结束偏移)；空选区或业务非法时 null。
  (int, int, int, int)? _ocrSelectionRange() {
    final anchorBlock = _ocrSelAnchorBlock;
    final focusBlock = _ocrSelFocusBlock;
    final anchorOffset = _ocrSelAnchorOffset;
    final focusOffset = _ocrSelFocusOffset;
    if (anchorBlock == null ||
        focusBlock == null ||
        anchorOffset == null ||
        focusOffset == null) {
      return null;
    }
    if (anchorBlock == focusBlock && anchorOffset == focusOffset) return null;
    final forward =
        anchorBlock < focusBlock ||
        (anchorBlock == focusBlock && anchorOffset < focusOffset);
    return forward
        ? (anchorBlock, anchorOffset, focusBlock, focusOffset)
        : (focusBlock, focusOffset, anchorBlock, anchorOffset);
  }

  /// 选区高亮矩形：起止块内按字符比例截取，中间块整块高亮。
  List<Rect> _ocrSelectionRects() {
    final range = _ocrSelectionRange();
    if (range == null) return const [];
    final (startBlock, startOffset, endBlock, endOffset) = range;
    final rects = <Rect>[];
    for (var i = startBlock; i <= endBlock; i++) {
      final block = _ocrBlocks[i];
      final length = block.region.source.length;
      if (length == 0) continue;
      final from = i == startBlock ? startOffset : 0;
      final to = i == endBlock ? endOffset : length;
      if (to <= from) continue;
      final left = block.rect.left + block.rect.width * (from / length);
      final right = block.rect.left + block.rect.width * (to / length);
      rects.add(Rect.fromLTRB(left, block.rect.top, right, block.rect.bottom));
    }
    return rects;
  }

  /// 选区文字：块内切片，跨块用换行连接（与图片里一行一段对应）。
  String _ocrSelectedText() {
    final range = _ocrSelectionRange();
    if (range == null) return '';
    final (startBlock, startOffset, endBlock, endOffset) = range;
    final parts = <String>[];
    for (var i = startBlock; i <= endBlock; i++) {
      final source = _ocrBlocks[i].region.source;
      final from = i == startBlock ? startOffset : 0;
      final to = i == endBlock ? endOffset : source.length;
      if (to > from) parts.add(source.substring(from, to));
    }
    return parts.join('\n');
  }

  Future<void> _copyOcrSelection() async {
    final text = _ocrSelectedText();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
  }

  /// 翻译：快照 → sidecar OCR+翻译 → 每个文字块生成蒙版+译文两条命令。
  /// 依赖未就绪时先弹安装向导（在线装一次，之后离线）。
  Future<void> _translate() async {
    // 后台 OCR 在跑不阻拦：_readyOcrRegions 会等它完成并复用结果。
    if (_translating) return;
    // 立刻给出可视反馈：检查组件/生成快照也要几秒，不能让用户干等。
    _setTranslateStatus('准备翻译…');
    _beginUndoGroup();
    try {
      final useApi = _settings.translateBackend == 'api';
      debugPrint(
        '[translate] backend=${_settings.translateBackend} '
        'target=${_settings.translateTarget}',
      );
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

      // 优先复用后台 OCR 的文字块：识别一次，框选和翻译共享，不再
      // 临时生成快照让 OCR 跑第二遍。没有缓存（模型后装、识别为空）
      // 才退回「快照 → sidecar」的原流程。
      final target = _resolveTranslateTarget();
      final cached = await _readyOcrRegions();
      if (cached != null) {
        await _translateFromRegions(cached, target, useApi);
        return;
      }

      _setTranslateStatus('生成快照…');
      final png = await _renderPinSnapshot();
      if (png == null) {
        _showMessage('生成快照失败，无法翻译');
        return;
      }
      final inputFile = File(
        '${Directory.systemTemp.path}/screenshot_tool_translate.png',
      );
      await inputFile.writeAsBytes(png);

      if (useApi) {
        await _translateViaApi(inputFile, target);
        return;
      }

      var translatedCount = 0;
      await for (final event in _translateService.run(
        imagePath: inputFile.path,
        target: target,
        ocrModel: _settings.ocrModel,
      )) {
        if (!mounted) return;
        switch (event.type) {
          case 'status':
            _setTranslateStatus(event.message ?? '');
          case 'region':
            if (event.region != null) {
              debugPrint(
                '[translate] region ${event.region!.source} -> '
                '${event.region!.translated}',
              );
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
      _endUndoGroup();
      if (mounted) setState(() => _translating = false);
    }
  }

  /// 等后台 OCR 就绪并取出文字块；还在跑就等一下，没有可用缓存返回
  /// null（调用方退回「快照 → sidecar」的原流程）。
  Future<List<TranslateRegion>?> _readyOcrRegions() async {
    final task = _ocrTask;
    if (task != null) {
      _setTranslateStatus('等待文字识别完成…');
      await task;
    }
    if (!mounted || _ocrBlocks.isEmpty) return null;
    return [for (final block in _ocrBlocks) block.region];
  }

  /// 复用已识别的文字块做翻译：只跑「翻译」这一步（本地语言包 texts
  /// 模式 / 在线 API 逐条翻译），不再让 OCR 跑第二遍。
  Future<void> _translateFromRegions(
    List<TranslateRegion> regions,
    String target,
    bool useApi,
  ) async {
    final texts = [for (final region in regions) region.source];
    final List<(String, bool)> results;
    if (useApi) {
      _setTranslateStatus('调用翻译 API…');
      final translations = await _translateService.translateViaApi(
        texts: texts,
        target: target,
        apiType: _settings.apiType,
        endpoint: _settings.apiEndpoint,
        apiKey: _settings.apiKey,
        model: _settings.apiModel,
        apiAppId: _settings.apiAppId,
        onRetry: _setTranslateStatus,
      );
      // API 路径不判源语言：译文与原文一致视为不需要覆盖。
      results = [
        for (var i = 0; i < translations.length; i++)
          (translations[i], translations[i].trim() == texts[i].trim()),
      ];
    } else {
      results = await _translateService.translateTextsLocal(
        texts,
        target,
        onStatus: _setTranslateStatus,
      );
    }
    var applied = 0;
    for (var i = 0; i < regions.length; i++) {
      if (results[i].$2) continue;
      _applyTranslateRegion(
        TranslateRegion(
          rect: regions[i].rect,
          source: regions[i].source,
          translated: results[i].$1,
          background: regions[i].background,
          foreground: regions[i].foreground,
        ),
      );
      applied++;
      _setTranslateStatus('已翻译 $applied 块…');
    }
    debugPrint('[translate] reused ocr: $applied/${regions.length} applied');
    _showMessage(applied > 0 ? '翻译完成：$applied 个文字块' : '没有需要翻译的文字');
  }

  /// 侧车返回的坐标基于裁剪后的显示图像，换算回画布坐标并落两条命令：
  /// 蒙版（盖住原文）+ 文字（原位显示译文），颜色取设置里的固定配色。
  void _applyTranslateRegion(TranslateRegion region) {
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    final decoded = _decodedImage;
    if (box == null || !box.hasSize || decoded == null) {
      // 以前这里是静默 return：API 调了、钱花了，画布却毫无变化。至少留个提示。
      debugPrint(
        '[translate] apply skipped: hasBox=${box?.hasSize} hasImage=${decoded != null}',
      );
      _showMessage('译文无法落回画布：画布尚未就绪，请重试');
      return;
    }
    final imageRect = displayedImageRect(
      box.size,
      decoded.width.toDouble(),
      decoded.height.toDouble(),
    );
    // 图片像素坐标 → 画布坐标的缩放比。
    final scaleX = imageRect.width / decoded.width;
    final scaleY = imageRect.height / decoded.height;
    final onCanvas = Rect.fromLTRB(
      region.rect.left * scaleX + imageRect.left,
      region.rect.top * scaleY + imageRect.top,
      region.rect.right * scaleX + imageRect.left,
      region.rect.bottom * scaleY + imageRect.top,
    );

    // 蒙版填充方式按设置：blur 模糊背景，solid 用固定颜色——都为后续
    // 译文不突兀。
    final maskMode = _settings.translateMaskMode;
    final maskFillColor = _settings.translateMaskColorValue;
    final maskStyle = maskMode == 'solid' ? MaskStyle.solid : MaskStyle.blur;

    // 文字颜色：auto = 用 sidecar 从图里测得的文字原色（前景色），
    // 与蒙版色太接近时退到黑/白，保证译文显眼。
    var textColor = _settings.translateTextColorValue;
    if (_settings.translateTextColorMode == 'auto' &&
        region.foreground.isNotEmpty) {
      textColor = _contrastSafeTextColor(
        region.foregroundColor,
        maskStyle == MaskStyle.blur ? region.backgroundColor : maskFillColor,
      );
    }

    // 蒙版略大于文字块，彻底盖住原文。
    final baseMask = onCanvas.inflate(2);
    const padding = 4.0;
    final maxTextWidth = math.max(12.0, baseMask.width - padding * 2);
    final maxTextHeight = math.max(12.0, baseMask.height - padding);

    // 先按块高估一个字号，装不下就在蒙版宽度内换行、逐级缩小；中译英这种
    // 变长的情况靠这两步消化。
    TextPainter layout(double size) => TextPainter(
      text: TextSpan(
        text: region.translated,
        style: TextStyle(fontSize: size, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxTextWidth);

    var fontSize = (onCanvas.height * 0.6).clamp(9.0, 40.0);
    var painter = layout(fontSize);
    var attempts = 0;
    while (painter.height > maxTextHeight && fontSize > 7 && attempts < 12) {
      fontSize = (fontSize * 0.86).clamp(7.0, 40.0);
      painter = layout(fontSize);
      attempts++;
    }

    // 缩到最小仍塞不下：把蒙版撑高，保证文字永远在蒙版里（不越界压到别的字）。
    var maskRect = baseMask;
    if (painter.height > maxTextHeight) {
      maskRect = Rect.fromLTWH(
        baseMask.left,
        baseMask.top,
        baseMask.width,
        painter.height + padding * 2,
      );
    }
    final fontStroke = fontSize / 4;

    setState(() {
      _pushCommand(
        DrawCommand(
          type: ScreenshotToolType.mask,
          start: maskRect.topLeft,
          end: maskRect.bottomRight,
          path: Path(),
          rect: maskRect,
          fillColor: maskFillColor,
          maskStyle: maskStyle,
        ),
      );
      _pushCommand(
        DrawCommand(
          type: ScreenshotToolType.text,
          start: onCanvas.topLeft,
          end: onCanvas.bottomRight,
          path: Path(),
          text: region.translated,
          rect: onCanvas,
          color: textColor,
          strokeWidth: fontStroke,
          textMaxWidth: maxTextWidth,
        ),
      );
    });
  }

  /// 提取的文字色与蒙版色对比不够时退到黑/白（按蒙版亮度选），
  /// 保证译文永远显眼。
  Color _contrastSafeTextColor(Color text, Color mask) {
    final dl = (text.computeLuminance() - mask.computeLuminance()).abs();
    if (dl >= 0.25) return text;
    return mask.computeLuminance() > 0.55 ? Colors.black : Colors.white;
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
            return editorDialogTheme(
              child: AlertDialog(
                backgroundColor: editorDialogBackground,
                shape: editorDialogShape,
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
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white60,
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
              ),
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
      ocrModel: _settings.ocrModel,
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
    _startApiElapsed(regions.length);
    final List<String> translated;
    try {
      translated = await _translateService.translateViaApi(
        texts: [for (final region in regions) region.source],
        target: target,
        apiType: _settings.apiType,
        endpoint: _settings.apiEndpoint,
        apiKey: _settings.apiKey,
        model: _settings.apiModel,
        apiAppId: _settings.apiAppId,
        onRetry: (note) {
          if (mounted) setState(() => _apiNote = note);
        },
      );
    } on Object catch (error) {
      _stopApiElapsed();
      _showMessage(_describeApiError(error), seconds: 5);
      setState(() => _translating = false);
      return;
    }
    _stopApiElapsed();
    var unchanged = 0;
    for (var i = 0; i < regions.length; i++) {
      final source = regions[i].source.trim();
      final result = translated[i].trim();
      if (result.isEmpty || result == source) unchanged++;
      debugPrint('[translate] "$source" -> "$result"');
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
    _showMessage(
      unchanged == regions.length
          ? '翻译完成：${regions.length} 块，但译文与原文一致'
                '（模型可能没按「1. 」编号返回，换模型或检查返回格式）'
          : '翻译完成：${regions.length} 个文字块',
    );
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
      box.size,
      decoded.width.toDouble(),
      decoded.height.toDouble(),
    );
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
    final cropped = await recorder.endRecording().toImage(
      imageRect.width.round(),
      imageRect.height.round(),
    );
    full.dispose();
    final data = await cropped.toByteData(format: ui.ImageByteFormat.png);
    cropped.dispose();
    return data?.buffer.asUint8List();
  }

  /// 长截图：把当前编辑图像在屏幕上的矩形作为连拍区域——先复位缩放，
  /// 测出 contain 布局下的屏幕矩形，关掉编辑器（不复制）后开始会话；
  /// 结束靠再按一次 Super+R 或屏幕顶部浮条。
  Future<void> _startScrollCapture() async {
    if (ScrollCaptureManager.instance.isActive) {
      await ScrollCaptureManager.instance.stop();
      return;
    }
    if (_canvasZoom != 1.0 || _canvasPan != Offset.zero) {
      setState(() {
        _canvasZoom = 1.0;
        _canvasPan = Offset.zero;
      });
      await WidgetsBinding.instance.endOfFrame;
    }
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    final decoded = _decodedImage;
    if (box == null || !box.hasSize || decoded == null || !mounted) return;
    final imageRect = displayedImageRect(
      box.size,
      decoded.width.toDouble(),
      decoded.height.toDouble(),
    );
    if (imageRect.width < 8 || imageRect.height < 8) return;
    final region = imageRect.shift(box.localToGlobal(Offset.zero));
    _closeEditor();
    await ScrollCaptureManager.instance.start(region);
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

  /// 复制按钮状态：working 沙漏、done 绿勾、failed 红叹号，除”done 且
  /// 即将关窗”外都自动回 idle——复制是异步的，按钮必须给出过程反馈。
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
    _CopyState.idle => '复制并关闭',
  };

  Color? get _copyColor => switch (_copyState) {
    _CopyState.done => Colors.green.withValues(alpha: 0.8),
    _CopyState.failed => Colors.red.withValues(alpha: 0.8),
    _ => null,
  };

  /// 更新复制按钮状态；短暂后自动回 idle，[holdUntilClose] 的 done 不回落
  /// （马上要关窗，回 idle 反而闪一下旧图标）。
  void _setCopyState(_CopyState state, {bool holdUntilClose = false}) {
    if (!mounted) return;
    setState(() => _copyState = state);
    _copyResetTimer?.cancel();
    if (holdUntilClose) return;
    _copyResetTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copyState = _CopyState.idle);
    });
  }

  /// Ctrl+C：只复制不关窗（关窗交给「复制并关闭」按钮或 Esc）。
  /// 不触发按钮动画，仅显示消息提示。
  Future<void> _copy() =>
      _copyImage(closeAfterCopy: false, updateButtonState: false);

  /// 「复制并关闭」按钮：恒定复制完就关闭，不看设置。
  Future<void> _copyAndClose() => _copyImage(closeAfterCopy: true);

  Future<void> _copyImage({
    required bool closeAfterCopy,
    bool updateButtonState = true,
  }) async {
    if (updateButtonState && _copyState == _CopyState.working) return;
    if (updateButtonState) _setCopyState(_CopyState.working);
    final png = await _renderCanvas();
    if (png == null) {
      recordClipboardNote('render returned null');
      if (updateButtonState) _setCopyState(_CopyState.failed);
      _showMessage('复制失败：画布还没渲染出来');
      return;
    }
    if (!await copyPngToClipboard(png)) {
      if (updateButtonState) _setCopyState(_CopyState.failed);
      _showMessage('复制失败，详见 $clipboardLogPath');
      return;
    }
    _ffi.copy();
    if (updateButtonState)
      _setCopyState(_CopyState.done, holdUntilClose: closeAfterCopy);
    _showMessage(closeAfterCopy ? '已复制到剪贴板，正在关闭…' : 'PNG 已复制到剪贴板', seconds: 2);
    if (closeAfterCopy) {
      // 让”已复制”的绿勾先亮一下再退出，否则点了像没反应。
      _copyResetTimer?.cancel();
      _copyResetTimer = Timer(const Duration(milliseconds: 700), () {
        if (mounted) _closeEditor();
      });
    }
  }

  Future<void> _openImage() async {
    final path = await _choosePath([
      '--file-selection',
      '--title=打开图片',
      '--file-filter=图片 | *.png *.jpg *.jpeg *.webp',
    ]);
    if (path == null) return;
    final bytes = await File(path).readAsBytes();
    setState(() {
      _currentImageBytes = bytes;
      _imageWidget = _buildImageWidget();
      _frozenBackdrop = _buildFrozenBackdrop();
      history.clear();
      currentStep = -1;
      selectionRect = null;
      // 旧图的文字块立刻失效，等后台 OCR 出新图的结果。
      _ocrBlocks = const [];
      _hasTextSelection = false;
      _ocrGeneration++;
    });
    _invalidateCommands();
    await _decodeCapturedImage(bytes);
  }

  /// 插件运行在合成器的最上层，zenity 这类外部窗口会被本层盖住，因此改用
  /// shell 内置的对话框（参数仍沿用原来的 zenity 命令行数组）。
  Future<String?> _choosePath(List<String> arguments) =>
      choosePathWithDialog(context: context, arguments: arguments);

  void _showMessage(String message, {int seconds = 3}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: Duration(seconds: seconds),
      ),
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
    final pinFile = File(
      '${Directory.systemTemp.path}/screenshot_tool_pin.png',
    );
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
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: Colors.white),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPinnedWindow() {
    // 后备卡片按快照（= 图像）比例锁定，图片铺满卡片，不留底色空边。
    return Material(
      type: MaterialType.transparency,
      child: Center(
        child: AspectRatio(
          aspectRatio: _worldSize.aspectRatio,
          child: GestureDetector(
            // Window drag: honored on X11; on Wayland the compositor's own
            // window drag moves the card and this call is ignored.
            behavior: HitTestBehavior.translucent,
            onPanUpdate: (details) =>
                _window.moveBy(details.delta.dx, details.delta.dy),
            child: Container(
              margin: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black45,
                    blurRadius: 18,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.memory(
                      _pinnedImageBytes!,
                      fit: BoxFit.fill,
                      gaplessPlayback: true,
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
                    // Replaces the old resize handle: reopen the editor (with
                    // all previous edits) and dismiss this floating card.
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
            ),
          ),
        ),
      ),
    );
  }

  /// 选中调色板里的颜色：记录最近使用并应用到当前工具。
  void _pickPaletteColor(Color color) {
    _recentPaletteColors
      ..remove(color)
      ..insert(0, color);
    if (_recentPaletteColors.length > 8) {
      _recentPaletteColors.removeRange(8, _recentPaletteColors.length);
    }
    setState(() => _paletteVisible = false);
    _switchColor(color);
  }

  void _openTextDialog(Offset position, {Rect? textBox}) {
    _editingTextIndex = null;
    _textBoxRect = textBox;
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

  /// 就地编辑已有文字（文本工具点击 / 光标模式双击）。
  void _beginTextEdit(int index) {
    if (index < 0 || index >= history.length) return;
    final command = history[index];
    if (command.type != ScreenshotToolType.text) return;
    _editingTextIndex = index;
    _textBoxRect = null;
    _textDialogPosition = command.start;
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    _textDialogWindowAnchor =
        box?.localToGlobal(command.start) ?? command.start;
    _textController.text = command.text;
    _textController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: command.text.length,
    );
    setState(() => _showTextDialog = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _textFocusNode.requestFocus();
    });
  }

  /// 确认输入（弹窗确定按钮 / 回车）：新建或改掉已有文字。
  void _confirmTextInput() {
    final value = _textController.text;
    final editing = _editingTextIndex;
    if (editing != null && editing < history.length) {
      if (value.trim().isEmpty) {
        // 清空内容等于删掉这条文字，省得留一个看不见的空命令。
        _eraseCommandAt(editing);
      } else {
        _updateTextCommand(editing, value);
      }
    } else if (value.isNotEmpty) {
      _addText(value);
      _ffi.inputText(value);
    }
    _hideTextDialog();
  }

  /// 改掉已有文字：保持原位置、原颜色、原字号，只换内容和包围框。
  /// 文本框文字换内容后框不动，字号按新内容重新自适应。
  void _updateTextCommand(int index, String text) {
    final old = history[index];
    Rect rect;
    final box = old.textBox;
    if (box != null) {
      rect = box;
    } else {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: old.color,
            fontSize: old.strokeWidth * 4,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: old.textMaxWidth);
      rect = Rect.fromLTWH(
        old.rect.left,
        old.rect.top,
        painter.width,
        painter.height,
      );
    }
    setState(() {
      _undoSnapshots.add(List<DrawCommand>.from(history));
      _redoSnapshots.clear();
      history[index] = old.copyWith(text: text, rect: rect);
      _invalidateCommands();
    });
  }

  /// 光标模式双击：命中文字就就地改字（弹窗预填原文，可直接覆盖）。
  Future<void> _onCanvasDoubleTap(Offset position) async {
    if (currentTool != ScreenshotToolType.select) return;
    final index = findManipulableCommandIndex(history, position);
    if (index == null) return;
    if (history[index].type != ScreenshotToolType.text) {
      _showMessage('这个对象不能改文字：拖动可移动，Delete 可删除');
      return;
    }
    _beginTextEdit(index);
  }

  void _hideTextDialog() {
    setState(() {
      _showTextDialog = false;
      _editingTextIndex = null;
      _textBoxRect = null;
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
    if (start == null || end == null) return null;
    if (currentTool == ScreenshotToolType.text) {
      // 拖拽 = 圈定文本框：细边框实时预览框的大小。
      return DrawCommand(
        type: ScreenshotToolType.rect,
        start: start,
        end: end,
        path: Path(),
        rect: _normalizedRect(start, end),
        color: currentColor,
        strokeWidth: 1.5,
      );
    }
    return DrawCommand(
      type: currentTool,
      start: start,
      end: end,
      path: _dragPath ?? Path(),
      rect: _normalizedRect(start, end),
      color: currentColor,
      strokeWidth: currentTool == ScreenshotToolType.eraser
          ? eraserSize
          : strokeWidth,
      fillColor: maskColor,
      maskStyle: currentTool == ScreenshotToolType.mask
          ? currentMaskStyle
          : MaskStyle.solid,
    );
  }

  int? _findMovableCommandIndex(Offset position) {
    return findManipulableCommandIndex(history, position);
  }

  /// 按手柄把原对象改成新大小：直线/箭头换端点，盒子对象换包围框并同步
  /// start/end；文字连文本框一起改（框内字号自适应缩小），自由文字拖完
  /// 也升级成文本框，避免字号不变、视觉范围不跟着走。
  DrawCommand _resizeCommand(
    DrawCommand original,
    ResizeHandle handle,
    Offset position,
  ) {
    if (handle == ResizeHandle.lineStart || handle == ResizeHandle.lineEnd) {
      final start = handle == ResizeHandle.lineStart
          ? position
          : original.start;
      final end = handle == ResizeHandle.lineEnd ? position : original.end;
      return original.resized(
        start: start,
        end: end,
        rect: _normalizedRect(start, end),
      );
    }
    final bounds = resizeBounds(
      commandDisplayBounds(original),
      handle,
      position,
    );
    return original.resized(
      rect: bounds,
      start: bounds.topLeft,
      end: bounds.bottomRight,
      textBox: original.type == ScreenshotToolType.text ? bounds : null,
    );
  }

  /// 纯点击（按下后未滑过 pan 位移阈值就抬起）：橡皮点删对象/擦一个小点，
  /// 光标点选或取消选中，画笔点个圆点。拖动场景 pan 已接手，直接跳过。
  void _onCanvasTapUp(Offset position) {
    // 标志在抬起时惰性复位：onPointerDown 比 pan 的接管晚分发，在 down
    // 里复位会把 pan 刚设置的标志清掉。
    final handledByPan = _pointerHandledByPan;
    _pointerHandledByPan = false;
    if (handledByPan || _dragStart != null || _editingCommandIndex != null) {
      return;
    }
    switch (currentTool) {
      case ScreenshotToolType.eraser:
        final index = findEraserTargetIndex(history, position, eraserSize / 2);
        if (index != null) {
          _eraseCommandAt(index);
        } else {
          _commitTapDot(position);
        }
      case ScreenshotToolType.select:
        final target = findManipulableCommandIndex(history, position);
        setState(() => _selectedCommandIndex = target);
      case ScreenshotToolType.brush:
        _commitTapDot(position);
      case ScreenshotToolType.text:
        // 文字模式点击已有文字对象：选中并进入编辑状态。
        final target = findManipulableCommandIndex(history, position);
        if (target != null && history[target].type == ScreenshotToolType.text) {
          setState(() => _selectedCommandIndex = target);
          _beginTextEdit(target);
        }
        break;
      default:
        break;
    }
  }

  /// 画一个"点"：落笔即抬笔的极短笔画（画笔=圆点，橡皮=擦掉一小圈）。
  void _commitTapDot(Offset position) {
    final path = Path()
      ..moveTo(position.dx, position.dy)
      ..lineTo(position.dx + 0.01, position.dy + 0.01);
    setState(() {
      _pushCommand(
        DrawCommand(
          type: currentTool,
          start: position,
          end: position,
          path: path,
          rect: Rect.fromCircle(center: position, radius: 0.01),
          color: currentColor,
          strokeWidth: currentTool == ScreenshotToolType.eraser
              ? eraserSize
              : strokeWidth,
          fillColor: maskColor,
        ),
      );
    });
  }

  void _onPanStart(DragStartDetails details) {
    final position = details.localPosition;
    _pointerHandledByPan = true;
    // 开始绘图就立即收起唤出的工具栏，别挡住落笔区域。
    if (_dockRevealed) _hideDockTransient();
    // Hover events stop during a drag, so the cursor ring must be fed from
    // the pan handlers to keep following the mouse.
    _cursorPosition = position;
    if (currentTool == ScreenshotToolType.eraser) {
      // 统一按笔画像素擦除开拖；「整块删除形状」只在松手判定为单点
      // （未滑动）且命中对象时执行（见 _onPanEnd），纯点击也可能根本没
      // 触发 pan——那条路径由 _onCanvasTapUp 兜底。
      _beginDrag(position);
      return;
    }
    if (currentTool == ScreenshotToolType.select) {
      // 若已选中对象且按在缩放手柄上，则进入改大小（不改变选中项）。
      final selected = _selectedCommandIndex;
      if (selected != null && selected < history.length) {
        final handle = hitTestCommandHandle(
          history[selected],
          position,
          _resizeHandleWorldSize,
        );
        if (handle != null) {
          _editingCommandIndex = selected;
          _movingOriginalCommand = history[selected];
          _movingStartPosition = position;
          _resizeHandle = handle;
          _dragStart = null;
          _dragEnd = null;
          _dragPath = null;
          setState(() {});
          return;
        }
      }
      // 光标模式：点谁选中谁（内部空白也能抓住），按住拖动即移动；
      // 点空白取消选中。选中后可用 Delete 删除。
      final target = findManipulableCommandIndex(history, position);
      setState(() => _selectedCommandIndex = target);
      if (target != null) {
        _editingCommandIndex = target;
        _movingOriginalCommand = history[target];
        _movingStartPosition = position;
        _resizeHandle = null;
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
    _resizeHandle = null;
    // 橡皮的增量擦除从头一点开始累积（其它工具用不到，空转无害）。
    _pendingEraseSegment = Path()..moveTo(position.dx, position.dy);
    _eraseTail = position;
    setState(() {});
  }

  void _onPanUpdate(DragUpdateDetails details) {
    _cursorPosition = details.localPosition;
    if (_editingCommandIndex != null &&
        _movingOriginalCommand != null &&
        _movingStartPosition != null) {
      final index = _editingCommandIndex!;
      final handle = _resizeHandle;
      if (handle != null) {
        history[index] = _resizeCommand(
          _movingOriginalCommand!,
          handle,
          details.localPosition,
        );
        setState(() {});
        _invalidateCommands();
        return;
      }
      final delta = details.localPosition - _movingStartPosition!;
      history[index] = _movingOriginalCommand!.translated(delta);
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
    if (currentTool == ScreenshotToolType.eraser) {
      // 实时擦除：把新笔画段烘进静态层位图（每帧至多一次），扫过即真洞。
      _eraseTail = end;
      _pendingEraseSegment?.lineTo(end.dx, end.dy);
      _scheduleEraseApply();
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

  /// 手势被竞技场取消（双击识别抢走、窗口失焦、系统手势介入等）时
  /// 不会走 [_onPanEnd]——不清掉拖动状态的话，预览命令会一直挂在
  /// 画布上：它不在 history 里（Ctrl+Z 撤不掉），又按 currentTool
  /// 构建（切工具就"变类型"），正是形状莫名变化的幽灵来源。
  void _onPanCancel() {
    _cancelActiveGesture();
  }

  /// 丢弃进行中的手势（不提交）：被移动的对象还原，其余拖动状态清空。
  void _cancelActiveGesture() {
    _pendingEraseSegment = null;
    _eraseTail = null;
    final moving = _editingCommandIndex;
    if (moving != null && _movingOriginalCommand != null) {
      history[moving] = _movingOriginalCommand!;
      _invalidateCommands();
    }
    if (_dragStart == null && _editingCommandIndex == null) return;
    setState(() {
      _dragStart = null;
      _dragEnd = null;
      _dragPath = null;
      _editingCommandIndex = null;
      _movingOriginalCommand = null;
      _movingStartPosition = null;
      _resizeHandle = null;
    });
  }

  void _onPanEnd(DragEndDetails details) {
    // 增量擦除状态只服务于拖动期间；未烘完的尾段由提交时的位图重建
    // 兜底（命令里的完整路径），这里直接丢弃。
    _pendingEraseSegment = null;
    _eraseTail = null;
    if (_editingCommandIndex != null) {
      setState(() {
        _editingCommandIndex = null;
        _movingOriginalCommand = null;
        _movingStartPosition = null;
        _resizeHandle = null;
      });
      // 移动期间位图停更，松手后按最终位置重烘。
      _invalidateCommands();
      return;
    }

    final start = _dragStart;
    final end = _dragEnd ?? start;
    if (start == null || end == null) return;

    if (currentTool == ScreenshotToolType.text) {
      // 拖拽 = 圈定文本框（太小视为点击创建单行文本）。
      final rect = _normalizedRect(start, end);
      _openTextDialog(
        start,
        textBox: rect.width > 32 && rect.height > 20 ? rect : null,
      );
    } else {
      final rect = _normalizedRect(start, end);
      final path = _dragPath ?? Path();
      // 橡皮「单点未滑动」：命中形状就整块删除，不落橡皮笔画；移动过
      // （哪怕从形状上起笔）就是局部像素擦除。阈值略大于拖动起步位移，
      // 手抖不误删。
      if (currentTool == ScreenshotToolType.eraser &&
          path.getBounds().longestSide <= 6) {
        final hit = findEraserTargetIndex(history, start, eraserSize / 2);
        if (hit != null) {
          _eraseCommandAt(hit);
          setState(() {
            _dragStart = null;
            _dragEnd = null;
            _dragPath = null;
          });
          return;
        }
      }
      if ((currentTool == ScreenshotToolType.brush ||
              currentTool == ScreenshotToolType.eraser) &&
          path.getBounds().isEmpty) {
        path.lineTo(start.dx + 0.01, start.dy + 0.01);
      }
      // 蒙版按当前样式落命令：blur 走模糊渲染，solid 用调色板颜色。
      final fillColor = maskColor;
      final maskStyle = currentTool == ScreenshotToolType.mask
          ? currentMaskStyle
          : MaskStyle.solid;
      final command = DrawCommand(
        type: currentTool,
        start: start,
        end: end,
        path: path,
        rect: rect,
        color: currentColor,
        // 橡皮痕迹的宽度 = 橡皮粗细（像素擦除的扫宽）。
        strokeWidth: currentTool == ScreenshotToolType.eraser
            ? eraserSize
            : strokeWidth,
        fillColor: fillColor,
        maskStyle: maskStyle,
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

/// 复制按钮的状态机：idle 图标、working 沙漏、done 绿勾、failed 红叹号，
/// 见 [_ScreenshotToolState._copyState]。
enum _CopyState { idle, working, done, failed }

/// 自绘橡皮图标：图标库里没有像样的橡皮，用一块 45° 斜置的圆角矩形
/// （本体加尾段分隔线）加一条桌面基线拼出来，线宽对齐 Material 图标。
class _EraserGlyph extends StatelessWidget {
  const _EraserGlyph();

  @override
  Widget build(BuildContext context) {
    // 停靠按钮给子节点的是 34×34 的紧约束，用 Center 收回 20×20 画布。
    return Center(
      child: CustomPaint(
        size: const Size(20, 20),
        painter: _EraserGlyphPainter(),
      ),
    );
  }
}

class _EraserGlyphPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // 斜置 45° 的橡皮块，右下角抵着基线；分隔线隔出贴近纸面的尾段。
    canvas.save();
    canvas.translate(size.width * 0.5, size.height * 0.43);
    canvas.rotate(math.pi / 4);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-6, -3.75, 12, 7.5),
        const Radius.circular(2),
      ),
      stroke,
    );
    canvas.drawLine(
      const Offset(2.2, -3.75),
      const Offset(2.2, 3.75),
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
    canvas.restore();

    canvas.drawLine(
      Offset(size.width * 0.21, size.height * 0.87),
      Offset(size.width * 0.84, size.height * 0.87),
      stroke,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 选色板里的一个色块：方格样式，点击即选中。
class _SwatchCell extends StatelessWidget {
  const _SwatchCell({required this.color, this.onTap});

  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 24,
        height: 24,
        margin: const EdgeInsets.all(1.5),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: Colors.black.withValues(alpha: 0.18)),
        ),
      ),
    );
  }
}
