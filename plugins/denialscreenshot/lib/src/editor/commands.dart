import 'dart:math' as math;

import 'package:flutter/painting.dart' show TextPainter, TextSpan, TextStyle;

import 'dart:ui';

import 'tools.dart';

/// 图形对象当前实际占据的包围框。
///
/// 文字的字号 = strokeWidth * 4，改粗细后视觉范围随之变化，必须按当前
/// 字号重新排版测量；其他图形用创建时记录的 rect。
Rect commandDisplayBounds(DrawCommand command) {
  if (command.type == ScreenshotToolType.text) {
    // 拖框创建的文字：整个文本框就是它的占据范围（点框内任意位置都能
    // 选中/命中，与 PPT 文本框一致）。
    final box = command.textBox;
    if (box != null) return box;
    final painter = command.textLayout();
    return Rect.fromLTWH(
      command.start.dx,
      command.start.dy,
      painter.width,
      painter.height,
    );
  }
  return command.rect;
}

/// 画布上 [BoxFit.contain] 显示的图像实际占据的矩形。
///
/// 编辑器画布跟随窗口（平铺布局会给出各种比例），图像按 contain 居中，
/// 周围是透明留白；置顶快照必须裁到这个矩形，否则留白和选区边框会烙进
/// 悬浮卡里。
Rect displayedImageRect(
  Size canvasSize,
  double imageWidth,
  double imageHeight,
) {
  if (imageWidth <= 0 || imageHeight <= 0 || canvasSize.isEmpty) {
    return Offset.zero & canvasSize;
  }
  final imageAspect = imageWidth / imageHeight;
  final canvasAspect = canvasSize.width / canvasSize.height;
  double width;
  double height;
  if (imageAspect > canvasAspect) {
    width = canvasSize.width;
    height = width / imageAspect;
  } else {
    height = canvasSize.height;
    width = height * imageAspect;
  }
  return Rect.fromLTWH(
    (canvasSize.width - width) / 2,
    (canvasSize.height - height) / 2,
    width,
    height,
  );
}

class DrawCommand {
  final ScreenshotToolType type;
  final Offset start;
  final Offset end;
  final Path path;
  final String text;
  final Rect rect;
  final Color color;
  final double strokeWidth;
  final Color fillColor;
  final MaskStyle maskStyle;

  /// 文字排版的换行宽度（翻译落回画布时按蒙版宽度收紧，避免译文超出蒙版）。
  /// 默认不限宽，即手绘文字仍是一行。
  final double textMaxWidth;

  /// 拖框创建的文本框（PPT 式）：内容按框宽换行、字号随框自适应缩小，
  /// 并在框内水平、垂直居中；null = 点击创建的自由文字。
  final Rect? textBox;

  /// 文字字体族名称，空字符串表示使用默认字体。
  final String fontFamily;

  /// 文字命令的排版缓存。绘制与命中测试都用它，避免每帧重新 layout；
  /// 字号（strokeWidth * 4）、颜色或文本框变化时自动失效。
  TextPainter? _textLayout;
  double? _textLayoutFontSize;
  Color? _textLayoutColor;
  double? _textLayoutMaxWidth;
  Rect? _textLayoutBox;
  String? _textLayoutFontFamily;

  TextPainter textLayout() {
    final fontSize = strokeWidth * 4;
    final cached = _textLayout;
    if (cached != null &&
        _textLayoutFontSize == fontSize &&
        _textLayoutColor == color &&
        _textLayoutMaxWidth == textMaxWidth &&
        _textLayoutBox == textBox &&
        _textLayoutFontFamily == fontFamily) {
      return cached;
    }
    final painter = _layoutText(fontSize);
    _textLayout = painter;
    _textLayoutFontSize = fontSize;
    _textLayoutColor = color;
    _textLayoutMaxWidth = textMaxWidth;
    _textLayoutBox = textBox;
    _textLayoutFontFamily = fontFamily;
    return painter;
  }

  TextPainter _layoutText(double baseFontSize) {
    final box = textBox;
    // 文本框留一圈内边距，文字不贴框边（PPT 默认内边距观感）。
    final inner = box?.deflate(4);
    TextPainter build(double fontSize) => TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontFamily: fontFamily.isEmpty ? null : fontFamily,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: inner?.width ?? textMaxWidth);
    if (inner == null) return build(baseFontSize);
    // 字号随框自适应：装不下就按比例逐级缩小（不放大，框大不多占）。
    var fontSize = baseFontSize;
    var painter = build(fontSize);
    var attempts = 0;
    while ((painter.width > inner.width || painter.height > inner.height) &&
        fontSize > 7 &&
        attempts < 24) {
      final scale =
          math.min(
            inner.width / math.max(painter.width, 1),
            inner.height / math.max(painter.height, 1),
          ) *
          0.92;
      fontSize = (fontSize * scale).clamp(7.0, baseFontSize);
      painter = build(fontSize);
      attempts++;
    }
    return painter;
  }

  DrawCommand({
    required this.type,
    required this.start,
    required this.end,
    required this.path,
    this.text = '',
    required this.rect,
    this.color = const Color(0xffff0000),
    this.strokeWidth = 3,
    this.fillColor = const Color(0xffffffff),
    this.maskStyle = MaskStyle.solid,
    this.textMaxWidth = double.infinity,
    this.textBox,
    this.fontFamily = '',
  });

  /// 光标模式拖动选中对象（整体平移）。
  DrawCommand translated(Offset delta) {
    return DrawCommand(
      type: type,
      start: start + delta,
      end: end + delta,
      path: path.shift(delta),
      text: text,
      rect: rect.shift(delta),
      color: color,
      strokeWidth: strokeWidth,
      fillColor: fillColor,
      maskStyle: maskStyle,
      textMaxWidth: textMaxWidth,
      textBox: textBox?.shift(delta),
      fontFamily: fontFamily,
    );
  }

  /// 光标模式拖拽手柄改大小：盒子对象换包围框（文字同时改写文本框，框内
  /// 字号自适应）；直线/箭头换端点。用新实例返回，供撤销快照与重绘识别。
  DrawCommand resized({Rect? rect, Offset? start, Offset? end, Rect? textBox}) {
    return DrawCommand(
      type: type,
      start: start ?? this.start,
      end: end ?? this.end,
      path: path,
      text: text,
      rect: rect ?? this.rect,
      color: color,
      strokeWidth: strokeWidth,
      fillColor: fillColor,
      maskStyle: maskStyle,
      textMaxWidth: textMaxWidth,
      textBox: textBox ?? this.textBox,
      fontFamily: fontFamily,
    );
  }

  /// 光标模式下编辑选中对象（文字内容 / 颜色 / 粗细 / 蒙版填充色 / 包围框）。
  DrawCommand copyWith({
    Color? color,
    double? strokeWidth,
    Color? fillColor,
    Rect? rect,
    String? text,
    MaskStyle? maskStyle,
    String? fontFamily,
  }) {
    return DrawCommand(
      type: type,
      start: start,
      end: end,
      path: path,
      text: text ?? this.text,
      rect: rect ?? this.rect,
      color: color ?? this.color,
      strokeWidth: strokeWidth ?? this.strokeWidth,
      fillColor: fillColor ?? this.fillColor,
      maskStyle: maskStyle ?? this.maskStyle,
      // 不带上换行宽度，译文就会在改色/移动后散成一行。
      textMaxWidth: textMaxWidth,
      textBox: textBox,
      fontFamily: fontFamily ?? this.fontFamily,
    );
  }
}

/// 画笔与橡皮痕迹是编辑效果而非图形对象，不参与点击选中/拖动/整体删除，
/// 否则点击会删掉之前的橡皮命令，令已擦除的痕迹重新出现。
bool isEditableEffect(DrawCommand command) {
  return command.type == ScreenshotToolType.brush ||
      command.type == ScreenshotToolType.eraser;
}

/// 从最上层往下找到第一个可整体操作（光标模式拖动/编辑）的图形对象。
/// 蒙版不可拖动（蒙版是区域效果，移动会破坏语义）。
int? findManipulableCommandIndex(List<DrawCommand> commands, Offset position) {
  for (var i = commands.length - 1; i >= 0; i--) {
    final command = commands[i];
    if (command.type == ScreenshotToolType.mask) {
      continue;
    }
    if (commandDisplayBounds(command).inflate(12).contains(position)) {
      return i;
    }
  }
  return null;
}

/// 橡皮点击删除的图形对象目标，[radius] 是橡皮半径（随橡皮粗细调节）。
///
/// 只有图形对象参与点击删除。画笔/橡皮痕迹是编辑效果：笔迹走拖动像素
/// 擦除（BlendMode.clear），橡皮命令本身点击删除会让已擦掉的痕迹重新
/// 出现，两者都必须排除。空心图形（矩形/椭圆）只有描边附近才算命中，
/// 点内部空白不删；蒙版和文字是实心块，整块都算。
int? findEraserTargetIndex(
  List<DrawCommand> commands,
  Offset position,
  double radius,
) {
  for (var i = commands.length - 1; i >= 0; i--) {
    final command = commands[i];
    if (isEditableEffect(command)) {
      continue;
    }
    if (commandHits(command, position, radius)) {
      return i;
    }
  }
  return null;
}

/// 单个图形对象的命中判定，[radius] 是点击容差。
bool commandHits(DrawCommand command, Offset position, double radius) {
  switch (command.type) {
    case ScreenshotToolType.select:
    case ScreenshotToolType.brush:
    case ScreenshotToolType.eraser:
      return false;
    case ScreenshotToolType.mask:
      return command.rect.inflate(radius).contains(position);
    case ScreenshotToolType.text:
      return commandDisplayBounds(command).inflate(radius).contains(position);
    case ScreenshotToolType.rect:
      return _nearRectOutline(command.rect, position, radius);
    case ScreenshotToolType.circle:
      return _nearEllipseOutline(command.rect, position, radius);
    case ScreenshotToolType.line:
    case ScreenshotToolType.arrow:
      return _distanceToSegment(position, command.start, command.end) <= radius;
  }
}

bool _nearRectOutline(Rect rect, Offset position, double radius) {
  if (!rect.inflate(radius).contains(position)) {
    return false;
  }
  final inner = rect.deflate(radius);
  return !inner.contains(position);
}

bool _nearEllipseOutline(Rect rect, Offset position, double radius) {
  final a = rect.width / 2;
  final b = rect.height / 2;
  if (a <= 0 || b <= 0) {
    return false;
  }
  final dx = (position.dx - rect.center.dx) / a;
  final dy = (position.dy - rect.center.dy) / b;
  final normalized = math.sqrt(dx * dx + dy * dy);
  final tolerance = radius / math.min(a, b);
  return (normalized - 1).abs() <= tolerance;
}

double _distanceToSegment(Offset point, Offset start, Offset end) {
  final segment = end - start;
  final lengthSquared = segment.distanceSquared;
  if (lengthSquared == 0) {
    return (point - start).distance;
  }
  var t =
      ((point - start).dx * segment.dx + (point - start).dy * segment.dy) /
      lengthSquared;
  t = t.clamp(0.0, 1.0);
  return (point - start - segment * t).distance;
}

/// 光标模式选中对象后，可拖拽改变大小的手柄位置。盒子类对象（矩形/椭圆/
/// 文字/蒙版）用四角+四边共八个手柄；直线/箭头只有两端两个端点手柄。
enum ResizeHandle {
  topLeft,
  top,
  topRight,
  right,
  bottomRight,
  bottom,
  bottomLeft,
  left,
  lineStart,
  lineEnd,
}

bool _isLineLike(DrawCommand command) =>
    command.type == ScreenshotToolType.line ||
    command.type == ScreenshotToolType.arrow;

/// 选中对象的全部手柄坐标（world），供绘制与命中测试共用。
List<(ResizeHandle, Offset)> commandHandlePoints(DrawCommand command) {
  if (_isLineLike(command)) {
    return [
      (ResizeHandle.lineStart, command.start),
      (ResizeHandle.lineEnd, command.end),
    ];
  }
  final bounds = commandDisplayBounds(command);
  return [
    (ResizeHandle.topLeft, bounds.topLeft),
    (ResizeHandle.top, bounds.topCenter),
    (ResizeHandle.topRight, bounds.topRight),
    (ResizeHandle.right, bounds.centerRight),
    (ResizeHandle.bottomRight, bounds.bottomRight),
    (ResizeHandle.bottom, bounds.bottomCenter),
    (ResizeHandle.bottomLeft, bounds.bottomLeft),
    (ResizeHandle.left, bounds.centerLeft),
  ];
}

/// 命中哪个手柄（[radius] 是 world 单位的点击容差）。
ResizeHandle? hitTestCommandHandle(
  DrawCommand command,
  Offset position,
  double radius,
) {
  for (final (handle, point) in commandHandlePoints(command)) {
    if ((point - position).distance <= radius) return handle;
  }
  return null;
}

/// 拖拽手柄后的新包围框：对角/对边固定，被拖的边跟随指针；拖过头不翻转，
/// 最小保留 1px，避免退化成零尺寸后再也抓不住。
Rect resizeBounds(Rect original, ResizeHandle handle, Offset position) {
  var left = original.left;
  var top = original.top;
  var right = original.right;
  var bottom = original.bottom;
  final movesLeft =
      handle == ResizeHandle.topLeft ||
      handle == ResizeHandle.left ||
      handle == ResizeHandle.bottomLeft;
  final movesRight =
      handle == ResizeHandle.topRight ||
      handle == ResizeHandle.right ||
      handle == ResizeHandle.bottomRight;
  final movesTop =
      handle == ResizeHandle.topLeft ||
      handle == ResizeHandle.top ||
      handle == ResizeHandle.topRight;
  final movesBottom =
      handle == ResizeHandle.bottomLeft ||
      handle == ResizeHandle.bottom ||
      handle == ResizeHandle.bottomRight;
  if (movesLeft) left = position.dx;
  if (movesRight) right = position.dx;
  if (movesTop) top = position.dy;
  if (movesBottom) bottom = position.dy;
  if (right - left < 1) {
    if (movesLeft) {
      left = right - 1;
    } else {
      right = left + 1;
    }
  }
  if (bottom - top < 1) {
    if (movesTop) {
      top = bottom - 1;
    } else {
      bottom = top + 1;
    }
  }
  return Rect.fromLTRB(left, top, right, bottom);
}
