import 'dart:ui' as ui;

import 'package:denial_screenshot/src/editor/collage.dart';
import 'package:flutter_test/flutter_test.dart';

/// 造一张纯色小图（headless 引擎下 PictureRecorder 可用）。
Future<ui.Image> _solid(int w, int h) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF808080),
  );
  final picture = recorder.endRecording();
  return picture.toImage(w, h);
}

void main() {
  group('CollageSlot 自由放置模型', () {
    late ui.Image img;

    setUp(() async => img = await _solid(200, 100));
    tearDown(() => img.dispose());

    test('初始 = 适配框架（contain），imageRect 完整在框内', () {
      final slot = CollageSlot(
        image: img,
        rect: const ui.Rect.fromLTWH(0, 0, 400, 400),
      );
      // 200×100 放进 400×400：contain 受宽限制 → 400×200，居中。
      expect(slot.zoom, 1.0);
      expect(slot.imageRect.width, closeTo(400, 0.01));
      expect(slot.imageRect.height, closeTo(200, 0.01));
      expect(slot.imageRect.center, const ui.Offset(200, 200));
    });

    test('zoomAt 锚点钉住：指针下的源图点缩放前后屏幕位置不变', () {
      final slot = CollageSlot(
        image: img,
        rect: const ui.Rect.fromLTWH(0, 0, 400, 400),
      );
      final pointer = const ui.Offset(300, 260);
      // 指针下对应的"图内相对位置"（0..1）：缩放前后必须一致。
      double relX(ui.Rect r) => (pointer.dx - r.left) / r.width;
      double relY(ui.Rect r) => (pointer.dy - r.top) / r.height;
      final beforeX = relX(slot.imageRect);
      final beforeY = relY(slot.imageRect);

      slot.zoomAt(pointer, 1.5);
      expect(slot.zoom, closeTo(1.5, 0.001));
      expect(relX(slot.imageRect), closeTo(beforeX, 0.001));
      expect(relY(slot.imageRect), closeTo(beforeY, 0.001));

      slot.zoomAt(pointer, 1 / 1.5);
      expect(slot.zoom, closeTo(1.0, 0.001));
      expect(relX(slot.imageRect), closeTo(beforeX, 0.001));
      expect(relY(slot.imageRect), closeTo(beforeY, 0.001));
    });

    test('zoomAt 可小于框（0.2×）且受下限约束', () {
      final slot = CollageSlot(
        image: img,
        rect: const ui.Rect.fromLTWH(0, 0, 400, 400),
      );
      slot.zoomAt(const ui.Offset(200, 200), 0.1);
      expect(slot.zoom, CollageSlot.minZoom);
      expect(slot.imageRect.width, closeTo(400 * 0.2, 0.01));
    });

    test('panByWorld 无边界：图片可以完全拖出框架', () {
      final slot = CollageSlot(
        image: img,
        rect: const ui.Rect.fromLTWH(0, 0, 400, 400),
      );
      slot.panByWorld(const ui.Offset(5000, -5000));
      expect(slot.imageRect.center.dx, greaterThan(400));
      expect(slot.imageRect.center.dy, lessThan(0));
    });

    test('resizeFrameTo 图片在世界里钉住不动', () {
      final slot = CollageSlot(
        image: img,
        rect: const ui.Rect.fromLTWH(100, 100, 400, 400),
      );
      slot.zoomAt(const ui.Offset(300, 300), 2.0);
      slot.panByWorld(const ui.Offset(30, -20));
      final before = slot.imageRect;
      slot.resizeFrameTo(const ui.Rect.fromLTWH(150, 80, 500, 300));
      // 图心不动；世界尺寸不变（fit 变了但 zoom 补偿）。
      expect(slot.imageRect.center.dx, closeTo(before.center.dx, 0.5));
      expect(slot.imageRect.center.dy, closeTo(before.center.dy, 0.5));
      expect(slot.imageRect.width, closeTo(before.width, 0.5));
      expect(slot.imageRect.height, closeTo(before.height, 0.5));
    });

    test('restoreImageRect 往返：快照记录→还原得到同一 imageRect', () {
      final slot = CollageSlot(
        image: img,
        rect: const ui.Rect.fromLTWH(0, 0, 400, 400),
      );
      slot.zoomAt(const ui.Offset(150, 250), 1.8);
      slot.panByWorld(const ui.Offset(-40, 60));
      final state = (rect: slot.rect, imageRect: slot.imageRect);

      final restored = CollageSlot(image: img, rect: state.rect)
        ..restoreImageRect(state.imageRect);
      expect(restored.imageRect.left, closeTo(state.imageRect.left, 0.5));
      expect(restored.imageRect.top, closeTo(state.imageRect.top, 0.5));
      expect(restored.imageRect.width, closeTo(state.imageRect.width, 0.5));
      expect(restored.imageRect.height, closeTo(state.imageRect.height, 0.5));
    });
  });

  group('snapAlignFrame 松手吸附', () {
    const far = ui.Rect.fromLTWH(0, 0, 100, 100);

    test('容差内：左对齐其他框左边并给竖直参考线', () {
      final other = const ui.Rect.fromLTWH(200, 0, 100, 100);
      final moving = const ui.Rect.fromLTWH(204, 300, 100, 100);
      final snap = snapAlignFrame(
        moving: moving,
        others: [other],
        tolerance: 8,
      );
      expect(snap.rect.left, 200);
      expect(snap.rect.top, 300); // 纵向无候选：保持跟手位
      expect(snap.guides.length, 1);
      expect(snap.guides.first.width, lessThan(2)); // 竖线
    });

    test('容差外：原样返回无参考线（画布边/中线不再是靶子）', () {
      final snap = snapAlignFrame(
        moving: const ui.Rect.fromLTWH(60, 60, 100, 100),
        others: [far],
        tolerance: 8,
      );
      expect(snap.rect, const ui.Rect.fromLTWH(60, 60, 100, 100));
      expect(snap.guides, isEmpty);
    });

    test('横向取最近一条线：中线比其他边近时吸中线', () {
      // other: left 100 / center 160 / right 220。
      // moving: left 108 / center 158 / right 208 → 到 other.center 差 2
      // 最近（到 other.left 差 8 是边界值），吸到后 moving 中心=160。
      final other = const ui.Rect.fromLTWH(100, 0, 120, 100);
      final snap = snapAlignFrame(
        moving: const ui.Rect.fromLTWH(108, 300, 100, 100),
        others: [other],
        tolerance: 8,
      );
      expect(snap.rect.center.dx, 160);
      expect(snap.guides.length, 1);
    });

    test('无其他框：绝不吸附', () {
      final snap = snapAlignFrame(
        moving: const ui.Rect.fromLTWH(3, 4, 100, 100),
        others: const [],
        tolerance: 8,
      );
      expect(snap.rect, const ui.Rect.fromLTWH(3, 4, 100, 100));
      expect(snap.guides, isEmpty);
    });
  });

  group('collageBounds 包围盒', () {
    test('多框并集', () {
      final slots = [
        (const ui.Rect.fromLTWH(10, 20, 100, 50)),
        (const ui.Rect.fromLTWH(80, 5, 60, 90)),
      ].map((r) => _rectSlot(r)).toList();
      final bounds = collageBounds(slots)!;
      expect(bounds, const ui.Rect.fromLTWH(10, 5, 130, 90));
      for (final slot in slots) {
        slot.dispose();
      }
    });

    test('空列表返回 null', () {
      expect(collageBounds(const []), isNull);
    });
  });
}

/// 只为 bounds 测试造一个带图的最小槽。
CollageSlot _rectSlot(ui.Rect rect) {
  // 共享一张 1×1 图即可：bounds 只看 rect。
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder)
      .drawLine(const ui.Offset(0, 0), const ui.Offset(1, 1), ui.Paint());
  final image = (recorder.endRecording()).toImageSync(1, 1);
  return CollageSlot(image: image, rect: rect);
}
