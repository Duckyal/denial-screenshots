import 'collage.dart';

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'commands.dart';
import 'tools.dart';

/// Brush/eraser pointer preview: a ring at the mouse position showing the
/// current stroke thickness and color. The system cursor is hidden over the
/// canvas while either tool is active, so this ring IS the cursor.
class ToolCursorPainter extends CustomPainter {
  const ToolCursorPainter({
    required this.position,
    required this.tool,
    required this.color,
    required this.strokeWidth,
  });

  final Offset position;
  final ScreenshotToolType tool;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    // The ring mirrors the real effect exactly: brush diameter = stroke
    // width, eraser diameter = the adjustable eraser pick size.
    final isEraser = tool == ScreenshotToolType.eraser;
    final diameter = isEraser ? strokeWidth : math.max(strokeWidth, 3.0);
    final radius = diameter / 2;

    // 双色描边：白环内外各一圈细黑边，纯白/纯黑底上都看得清（描边只在
    // 白环那一侧可见，黑底上靠白环本体）。
    void ring(double r, double width, Color color) {
      canvas.drawCircle(
        position,
        r,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = width,
      );
    }

    if (isEraser) {
      canvas.drawCircle(
        position,
        radius,
        Paint()..color = Colors.white.withValues(alpha: 0.25),
      );
      ring(radius, 3.5, Colors.black.withValues(alpha: 0.9));
      ring(radius, 1.5, Colors.white);
      // Crosshair marks the exact pick point：黑色十字加白色描边，红白底
      // 都能对准。
      final halo = Paint()
        ..color = Colors.white.withValues(alpha: 0.9)
        ..strokeWidth = 3;
      final cross = Paint()
        ..color = Colors.black.withValues(alpha: 0.9)
        ..strokeWidth = 1.2;
      for (final paint in [halo, cross]) {
        canvas.drawLine(
          position - const Offset(5, 0),
          position + const Offset(5, 0),
          paint,
        );
        canvas.drawLine(
          position - const Offset(0, 5),
          position + const Offset(0, 5),
          paint,
        );
      }
      return;
    }

    // 荧光笔：光标圈填充用实际落笔色（半透明），与画出的高亮一致；再套
    // 白环 + 黑边，任意底色都辨得出位置。
    if (tool == ScreenshotToolType.highlighter) {
      canvas.drawCircle(
        position,
        radius,
        Paint()..color = color.withValues(alpha: 0.4),
      );
      ring(radius, 3.2, Colors.black.withValues(alpha: 0.9));
      ring(radius, 1.6, Colors.white);
      return;
    }

    // 画笔：环体显示笔色，外面套白环 + 黑边，任意底色都辨得出位置。
    canvas.drawCircle(position, radius, Paint()..color = color);
    ring(radius, 3.2, Colors.black.withValues(alpha: 0.9));
    ring(radius, 1.6, Colors.white);
  }

  @override
  bool shouldRepaint(ToolCursorPainter oldDelegate) =>
      oldDelegate.position != position ||
      oldDelegate.tool != tool ||
      oldDelegate.color != color ||
      oldDelegate.strokeWidth != strokeWidth;
}

/// 已提交的图形层。
///
/// 拖动绘制时这一层的内容不变，所以只有命令列表（或选中项）变化才重绘，
/// 不必每帧重放历史笔画；[version] 用于捕捉「列表实例没变但内容被改」的
/// 情况（例如光标模式拖动某个图形）。
///
/// 有 [annotationImage]（已提交命令的栅格化位图，橡皮擦除已烘焙成透明
/// 洞）时直接整块 blit：擦过的区域是真洞，透出下层的 Image 组件，与
/// 提交后的结果逐像素一致；没有位图（拖动移动对象期间、底图未就绪）
/// 才退回逐条重放。
class StaticDrawPainter extends CustomPainter {
  const StaticDrawPainter({
    required this.commands,
    required this.version,
    this.backgroundImage,
    this.annotationImage,
    this.skipIndex,
  });

  final List<DrawCommand> commands;
  final int version;

  /// 底图（截图原图）。模糊蒙版用它把矩形区域重画成模糊效果；世界坐标
  /// 即图像像素坐标，整图直接映射到画布即可对齐。
  final ui.Image? backgroundImage;

  /// 就地编辑中的文字命令下标：编辑层用实时草稿替换它，静态层必须跳过
  /// 原对象（位图与重放两条路径都跳），否则旧字和草稿会重叠闪跳。
  final int? skipIndex;

  /// 已提交命令的栅格化位图（世界尺寸）。由编辑器状态在命令变化时重建，
  /// 橡皮拖动擦除时增量更新。
  final ui.Image? annotationImage;

  @override
  void paint(Canvas canvas, Size size) {
    final skip = skipIndex;
    final raster = skip == null ? annotationImage : null;
    if (raster != null) {
      canvas.drawImage(
        raster,
        Offset.zero,
        Paint()..filterQuality = FilterQuality.low,
      );
    } else {
      // BlendMode.clear（橡皮）只在独立图层里才能擦掉本层已画的内容；没有
      // 橡皮命令时省掉这张与画布等大的离屏图层——4K 截图下它是几十 MB。
      final needsLayer = _hasEraser || skip != null;
      if (needsLayer) canvas.saveLayer(Offset.zero & size, Paint());
      for (var i = 0; i < commands.length; i++) {
        if (i == skip) continue;
        drawCommand(canvas, commands[i], backgroundImage: backgroundImage);
      }
      if (needsLayer) canvas.restore();
    }
  }

  bool get _hasEraser {
    for (final command in commands) {
      if (command.type == ScreenshotToolType.eraser) return true;
    }
    return false;
  }

  @override
  bool shouldRepaint(StaticDrawPainter oldDelegate) =>
      oldDelegate.commands != commands ||
      oldDelegate.version != version ||
      oldDelegate.backgroundImage != backgroundImage ||
      oldDelegate.annotationImage != annotationImage ||
      oldDelegate.skipIndex != skipIndex;
}

/// 实时文字编辑层：把正在输入的草稿按提交规则画进世界坐标。排版来自
/// layoutTextBlock（与提交渲染同一实现），落位偏移也由编辑器按同一规则
/// 算好传入——编辑中长什么样，提交后就长什么样。
class LiveTextPainter extends CustomPainter {
  const LiveTextPainter({required this.painter, required this.offset});

  final TextPainter painter;
  final Offset offset;

  @override
  void paint(Canvas canvas, Size size) => painter.paint(canvas, offset);

  @override
  bool shouldRepaint(LiveTextPainter oldDelegate) =>
      oldDelegate.painter != painter || oldDelegate.offset != offset;
}

/// 光标模式选中对象的高亮框 + 缩放手柄。
///
/// 画在世界坐标里（跟随图像缩放），但整层放在 `_canvasKey` 重绘边界之外，
/// 保存/置顶快照不会把选中框和手柄烙进图片。手柄尺寸按屏幕像素给定，
/// 由调用方按当前显示比例换算成世界单位，缩放时观感大小恒定。
class SelectionPainter extends CustomPainter {
  const SelectionPainter({
    required this.command,
    required this.handleSize,
    this.showHandles = true,
  });

  final DrawCommand? command;
  final double handleSize;

  /// 缩放手柄开关：文字工具下的选中只画蓝框（手柄拖拽逻辑归光标模式，
  /// 画了也拖不动，反而误导）。
  final bool showHandles;

  @override
  void paint(Canvas canvas, Size size) {
    final target = command;
    if (target == null) return;
    final bounds = commandDisplayBounds(target).inflate(5);
    canvas.drawRect(
      bounds,
      Paint()
        ..color = Colors.blue.withValues(alpha: 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    final fill = Paint()..color = Colors.white;
    final border = Paint()
      ..color = Colors.blue
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    if (showHandles) {
      for (final (_, point) in commandHandlePoints(target)) {
        final rect = Rect.fromCenter(
          center: point,
          width: handleSize,
          height: handleSize,
        );
        canvas.drawRect(rect, fill);
        canvas.drawRect(rect, border);
      }
    }
  }

  @override
  bool shouldRepaint(SelectionPainter oldDelegate) =>
      oldDelegate.command != command ||
      oldDelegate.handleSize != handleSize ||
      oldDelegate.showHandles != showHandles;
}

/// 正在绘制的那一笔（预览层）。
///
/// 指针每移动一次就重建这一层，但它只画当前笔画，成本与历史笔画数无关。
class PreviewDrawPainter extends CustomPainter {
  const PreviewDrawPainter({this.preview, this.backgroundImage});

  final DrawCommand? preview;
  final ui.Image? backgroundImage;

  @override
  void paint(Canvas canvas, Size size) {
    final command = preview;
    if (command != null) {
      drawCommand(canvas, command, backgroundImage: backgroundImage);
    }
  }

  @override
  bool shouldRepaint(PreviewDrawPainter oldDelegate) =>
      oldDelegate.preview != preview ||
      oldDelegate.backgroundImage != backgroundImage;
}

/// OCR 文字选区高亮：把当前跨块选中的文字区间逐块涂成半透明蓝，并沿每块
/// 选中边界描一圈实线，让选中的文本轮廓清晰可辨。矩形由调用方按字符比例
/// 算好（world 坐标），这里只负责画。整层在 `_canvasKey` 重绘边界之外，
/// 保存/置顶不会带上。
class OcrSelectionPainter extends CustomPainter {
  const OcrSelectionPainter({
    required this.rects,
    this.handles = const [],
    this.anchorRadius = 7,
  });

  final List<Rect> rects;

  /// Ctrl 多选关闭锚点：每个固化选段起点旁的 ✕ 钮，点它 = 释放该段。
  final List<Offset> handles;

  /// 锚点半径（世界像素），由编辑器按当前显示缩放换算传入：固定世界半径
  /// 在缩小适配下只剩两三个屏幕像素，✕ 的两条斜线会被抗锯齿糊成一个点、
  /// 看着就不是叉了——换算后屏幕上锚点恒定大小、✕ 永远清晰。
  final double anchorRadius;

  @override
  void paint(Canvas canvas, Size size) {
    if (rects.isEmpty) return;
    final fill = Paint()..color = const Color(0x6633AADD);
    final border = Paint()
      ..color = const Color(0xFF1E88C9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final rect in rects) {
      canvas.drawRect(rect, fill);
      canvas.drawRect(rect, border);
    }
    if (handles.isNotEmpty) {
      // 关闭锚点：实心圆 + 白色 ✕。Ctrl+点它 = 释放对应选段。
      final r = anchorRadius;
      final bg = Paint()..color = const Color(0xFF1E88C9);
      final ring = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.16;
      final cross = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.0, r * 0.22)
        ..strokeCap = StrokeCap.round;
      final arm = r * 0.45;
      for (final center in handles) {
        canvas.drawCircle(center, r, bg);
        canvas.drawCircle(center, r, ring);
        canvas.drawLine(
          center - Offset(arm, arm),
          center + Offset(arm, arm),
          cross,
        );
        // 右上 → 左下（+arm,-arm 到 -arm,+arm），与上一条对角线交叉成 ✕。
        canvas.drawLine(
          center + Offset(arm, -arm),
          center - Offset(arm, -arm),
          cross,
        );
      }
    }
  }

  @override
  bool shouldRepaint(OcrSelectionPainter oldDelegate) =>
      !listEquals(oldDelegate.rects, rects) ||
      !listEquals(oldDelegate.handles, handles) ||
      oldDelegate.anchorRadius != anchorRadius;
}

/// 文本背景层：实时编辑时画在草稿底下，与静态渲染同一圆角/外扩规则
/// （由调用方算好矩形，这里只画圆角色块）。
class TextBackgroundPainter extends CustomPainter {
  const TextBackgroundPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(TextBackgroundPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}

/// 拼图工作台的内容层：逐槽 clip 到框架矩形并按 pan/zoom 绘制图片。
/// 槽的 pan/zoom 原地修改，编辑器用 _canvasTick 驱动重绘，这里每帧全画
/// （槽数 ≤ 十几，成本可忽略）。
class CollageContentPainter extends CustomPainter {
  CollageContentPainter({required this.slots, this.version = 0});

  final List<CollageSlot> slots;

  /// 槽的 pan/zoom 原地修改（引用不变），编辑器每次改动递增版本号并重建
  /// painter，shouldRepaint 靠它判定重绘。
  final int version;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..filterQuality = FilterQuality.medium;
    for (final slot in slots) {
      canvas.save();
      canvas.clipRect(slot.rect);
      canvas.drawImageRect(
        slot.image,
        Rect.fromLTWH(
          0,
          0,
          slot.image.width.toDouble(),
          slot.image.height.toDouble(),
        ),
        slot.imageRect,
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(CollageContentPainter oldDelegate) =>
      oldDelegate.slots != slots || oldDelegate.version != version;
}

/// 工作台框架导引层：每个槽画一圈细边框（选中高亮），编辑期悬浮在画布
/// 上提示"框在哪"；导出走烘焙图，天然不含这层。
class CollageGuidePainter extends CustomPainter {
  CollageGuidePainter({
    required this.slots,
    this.selectedIndex,
    this.version = 0,
    this.handleSize = 0,
    this.guides = const [],
    this.strokeWidthScale = 1.0,
  });

  /// 世界像素/屏幕像素换算：>1 放大（线变细回屏幕宽度），<1 全景
  /// （线加粗到屏幕宽度）。线宽与出线长度都按它除。
  final double strokeWidthScale;

  final List<CollageSlot> slots;
  final int? selectedIndex;

  /// 拖框过程中命中的对齐参考线（世界坐标矩形），实时画成蓝线；
  /// 空列表不画。松手吸附后由编辑器清空。
  final List<Rect> guides;

  /// 槽的 pan/zoom 是原地修改（引用不变），编辑器每次改动递增此版本号，
  /// 否则 shouldRepaint 的引用比较会漏画。
  final int version;

  /// >0 时给选中框架画 8 向调大小手柄（白方块蓝边，世界尺寸由调用方按
  /// 屏幕恒定换算）。
  final double handleSize;

  @override
  void paint(Canvas canvas, Size size) {
    final k = strokeWidthScale <= 0 ? 1.0 : strokeWidthScale;

    void frame(CollageSlot slot, {required bool selected}) {
      final rect = slot.rect;
      // 深浅双线描边：单色细线在白底（或黑底）上都会隐形，深色外圈 +
      // 亮色内圈保证任何画面背景都有对比；线宽除以显示比例，屏幕上
      // 恒定（全景 fit<1 时不会细到看不见）。
      canvas.drawRect(
        rect,
        Paint()
          ..color = const Color(0xB3000000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = (selected ? 4.0 : 2.8) / k,
      );
      canvas.drawRect(
        rect,
        Paint()
          ..color = selected ? const Color(0xFF4C9AFF) : const Color(0xF2FFFFFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = (selected ? 2.2 : 1.2) / k,
      );
    }

    // 相邻框架共用一条边：按 slots 顺序画的话，后画的白边会盖住先画
    // 的选中蓝边——同一框的边一半蓝一半白。分两遍：普通框在前，选中
    // 框最后画，蓝边完整。
    for (var i = 0; i < slots.length; i++) {
      if (i != selectedIndex) frame(slots[i], selected: false);
    }
    if (selectedIndex != null &&
        selectedIndex! >= 0 &&
        selectedIndex! < slots.length) {
      frame(slots[selectedIndex!], selected: true);
    }

    // 对齐参考线：拖框时命中才画（1.5px 亮蓝，盖在所有框线之上）。
    if (guides.isNotEmpty) {
      final halo = Paint()..color = const Color(0x99000000);
      final line = Paint()..color = const Color(0xFF4C9AFF);
      for (final g in guides) {
        canvas.drawRect(g.inflate(1.5), halo);
        canvas.drawRect(g, line);
      }
    }

    for (var i = 0; i < slots.length; i++) {
      final selected = i == selectedIndex;
      final rect = slots[i].rect;
      if (selected && handleSize > 0) {
        final fill = Paint()..color = Colors.white;
        final border = Paint()
          ..color = const Color(0xFF4C9AFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5;
        for (final point in [
          rect.topLeft,
          rect.topCenter,
          rect.topRight,
          rect.centerRight,
          rect.bottomRight,
          rect.bottomCenter,
          rect.bottomLeft,
          rect.centerLeft,
        ]) {
          final hr = Rect.fromCenter(
            center: point,
            width: handleSize,
            height: handleSize,
          );
          canvas.drawRect(hr, fill);
          canvas.drawRect(hr, border);
        }
      }
    }
  }

  @override
  bool shouldRepaint(CollageGuidePainter oldDelegate) =>
      oldDelegate.selectedIndex != selectedIndex ||
      oldDelegate.slots != slots ||
      oldDelegate.version != version ||
      oldDelegate.handleSize != handleSize ||
      oldDelegate.guides != guides ||
      oldDelegate.strokeWidthScale != strokeWidthScale;
}

/// 文本框编辑态的高亮层：高对比虚线描边 + 半透明底 + 四角实心角标，
/// 在任意截图底色上都能把编辑区域显式圈出来。
class TextBoxHighlightPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final fill = Paint()..color = const Color(0x1F4C9AFF);
    final dash = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    final halo = Paint()
      ..color = const Color(0xFF0A84FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round;
    canvas.drawRect(rect, fill);
    // 3px 划线 + 4.5px 间隔的虚线：先画蓝色宽晕，再叠白色细线，形成描边
    // 对比；halo 用圆头避免短线头生硬。
    final path = Path()
      ..moveTo(rect.left, rect.top)
      ..lineTo(rect.right, rect.top)
      ..lineTo(rect.right, rect.bottom)
      ..lineTo(rect.left, rect.bottom)
      ..close();
    _drawDashed(canvas, path, dash, halo);
  }

  static void _drawDashed(Canvas canvas, Path path, Paint line, Paint halo) {
    for (final metrics in path.computeMetrics()) {
      double distance = 0;
      while (distance < metrics.length) {
        final next = math.min(distance + 3.5, metrics.length);
        final seg = metrics.extractPath(distance, next);
        canvas.drawPath(seg, halo);
        canvas.drawPath(seg, line);
        distance = next + 4.5;
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

void drawCommand(
  Canvas canvas,
  DrawCommand command, {
  ui.Image? backgroundImage,
}) {
  switch (command.type) {
    case ScreenshotToolType.select:
      break;
    case ScreenshotToolType.brush:
    case ScreenshotToolType.eraser:
      final paint = Paint()
        ..color = command.type == ScreenshotToolType.eraser
            ? Colors.transparent
            : command.color
        ..strokeWidth = command.strokeWidth
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..blendMode = command.type == ScreenshotToolType.eraser
            ? BlendMode.clear
            : BlendMode.srcOver;
      canvas.drawPath(command.path, paint);
      break;
    case ScreenshotToolType.highlighter:
      // 荧光笔：像直线那样从起点画到终点（一条粗线，盖住一行文字），
      // 但强制半透明 + 圆头，叠在内容上像记号笔。用 srcOver 而非 multiply
      // ——注释层是透明位图，栅格化后再叠到截图上，multiply 无背景可乘会失真。
      final paint = Paint()
        ..color = command.color.withValues(alpha: 0.4)
        ..strokeWidth = command.strokeWidth
        ..strokeCap = StrokeCap.round
        ..blendMode = BlendMode.srcOver;
      canvas.drawLine(command.start, command.end, paint);
      break;
    case ScreenshotToolType.line:
      final paint = Paint()
        ..color = command.color
        ..strokeWidth = command.strokeWidth
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawLine(command.start, command.end, paint);
      break;
    case ScreenshotToolType.arrow:
      _drawArrow(
        canvas,
        command.start,
        command.end,
        command.color,
        command.strokeWidth,
      );
      break;
    case ScreenshotToolType.rect:
      final paint = Paint()
        ..color = command.color
        ..strokeWidth = command.strokeWidth
        ..style = PaintingStyle.stroke;
      canvas.drawRect(command.rect, paint);
      break;
    case ScreenshotToolType.circle:
      final paint = Paint()
        ..color = command.color
        ..strokeWidth = command.strokeWidth
        ..style = PaintingStyle.stroke;
      canvas.drawOval(command.rect, paint);
      break;
    case ScreenshotToolType.mask:
      if (command.maskStyle == MaskStyle.blur && backgroundImage != null) {
        // 模糊背景：把原图按模糊滤镜重画进蒙版矩形。镜像采样避免矩形
        // 贴近图像边缘时出现透明/发暗的滤波边界。
        final source = Rect.fromLTWH(
          0,
          0,
          backgroundImage.width.toDouble(),
          backgroundImage.height.toDouble(),
        );
        canvas.save();
        canvas.clipRect(command.rect);
        canvas.drawImageRect(
          backgroundImage,
          source,
          source,
          Paint()
            ..imageFilter = ui.ImageFilter.blur(
              sigmaX: 12,
              sigmaY: 12,
              tileMode: TileMode.mirror,
            ),
        );
        canvas.restore();
      } else {
        canvas.drawRect(command.rect, Paint()..color = command.fillColor);
      }
      break;
    case ScreenshotToolType.text:
      // 排版结果缓存在命令上：字号随粗细变化，变了才重新 layout。
      // 有文本框（拖框创建）时逐行左对齐、整块垂直居中——与实时编辑的
      // EditableText 约束完全同构（框内区宽度 + 起始对齐），所见即所得。
      final layout = command.textLayout();
      final box = command.textBox;
      final bg = command.textBackground;
      if (bg != null) {
        // 背景：文本框画整框；自由文字画排版包围盒按字号外扩一圈。
        final fontSize = command.strokeWidth * 4;
        final pad = fontSize * 0.22;
        final bgRect =
            box ??
            Rect.fromLTWH(
              command.start.dx - pad,
              command.start.dy - pad,
              layout.width + pad * 2,
              layout.height + pad * 2,
            );
        canvas.drawRRect(
          RRect.fromRectAndRadius(bgRect, Radius.circular(fontSize * 0.18)),
          Paint()..color = bg,
        );
      }
      final offset = box == null
          ? command.start
          : Offset(
              box.deflate(4).left,
              box.deflate(4).top + (box.deflate(4).height - layout.height) / 2,
            );
      layout.paint(canvas, offset);
      break;
  }
}

void _drawArrow(
  Canvas canvas,
  Offset start,
  Offset end,
  Color color,
  double width,
) {
  final direction = end - start;
  final length = direction.distance;
  if (length == 0) return;
  final normalized = direction / length;
  final headLength = width * 4;
  final angle = math.pi / 6;
  final side = Offset(
    -normalized.dy * headLength * math.sin(angle),
    normalized.dx * headLength * math.sin(angle),
  );
  final base = end - normalized * headLength * 1.5;
  final path = Path()
    ..moveTo(start.dx, start.dy)
    ..lineTo(end.dx, end.dy)
    ..moveTo((base + side).dx, (base + side).dy)
    ..lineTo(end.dx, end.dy)
    ..lineTo((base - side).dx, (base - side).dy);
  canvas.drawPath(
    path,
    Paint()
      ..color = color
      ..strokeWidth = width
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round,
  );
}
