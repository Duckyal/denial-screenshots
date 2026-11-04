/// 拼图 / 拆图的纯合成逻辑：只吃 `ui.Image`，产出 `ui.Image`，不碰编辑器
/// 状态，方便单测与「更多功能」面板复用。
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

/// 拼图工作台的一个框架槽：框架矩形（世界坐标）+ 框内图片的**取景窗口**
/// （源图像素坐标）。图片永远盖满框架（cover）：拖拽 = 平移取景、滚轮 =
/// 缩放取景范围、手柄调框架 = 改窗口形状。窗口自动夹在图片边界内，框架
/// 里永不露白。撤销快照记录 (rect, frame) 一对值即可完整还原。
final class CollageSlot {
  CollageSlot({required this.image, required this.rect})
    : frame = const ui.Rect.fromLTWH(0, 0, 1, 1) {
    // 初始 = cover 基准（恰好盖满框架），取景中心在图片正中。
    frame = _frameFor(
      rect.size,
      1.0,
      ui.Offset(image.width / 2.0, image.height / 2.0),
    );
  }

  final ui.Image image;

  /// 框架矩形（世界坐标），手柄可原地调整。
  ui.Rect rect;

  /// 取景窗口：源图像素坐标下当前显示的部分，宽高比恒等于框架宽高比，
  /// 且完整落在图片内。
  ui.Rect frame;

  static const minSide = 60.0;
  static const maxZoom = 8.0;

  ui.Size get _imgSize =>
      ui.Size(image.width.toDouble(), image.height.toDouble());

  /// cover 基准窗口：恰好盖满框架的最小取景（zoom = 1 时的 frame 尺寸）。
  ui.Size _baseFrame(ui.Size slotSize) {
    final img = _imgSize;
    if (img.width <= 0 || img.height <= 0 || slotSize.width <= 0) {
      return const ui.Size(1, 1);
    }
    // 宽高比 = 框架；取"能盖满框架"里最小的窗口 = 另一轴贴满图片。
    final byHeight = ui.Size(
      img.height * slotSize.width / slotSize.height,
      img.height,
    );
    return byHeight.width <= img.width
        ? byHeight
        : ui.Size(img.width, img.width * slotSize.height / slotSize.width);
  }

  /// 当前放大倍率（1 = 恰好盖满）。
  double get zoom {
    final base = _baseFrame(rect.size);
    return base.width <= 0
        ? 1.0
        : (base.width / frame.width).clamp(1.0, maxZoom);
  }

  /// 以 [center]（源图像素）为中心、[zoom] 倍率下的窗口，夹进图片边界。
  ui.Rect _frameFor(ui.Size slotSize, double zoom, ui.Offset center) {
    final base = _baseFrame(slotSize);
    final z = zoom.clamp(1.0, maxZoom);
    final w = math.min(base.width / z, _imgSize.width);
    final h = math.min(base.height / z, _imgSize.height);
    return ui.Rect.fromLTWH(
      (center.dx - w / 2).clamp(0.0, math.max(0.0, _imgSize.width - w)),
      (center.dy - h / 2).clamp(0.0, math.max(0.0, _imgSize.height - h)),
      w,
      h,
    );
  }

  /// 平移：框架内拖动 [deltaWorld]（世界坐标）→ 看到的内容跟着手指走
  /// （窗口反向移动，按 源图像素/世界像素 比例换算）。
  void panByWorld(ui.Offset deltaWorld) {
    final k = frame.width / rect.width;
    frame = _frameFor(rect.size, zoom, frame.center - deltaWorld * k);
  }

  /// 滚轮缩放取景：以指针下的源图点为锚（缩放时指针指着的内容不动）。
  void zoomAt(ui.Offset worldPoint, double factor) {
    final rel = ui.Offset(
      ((worldPoint.dx - rect.left) / rect.width).clamp(0.0, 1.0),
      ((worldPoint.dy - rect.top) / rect.height).clamp(0.0, 1.0),
    );
    final anchor = ui.Offset(
      frame.left + rel.dx * frame.width,
      frame.top + rel.dy * frame.height,
    );
    final next = (zoom * factor).clamp(1.0, maxZoom);
    final base = _baseFrame(rect.size);
    final w = math.min(base.width / next, _imgSize.width);
    final h = math.min(base.height / next, _imgSize.height);
    frame = ui.Rect.fromLTWH(
      (anchor.dx - rel.dx * w).clamp(0.0, math.max(0.0, _imgSize.width - w)),
      (anchor.dy - rel.dy * h).clamp(0.0, math.max(0.0, _imgSize.height - h)),
      w,
      h,
    );
  }

  /// 手柄调整框架后：保持取景中心与倍率，按新框架形状重算窗口。
  void reframeAfterResize() {
    frame = _frameFor(rect.size, zoom, frame.center);
  }

  /// 整体移动框架（世界坐标 delta）：取景窗口原样跟着走（看到的内容
  /// 不变，只是框挪位置）。
  void moveByWorld(ui.Offset deltaWorld) {
    rect = rect.shift(deltaWorld);
  }

  /// 绘制目标 = 框架本身（cover 模型下图必盖满框，无内缩偏移）。
  ui.Rect get contentRect => rect;
  ui.Rect get sourceRect => frame;

  void dispose() => image.dispose();
}

/// 按槽数与图片尺寸算网格布局：返回（世界尺寸，各槽框架矩形）。
({ui.Size world, List<ui.Rect> rects}) collageLayout(
  List<ui.Image> images, {
  int? columns,
  int gap = 12,
}) {
  final (rows: rows, cols: cols) = gridFor(images.length, columns);
  // 面积归一的方形格：边长 = 全体最大图面积的平方根。默认不再是
  // "最大宽×最大高"的扁长方形；每张图 contain 居中，框可再手动调。
  var maxArea = 0.0;
  for (final image in images) {
    maxArea = math.max(maxArea, (image.width * image.height).toDouble());
  }
  final side = math.max(1, math.sqrt(maxArea).round());
  final cellW = side;
  final cellH = side;
  final width = cols * cellW + (cols + 1) * gap;
  final height = rows * cellH + (rows + 1) * gap;
  final rects = <ui.Rect>[];
  for (var i = 0; i < images.length; i++) {
    rects.add(
      ui.Rect.fromLTWH(
        (gap + (i % cols) * (cellW + gap)).toDouble(),
        (gap + (i ~/ cols) * (cellH + gap)).toDouble(),
        cellW.toDouble(),
        cellH.toDouble(),
      ),
    );
  }
  return (world: ui.Size(width.toDouble(), height.toDouble()), rects: rects);
}

/// 所有框架的并集包围盒（世界坐标）：保存/复制/置顶只出这块，框外的
/// 留白（含透明）不再烙白底强制整块 world 出图。空槽返回 null。
ui.Rect? collageBounds(List<CollageSlot> slots) {
  if (slots.isEmpty) return null;
  var left = slots.first.rect.left;
  var top = slots.first.rect.top;
  var right = slots.first.rect.right;
  var bottom = slots.first.rect.bottom;
  for (final slot in slots) {
    left = math.min(left, slot.rect.left);
    top = math.min(top, slot.rect.top);
    right = math.max(right, slot.rect.right);
    bottom = math.max(bottom, slot.rect.bottom);
  }
  return ui.Rect.fromLTRB(left, top, right, bottom);
}

/// 烘焙工作台为一张成品图：背景 + 每槽（clip 框架、按 pan/zoom 画内容）。
/// [showGuides] 仅预览用（导出必须 false，框架线不烙进图里）。
Future<ui.Image?> bakeCollage(
  List<CollageSlot> slots,
  ui.Size world, {
  ui.Color background = const ui.Color(0x00000000),
  ui.Rect? crop,
}) async {
  final area = crop ?? (ui.Offset.zero & world);
  final w = area.width.round();
  final h = area.height.round();
  if (w <= 0 || h <= 0) return null;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder, ui.Offset.zero & area.size);
  canvas.translate(-area.left, -area.top);
  if (background.a > 0) {
    canvas.drawRect(area, ui.Paint()..color = background);
  }
  final paint = ui.Paint()..filterQuality = ui.FilterQuality.medium;
  for (final slot in slots) {
    canvas.save();
    canvas.clipRect(slot.rect);
    canvas.drawImageRect(slot.image, slot.sourceRect, slot.contentRect, paint);
    canvas.restore();
  }
  final picture = recorder.endRecording();
  final out = await picture.toImage(w, h);
  picture.dispose();
  return out;
}

/// ui.Image → PNG 字节。
Future<Uint8List?> imageToPng(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data?.buffer.asUint8List();
}
