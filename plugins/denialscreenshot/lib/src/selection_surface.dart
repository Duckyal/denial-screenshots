import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:denial_flutter_sdk/input.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;

import 'capture_flow_bus.dart';
import 'clipboard.dart';
import 'editor/file_picker.dart';
import 'editor/settings.dart';
import 'editor/translate_service.dart';
import 'editor_bus.dart';
import 'pin_surface.dart';
import 'scroll_capture.dart';
import 'screenshot_store.dart';
import 'selection_settings_panel.dart';

/// 「框选 → 工具栏」截图的 surface 宿主。
///
/// 覆盖整个输出：压暗后拖动框选屏幕区域，松手后选区保留、可拖角/边微调、
/// 可整体移动，并就地显示工具栏（识字/翻译/长截屏/编辑/复制/保存/置顶/关闭）。
/// 取图用 `grim`（wlr-screencopy）截活画面，不经过合成器的选区流程；截取前
/// 先把本 surface 的遮罩藏掉一拍，避免把压暗层也截进图里。
final class CaptureFlowHost extends StatefulWidget {
  const CaptureFlowHost({super.key});

  @override
  State<CaptureFlowHost> createState() => _CaptureFlowHostState();
}

class _CaptureFlowHostState extends State<CaptureFlowHost> {
  final ScreenshotStore _store = const ScreenshotStore();
  final TranslateService _translateService = TranslateService();

  static const Duration _hideDelay = Duration(milliseconds: 180);
  static const double _minSelection = 8;
  static const double _edgeInset = 2;

  StreamSubscription<void>? _requests;
  ScreenshotSettings _settings = const ScreenshotSettings();

  bool _visible = false;
  bool _capturing = false;

  /// 当前选区（surface 逻辑坐标 == 输出坐标）。
  Rect? _region;

  /// 一次手势用的快照：按下点、按下时的选区、命中边（0=移动/新建）。
  Offset? _pressStart;
  Rect? _pressBox;
  int _edge = 0;
  bool _dragging = false;
  bool _freshSelection = false;
  bool _moved = false;

  /// 最近一次 grim 结果；选区没变时复用，避免重复截取。
  File? _capturedFile;
  Uint8List? _capturedBytes;
  Rect? _capturedRect;

  /// 识字/翻译结果浮层。
  bool _resultOpen = false;
  bool _resultBusy = false;
  String _resultMode = '';
  String _resultStatus = '';
  List<TranslateRegion> _resultRegions = const [];

  /// 设置面板（框选流程专用精简面板）。
  bool _settingsOpen = false;

  /// 结果窗实际渲染高度（首帧后量到）：工具栏要贴在它下面，得知道它多高。
  final GlobalKey _resultCardKey = GlobalKey();
  double? _resultWindowHeight;

  /// 指针落在工具栏内时为 true：不当作“点空白重新框选”。
  bool _toolbarHit = false;

  static String get _dataDir =>
      Platform.environment['XDG_DATA_HOME'] ??
      '${Platform.environment['HOME'] ?? '/home'}/.local/share/denial-screenshots';

  @override
  void initState() {
    super.initState();
    _requests = CaptureFlowBus.instance.requests.listen((_) => _begin());
    ScreenshotSettings.load().then((settings) {
      if (mounted) setState(() => _settings = settings);
    });
  }

  @override
  void dispose() {
    _requests?.cancel();
    _translateService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ShellInputRegion(
      debugLabel: 'Denial screenshot selection',
      active: _visible,
      pointerPolicy: ShellPointerPolicy.fullScene,
      keyboardPolicy: ShellKeyboardPolicy.capture,
      compositorPolicy: ShellCompositorPolicy.exclusive,
      child: Focus(
        autofocus: _visible,
        onKeyEvent: (FocusNode node, KeyEvent event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            if (!_visible || _capturing) return KeyEventResult.handled;
            if (_settingsOpen) {
              setState(() => _settingsOpen = false);
              return KeyEventResult.handled;
            }
            if (_resultOpen) {
              setState(() => _resultOpen = false);
              return KeyEventResult.handled;
            }
            _close();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: !_visible
            ? const SizedBox.shrink()
            : MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: ThemeData(
                  colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
                  useMaterial3: true,
                ),
                home: Material(
                  type: MaterialType.transparency,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final size = Size(
                        constraints.maxWidth,
                        constraints.maxHeight,
                      );
                      return _buildOverlay(size);
                    },
                  ),
                ),
              ),
      ),
    );
  }

  Widget _buildOverlay(Size size) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) => _handleDown(event.localPosition, size),
      onPointerMove: (event) => _handleMove(event.localPosition, size),
      onPointerUp: (_) => _handleUp(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (!_capturing) CustomPaint(painter: _DimPainter(region: _region)),
          if (_capturing) _buildCapturing(),
          if (!_capturing && _region != null)
            _buildRegionOverlay(size, _region!),
          if (!_capturing && _resultOpen && _region != null)
            _buildResultWindow(size, _region!),
          if (!_capturing && _settingsOpen && _region != null)
            _buildSettingsOverlay(size, _region!),
        ],
      ),
    );
  }

  /// 设置面板：和结果窗一样按选区判定贴边——右侧放得下贴右、否则贴左，
  /// 水平都放不下就贴选区下方（下方不够贴上方）。外层 [GestureDetector]
  /// 吃掉指针，点面板空白不会误当成“重新框选”。
  Widget _buildSettingsOverlay(Size size, Rect region) {
    const gap = 10.0;
    const panelWidth = 380.0;
    final maxHeight = math.min(520.0, size.height - 16);

    final rightRoom = size.width - region.right - gap;
    final leftRoom = region.left - gap;
    final belowRoom = size.height - region.bottom - gap;
    final aboveRoom = region.top - gap;

    final panel = ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SelectionSettingsPanel(
        settings: _settings,
        translateService: _translateService,
        onChanged: _onSettingsChanged,
        onClose: () => setState(() => _settingsOpen = false),
      ),
    );

    final resultSide = _resultOpen ? _resultSide(size, region) : null;
    final resultHeight = _resultWindowHeight ?? 0;

    // 侧边：结果窗在左/右侧时就避开那侧，让两者能同时显示（结果窗优先占侧边）。
    final canRight = rightRoom >= panelWidth && resultSide != 'right';
    final canLeft = leftRoom >= panelWidth && resultSide != 'left';

    Widget positioned;
    if (canRight || canLeft) {
      final left = canRight
          ? region.right + gap
          : region.left - gap - panelWidth;
      final top = region.top
          .clamp(8.0, math.max(size.height - maxHeight - 8, 8.0))
          .toDouble();
      positioned = Positioned(left: left, top: top, child: panel);
    } else {
      final toolbarTop = _toolbarPlacement(size, region).top;
      final toolbarBelow = toolbarTop >= region.bottom;
      final toolbarAbove = toolbarTop + _toolbarBarHeight <= region.top;
      final resultBelow = resultSide == 'below';
      final resultAbove = resultSide == 'above';

      final down = belowRoom >= aboveRoom;
      final left = region.left
          .clamp(8.0, math.max(size.width - panelWidth - 8, 8.0))
          .toDouble();
      if (down) {
        var top = region.bottom + gap;
        if (resultBelow) {
          top = math.max(top, region.bottom + 10 + resultHeight + gap);
        }
        if (toolbarBelow) {
          top = math.max(top, toolbarTop + _toolbarBarHeight + gap);
        }
        positioned = Positioned(left: left, top: top, child: panel);
      } else {
        var y = region.top - gap;
        if (resultAbove) {
          y = math.min(y, region.top - 10 - resultHeight - gap);
        }
        if (toolbarAbove) {
          y = math.min(y, toolbarTop - gap);
        }
        positioned = Positioned(
          left: left,
          bottom: size.height - y,
          child: panel,
        );
      }
    }

    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: Stack(children: [positioned]),
      ),
    );
  }

  Widget _buildCapturing() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          SizedBox(height: 12),
          Text('正在截取…', style: TextStyle(fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildRegionOverlay(Size size, Rect region) {
    final label = '${region.width.round()} × ${region.height.round()}';
    const labelWidth = 150.0;
    final labelLeft = (region.left + 8)
        .clamp(4.0, size.width - labelWidth - 4)
        .toDouble();
    final labelTop = (region.top - 34).clamp(4.0, size.height - 30).toDouble();
    final toolbar = _toolbarPlacement(size, region);
    return Stack(
      children: [
        Positioned(
          left: labelLeft,
          top: labelTop,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xCC23272B),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                color: Colors.white,
                fontFeatures: [ui.FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
        _ToolbarHost(
          left: toolbar.left,
          top: toolbar.top,
          onToolbarHitChanged: (hit) => _toolbarHit = hit,
          children: [
            _toolItem(Icons.text_fields, '识字', () => _runText('ocr')),
            _toolItem(Icons.translate, '翻译', () => _runText('translate')),
            _toolItem(Icons.screenshot, '长截屏', _startScrollCapture),
            _toolItem(Icons.edit, '编辑', _openEditor),
            _toolItem(Icons.copy, '复制', _copyImage),
            _toolItem(Icons.save_alt, '保存', _saveImage),
            _toolItem(Icons.push_pin, '置顶', _pinImage),
            _toolItem(Icons.settings, '设置', _openSettings),
            _toolItem(Icons.close, '关闭', _close),
          ],
        ),
      ],
    );
  }

  Widget _toolItem(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 54,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 21, color: Colors.white70),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(fontSize: 11, color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }

  static const int _toolbarItemCount = 9;
  static const double _toolbarBarHeight = 72;
  static const double _toolbarBarWidth = 54 * _toolbarItemCount + 8 * 2 + 4;

  /// 结果窗贴边方向：竖直优先（与选区同宽），空间不够改水平（与选区同高）。
  String _resultSide(Size size, Rect region) {
    const gap = 10.0;
    const minSpan = 200.0;
    final below = size.height - region.bottom - gap;
    final above = region.top - gap;
    final right = size.width - region.right - gap;
    final left = region.left - gap;
    final verticalRoom = math.max(below, above);
    final horizontalRoom = math.max(right, left);
    final bool useVertical;
    if (verticalRoom >= minSpan) {
      useVertical = true;
    } else if (horizontalRoom >= minSpan) {
      useVertical = false;
    } else {
      useVertical = verticalRoom >= horizontalRoom;
    }
    if (useVertical) return below >= above ? 'below' : 'above';
    return right >= left ? 'right' : 'left';
  }

  /// 工具栏位置。默认贴选区下方；若结果窗也在下方，则让到结果窗下面；结果窗在
  /// 上方时对称地让到结果窗上面。同侧放不下就换另一侧，上下都放不下时取上方并
  /// 夹取到屏幕内。
  ({double left, double top}) _toolbarPlacement(Size size, Rect region) {
    final resultHeight = _resultWindowHeight ?? 0;
    final resultSide = _resultOpen ? _resultSide(size, region) : null;
    final canBelow = region.bottom + 12 + _toolbarBarHeight <= size.height;
    final canAbove = region.top - 12 - _toolbarBarHeight >= 0;
    final belowPlain = region.bottom + 12;
    final abovePlain = region.top - 12 - _toolbarBarHeight;
    final belowStacked = region.bottom + 10 + resultHeight + 10;
    final aboveStacked =
        region.top - 10 - resultHeight - 10 - _toolbarBarHeight;

    double top;
    if (resultSide == 'below' && canBelow) {
      top = belowStacked;
    } else if (resultSide == 'above' && canAbove) {
      top = aboveStacked;
    } else if (canBelow) {
      top = belowPlain;
    } else {
      top = abovePlain;
    }
    final maxTop = math.max(size.height - _toolbarBarHeight - 4, 4.0);
    top = top.clamp(4.0, maxTop).toDouble();
    final left = (region.center.dx - _toolbarBarWidth / 2)
        .clamp(4.0, size.width - _toolbarBarWidth - 4)
        .toDouble();
    return (left: left, top: top);
  }

  void _measureResultCard() {
    if (!mounted || !_resultOpen) return;
    final box = _resultCardKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || box.size.height < 1) return;
    final height = box.size.height;
    if (_resultWindowHeight == null ||
        (height - _resultWindowHeight!).abs() > 0.5) {
      setState(() => _resultWindowHeight = height);
    }
  }

  /// 结果窗：识字/翻译的文本列表。窗口不叠在图片上，而是**按选区判定贴边**：
  /// 优先贴选区正下方（与选区同宽），下方不够就贴正上方；上下都放不下再改贴
  /// 正右方（与选区同高），最后贴正左方。位置与尺寸都跟着选区走。
  Widget _buildResultWindow(Size size, Rect region) {
    const gap = 10.0;

    final below = size.height - region.bottom - gap;
    final above = region.top - gap;
    final right = size.width - region.right - gap;
    final left = region.left - gap;
    final side = _resultSide(size, region);
    final useVertical = side == 'below' || side == 'above';

    Widget card({required double maxWidth, required double maxHeight}) {
      final title = _resultMode == 'ocr' ? '识别结果' : '翻译结果';
      final hasText = _resultRegions.isNotEmpty;
      return KeyedSubtree(
        key: _resultCardKey,
        child: Material(
          color: const Color(0xF2202428),
          borderRadius: BorderRadius.circular(10),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: maxWidth,
              maxHeight: maxHeight,
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(
                            fontSize: 14,
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      InkWell(
                        onTap: () => setState(() => _resultOpen = false),
                        child: const Icon(
                          Icons.close,
                          size: 18,
                          color: Colors.white54,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_resultBusy)
                    Row(
                      children: [
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _resultStatus,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Colors.white70,
                            ),
                          ),
                        ),
                      ],
                    )
                  else if (!hasText)
                    Text(
                      _resultStatus.isEmpty ? '未识别到文字' : _resultStatus,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.white54,
                      ),
                    )
                  else
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: _resultRegions.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) => _ResultRow(
                          mode: _resultMode,
                          source: _resultRegions[index].source,
                          translated: _resultRegions[index].translated,
                          index: index,
                        ),
                      ),
                    ),
                  if (hasText) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _copyResultText,
                        child: const Text('复制文字'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => _measureResultCard());

    if (useVertical) {
      final down = side == 'below';
      final width = math.min(region.width, size.width);
      final available = math.max(down ? below : above, 100.0);
      final content = card(maxWidth: width, maxHeight: available);
      final leftEdge = region.left
          .clamp(0.0, math.max(size.width - width, 0.0))
          .toDouble();
      if (down) {
        return Positioned(
          left: leftEdge,
          top: region.bottom + gap,
          width: width,
          child: content,
        );
      }
      return Positioned(
        left: leftEdge,
        bottom: size.height - region.top + gap,
        width: width,
        child: content,
      );
    }

    final rightSide = side == 'right';
    final height = math.min(region.height, size.height);
    final available = math.max(rightSide ? right : left, 140.0);
    final content = card(maxWidth: available, maxHeight: height);
    final topEdge = region.top
        .clamp(0.0, math.max(size.height - height, 0.0))
        .toDouble();
    if (rightSide) {
      return Positioned(
        left: region.right + gap,
        top: topEdge,
        height: height,
        child: content,
      );
    }
    return Positioned(
      right: size.width - region.left + gap,
      top: topEdge,
      height: height,
      child: content,
    );
  }

  // ---- 手势：框选 / 微调 ----

  void _handleDown(Offset position, Size size) {
    if (!_visible || _capturing || _resultOpen || _settingsOpen || _toolbarHit)
      return;
    final region = _region;
    if (region != null) {
      final edge = _hitTestEdge(region, position);
      if (edge != 0 || region.contains(position)) {
        setState(() {
          _edge = edge;
          _pressStart = position;
          _pressBox = region;
          _dragging = true;
          _freshSelection = false;
        });
        return;
      }
    }
    setState(() {
      _edge = 0;
      _pressStart = position;
      _pressBox = region;
      _freshSelection = true;
      _dragging = true;
      _region = null;
    });
  }

  void _handleMove(Offset position, Size size) {
    if (!_dragging || _capturing || _resultOpen || _settingsOpen || _toolbarHit)
      return;
    final start = _pressStart;
    if (start == null) return;
    if ((position - start).distance > 2) _moved = true;
    setState(() {
      if (_freshSelection) {
        _region = _clampRect(Rect.fromPoints(start, position), size);
      } else if (_edge == 0) {
        final base = _pressBox;
        _region = base == null
            ? _clampRect(Rect.fromPoints(start, position), size)
            : _clampRect(base.shift(position - start), size);
      } else {
        final base = _pressBox;
        if (base == null) return;
        _region = _resizedFrom(_edge, base, start, position, size);
      }
    });
  }

  void _handleUp() {
    if (!_dragging || _capturing || _resultOpen || _settingsOpen || _toolbarHit)
      return;
    setState(() {
      _dragging = false;
      _edge = 0;
      _pressStart = null;
      if (!_moved) {
        _region = _pressBox;
        _freshSelection = false;
        _moved = false;
        return;
      }
      _moved = false;
      _freshSelection = false;
      _pressBox = null;
    });
  }

  int _hitTestEdge(Rect region, Offset position) {
    const tolerance = 6.0;
    final nearLeft = (position.dx - region.left).abs() <= tolerance;
    final nearRight = (position.dx - region.right).abs() <= tolerance;
    final nearTop = (position.dy - region.top).abs() <= tolerance;
    final nearBottom = (position.dy - region.bottom).abs() <= tolerance;
    if (nearLeft && nearTop) return 1;
    if (nearRight && nearTop) return 2;
    if (nearLeft && nearBottom) return 3;
    if (nearRight && nearBottom) return 4;
    if (nearTop) return 5;
    if (nearBottom) return 6;
    if (nearLeft) return 7;
    if (nearRight) return 8;
    return 0;
  }

  Rect _resizedFrom(int edge, Rect base, Offset start, Offset now, Size size) {
    final dx = now.dx - start.dx;
    final dy = now.dy - start.dy;
    var left = base.left;
    var top = base.top;
    var right = base.right;
    var bottom = base.bottom;
    if (edge == 1 || edge == 3 || edge == 5 || edge == 7) {
      left = base.left + dx;
    }
    if (edge == 2 || edge == 4 || edge == 6 || edge == 8) {
      right = base.right + dx;
    }
    if (edge == 1 || edge == 2 || edge == 5) top = base.top + dy;
    if (edge == 3 || edge == 4 || edge == 6) bottom = base.bottom + dy;
    if (right - left < _minSelection) right = left + _minSelection;
    if (bottom - top < _minSelection) bottom = top + _minSelection;
    return _clampRect(Rect.fromLTRB(left, top, right, bottom), size);
  }

  Rect _clampRect(Rect rect, Size size) {
    var left = rect.left;
    var top = rect.top;
    var right = rect.right;
    var bottom = rect.bottom;
    if (right > size.width) right = size.width;
    if (bottom > size.height) bottom = size.height;
    if (left < 0) {
      right += -left;
      left = 0;
    }
    if (top < 0) {
      bottom += -top;
      top = 0;
    }
    if (right > size.width) right = size.width;
    if (bottom > size.height) bottom = size.height;
    return Rect.fromLTRB(left, top, right, bottom);
  }

  // ---- 动作 ----

  void _begin() {
    if (!mounted || _visible) return;
    DenialScreenshotEditorBus.instance.suppressAutoOpen.value = true;
    setState(() {
      _visible = true;
      _capturing = false;
      _region = null;
      _capturedFile = null;
      _capturedBytes = null;
      _capturedRect = null;
      _resultOpen = false;
      _resultBusy = false;
      _resultRegions = const [];
      _settingsOpen = false;
      _resultWindowHeight = null;
    });
  }

  void _close() {
    DenialScreenshotEditorBus.instance.suppressAutoOpen.value = false;
    if (!mounted) return;
    setState(() {
      _visible = false;
      _capturing = false;
      _region = null;
      _capturedFile = null;
      _capturedBytes = null;
      _capturedRect = null;
      _resultOpen = false;
      _resultBusy = false;
      _resultRegions = const [];
      _settingsOpen = false;
      _resultWindowHeight = null;
    });
  }

  Future<({File file, Uint8List bytes})?> _captureNow() async {
    if (_capturing) return null;
    final region = _region;
    if (region == null ||
        region.width < _minSelection ||
        region.height < _minSelection) {
      return null;
    }
    if (_capturedBytes != null &&
        _capturedFile != null &&
        _capturedRect == region) {
      return (file: _capturedFile!, bytes: _capturedBytes!);
    }
    setState(() => _capturing = true);
    // 遮罩藏掉一拍再截，grim 抓的是合成帧，会连压暗层一起抓到。
    await Future<void>.delayed(_hideDelay);
    final directory = Directory('$_dataDir/selection-captures');
    directory.createSync(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final path = '${directory.path}/capture-$stamp.png';
    var captureRect = region;
    if (region.width > _edgeInset * 2 + _minSelection &&
        region.height > _edgeInset * 2 + _minSelection) {
      captureRect = region.deflate(_edgeInset);
    }
    final geometry =
        '${captureRect.left.round()},${captureRect.top.round()} '
        '${captureRect.width.round()}x${captureRect.height.round()}';
    var ok = false;
    try {
      final process = await Process.start('grim', [
        '-g',
        geometry,
        '-t',
        'png',
        path,
      ], environment: childProcessEnvironment());
      final code = await process.exitCode.timeout(
        const Duration(seconds: 4),
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
      ok = code == 0;
    } on Object {
      ok = false;
    }
    final bytes = ok ? await _store.readStable(File(path)) : null;
    if (mounted) setState(() => _capturing = false);
    if (!ok || bytes == null || bytes.isEmpty) {
      PinCardBus.instance.showToast('截取失败，请重试');
      return null;
    }
    _capturedFile = File(path);
    _capturedBytes = bytes;
    _capturedRect = region;
    return (file: _capturedFile!, bytes: bytes);
  }

  String _targetLanguage() {
    final configured = _settings.translateTarget;
    if (configured != 'system') return configured;
    return View.of(context).platformDispatcher.locale.languageCode;
  }

  Future<void> _runText(String mode) async {
    final captured = await _captureNow();
    if (captured == null) return;
    if (!await _translateService.isReady()) {
      PinCardBus.instance.showToast('翻译组件未安装，请先在编辑器设置中安装');
      return;
    }
    setState(() {
      _resultMode = mode;
      _resultRegions = const [];
      _resultStatus = mode == 'ocr' ? '正在识别文字…' : '正在翻译…';
      _resultBusy = true;
      _resultOpen = true;
      _resultWindowHeight = null;
    });
    try {
      await for (final event in _translateService.run(
        imagePath: captured.file.path,
        target: _targetLanguage(),
        mode: mode,
        ocrModel: _settings.ocrModel,
      )) {
        if (!mounted) return;
        switch (event.type) {
          case 'status':
            setState(() => _resultStatus = event.message ?? _resultStatus);
          case 'region':
            break;
          case 'done':
            setState(() {
              _resultRegions = List<TranslateRegion>.of(event.regions);
              _resultBusy = false;
              _resultStatus = '';
            });
          case 'error':
            setState(() {
              _resultBusy = false;
              _resultStatus = event.message ?? '处理失败';
            });
        }
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _resultBusy = false;
        _resultStatus = '$error';
      });
    }
  }

  Future<void> _copyResultText() async {
    final text = _resultMode == 'ocr'
        ? _resultRegions.map((region) => region.source).join('\n')
        : _resultRegions
              .map((region) => region.translated)
              .where((line) => line.isNotEmpty)
              .join('\n');
    if (text.isEmpty) return;
    final ok = await copyTextToClipboard(text);
    if (!mounted) return;
    PinCardBus.instance.showToast(ok ? '已复制文字' : '复制失败（缺 wl-copy / xclip）');
  }

  Future<void> _openEditor() async {
    final captured = await _captureNow();
    if (captured == null) return;
    DenialScreenshotEditorBus.instance.openPath(captured.file.path);
    _close();
  }

  Future<void> _copyImage() async {
    final captured = await _captureNow();
    if (captured == null) return;
    final ok = await copyPngToClipboard(captured.bytes);
    if (!mounted) return;
    if (ok) {
      PinCardBus.instance.showToast('已复制图片到剪贴板');
      _close();
    } else {
      PinCardBus.instance.showToast('复制失败（缺 wl-copy / xclip）');
    }
  }

  /// 保存：复刻编辑器那套——拉起插件内置的路径选择对话框，由用户挑目录和
  /// 文件名（初始定位在 ~/Pictures/Screenshots），而不是直接写死固定位置。
  Future<void> _saveImage() async {
    final captured = await _captureNow();
    if (captured == null) return;
    final path = await choosePathWithDialog(
      context: context,
      arguments: [
        '--file-selection',
        '--save',
        '--confirm-overwrite',
        '--title=保存截图',
        '--filename=Screenshot.png',
        '--file-filter=PNG 图片 | *.png',
      ],
    );
    if (path == null || path.isEmpty) return;
    try {
      await File(path).writeAsBytes(captured.bytes, flush: true);
    } on Object {
      PinCardBus.instance.showToast('保存失败');
      return;
    }
    if (!mounted) return;
    PinCardBus.instance.showToast('已保存：$path');
  }

  Future<void> _pinImage() async {
    final captured = await _captureNow();
    if (captured == null) return;
    PinCardBus.instance.add(
      PinImage(bytes: captured.bytes, sourceBytes: captured.bytes),
    );
    _close();
  }

  void _openSettings() {
    setState(() => _settingsOpen = true);
  }

  void _onSettingsChanged(ScreenshotSettings next) {
    setState(() => _settings = next);
    next.save();
  }

  Future<void> _startScrollCapture() async {
    final region = _region;
    if (region == null ||
        region.width < _minSelection ||
        region.height < _minSelection) {
      return;
    }
    _close();
    // 等遮罩藏好再开始连拍，免得第一帧带着压暗层。
    await Future<void>.delayed(_hideDelay);
    await ScrollCaptureManager.instance.start(region);
  }
}

/// 识字/翻译结果列表里的单行：OCR 显示原文，翻译显示序号+原文+译文。
class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.mode,
    required this.source,
    required this.translated,
    required this.index,
  });

  final String mode;
  final String source;
  final String translated;
  final int index;

  @override
  Widget build(BuildContext context) {
    if (mode == 'ocr') {
      return Text(
        source,
        style: const TextStyle(fontSize: 13, color: Colors.white),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${index + 1}. $source',
          style: const TextStyle(fontSize: 12, color: Colors.white54),
        ),
        const SizedBox(height: 2),
        Text(
          translated,
          style: const TextStyle(fontSize: 13, color: Colors.white),
        ),
      ],
    );
  }
}

/// 挂在选区旁的小工具栏：整体包一层 [Listener]，让它把指针事件吃掉，
/// 以免点按钮被当成“点空白重新框选”。
class _ToolbarHost extends StatelessWidget {
  const _ToolbarHost({
    required this.left,
    required this.top,
    required this.onToolbarHitChanged,
    required this.children,
  });

  final double left;
  final double top;
  final ValueChanged<bool> onToolbarHitChanged;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    const padding = 8.0;
    return Positioned(
      left: left,
      top: top,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => onToolbarHitChanged(true),
        onPointerUp: (_) => onToolbarHitChanged(false),
        onPointerCancel: (_) => onToolbarHitChanged(false),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: padding, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xF0202428),
            borderRadius: BorderRadius.circular(12),
            boxShadow: const [
              BoxShadow(color: Color(0x40000000), blurRadius: 18),
            ],
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: children),
        ),
      ),
    );
  }
}

/// 压暗层：全屏半透明黑，选区矩形挖洞（[ui.BlendMode.clear]），再画白色描边
/// 与四角拖拽柄。
class _DimPainter extends CustomPainter {
  _DimPainter({required this.region});

  final Rect? region;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.saveLayer(Offset.zero & size, Paint());
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black45);
    final current = region;
    if (current != null && current.width >= 1 && current.height >= 1) {
      canvas.drawRect(current, Paint()..blendMode = ui.BlendMode.clear);
    }
    canvas.restore();
    if (current == null) return;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = Colors.white;
    canvas.drawRect(current, stroke);
    final handle = Paint()..color = Colors.white;
    for (final corner in [
      current.topLeft,
      current.topRight,
      current.bottomLeft,
      current.bottomRight,
    ]) {
      canvas.drawRect(
        Rect.fromCenter(center: corner, width: 9, height: 9),
        handle,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DimPainter oldDelegate) =>
      oldDelegate.region != region;
}
