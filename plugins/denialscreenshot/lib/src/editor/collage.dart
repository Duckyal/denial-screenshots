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

/// 拼图工作台的一个框架槽：框架矩形（世界坐标）+ 框内图片的自由摆放
/// 状态（缩放倍率 + 平移偏移，均相对框架）。图片按「适配框架」为 1×
/// 基准：滚轮 0.2×–8× 随便调，**可以小于框架**（四周留白，构图用），
/// 也可以大于框架（只显示框住的部分，框架=开在图上的窗口）；平移不设
/// 边界限制，想怎么挪就怎么挪。撤销快照记录 (rect, imageRect) 一对
/// 矩形即可完整还原。
final class CollageSlot {
  CollageSlot({required this.image, required this.rect});

  final ui.Image image;

  /// 框架矩形（世界坐标），手柄可调大小、拖动可移动。
  ui.Rect rect;

  /// 相对框架的缩放倍率：1 = 恰好适配（contain），<1 图小于框，
  /// >1 图大于框（超出部分被框架裁掉）。
  double zoom = 1.0;

  /// 图心相对框心的偏移（世界坐标）。
  ui.Offset pan = ui.Offset.zero;

  /// 拆图：本格显示的原图区域（源矩形，原图像素坐标）。**仅逐格独立
  /// 模式**用（各格自己的那块）；联动模式下整张底图共享一组 zoom/pan，
  /// 每格是底图的一个窗口（源区域由 zoom/pan 算出，无需显式矩形）。
  /// 拼图工作台为 null（= 整张图，自由取景）。
  ui.Rect? sourceViewport;

  /// 联动取景的**共享锚点**（世界坐标）：底图整体摆放的参考框——所有格
  /// 共享它（底图在世界里只摆一份），每格是它在锚点内的窗口。联动时
  /// 设为整个网格矩形；逐格独立/拼图为 null（各自按自己的 rect 摆）。
  ui.Rect? anchorRect;

  static const minSide = 60.0;
  static const minZoom = 0.2;

  /// 上限 32×：拆图工作台初始取景 = 底图铺满 world，大图多格时
  /// 1/fitScale 可达 16+；拼图手动放大也够用了。
  static const maxZoom = 32.0;

  ui.Size get _imgSize =>
      ui.Size(image.width.toDouble(), image.height.toDouble());

  /// 摆放参考框：联动时用共享锚点（底图对所有格同一个位置），否则用
  /// 本格矩形。
  ui.Rect get _frameRect => anchorRect ?? rect;

  /// 适配基准：图完整放进参考框的最大比例（contain）。
  double get _fitScale {
    final img = _imgSize;
    final frame = _frameRect;
    if (img.width <= 0 ||
        img.height <= 0 ||
        frame.width <= 0 ||
        frame.height <= 0) {
      return 1.0;
    }
    return math.min(frame.width / img.width, frame.height / img.height);
  }

  /// 这一格实际取用的**源矩形**（原图像素坐标）：拆图=自己的源区域
  /// [sourceViewport]（各格不同，拼起来 = 原图或共享区域）；拼图=整张图。
  ui.Rect get effectiveSourceRect {
    final full = ui.Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    final vp = sourceViewport;
    if (vp == null) return full;
    final l = vp.left.clamp(0.0, full.right);
    final t = vp.top.clamp(0.0, full.bottom);
    final r = vp.right.clamp(0.0, full.right);
    final b = vp.bottom.clamp(0.0, full.bottom);
    if (r <= l || b <= t) return full;
    return ui.Rect.fromLTRB(l, t, r, b);
  }

  /// 图片当前占据的世界矩形（可能小于/大于框架；绘制与烘焙都按它）。
  /// 联动取景开启时用共享的 [linkZoom]/[linkPan] 代替本槽的 zoom/pan。
  ui.Rect get imageRect {
    if (fixedTarget) {
      // 逐格独立：源区域直接铺进格子（不做 contain 缩放）。
      return rect;
    }
    final base = _fitScale * zoom;
    final w = _imgSize.width * base;
    final h = _imgSize.height * base;
    // 拆图（oneToOne）：底图 1:1 贴原图，锚点 = 原图区域（世界坐标），
    // pan=0 时底图与原图重合，九格各看自己那块。
    // 拼图：contain 基准 + zoom/pan（自由取景）。
    return ui.Rect.fromCenter(
      center: _frameRect.center + pan,
      width: w,
      height: h,
    );
  }

  /// 拆图模式：目标矩形恒等于格子（源区域直接映射进格子）。
  bool fixedTarget = false;

  /// 拆图：底图按 **1:1** 贴原图（fit=1），九宫格框架是原图上的窗口——
  /// 每格显示原图对应那一块，拖动/缩放底图就是在原图上取景。
  bool oneToOne = false;

  /// 平移：框架内拖动 [deltaWorld]（世界坐标）→ 图片跟着手指走。
  void panByWorld(ui.Offset deltaWorld) {
    pan += deltaWorld;
  }

  /// 滚轮缩放：以指针下的世界点为锚（指针指着的内容不动）。
  void zoomAt(ui.Offset worldPoint, double factor) {
    final next = (zoom * factor).clamp(minZoom, maxZoom);
    if (next == zoom) return;
    // 指针相对"当前图心"的偏移；缩放 r 倍后图心沿反方向外移，指针下
    // 的内容保持钉住：C' = P + r*(C-P) ⇒ pan' = pan + (P-C)*(1-r)。
    final offset = worldPoint - (rect.center + pan);
    final ratio = next / zoom;
    pan = pan + offset * (1.0 - ratio);
    zoom = next;
  }

  /// 手柄调整框架：图片在世界坐标里钉住不动（位置与大小都不变），
  /// 框架矩形在其上变形——"窗口"心智：调框只改变露出范围，不挪内容。
  void resizeFrameTo(ui.Rect newRect) {
    if (newRect.width <= 0 || newRect.height <= 0) return;
    final oldImage = imageRect;
    final oldFit = _fitScale;
    rect = newRect;
    if (oldFit > 0 && _fitScale > 0) {
      zoom = (zoom * oldFit / _fitScale).clamp(minZoom, maxZoom);
    }
    pan = oldImage.center - rect.center;
  }

  /// 拆图：平移本格的源区域（选截原图哪一块），夹在原图范围内。
  void panSourceViewport(ui.Offset deltaSource) {
    final vp = sourceViewport;
    if (vp == null) return;
    final full = ui.Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    final left = (vp.left + deltaSource.dx).clamp(
      0.0,
      math.max(0.0, full.width - vp.width).toDouble(),
    );
    final top = (vp.top + deltaSource.dy).clamp(
      0.0,
      math.max(0.0, full.height - vp.height).toDouble(),
    );
    sourceViewport = ui.Rect.fromLTWH(left, top, vp.width, vp.height);
  }

  /// 拆图：缩放本格的源区域（围绕中心），夹在原图范围内。
  void zoomSourceViewport(double factor) {
    final vp = sourceViewport;
    if (vp == null) return;
    final full = ui.Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    final w = (vp.width * factor).clamp(8.0, full.width);
    final h = (vp.height * factor).clamp(8.0, full.height);
    var left = vp.center.dx - w / 2;
    var top = vp.center.dy - h / 2;
    left = left.clamp(0.0, math.max(0.0, full.width - w).toDouble());
    top = top.clamp(0.0, math.max(0.0, full.height - h).toDouble());
    sourceViewport = ui.Rect.fromLTWH(left, top, w, h);
  }

  /// 整体移动框架（世界坐标 delta）：图片跟着框走（相对位置不变）。
  void moveByWorld(ui.Offset deltaWorld) {
    rect = rect.shift(deltaWorld);
  }

  /// 撤销快照还原：用记录时的 imageRect 反推 pan/zoom。
  void restoreImageRect(ui.Rect imageRect) {
    pan = imageRect.center - rect.center;
    final img = _imgSize;
    // oneToOne 模式：底图 1:1 贴原图，fitScale 恒为 1（anchorRect = 原图区域），
    // 还原时直接用 imageRect 尺寸比上原图像素尺寸即可——别再乘/除 fitScale，
    // 否则 fitScale 被当成 contain 基准，缩放值完全错乱。
    if (oneToOne && anchorRect != null) {
      zoom = (imageRect.width / img.width).clamp(minZoom, maxZoom);
      return;
    }
    final fit = _fitScale;
    if (img.width <= 0 || img.height <= 0 || fit <= 0) return;
    zoom = (imageRect.width / img.width / fit).clamp(minZoom, maxZoom);
  }

  void dispose() => image.dispose();
}

/// 桌面式对齐（重做版）：**只对齐其他框架的边/中线**——不再拿画布
/// 边缘和中线当靶子（上一版线太密、吸得突兀被否）。[moving] 的
/// 左/中/右 与 [others] 各框的左/中/右 距离 ≤ [tolerance] 时吸附到
/// 该线（横纵独立、取最近一条），命中的线作为参考线返回：拖拽中实时
/// 显示蓝线提示，松手才真正吸附。无命中则原样返回。
({ui.Rect rect, List<ui.Rect> guides}) snapAlignFrame({
  required ui.Rect moving,
  required List<ui.Rect> others,
  required double tolerance,
  double lineWidth = 1.5,
  double overhang = 40.0,
}) {
  final guides = <ui.Rect>[];
  double? bestX;
  var bestXD = tolerance + 1;
  double? bestXLine;
  for (final r in others) {
    for (final line in [r.left, r.center.dx, r.right]) {
      for (final edge in [moving.left, moving.center.dx, moving.right]) {
        final d = (line - edge).abs();
        if (d <= tolerance && d < bestXD) {
          bestXD = d;
          bestX = line - edge;
          bestXLine = line;
        }
      }
    }
  }
  double? bestY;
  var bestYD = tolerance + 1;
  double? bestYLine;
  for (final r in others) {
    for (final line in [r.top, r.center.dy, r.bottom]) {
      for (final edge in [moving.top, moving.center.dy, moving.bottom]) {
        final d = (line - edge).abs();
        if (d <= tolerance && d < bestYD) {
          bestYD = d;
          bestY = line - edge;
          bestYLine = line;
        }
      }
    }
  }
  final left = moving.left + (bestX ?? 0);
  final top = moving.top + (bestY ?? 0);
  final out = ui.Rect.fromLTWH(left, top, moving.width, moving.height);
  if (bestXLine != null) {
    guides.add(
      ui.Rect.fromLTWH(
        bestXLine - lineWidth / 2,
        out.top - overhang,
        lineWidth,
        out.height + overhang * 2,
      ),
    );
  }
  if (bestYLine != null) {
    guides.add(
      ui.Rect.fromLTWH(
        out.left - overhang,
        bestYLine - lineWidth / 2,
        out.width + overhang * 2,
        lineWidth,
      ),
    );
  }
  return (rect: out, guides: guides);
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
    canvas.drawImageRect(
      slot.image,
      slot.effectiveSourceRect,
      slot.imageRect,
      paint,
    );
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
