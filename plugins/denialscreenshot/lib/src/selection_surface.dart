import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/state.dart'
    show denialBridgeProvider, screenshotSelectionProvider;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'capture_flow_bus.dart';
import 'clipboard.dart';
import 'editor/settings.dart';
import 'editor/translate_service.dart';
import 'editor_bus.dart';
import 'pin_surface.dart';
import 'scroll_capture.dart';
import 'scroll_stitch.dart' show eraseRegionInPlace;
import 'selection_save_panel.dart';
import 'selection_settings_panel.dart';

/// 「框选 → 工具栏」截图的 surface 宿主。
///
/// 覆盖整个输出：压暗后拖动框选屏幕区域，松手后选区保留、可拖角/边微调、
/// 可整体移动，并就地显示工具栏（识字/翻译/长截屏/编辑/复制/保存/置顶/关闭）。
/// 取图用 `grim`（wlr-screencopy）截活画面，不经过合成器的选区流程；截取前
/// 先把本 surface 的遮罩藏掉一拍，避免把压暗层也截进图里。
final class CaptureFlowHost extends ConsumerStatefulWidget {
  const CaptureFlowHost({super.key});

  @override
  ConsumerState<CaptureFlowHost> createState() => _CaptureFlowHostState();
}

class _CaptureFlowHostState extends ConsumerState<CaptureFlowHost> {
  final TranslateService _translateService = TranslateService();

  static const Duration _hideDelay = Duration(milliseconds: 180);
  static const double _minSelection = 8;
  static const double _edgeInset = 2;

  StreamSubscription<void>? _requests;
  StreamSubscription<Offset>? _cursorSub;
  ScreenshotSettings _settings = const ScreenshotSettings();

  /// 实时系统指针位置（输出逻辑坐标），长截屏时用来抹掉画面里的鼠标。
  final ValueNotifier<Offset?> _cursorPosition = ValueNotifier(null);

  bool _visible = false;
  bool _capturing = false;

  /// 抓帧期间把整个选区浮层藏起来：grim 抓的是合成帧，浮层（压暗层/边框/
  /// 工具栏）会一起被拍进去。隐藏期间不显示任何“正在截取”提示，避免用户
  /// 看到浮层消失又出现（退出再进）的闪烁；复制/置顶/编辑这类结束动作干脆
  /// 保持隐藏直到 [_close]，保存/识字则在抓完后直接展开对应面板。
  bool _captureHidden = false;

  /// 正在进行的抓帧：选区一确定就立刻在后台抓好缓存，这样点复制/保存时
  /// 直接命中缓存、不用再藏浮层重截（也就是不会“重载选区截图”）。
  Future<({File file, Uint8List bytes})?>? _inflightCapture;

  /// 触发截图那一刻（浮层还没盖上去）抓好的整屏关键帧。后续复制/保存/
  /// 识字/置顶都直接从这个关键帧裁出选区，全程不用藏浮层、也不会闪一下。
  ui.Image? _keyFrame;
  bool _beginBusy = false;

  /// 本会话是否是「长截图」：选区确定后直接开始滚动拼接，而不是弹工具栏。
  bool _scrollMode = false;

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
  bool _savePanelOpen = false;
  String _saveDirectory = '';
  String _saveFileName = 'Screenshot.png';

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
    _cursorSub = ref
        .read(denialBridgeProvider)
        .cursorPositions
        .listen((position) => _cursorPosition.value = position);
    ScreenshotSettings.load().then((settings) {
      if (mounted) {
        final homeDir = Platform.environment['HOME'] ?? '/';
        setState(() {
          _settings = settings;
          _saveDirectory = '$homeDir/Pictures/Screenshots';
          try {
            Directory(_saveDirectory).createSync(recursive: true);
          } catch (_) {}
          _saveFileName =
              'Screenshot-${DateTime.now().millisecondsSinceEpoch}.png';
        });
      }
    });
  }

  @override
  void dispose() {
    _requests?.cancel();
    _cursorSub?.cancel();
    _cursorPosition.dispose();
    _translateService.dispose();
    _disposeKeyFrame();
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
            if (_savePanelOpen) {
              setState(() => _savePanelOpen = false);
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
    // 抓帧时整层隐藏（不含任何提示），这样用户不会看到浮层被替换成转圈再
    // 弹回来的“退出重进”过程。
    if (_captureHidden) return const SizedBox.shrink();
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) => _handleDown(event.localPosition, size),
      onPointerMove: (event) => _handleMove(event.localPosition, size),
      onPointerUp: (_) => _handleUp(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 用触发时抓的关键帧当背景：所见即所得——被压暗的就是将来截下来的
          // 那一帧，不会出现“看着画面在变、截下来的却是旧帧”的错位。
          if (_keyFrame case final keyFrame?)
            CustomPaint(painter: _KeyFramePainter(image: keyFrame)),
          CustomPaint(painter: _DimPainter(region: _region)),
          if (_region != null) _buildRegionOverlay(size, _region!),
          if (_resultOpen && _region != null)
            _buildResultWindow(size, _region!),
          if (_settingsOpen && _region != null)
            _buildSettingsOverlay(size, _region!),
          if (_savePanelOpen && _region != null)
            _buildSaveOverlay(size, _region!),
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

    // 不要像之前那样用全屏 opaque 的遮罩把指针全吃掉：那会让工具栏（在设置
    // 面板底下那层 Stack）点不到。误触“重新框选/改选区”由外层 Listener 的
    // _settingsOpen 守卫拦住（[CaptureFlowHostState._handleDown] 等），
    // 所以这里只放面板本体，面板区域之外的事件照常穿透给工具栏。
    return Stack(children: [positioned]);
  }

  /// 保存面板：沿用设置面板的贴边规则，把内嵌的文件选择浮层放到选区旁。
  Widget _buildSaveOverlay(Size size, Rect region) {
    const gap = 10.0;
    const panelWidth = 380.0;
    final maxHeight = math.min(520.0, size.height - 16);

    final rightRoom = size.width - region.right - gap;
    final leftRoom = region.left - gap;
    final belowRoom = size.height - region.bottom - gap;
    final aboveRoom = region.top - gap;

    final panel = ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SelectionSavePanel(
        initialDirectory: _saveDirectory,
        initialFileName: _saveFileName,
        onConfirm: _confirmSave,
        onClose: () => setState(() => _savePanelOpen = false),
      ),
    );

    final resultSide = _resultOpen ? _resultSide(size, region) : null;

    Widget positioned;
    if (rightRoom >= panelWidth || leftRoom >= panelWidth) {
      final canRight = rightRoom >= panelWidth && resultSide != 'right';
      final left = canRight
          ? region.right + gap
          : region.left - gap - panelWidth;
      final top = region.top
          .clamp(8.0, math.max(size.height - maxHeight - 8, 8.0))
          .toDouble();
      positioned = Positioned(left: left, top: top, child: panel);
    } else {
      final left = region.left
          .clamp(8.0, math.max(size.width - panelWidth - 8, 8.0))
          .toDouble();
      final down = belowRoom >= aboveRoom;
      if (down) {
        final top = region.bottom + gap;
        positioned = Positioned(left: left, top: top, child: panel);
      } else {
        positioned = Positioned(
          left: left,
          bottom: size.height - (region.top - gap),
          child: panel,
        );
      }
    }

    return Stack(children: [positioned]);
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

  /// 工具栏位置。结果窗已占一侧时，工具栏优先移到选区的**另一侧**，避免与
  /// 结果窗同侧堆叠被挤出屏幕；异侧放不下才退回同侧堆叠。结果窗在左/右侧或
  /// 未展开时，工具栏贴选区下方，下方放不下再贴上方，最后夹取到屏幕内。
  ({double left, double top}) _toolbarPlacement(Size size, Rect region) {
    final resultHeight = _resultWindowHeight ?? 0;
    final resultSide = _resultOpen ? _resultSide(size, region) : null;
    const gap = 12.0;
    final canBelow = region.bottom + gap + _toolbarBarHeight <= size.height;
    final canAbove = region.top - gap - _toolbarBarHeight >= 0;
    final belowPlain = region.bottom + gap;
    final abovePlain = region.top - gap - _toolbarBarHeight;
    final belowStacked = region.bottom + 10 + resultHeight + 10;
    final aboveStacked =
        region.top - 10 - resultHeight - 10 - _toolbarBarHeight;
    final belowStackedFits = belowStacked + _toolbarBarHeight <= size.height;
    final aboveStackedFits = aboveStacked >= 0;

    double top;
    if (resultSide == 'below') {
      if (canAbove) {
        top = abovePlain;
      } else if (belowStackedFits) {
        top = belowStacked;
      } else {
        top = abovePlain;
      }
    } else if (resultSide == 'above') {
      if (canBelow) {
        top = belowPlain;
      } else if (aboveStackedFits) {
        top = aboveStacked;
      } else {
        top = belowPlain;
      }
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
    if (!_visible ||
        _capturing ||
        _resultOpen ||
        _settingsOpen ||
        _savePanelOpen ||
        _toolbarHit)
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
    if (!_dragging ||
        _capturing ||
        _resultOpen ||
        _settingsOpen ||
        _savePanelOpen ||
        _toolbarHit)
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
    if (!_dragging ||
        _capturing ||
        _resultOpen ||
        _settingsOpen ||
        _savePanelOpen ||
        _toolbarHit)
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
    final region = _region;
    if (region == null ||
        region.width < _minSelection ||
        region.height < _minSelection) {
      return;
    }
    if (_scrollMode) {
      // 长截图：选区确定后直接开拼，不弹工具栏。
      _scrollMode = false;
      unawaited(_startScrollCapture());
      return;
    }
    // 普通模式：选区一确定就在后台预定抓帧，这样点复制/保存/置顶时直接命中
    // 缓存，不用再藏一次浮层重截。
    unawaited(_captureNow());
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

  Future<void> _begin() async {
    if (!mounted || _visible || _beginBusy) return;
    _beginBusy = true;
    DenialScreenshotEditorBus.instance.suppressAutoOpen.value = true;
    // 长截图模式：选区确定后直接滚动拼接。
    _scrollMode = CaptureFlowBus.instance.scrollMode;
    CaptureFlowBus.instance.scrollMode = false;
    try {
      // 先抓关键帧（这拍浮层还没出现，画面是干净的），再显示压暗/选区浮层。
      await _loadKeyFrame();
    } on Object {
      // 关键帧抓不到就空着，之后走藏浮层重抓的兜底。
    }
    if (!mounted) return;
    setState(() {
      _visible = true;
      _capturing = false;
      _captureHidden = false;
      _region = null;
      _capturedFile = null;
      _capturedBytes = null;
      _capturedRect = null;
      _resultOpen = false;
      _resultBusy = false;
      _resultRegions = const [];
      _settingsOpen = false;
      _savePanelOpen = false;
      _resultWindowHeight = null;
    });
    _beginBusy = false;
  }

  /// 鼠标被合成进 grim 的整屏帧里的包围盒大小（输出逻辑像素）。
  static const double _keyCursorBoxLogical = 36.0;

  /// 借用 shell 藏好光标后、grim 之前留给合成的一拍时长。太小 grim 可能仍
  /// 抓到含光标的旧帧（尤其静态画面这一拍没重绘），太大拖慢启动；当前取
  /// ~1.5 帧，按实测再调。
  static const Duration _cursorHideSettle = Duration(milliseconds: 24);

  /// 用 grim 抓整屏作为关键帧并解码。为了让抓到的画面天生不含软件光标，
  /// 先借用 shell 自己的隐藏光标信号（把 `screenshotSelectionProvider` 置为
  /// `preparing` 相 → shell 这一拍不画光标），等一拍合成出无光标画面后再 grim，
  /// 抓完立刻恢复光标。若借不到（已有原生截图在跑，`prepare` 返回 false）就
  /// 退回老办法：抓到后在像素层把光标抹掉。指针位置在 grim 一启动就读，抓帧
  /// 有延迟，等解码后再读会滞后。
  Future<void> _loadKeyFrame() async {
    Uint8List? bytes;
    Offset? cursorAtCapture;
    final hideId = _beginCursorHide();
    if (hideId != null) {
      // 给 shell 一拍时间真正合成出无光标的帧，否则 grim 仍可能抓到旧帧。
      await Future<void>.delayed(_cursorHideSettle);
    }
    try {
      final process = await Process.start('grim', [
        '-t',
        'png',
        '-',
      ], environment: childProcessEnvironment());
      cursorAtCapture = _cursorPosition.value;
      final stdout = BytesBuilder(copy: false);
      final stderr = BytesBuilder(copy: false);
      process.stdout.listen(stdout.add);
      process.stderr.listen(stderr.add);
      final code = await process.exitCode.timeout(
        const Duration(seconds: 4),
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
      if (code == 0 && stdout.length > 0) {
        bytes = stdout.takeBytes();
      }
    } on Object {
      bytes = null;
    } finally {
      _endCursorHide(hideId);
    }
    if (bytes == null || bytes.isEmpty) {
      _disposeKeyFrame();
      return;
    }
    ui.Image? image;
    if (hideId != null) {
      // 主路径：画面本就无光标、不抹除，直接把 PNG 解成 ui.Image 即可，
      // 省掉读回 rawRgba 再重编码这两趟全屏。
      image = await _decodePngToImage(bytes);
    } else {
      // 回退：grim 抓到了光标，需在像素层抹掉，只能走 rawRgba 往返。
      final rgba = await _decodeRgbaBytes(bytes);
      if (rgba != null) {
        _eraseKeyCursor(rgba.$1, rgba.$2, rgba.$3, cursorAtCapture);
        image = await _rgbaToImage(rgba.$1, rgba.$2, rgba.$3);
      }
    }
    if (image == null) {
      _disposeKeyFrame();
      return;
    }
    final previous = _keyFrame;
    _keyFrame = image;
    previous?.dispose();
  }

  /// PNG 一次性解码成 ui.Image，供「已藏光标、无需抹除」的关键帧路径使用。
  static Future<ui.Image?> _decodePngToImage(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } on Object {
      return null;
    }
  }

  static int _cursorHideSeq = 0;

  /// 请求 shell 进入「截图准备」相以隐藏软件光标；成功返回 requestId，
  /// 借不到（已有原生会话）返回 null。
  int? _beginCursorHide() {
    try {
      final id = ++_cursorHideSeq;
      final prepared = ref
          .read(screenshotSelectionProvider.notifier)
          .prepare(id);
      return prepared ? id : null;
    } on Object {
      return null;
    }
  }

  /// 结束隐藏会话、恢复光标。幂等：[id] 为 null 时什么都不做。
  void _endCursorHide(int? id) {
    if (id == null) return;
    try {
      ref.read(screenshotSelectionProvider.notifier).done(id);
    } on Object {
      // 恢复失败不致命：下一次抓取/交互会重绘光标。
    }
  }

  /// 整屏关键帧里抹掉鼠标：关键帧覆盖整个输出，指针逻辑坐标即像素坐标，
  /// 块大小不再缩放（scale=1）。
  void _eraseKeyCursor(Uint8List rgba, int width, int height, Offset? cursor) {
    if (cursor == null) return;
    final box = _keyCursorBoxLogical.ceil();
    if (cursor.dx + box < 0 ||
        cursor.dx > width ||
        cursor.dy + box < 0 ||
        cursor.dy > height) {
      return;
    }
    const pad = 4;
    final px = (cursor.dx - pad)
        .floor()
        .clamp(0, math.max(0, width - 1))
        .toInt();
    final py = (cursor.dy - pad)
        .floor()
        .clamp(0, math.max(0, height - 1))
        .toInt();
    eraseRegionInPlace(rgba, width, height, px, py, box + pad, box + pad);
  }

  static Future<(Uint8List, int, int)?> _decodeRgbaBytes(
    Uint8List bytes,
  ) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      final data = await frame.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      final width = frame.image.width;
      final height = frame.image.height;
      frame.image.dispose();
      if (data == null) return null;
      return (data.buffer.asUint8List(), width, height);
    } on Object {
      return null;
    }
  }

  static Future<ui.Image?> _rgbaToImage(
    Uint8List rgba,
    int width,
    int height,
  ) async {
    try {
      final descriptor = await ui.ImageDescriptor.raw(
        await ui.ImmutableBuffer.fromUint8List(rgba),
        width: width,
        height: height,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      final codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      codec.dispose();
      descriptor.dispose();
      return frame.image;
    } on Object {
      return null;
    }
  }

  void _close() {
    DenialScreenshotEditorBus.instance.suppressAutoOpen.value = false;
    _disposeKeyFrame();
    if (!mounted) return;
    setState(() {
      _visible = false;
      _capturing = false;
      _captureHidden = false;
      _region = null;
      _capturedFile = null;
      _capturedBytes = null;
      _capturedRect = null;
      _resultOpen = false;
      _resultBusy = false;
      _resultRegions = const [];
      _settingsOpen = false;
      _savePanelOpen = false;
      _resultWindowHeight = null;
    });
  }

  void _disposeKeyFrame() {
    final frame = _keyFrame;
    _keyFrame = null;
    frame?.dispose();
  }

  /// 抓取当前选区。[restore] 为 false 时抓完仍保持隐藏，交由调用方直接
  /// [_close] 或展开面板，避免浮层先弹回来再消失的闪烁。
  Future<({File file, Uint8List bytes})?> _captureNow({bool restore = true}) {
    final inflight = _inflightCapture;
    if (inflight != null) return inflight;
    if (_capturing) return Future.value(null);
    final region = _region;
    if (region == null ||
        region.width < _minSelection ||
        region.height < _minSelection) {
      return Future.value(null);
    }
    if (_capturedBytes != null &&
        _capturedFile != null &&
        _capturedRect == region) {
      return Future.value((file: _capturedFile!, bytes: _capturedBytes!));
    }
    final future = _captureFromKey(region: region, restore: restore);
    _inflightCapture = future;
    future.whenComplete(() {
      if (identical(_inflightCapture, future)) _inflightCapture = null;
    });
    return future;
  }

  /// 首选路径：直接从触发时抓好的关键帧裁出选区，不藏浮层、不经 grim。
  Future<({File file, Uint8List bytes})?> _captureFromKey({
    required Rect region,
    required bool restore,
  }) async {
    if (_keyFrame == null) {
      // 关键帧没抓到（grim 失败或还没就绪）才退回藏浮层实时抓。
      return _doCapture(region: region, restore: restore);
    }
    Uint8List? bytes;
    try {
      bytes = await _cropKeyFrame(region);
    } on Object {
      bytes = null;
    }
    if (bytes == null || bytes.isEmpty) {
      PinCardBus.instance.showToast('截取失败，请重试');
      if (mounted) setState(() => _captureHidden = false);
      return null;
    }
    final file = await _writeCapture(region, bytes);
    if (file == null) {
      PinCardBus.instance.showToast('截取失败，请重试');
      return null;
    }
    return (file: file, bytes: bytes);
  }

  /// 从关键帧裁出选区矩形并编码成 PNG。
  Future<Uint8List?> _cropKeyFrame(Rect region) async {
    final full = _keyFrame;
    if (full == null) return null;
    var src = Rect.fromLTRB(
      region.left,
      region.top,
      region.right,
      region.bottom,
    );
    if (region.width > _edgeInset * 2 + _minSelection &&
        region.height > _edgeInset * 2 + _minSelection) {
      src = src.deflate(_edgeInset);
    }
    final left = src.left.clamp(0.0, full.width.toDouble()).toDouble();
    final top = src.top.clamp(0.0, full.height.toDouble()).toDouble();
    final right = src.right.clamp(0.0, full.width.toDouble()).toDouble();
    final bottom = src.bottom.clamp(0.0, full.height.toDouble()).toDouble();
    final width = math.max(1, (right - left).round());
    final height = math.max(1, (bottom - top).round());
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      full,
      Rect.fromLTRB(left, top, right, bottom),
      Offset.zero & Size(width.toDouble(), height.toDouble()),
      Paint()..filterQuality = FilterQuality.none,
    );
    final cropped = await recorder.endRecording().toImage(width, height);
    try {
      final data = await cropped.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } finally {
      cropped.dispose();
    }
  }

  static int _captureSeq = 0;

  /// 把选区 PNG 写到临时目录，并更新 [_capturedFile]/[_capturedBytes] 缓存。
  Future<File?> _writeCapture(Rect region, Uint8List bytes) async {
    try {
      final directory = Directory('$_dataDir/selection-captures');
      directory.createSync(recursive: true);
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final path = '${directory.path}/capture-$stamp-${_captureSeq++}.png';
      final file = File(path);
      await file.writeAsBytes(bytes, flush: true);
      _capturedFile = file;
      _capturedBytes = bytes;
      _capturedRect = region;
      return file;
    } on Object {
      return null;
    }
  }

  Future<({File file, Uint8List bytes})?> _doCapture({
    required Rect region,
    required bool restore,
  }) async {
    setState(() {
      _capturing = true;
      _captureHidden = true;
    });
    // 遮罩/浮层藏掉一拍再截，grim 抓的是合成帧，会连压暗层一起抓到。
    await Future<void>.delayed(_hideDelay);
    var captureRect = region;
    if (region.width > _edgeInset * 2 + _minSelection &&
        region.height > _edgeInset * 2 + _minSelection) {
      captureRect = region.deflate(_edgeInset);
    }
    final geometry =
        '${captureRect.left.round()},${captureRect.top.round()} '
        '${captureRect.width.round()}x${captureRect.height.round()}';
    Uint8List? bytes;
    try {
      final process = await Process.start('grim', [
        '-g',
        geometry,
        '-t',
        'png',
        '-',
      ], environment: childProcessEnvironment());
      final stdout = <int>[];
      final stderr = <int>[];
      process.stdout.listen((chunk) => stdout.addAll(chunk));
      process.stderr.listen((chunk) => stderr.addAll(chunk));
      final code = await process.exitCode.timeout(
        const Duration(seconds: 4),
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
      if (code == 0 && stdout.isNotEmpty) {
        bytes = Uint8List.fromList(stdout);
      } else {
        bytes = null;
      }
    } on Object {
      bytes = null;
    }
    if (mounted) {
      setState(() {
        _capturing = false;
        // 成功且 restore=false 时保持隐藏（交由调用方关闭或展开面板）；
        // 其余情况（失败，或 restore=true）都要把浮层恢复出来。
        if (restore || bytes == null || bytes.isEmpty) {
          _captureHidden = false;
        }
      });
    }
    if (bytes == null || bytes.isEmpty) {
      PinCardBus.instance.showToast('截取失败，请重试');
      return null;
    }
    final file = await _writeCapture(region, bytes);
    if (file == null) {
      PinCardBus.instance.showToast('截取失败，请重试');
      return null;
    }
    return (file: file, bytes: bytes);
  }

  String _targetLanguage() {
    final configured = _settings.translateTarget;
    if (configured != 'system') return configured;
    return View.of(context).platformDispatcher.locale.languageCode;
  }

  Future<void> _runText(String mode) async {
    final captured = await _captureNow(restore: false);
    if (captured == null) return;
    if (!await _translateService.isReady()) {
      if (mounted) setState(() => _captureHidden = false);
      PinCardBus.instance.showToast('翻译组件未安装，请先在编辑器设置中安装');
      return;
    }
    setState(() {
      _captureHidden = false;
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
    final captured = await _captureNow(restore: false);
    if (captured == null) return;
    DenialScreenshotEditorBus.instance
        .openBytes(captured.bytes, path: captured.file.path);
    _close();
  }

  Future<void> _copyImage() async {
    final captured = await _captureNow(restore: false);
    if (captured == null) return;
    final ok = await copyPngToClipboard(captured.bytes);
    if (!mounted) return;
    if (ok) {
      PinCardBus.instance.showToast('已复制图片到剪贴板');
      _close();
    } else {
      setState(() => _captureHidden = false);
      PinCardBus.instance.showToast('复制失败（缺 wl-copy / xclip）');
    }
  }

  /// 保存：先在选区浮层里展开内嵌的保存面板（参照设置面板样式），由用户
  /// 挑目录、填文件名，确认后再写盘——不再拉起外部路径对话框。
  Future<void> _saveImage() async {
    final captured = await _captureNow(restore: false);
    if (captured == null) return;
    if (!mounted) return;
    setState(() {
      _captureHidden = false;
      _settingsOpen = false;
      _resultOpen = false;
      _savePanelOpen = true;
    });
  }

  /// 保存面板确认路径：抓取当前选区并写到该路径。
  Future<void> _confirmSave(String path) async {
    final captured = await _captureNow(restore: false);
    if (captured == null) return;
    try {
      await File(path).writeAsBytes(captured.bytes, flush: true);
    } on Object {
      if (mounted) setState(() => _captureHidden = false);
      PinCardBus.instance.showToast('保存失败');
      return;
    }
    if (!mounted) return;
    final slash = path.lastIndexOf('/');
    setState(() {
      _captureHidden = false;
      _savePanelOpen = false;
      if (slash > 0) {
        _saveDirectory = path.substring(0, slash);
        final name = path.substring(slash + 1);
        if (name.isNotEmpty) _saveFileName = name;
      }
    });
    PinCardBus.instance.showToast('已保存：$path');
  }

  Future<void> _pinImage() async {
    final captured = await _captureNow(restore: false);
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
    // 等遮罩藏好再开始连拍，免得第一帧带着压暗层。同时等 shell 交还键盘
    // 焦点给目标客户端，注入的滚动键才会落到被截的窗口上。
    await Future<void>.delayed(_hideDelay);
    final speed = _settings.autoScrollSpeed;
    final autoDelay = switch (speed) {
      'fast' => const Duration(milliseconds: 150),
      'slow' => const Duration(milliseconds: 400),
      _ => const Duration(milliseconds: 250),
    };
    await ScrollCaptureManager.instance.start(
      region,
      injector: _autoScrollInjector(),
      cursor: _cursorPosition,
      autoDelay: autoDelay,
    );
  }

  /// 自动滚动模式的注入器：向聚焦客户端发一档滚动键；关闭时返回 null
  /// 走手动模式。默认走 denial 桥接的虚拟键盘，也可切换成外部的 wtype /
  /// ydotool（需系统已安装，未装时注入会静默失效并因停滞自动收尾）。
  ScrollInjector? _autoScrollInjector() {
    if (!_settings.autoScroll) return null;
    final key = _settings.autoScrollKey;
    switch (_settings.scrollInjector) {
      case 'wtype':
        final keysym = key == 'space' ? 'space' : 'Down';
        return () => unawaited(_runInjectTool('wtype', ['-k', keysym]));
      case 'ydotool':
        // Linux 输入事件码：KEY_SPACE=57，KEY_DOWN=108。
        final code = key == 'space' ? 57 : 108;
        return () =>
            unawaited(_runInjectTool('ydotool', ['key', '$code:1', '$code:0']));
      default:
        final bridge = ref.read(denialBridgeProvider);
        final name = key == 'space' ? 'space' : 'Down';
        return () => bridge.sendKeyboardKey(name);
    }
  }

  /// 调外部注入工具发一次滚动键。失败（未安装 / 无权限 / 服务未起）时静默
  /// 忽略，自动模式随后会因连续多档页面没动而正常收尾。
  Future<void> _runInjectTool(String executable, List<String> arguments) async {
    try {
      await Process.run(
        executable,
        arguments,
        environment: childProcessEnvironment(),
      );
    } on Object {
      // 忽略：交由自动模式的停滞判定收尾。
    }
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
/// 把触发时抓的整屏关键帧铺满选区浮层作为背景。
class _KeyFramePainter extends CustomPainter {
  _KeyFramePainter({required this.image});

  final ui.Image image;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.none,
    );
  }

  @override
  bool shouldRepaint(covariant _KeyFramePainter oldDelegate) =>
      oldDelegate.image != image;
}

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
