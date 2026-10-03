import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screenshot_tool/commands.dart';
import 'package:screenshot_tool/tools.dart';

DrawCommand _command(ScreenshotToolType type, Rect rect) => DrawCommand(
      type: type,
      start: rect.topLeft,
      end: rect.bottomRight,
      path: Path(),
      rect: rect,
    );

void main() {
  test('eraser tap deletes the shape instead of a previous eraser stroke', () {
    final history = [
      _command(ScreenshotToolType.brush, const Rect.fromLTRB(10, 10, 100, 100)),
      _command(
          ScreenshotToolType.eraser, const Rect.fromLTRB(10, 10, 100, 100)),
      _command(ScreenshotToolType.rect, const Rect.fromLTRB(10, 10, 100, 100)),
    ];

    expect(findManipulableCommandIndex(history, const Offset(50, 50)), 2);
  });

  test('tap inside a previous eraser stroke does not delete the erasure', () {
    final history = [
      _command(
          ScreenshotToolType.eraser, const Rect.fromLTRB(10, 10, 100, 100)),
    ];

    expect(findManipulableCommandIndex(history, const Offset(50, 50)), isNull);
  });

  test('brush strokes stay unselectable for tap deletion', () {
    final history = [
      _command(ScreenshotToolType.brush, const Rect.fromLTRB(10, 10, 100, 100)),
    ];

    expect(findManipulableCommandIndex(history, const Offset(50, 50)), isNull);
  });

  test('brush strokes are not tap-deleted (pixel erase handles them)', () {
    final stroke = DrawCommand(
      type: ScreenshotToolType.brush,
      start: const Offset(40, 40),
      end: const Offset(60, 60),
      path: Path()
        ..moveTo(40, 40)
        ..lineTo(60, 60),
      rect: Rect.zero,
    );
    final history = [stroke];

    // Tapping a stroke must NOT remove it as an object; dragging the eraser
    // paints a BlendMode.clear stroke that partially erases it instead.
    expect(findEraserTargetIndex(history, const Offset(50, 50), 12), isNull);
  });

  test('eraser does not delete hollow shapes from their interior', () {
    final history = [
      _command(
          ScreenshotToolType.rect, const Rect.fromLTRB(100, 100, 200, 200)),
      _command(
          ScreenshotToolType.circle, const Rect.fromLTRB(300, 100, 400, 200)),
    ];

    // 内部空白不是命中目标，只有描边附近才删。
    expect(findEraserTargetIndex(history, const Offset(150, 150), 6), isNull);
    expect(findEraserTargetIndex(history, const Offset(350, 150), 6), isNull);
    expect(findEraserTargetIndex(history, const Offset(105, 150), 6), 0);
    expect(findEraserTargetIndex(history, const Offset(302, 150), 6), 1);
  });

  test('eraser never deletes eraser commands', () {
    final history = [
      _command(
          ScreenshotToolType.eraser, const Rect.fromLTRB(10, 10, 100, 100)),
    ];

    expect(findEraserTargetIndex(history, const Offset(50, 50), 40), isNull);
  });

  test('eraser radius bounds the pick range', () {
    final history = [
      _command(
          ScreenshotToolType.rect, const Rect.fromLTRB(100, 100, 200, 200)),
    ];

    expect(findEraserTargetIndex(history, const Offset(50, 50), 10), isNull);
    expect(findEraserTargetIndex(history, const Offset(105, 105), 10), 0);
  });
}
