import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'commands.dart';
import 'tools.dart';

/// Brush/eraser pointer preview: a ring at the mouse position showing the
/// current stroke thickness and color. The system cursor is hidden over the
/// canvas while either tool is active, so this ring IS the cursor.
class ToolCursorPainter extends CustomPainter {
  const ToolCursorPainter({
    required this.position,
    required this.isEraser,
    required this.color,
    required this.strokeWidth,
  });

  final Offset position;
  final bool isEraser;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    // The ring mirrors the real effect exactly: brush diameter = stroke
    // width, eraser diameter = the adjustable eraser pick size.
    final diameter = isEraser ? strokeWidth : math.max(strokeWidth, 3.0);
    final radius = diameter / 2;
    final ringColor =
        color.computeLuminance() > 0.55 ? Colors.black : Colors.white;

    if (isEraser) {
      canvas.drawCircle(
        position,
        radius,
        Paint()..color = Colors.white.withOpacity(0.25),
      );
      canvas.drawCircle(
        position,
        radius,
        Paint()
          ..color = ringColor.withOpacity(0.9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      // Crosshair marks the exact pick point.
      canvas.drawLine(
        position - const Offset(4, 0),
        position + const Offset(4, 0),
        Paint()
          ..color = ringColor
          ..strokeWidth = 1,
      );
      canvas.drawLine(
        position - const Offset(0, 4),
        position + const Offset(0, 4),
        Paint()
          ..color = ringColor
          ..strokeWidth = 1,
      );
      return;
    }

    canvas.drawCircle(position, radius, Paint()..color = color);
    canvas.drawCircle(
      position,
      radius,
      Paint()
        ..color = ringColor.withOpacity(0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(ToolCursorPainter oldDelegate) =>
      oldDelegate.position != position ||
      oldDelegate.isEraser != isEraser ||
      oldDelegate.color != color ||
      oldDelegate.strokeWidth != strokeWidth;
}

/// 已提交的图形层。
///
/// 拖动绘制时这一层的内容不变，所以只有命令列表（或选中项）变化才重绘，
/// 不必每帧重放历史笔画；[version] 用于捕捉「列表实例没变但内容被改」的
/// 情况（例如光标模式拖动某个图形）。
class StaticDrawPainter extends CustomPainter {
  const StaticDrawPainter({
    required this.commands,
    required this.version,
    this.selectedIndex,
  });

  final List<DrawCommand> commands;
  final int version;

  /// 光标模式当前选中的图形对象，画一圈蓝色高亮框。
  final int? selectedIndex;

  @override
  void paint(Canvas canvas, Size size) {
    // BlendMode.clear（橡皮）只在独立图层里才能擦掉本层已画的内容；没有
    // 橡皮命令时省掉这张与画布等大的离屏图层——4K 截图下它是几十 MB。
    final needsLayer = _hasEraser;
    if (needsLayer) canvas.saveLayer(Offset.zero & size, Paint());
    for (final command in commands) {
      drawCommand(canvas, command);
    }
    if (needsLayer) canvas.restore();
    final index = selectedIndex;
    if (index != null && index >= 0 && index < commands.length) {
      final bounds = commandDisplayBounds(commands[index]).inflate(5);
      canvas.drawRect(
        bounds,
        Paint()
          ..color = Colors.blue.withOpacity(0.9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
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
      oldDelegate.selectedIndex != selectedIndex;
}

/// 正在绘制的那一笔（预览层）。
///
/// 指针每移动一次就重建这一层，但它只画当前笔画，成本与历史笔画数无关。
class PreviewDrawPainter extends CustomPainter {
  const PreviewDrawPainter({this.preview});

  final DrawCommand? preview;

  @override
  void paint(Canvas canvas, Size size) {
    final command = preview;
    if (command != null) drawCommand(canvas, command);
  }

  @override
  bool shouldRepaint(PreviewDrawPainter oldDelegate) =>
      oldDelegate.preview != preview;
}

/// 橡皮预览必须与已画内容在同一图层里，clear 混合才擦得动，所以橡皮工具
/// 下退回单一 painter（全量重放，但橡皮场景命令通常不多）。
class CombinedDrawPainter extends CustomPainter {
  const CombinedDrawPainter({
    required this.commands,
    required this.version,
    this.preview,
    this.selectedIndex,
  });

  final List<DrawCommand> commands;
  final int version;
  final DrawCommand? preview;
  final int? selectedIndex;

  @override
  void paint(Canvas canvas, Size size) {
    final command = preview;
    final needsLayer =
        command?.type == ScreenshotToolType.eraser || _hasEraser(commands);
    if (needsLayer) canvas.saveLayer(Offset.zero & size, Paint());
    for (final item in commands) {
      drawCommand(canvas, item);
    }
    if (command != null) drawCommand(canvas, command);
    if (needsLayer) canvas.restore();
    final index = selectedIndex;
    if (index != null && index >= 0 && index < commands.length) {
      final bounds = commandDisplayBounds(commands[index]).inflate(5);
      canvas.drawRect(
        bounds,
        Paint()
          ..color = Colors.blue.withOpacity(0.9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(CombinedDrawPainter oldDelegate) =>
      oldDelegate.commands != commands ||
      oldDelegate.version != version ||
      oldDelegate.preview != preview ||
      oldDelegate.selectedIndex != selectedIndex;
}

bool _hasEraser(List<DrawCommand> commands) {
  for (final command in commands) {
    if (command.type == ScreenshotToolType.eraser) return true;
  }
  return false;
}

void drawCommand(Canvas canvas, DrawCommand command) {
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
      _drawArrow(canvas, command.start, command.end, command.color,
          command.strokeWidth);
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
      canvas.drawRect(command.rect, Paint()..color = command.fillColor);
      break;
    case ScreenshotToolType.text:
      // 排版结果缓存在命令上：字号随粗细变化，变了才重新 layout。
      command.textLayout().paint(canvas, command.start);
      break;
  }
}

void _drawArrow(
    Canvas canvas, Offset start, Offset end, Color color, double width) {
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
