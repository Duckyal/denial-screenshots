import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:denial_screenshot/src/editor/commands.dart';
import 'package:denial_screenshot/src/editor/painter.dart';
import 'package:denial_screenshot/src/editor/tools.dart';

Future<ui.Image> _render(
  List<DrawCommand> commands, {
  ui.Image? background,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const size = Size(120, 80);
  StaticDrawPainter(
    commands: commands,
    version: 0,
    backgroundImage: background,
  ).paint(canvas, size);
  return recorder.endRecording().toImage(
    size.width.toInt(),
    size.height.toInt(),
  );
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
  test('boxed text shrinks to fit and renders inside its box only', () async {
    const box = Rect.fromLTWH(10, 10, 100, 40);
    final command = DrawCommand(
      type: ScreenshotToolType.text,
      start: box.topLeft,
      end: box.topLeft,
      path: Path(),
      text: '这是一段很长很长的文本框内容，需要自适应缩小并居中',
      rect: box,
      color: Colors.black,
      strokeWidth: 3,
      textBox: box,
    );

    // 文本框即交互范围（点框内任意位置可命中）。
    expect(commandDisplayBounds(command), box);
    // 字号随框自适应：排版结果必须装进框的内边距区域。
    final layout = command.textLayout();
    expect(layout.width, lessThanOrEqualTo(92));
    expect(layout.height, lessThanOrEqualTo(32));

    final image = await _render([command]);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    bool hasInk(int x0, int y0, int x1, int y1) {
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          if (bytes.getUint8((y * 120 + x) * 4 + 3) > 0) return true;
        }
      }
      return false;
    }

    expect(hasInk(10, 10, 110, 50), isTrue, reason: '框内应有文字');
    expect(hasInk(0, 10, 10, 50), isFalse, reason: '框外左侧不应有内容');
    expect(hasInk(10, 50, 110, 80), isFalse, reason: '框外下方不应有内容');
    image.dispose();
  });

  test(
    'rasterized annotation bitmap bakes eraser holes that reveal the image',
    () async {
      // 复刻编辑器的位图烘焙路径：已提交命令（含橡皮）录进单个 picture
      // 栅格化——clear 在同一 picture 内天然擦得动先画的内容，无需
      // saveLayer；静态层 blit 位图后，洞透出下层 Image 组件（底图）。
      final bgRecorder = ui.PictureRecorder();
      final bgCanvas = Canvas(bgRecorder);
      bgCanvas.drawRect(
        const Rect.fromLTRB(0, 0, 60, 80),
        Paint()..color = Colors.black,
      );
      bgCanvas.drawRect(
        const Rect.fromLTRB(60, 0, 120, 80),
        Paint()..color = Colors.white,
      );
      final background = await bgRecorder.endRecording().toImage(120, 80);

      DrawCommand stroke(double x, Color color) {
        return DrawCommand(
          type: ScreenshotToolType.brush,
          start: Offset(x, 5),
          end: Offset(x, 75),
          path: Path()
            ..moveTo(x, 5)
            ..lineTo(x, 75),
          rect: Rect.fromLTRB(x - 2, 5, x + 2, 75),
          color: color,
          strokeWidth: 4,
        );
      }

      final eraser = DrawCommand(
        type: ScreenshotToolType.eraser,
        start: const Offset(20, 40),
        end: const Offset(40, 40),
        path: Path()
          ..moveTo(20, 40)
          ..lineTo(40, 40),
        rect: const Rect.fromLTRB(20, 40, 40, 40),
        strokeWidth: 10,
      );

      // 烘位图：与 _rebuildAnnotationImage 相同的录制方式。
      const size = Size(120, 80);
      final rasterRecorder = ui.PictureRecorder();
      final rasterCanvas = Canvas(rasterRecorder, Offset.zero & size);
      for (final command in [
        stroke(30, Colors.red),
        stroke(90, Colors.blue),
        eraser,
      ]) {
        drawCommand(rasterCanvas, command, backgroundImage: background);
      }
      final annotation = rasterRecorder.endRecording().toImageSync(120, 80);

      // 复刻画布 Stack 合成顺序：底图 -> 静态层（blit 位图）。
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImage(background, Offset.zero, Paint());
      StaticDrawPainter(
        commands: const [],
        version: 0,
        backgroundImage: background,
        annotationImage: annotation,
      ).paint(canvas, size);
      final image = await recorder.endRecording().toImage(120, 80);

      // 擦除带穿过的红笔迹处是真洞，透出底图（左半幅为黑）。
      final erased = await _pixel(image, 30, 40);
      expect(erased.red, lessThan(60), reason: '擦除处应透出底图：$erased');
      // 同一笔迹在擦除带之外必须依然可见（回归：其它笔迹不得消失）。
      final outside = await _pixel(image, 30, 10);
      expect(outside.red, greaterThan(200), reason: '带外笔迹应保持不动：$outside');
      // 未触及的蓝笔迹不受影响。
      expect((await _pixel(image, 90, 40)).blue, greaterThan(200));

      background.dispose();
      annotation.dispose();
      image.dispose();
    },
  );

  test('solid mask fills its rect with the saved color', () async {
    final image = await _render([
      DrawCommand(
        type: ScreenshotToolType.mask,
        start: const Offset(30, 20),
        end: const Offset(90, 60),
        path: Path(),
        rect: const Rect.fromLTRB(30, 20, 90, 60),
        fillColor: Colors.teal,
      ),
    ]);

    expect((await _pixel(image, 60, 40)).blue, greaterThan(100));
    expect((await _pixel(image, 10, 10)).alpha, 0);
    image.dispose();
  });

  test('blur mask blurs the underlying background image', () async {
    // 左黑右白的底图，黑白交界在 x=60；模糊蒙版盖住交界后中心应是灰色，
    // 而底图本身在交界处是锐利的。
    final bgRecorder = ui.PictureRecorder();
    final bgCanvas = Canvas(bgRecorder);
    bgCanvas.drawRect(
      const Rect.fromLTRB(0, 0, 60, 80),
      Paint()..color = Colors.black,
    );
    bgCanvas.drawRect(
      const Rect.fromLTRB(60, 0, 120, 80),
      Paint()..color = Colors.white,
    );
    final background = await bgRecorder.endRecording().toImage(120, 80);

    final image = await _render([
      DrawCommand(
        type: ScreenshotToolType.mask,
        start: const Offset(50, 10),
        end: const Offset(70, 70),
        path: Path(),
        rect: const Rect.fromLTRB(50, 10, 70, 70),
        maskStyle: MaskStyle.blur,
      ),
    ], background: background);

    final center = await _pixel(image, 60, 40);
    expect(center.red, greaterThan(60));
    expect(center.red, lessThan(200));
    // 蒙版矩形外 painter 不画任何内容（底图由下层负责）。
    expect((await _pixel(image, 40, 40)).alpha, 0);
    expect((await _pixel(image, 80, 40)).alpha, 0);
    background.dispose();
    image.dispose();
  });
}