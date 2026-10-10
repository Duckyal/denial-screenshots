import 'dart:async';
import 'dart:typed_data';

import 'package:denial_flutter_sdk/input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'clipboard.dart';
import 'clipboard_read.dart';
import 'scroll_capture.dart';
import 'editor/commands.dart';
import 'editor_bus.dart';

/// 钉住卡片的内容：图片（可带标注命令，回到编辑器继续画）或纯文本。
sealed class PinContent {
  const PinContent();
}

final class PinImage extends PinContent {
  const PinImage({
    required this.bytes,
    this.commands = const <DrawCommand>[],
    this.sourceBytes,
  });

  /// 卡片上显示的 PNG（编辑器钉住时是裁好边的成品图）。
  final Uint8List bytes;

  /// 编辑器导出的标注命令；非空且带底图时双击卡片可回编辑器继续画。
  final List<DrawCommand> commands;
  final Uint8List? sourceBytes;
}

final class PinText extends PinContent {
  const PinText(this.text);

  final String text;
}

/// 一张钉在桌面上的卡片；[id] 让宿主为每张卡维护各自的位置与尺寸。
final class PinCard {
  const PinCard({required this.id, required this.content});

  final int id;
  final PinContent content;
}

/// 钉住卡片总线：编辑器「置顶显示」与 Super+C 剪贴板钉住都往这里塞卡片，
/// 钉住 surface 监听并画成桌面上的浮动小窗；一次可以钉多张。
final class PinCardBus {
  PinCardBus._();

  static final PinCardBus instance = PinCardBus._();

  final ValueNotifier<List<PinCard>> cards = ValueNotifier(const []);

  /// 短暂提示（剪贴板为空等），几秒后自动消失。
  final ValueNotifier<String?> toast = ValueNotifier<String?>(null);
  Timer? _toastTimer;
  int _nextId = 0;

  /// 钉一张新卡片（编辑器置顶、剪贴板钉住都走这里，叠加不互斥）。
  void add(PinContent content) {
    cards.value = [...cards.value, PinCard(id: _nextId++, content: content)];
  }

  void remove(int id) {
    cards.value = cards.value.where((card) => card.id != id).toList();
  }

  void showToast(String message) {
    toast.value = message;
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(milliseconds: 1800), () {
      toast.value = null;
    });
  }

  /// Super+C：读剪贴板（图片优先，其次文字）钉成新卡片。
  Future<void> pinFromClipboard() async {
    final content = await readClipboardPinContent();
    if (content == null) {
      showToast('剪贴板里没有可钉住的图片或文字');
      return;
    }
    if (content is ClipboardImage) {
      add(PinImage(bytes: content.bytes));
    } else if (content is ClipboardText) {
      add(PinText(content.text));
    }
  }
}

/// 钉住的浮动卡片群。
///
/// surface 本身占满输出（这样卡片可以在屏幕内自由拖动），但只有每张卡片
/// 区域注册输入，其余部分把指针与键盘交还给桌面。
class PinnedShotHost extends ConsumerStatefulWidget {
  const PinnedShotHost({super.key});

  @override
  ConsumerState<PinnedShotHost> createState() => _PinnedShotHostState();
}

class _CardPlacement {
  _CardPlacement({required this.offset});

  Offset offset;

  /// 设定/测量到的卡片尺寸；null 表示还没测量过（首帧由内容决定尺寸）。
  Size? size;
}

class _PinnedShotHostState extends ConsumerState<PinnedShotHost> {
  final Map<int, _CardPlacement> _placements = {};

  static const double _defaultOffset = 80;
  static const double _cascadeStep = 28;
  static const double _minWidth = 120;
  static const double _minHeight = 90;

  @override
  void initState() {
    super.initState();
    PinCardBus.instance.cards.addListener(_syncPlacements);
    _syncPlacements();
  }

  @override
  void dispose() {
    PinCardBus.instance.cards.removeListener(_syncPlacements);
    super.dispose();
  }

  /// 卡片列表变化：给新卡片发层叠位置，清掉已关闭卡片的摆放状态。
  void _syncPlacements() {
    final cards = PinCardBus.instance.cards.value;
    var changed = false;
    for (final card in cards) {
      if (!_placements.containsKey(card.id)) {
        final n = _placements.length;
        final step = (n % 6) * _cascadeStep;
        _placements[card.id] = _CardPlacement(
          offset: Offset(_defaultOffset + step, _defaultOffset + step),
        );
        changed = true;
      }
    }
    final closed = _placements.keys
        .where((id) => !cards.any((card) => card.id == id))
        .toList();
    for (final id in closed) {
      _placements.remove(id);
      changed = true;
    }
    if (changed && mounted) setState(() {});
  }

  /// 卡片默认宽度：按屏幕短边比例给一个和原来 360 相当的初始值。
  double _defaultWidth(double minExtent) =>
      (minExtent * 0.4).clamp(200.0, 420.0).toDouble();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<PinCard>>(
      valueListenable: PinCardBus.instance.cards,
      builder: (BuildContext context, List<PinCard> cards, Widget? child) {
        return Stack(
          children: <Widget>[
            for (final card in cards) _buildCard(card),
            _buildScrollCaptureHud(),
            _buildToast(),
          ],
        );
      },
    );
  }

  Widget _buildCard(PinCard card) {
    final placement = _placements[card.id];
    if (placement == null) return const SizedBox.shrink();
    return Positioned(
      left: placement.offset.dx,
      top: placement.offset.dy,
      child: ShellInputRegion(
        debugLabel: 'Denial pinned screenshot #${card.id}',
        active: true,
        pointerPolicy: ShellPointerPolicy.childBounds,
        keyboardPolicy: ShellKeyboardPolicy.none,
        compositorPolicy: ShellCompositorPolicy.normal,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final minExtent = constraints.biggest.shortestSide.isFinite
                ? constraints.biggest.shortestSide
                : 900.0;
            final width = placement.size?.width ?? _defaultWidth(minExtent);
            return _PinCardView(
              key: ValueKey(card.id),
              card: card,
              width: width,
              height: placement.size?.height,
              onNaturalSize: (Size size) => _setNaturalSize(card.id, size),
              onDrag: (Offset delta) => _move(card.id, delta),
              onResize: (Alignment grip, Offset delta) =>
                  _resize(card.id, grip, delta),
              onContinue: () => _continueEditing(card),
              onClose: () => PinCardBus.instance.remove(card.id),
            );
          },
        ),
      ),
    );
  }

  /// 长截图会话 HUD：吸顶胶囊，点击结束会话（编辑器已关，桌面可正常
  /// 滚动操作；输入只占胶囊范围）。
  Widget _buildScrollCaptureHud() {
    return ValueListenableBuilder<bool>(
      valueListenable: ScrollCaptureManager.instance.active,
      builder: (BuildContext context, bool active, Widget? child) {
        if (!active) return const SizedBox.shrink();
        return Positioned(
          left: 0,
          right: 0,
          top: 20,
          child: Center(
            child: ShellInputRegion(
              debugLabel: 'Denial scroll capture hud',
              pointerPolicy: ShellPointerPolicy.childBounds,
              keyboardPolicy: ShellKeyboardPolicy.none,
              compositorPolicy: ShellCompositorPolicy.normal,
              child: GestureDetector(
                onTap: () => ScrollCaptureManager.instance.stop(),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.82),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: Colors.blue.withValues(alpha: 0.7),
                    ),
                  ),
                  child: const Text(
                    '长截图进行中：滚动页面，点此或再按 Super+R 结束',
                    style: TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildToast() {
    return ValueListenableBuilder<String?>(
      valueListenable: PinCardBus.instance.toast,
      builder: (BuildContext context, String? message, Widget? child) {
        return Positioned(
          left: 0,
          right: 0,
          bottom: 56,
          child: IgnorePointer(
            child: Center(
              child: AnimatedOpacity(
                opacity: message == null ? 0 : 1,
                duration: const Duration(milliseconds: 160),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.82),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    message ?? '',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 首帧后把卡片的自然尺寸记下来，作为边缘缩放的基准；顺带夹到视口内。
  ///
  /// 图片是异步解码的：首帧量到的必然是零尺寸，必须等内容真正画出来
  /// （高度非 0）再量，否则卡片会被定成 0 高，只剩浮在外面的关闭按钮、
  /// 且输入区域为空什么都点不到。钳制必须锁定宽高比：只夹一个维度会让
  /// 卡片比例偏离图片，图片只能 contain 缩进卡片里，四周露出底色空边。
  void _setNaturalSize(int id, Size natural) {
    final placement = _placements[id];
    if (!mounted || placement == null || placement.size != null) return;
    if (natural.width < 1 || natural.height < 1) return;
    final viewport = MediaQuery.maybeOf(context)?.size;
    var size = natural;
    if (viewport != null && !viewport.isEmpty) {
      final aspect = size.width / size.height;
      final maxWidth = (viewport.width - placement.offset.dx - 16).clamp(
        _minWidth,
        viewport.width,
      );
      final maxHeight = (viewport.height - placement.offset.dy - 16).clamp(
        _minHeight,
        viewport.height,
      );
      var width = size.width.clamp(_minWidth, maxWidth.toDouble());
      var height = width / aspect;
      if (height > maxHeight) {
        height = maxHeight;
        width = height * aspect;
      }
      size = Size(width, height);
    }
    setState(() => placement.size = size);
  }

  void _move(int id, Offset delta) {
    final placement = _placements[id];
    if (placement == null) return;
    setState(() => placement.offset = placement.offset + delta);
  }

  /// 边缘/角落手柄拖动：**锁定宽高比**缩放（像图像编辑器那样不变形）。
  ///
  /// 角手柄取位移更大的那根轴驱动，边手柄用该边对应的轴驱动；另一维按比例
  /// 推出。锚点固定对边/对角：拖左/上边时同时移动位置，拖右边/下边只改尺寸。
  void _resize(int id, Alignment grip, Offset delta) {
    final placement = _placements[id];
    final base = placement?.size;
    if (placement == null ||
        base == null ||
        base.width <= 0 ||
        base.height <= 0) {
      return;
    }
    final aspect = base.width / base.height;

    // 1) 每类手柄先算出「被拖的轴」想要的新尺寸。
    double? wantedWidth;
    if (grip.x > 0) {
      wantedWidth = base.width + delta.dx;
    } else if (grip.x < 0) {
      wantedWidth = base.width - delta.dx;
    }
    double? wantedHeight;
    if (grip.y > 0) {
      wantedHeight = base.height + delta.dy;
    } else if (grip.y < 0) {
      wantedHeight = base.height - delta.dy;
    }

    // 2) 角手柄两个轴都动了：选位移更大的那根轴决定缩放比例，避免抖动。
    double scale;
    if (wantedWidth != null && wantedHeight != null) {
      final byWidth = wantedWidth / base.width;
      final byHeight = wantedHeight / base.height;
      scale = byWidth.abs() >= byHeight.abs() ? byWidth : byHeight;
    } else if (wantedWidth != null) {
      scale = wantedWidth / base.width;
    } else if (wantedHeight != null) {
      scale = wantedHeight / base.height;
    } else {
      return;
    }

    // 3) 复合成新尺寸并夹到最小值（宽度下限保证图片仍有意义，高度下限保证
    //    关闭按钮可见）。夹取后按缩放后的比例反推另一维。
    var width = base.width * scale;
    var height = base.height * scale;
    final clampedWidth = width.clamp(_minWidth, double.infinity);
    final clampedHeight = height.clamp(_minHeight, double.infinity);
    if (clampedWidth != width) {
      width = clampedWidth;
      height = width / aspect;
    } else if (clampedHeight != height) {
      height = clampedHeight;
      width = height * aspect;
    }

    // 4) 锚定：拖左/上边时把尺寸变化同步到位置，保持对边不动。
    var offset = placement.offset;
    if (grip.x < 0) offset = offset + Offset(base.width - width, 0);
    if (grip.y < 0) offset = offset + Offset(0, base.height - height);

    setState(() {
      placement.offset = offset;
      placement.size = Size(width, height);
    });
  }

  /// 双击图片卡回到编辑器：编辑器钉的卡带标注命令，恢复底图+命令继续画；
  /// Super+S 钉的剪贴板图没有命令，就把钉住图本身当底图开进编辑器。
  void _continueEditing(PinCard card) {
    final image = card.content;
    if (image is! PinImage) return;
    final source = image.sourceBytes;
    final hasAnnotations =
        image.commands.isNotEmpty && source != null && source.isNotEmpty;
    PinCardBus.instance.remove(card.id);
    EditorReentryBus.instance.resume(
      EditorResumeRequest(
        imageBytes: hasAnnotations ? source : image.bytes,
        commands: hasAnnotations ? image.commands : const <DrawCommand>[],
      ),
    );
  }
}

/// 单张卡片：量自然尺寸、接拖动/双击手势，把内容画出来。
class _PinCardView extends StatefulWidget {
  const _PinCardView({
    super.key,
    required this.card,
    required this.width,
    this.height,
    required this.onNaturalSize,
    required this.onDrag,
    required this.onResize,
    required this.onContinue,
    required this.onClose,
  });

  final PinCard card;
  final double width;
  final double? height;
  final ValueChanged<Size> onNaturalSize;
  final ValueChanged<Offset> onDrag;
  final void Function(Alignment grip, Offset delta) onResize;
  final VoidCallback? onContinue;
  final VoidCallback onClose;

  @override
  State<_PinCardView> createState() => _PinCardViewState();
}

class _PinCardViewState extends State<_PinCardView> {
  /// 用来在首帧量出卡片的自然尺寸，之后所有缩放都以它为基准。
  final GlobalKey _contentKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  void _measure() {
    if (!mounted) return;
    final box = _contentKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null ||
        !box.hasSize ||
        box.size.width < 1 ||
        box.size.height < 1) {
      // 内容（图片）还在解码，等下一帧再量。
      WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
      return;
    }
    widget.onNaturalSize(box.size);
  }

  @override
  Widget build(BuildContext context) {
    final content = widget.card.content;
    // 图片卡：整卡拖动 + 双击进编辑器；文字卡拖动只挂在顶部握把条上，
    // 正文让给划选复制。
    return GestureDetector(
      onPanUpdate: content is PinImage
          ? (DragUpdateDetails details) => widget.onDrag(details.delta)
          : null,
      onDoubleTap: content is PinImage ? widget.onContinue : null,
      child: switch (content) {
        final PinImage image => _PinnedImageCard(
          image: image,
          width: widget.width,
          height: widget.height,
          contentKey: _contentKey,
          onResize: widget.onResize,
          onClose: widget.onClose,
        ),
        final PinText text => _PinnedTextCard(
          text: text.text,
          contentKey: _contentKey,
          onDrag: widget.onDrag,
          onClose: widget.onClose,
        ),
      },
    );
  }
}

class _PinnedImageCard extends StatelessWidget {
  const _PinnedImageCard({
    required this.image,
    required this.width,
    this.height,
    required this.contentKey,
    required this.onResize,
    required this.onClose,
  });

  final PinImage image;
  final double width;
  final double? height;
  final GlobalKey contentKey;
  final void Function(Alignment grip, Offset delta) onResize;
  final VoidCallback onClose;

  /// 深色底：旧独立版原生浮窗用的就是近黑底，图片按比例居中，四周露出的
  /// 底色一致。
  static const Color _backdrop = Color(0xFF0F1419);

  @override
  Widget build(BuildContext context) {
    // 图片铺满整卡，不预留按钮栏，也不留底色空边——按钮浮在图上。卡片
    // 尺寸恒按图片比例锁定；首次渲染（高度未定）用 contain 由图片撑出
    // 自然高度，尺寸定下后用 cover 铺满，万一有亚像素误差也只会裁掉
    // 半个像素，绝不会露出底色条。
    final content = ColoredBox(
      color: _backdrop,
      child: Image.memory(
        image.bytes,
        key: contentKey,
        fit: height == null ? BoxFit.contain : BoxFit.cover,
        filterQuality: FilterQuality.high,
        errorBuilder: (context, error, stackTrace) => const SizedBox(
          width: 160,
          height: 120,
          child: Icon(Icons.broken_image_outlined, color: Colors.white38),
        ),
      ),
    );
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 高度未定时由图片决定卡片尺寸；定了就铺满。
          if (height != null) Positioned.fill(child: content) else content,
          // 右上角：外圈内叉的关闭图标；双击整卡进编辑器。
          Positioned(
            top: 6,
            right: 6,
            child: _PinCloseButton(onTap: onClose, tooltip: '关闭（双击浮窗打开编辑）'),
          ),
          // 窗口式边缘/角落缩放手柄。右上角留给关闭按钮，从手柄列表里去掉。
          Positioned.fill(child: _PinnedResizeHandles(onResize: onResize)),
        ],
      ),
    );
  }
}

class _PinnedTextCard extends StatelessWidget {
  const _PinnedTextCard({
    required this.text,
    required this.contentKey,
    required this.onDrag,
    required this.onClose,
  });

  final String text;
  final GlobalKey contentKey;
  final ValueChanged<Offset> onDrag;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    // 浅色便签卡：Snipaste 的文字钉住观感。正文用 SelectableText 支持
    // 划选 + 右键菜单复制；移动卡片走顶部握把条，不和划选抢手势。
    return Container(
      constraints: BoxConstraints(
        maxWidth: 420,
        maxHeight: viewport.height * 0.7,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F6F1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.black.withValues(alpha: 0.18)),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: (details) => onDrag(details.delta),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.move,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 2,
                        horizontal: 2,
                      ),
                      child: Icon(
                        Icons.drag_indicator,
                        size: 18,
                        color: Colors.black.withValues(alpha: 0.35),
                      ),
                    ),
                  ),
                ),
                const Spacer(),
                Tooltip(
                  message: '复制全部',
                  child: GestureDetector(
                    onTap: () async {
                      final copied = await copyTextToClipboard(text);
                      PinCardBus.instance.showToast(copied ? '已复制文字' : '复制失败');
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        Icons.content_copy,
                        size: 16,
                        color: Colors.black.withValues(alpha: 0.55),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _PinCloseButton(onTap: onClose, tooltip: '关闭'),
              ],
            ),
            const SizedBox(height: 4),
            Flexible(
              child: SingleChildScrollView(
                child: SelectableText(
                  text,
                  key: contentKey,
                  style: const TextStyle(
                    fontSize: 15,
                    height: 1.45,
                    color: Color(0xFF20242A),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 卡片四边与四角的缩放手柄。
///
/// 命中区必须落在卡片矩形内：`ShellInputRegion` 用 `childBounds` 只把指针
/// 路由到卡片范围，伸到卡片外的一半收不到事件。所以手柄用 [Align] 贴边布置
/// 在卡片内部。右上角让给「关闭」按钮，从手柄列表里去掉；边中点的手柄只占中间
/// 一小段。
class _PinnedResizeHandles extends StatelessWidget {
  const _PinnedResizeHandles({required this.onResize});

  final void Function(Alignment grip, Offset delta) onResize;

  static const List<(Alignment, MouseCursor)> _handles = [
    (Alignment.topLeft, SystemMouseCursors.resizeUpLeft),
    (Alignment.topCenter, SystemMouseCursors.resizeUp),
    (Alignment.centerLeft, SystemMouseCursors.resizeLeft),
    (Alignment.centerRight, SystemMouseCursors.resizeRight),
    (Alignment.bottomLeft, SystemMouseCursors.resizeDownLeft),
    (Alignment.bottomCenter, SystemMouseCursors.resizeDown),
    (Alignment.bottomRight, SystemMouseCursors.resizeDownRight),
  ];

  static bool _isCorner(Alignment grip) => grip.x != 0 && grip.y != 0;

  static double _width(Alignment grip) {
    if (_isCorner(grip)) return 22;
    return grip.y != 0 ? 44 : 14;
  }

  static double _height(Alignment grip) {
    if (_isCorner(grip)) return 22;
    return grip.y != 0 ? 14 : 44;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (final (grip, cursor) in _handles)
          Positioned.fill(
            child: Align(
              alignment: grip,
              child: _GripHitTarget(
                grip: grip,
                cursor: cursor,
                width: _width(grip),
                height: _height(grip),
                onResize: onResize,
              ),
            ),
          ),
      ],
    );
  }
}

class _GripHitTarget extends StatelessWidget {
  const _GripHitTarget({
    required this.grip,
    required this.cursor,
    required this.width,
    required this.height,
    required this.onResize,
  });

  final Alignment grip;
  final MouseCursor cursor;
  final double width;
  final double height;
  final void Function(Alignment grip, Offset delta) onResize;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: cursor,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (details) => onResize(grip, details.delta),
        child: SizedBox(width: width, height: height),
      ),
    );
  }
}

/// 浮在快照右上角的关闭按钮：半透明深色圆底 + 外圈内叉的图标。
class _PinCloseButton extends StatelessWidget {
  const _PinCloseButton({required this.onTap, this.tooltip = '关闭'});

  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.45),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.cancel_outlined,
            size: 18,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
