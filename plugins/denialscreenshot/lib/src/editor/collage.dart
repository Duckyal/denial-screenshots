/// 拼图 / 拆图的纯合成逻辑：只吃 `ui.Image`，产出 `ui.Image`，不碰编辑器
/// 状态，方便单测与两处入口（工具栏）复用。
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

/// 拆图：把 [image] 均分 rows×cols 块，块四周留 [gap] 背景色（烙进每块，
/// 所见即所拆）。返回按行优先顺序的 N 张图，调用方负责 dispose 原件。
Future<List<ui.Image>> splitGrid(
  ui.Image image, {
  required int rows,
  required int cols,
  int gap = 0,
  ui.Color background = const ui.Color(0xFFFFFFFF),
}) async {
  final r = math.max(1, rows);
  final c = math.max(1, cols);
  final w = image.width ~/ c;
  final h = image.height ~/ r;
  final out = <ui.Image>[];
  final paint = ui.Paint()..filterQuality = ui.FilterQuality.medium;
  for (var i = 0; i < r * c; i++) {
    final row = i ~/ c;
    final col = i % c;
    // 最后一行/列吃掉整除余数，保证拆完无缝覆盖原图。
    final x = col * w;
    final y = row * h;
    final blockW = col == c - 1 ? image.width - x : w;
    final blockH = row == r - 1 ? image.height - y : h;
    if (blockW <= 0 || blockH <= 0) continue;
    final innerW = math.max(1, blockW - gap * 2);
    final innerH = math.max(1, blockH - gap * 2);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(
      recorder,
      ui.Offset.zero & ui.Size(blockW.toDouble(), blockH.toDouble()),
    );
    if (gap > 0) {
      canvas.drawRect(
        ui.Offset.zero & ui.Size(blockW.toDouble(), blockH.toDouble()),
        ui.Paint()..color = background,
      );
    }
    canvas.drawImageRect(
      image,
      ui.Rect.fromLTWH(
        x.toDouble(),
        y.toDouble(),
        blockW.toDouble(),
        blockH.toDouble(),
      ),
      ui.Rect.fromLTWH(
        (blockW - innerW) / 2,
        (blockH - innerH) / 2,
        innerW.toDouble(),
        innerH.toDouble(),
      ),
      paint,
    );
    final picture = recorder.endRecording();
    out.add(await picture.toImage(blockW, blockH));
    picture.dispose();
  }
  return out;
}

/// ui.Image → PNG 字节。
Future<Uint8List?> imageToPng(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data?.buffer.asUint8List();
}
