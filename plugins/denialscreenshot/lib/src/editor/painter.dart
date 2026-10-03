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

class DrawPainter extends CustomPainter {
  const DrawPainter({required this.commands, this.preview, this.selectedIndex});

  final List<DrawCommand> commands;
  final DrawCommand? preview;

  /// 光标模式当前选中的图形对象，画一圈蓝色高亮框。
  final int? selectedIndex;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.saveLayer(Offset.zero & size, Paint());
    for (final command in commands) {
      _drawCommand(canvas, command);
    }
    if (preview != null) _drawCommand(canvas, preview!);
    canvas.restore();
    if (selectedIndex != null &&
        selectedIndex! >= 0 &&
        selectedIndex! < commands.length) {
      final bounds = commandDisplayBounds(commands[selectedIndex!]).inflate(5);
      canvas.drawRect(
        bounds,
        Paint()
          ..color = Colors.blue.withOpacity(0.9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  void _drawCommand(Canvas canvas, DrawCommand command) {
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
        final textPainter = TextPainter(
          text: TextSpan(
            text: command.text,
            style: TextStyle(
              color: command.color,
              fontSize: command.strokeWidth * 4,
              fontWeight: FontWeight.bold,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        textPainter.paint(canvas, command.start);
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

  @override
  bool shouldRepaint(DrawPainter oldDelegate) =>
      oldDelegate.commands != commands ||
      oldDelegate.preview != preview ||
      oldDelegate.selectedIndex != selectedIndex;
}
