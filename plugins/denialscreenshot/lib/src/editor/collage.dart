/// 拼图的纯合成逻辑：只吃 `ui.Image`，产出 `ui.Image`，不碰编辑器状态，
/// 方便单测与工具栏入口复用。
///
/// 拼图一期 = 等比网格：所有图放进同一尺寸的格子，格内 contain 居中，
/// 留白填背景色——不同 DPI / 比例的图天然对齐，不做自由摆放（二期）。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// 网格布局：n 张图排 cols 列，行数向上取整；不满行右留空。
({int rows, int cols}) gridFor(int count, int? preferredCols) {
  if (count <= 0) return (rows: 0, cols: 0);
  final cols = (preferredCols ?? 0) > 0
      ? math.min(preferredCols!, count)
      : math.max(1, math.sqrt(count).ceil());
  return (rows: (count / cols).ceil(), cols: cols);
}

/// 等比网格拼图：[images] 按序入格。单元格 = 全体图的最大宽高，每张
/// contain 居中，格间与外缘留 [gap] 像素的背景色 [background]。
Future<ui.Image?> composeGridCollage(
  List<ui.Image> images, {
  int? columns,
  int gap = 12,
  ui.Color background = const ui.Color(0xFFFFFFFF),
}) async {
  if (images.isEmpty) return null;
  final (rows: rows, cols: cols) = gridFor(images.length, columns);
  if (rows == 0) return null;
  var cellW = 0;
  var cellH = 0;
  for (final image in images) {
    cellW = math.max(cellW, image.width);
    cellH = math.max(cellH, image.height);
  }
  final width = cols * cellW + (cols + 1) * gap;
  final height = rows * cellH + (rows + 1) * gap;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(
    recorder,
    ui.Offset.zero & ui.Size(width.toDouble(), height.toDouble()),
  );
  canvas.drawRect(
    ui.Offset.zero & ui.Size(width.toDouble(), height.toDouble()),
    ui.Paint()..color = background,
  );
  final paint = ui.Paint()..filterQuality = ui.FilterQuality.medium;
  for (var i = 0; i < images.length; i++) {
    final image = images[i];
    final cell = i % cols;
    final row = i ~/ cols;
    final slot = ui.Rect.fromLTWH(
      (gap + cell * (cellW + gap)).toDouble(),
      (gap + row * (cellH + gap)).toDouble(),
      cellW.toDouble(),
      cellH.toDouble(),
    );
    // contain 居中：取较小的缩放比，两边各留内边距。
    final scale = math.min(
      slot.width / image.width,
      slot.height / image.height,
    );
    final drawW = image.width * scale;
    final drawH = image.height * scale;
    final dest = ui.Rect.fromLTWH(
      slot.center.dx - drawW / 2,
      slot.center.dy - drawH / 2,
      drawW,
      drawH,
    );
    canvas.drawImageRect(
      image,
      ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      dest,
      paint,
    );
  }
  final picture = recorder.endRecording();
  final out = await picture.toImage(width, height);
  picture.dispose();
  return out;
}

/// ui.Image → PNG 字节。
Future<Uint8List?> imageToPng(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data?.buffer.asUint8List();
}
