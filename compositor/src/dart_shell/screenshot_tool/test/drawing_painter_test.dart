import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screenshot_tool/commands.dart';
import 'package:screenshot_tool/painter.dart';
import 'package:screenshot_tool/tools.dart';

Future<ui.Image> _render(List<DrawCommand> commands) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const size = Size(120, 80);
  DrawPainter(commands: commands).paint(canvas, size);
  return recorder
      .endRecording()
      .toImage(size.width.toInt(), size.height.toInt());
}

Future<Color> _pixel(ui.Image image, int x, int y) async {
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final offset = (y * image.width + x) * 4;
  return Color.fromARGB(
    bytes.getUint8(offset + 3),
    bytes.getUint8(offset),
    bytes.getUint8(offset + 1),
    bytes.getUint8(offset + 2),
  );
}

void main() {
  test('mask fills the selected rectangle with its saved color', () async {
    final image = await _render([
      DrawCommand(
        type: ScreenshotToolType.mask,
        start: const Offset(10, 10),
        end: const Offset(50, 40),
        path: Path(),
        rect: const Rect.fromLTRB(10, 10, 50, 40),
        fillColor: Colors.white,
      ),
    ]);

    expect(await _pixel(image, 20, 20), Colors.white);
    expect((await _pixel(image, 5, 5)).alpha, 0);
    image.dispose();
  });

  test('ellipse uses both drag dimensions rather than a radius circle',
      () async {
    final image = await _render([
      DrawCommand(
        type: ScreenshotToolType.circle,
        start: const Offset(20, 10),
        end: const Offset(100, 30),
        path: Path(),
        rect: const Rect.fromLTRB(20, 10, 100, 30),
        color: Colors.red,
        strokeWidth: 2,
      ),
    ]);

    expect((await _pixel(image, 60, 10)).red, greaterThan(200));
    expect((await _pixel(image, 60, 20)).alpha, 0);
    image.dispose();
  });

  test('freehand path retains a curved stroke', () async {
    final path = Path()
      ..moveTo(5, 55)
      ..quadraticBezierTo(35, 5, 65, 55);
    final image = await _render([
      DrawCommand(
        type: ScreenshotToolType.brush,
        start: const Offset(5, 55),
        end: const Offset(65, 55),
        path: path,
        rect: const Rect.fromLTRB(5, 5, 65, 55),
        color: Colors.black,
        strokeWidth: 3,
      ),
    ]);

    expect((await _pixel(image, 35, 30)).alpha, greaterThan(0));
    expect((await _pixel(image, 35, 55)).alpha, 0);
    image.dispose();
  });

  test('straight line draws a visible segment between endpoints', () async {
    final image = await _render([
      DrawCommand(
        type: ScreenshotToolType.line,
        start: const Offset(10, 20),
        end: const Offset(90, 60),
        path: Path(),
        rect: const Rect.fromLTRB(10, 20, 90, 60),
        color: Colors.blue,
        strokeWidth: 4,
      ),
    ]);

    expect((await _pixel(image, 20, 25)).blue, greaterThan(200));
    expect((await _pixel(image, 50, 40)).alpha, greaterThan(0));
    image.dispose();
  });
}
