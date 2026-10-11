import 'dart:math' as math;
import 'dart:typed_data';

import 'package:denial_screenshot/src/scroll_stitch.dart';
import 'package:flutter_test/flutter_test.dart';

int _hash(int x, int y, int seed) {
  var h = x * 374761393 + y * 668265263 + seed * 2654435761;
  h = (h ^ (h >> 13)) * 1274126177;
  h = h ^ (h >> 16);
  return h & 0x7fffffff;
}

/// Aperiodic screenshot-like page: 8px value blocks that change every row, so
/// each row has a unique horizontal profile (no accidental vertical period).
Uint8List _page(int w, int h, int seed) {
  final b = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    final isText = _hash(0, y, seed) % 3 != 0;
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      final int v;
      if (isText && _hash(x >> 3, y, seed) % 5 != 0) {
        v = 20 + _hash(x >> 2, y, seed) % 70;
      } else {
        v = 185 + _hash(x >> 3, y, seed) % 70;
      }
      b[i] = v;
      b[i + 1] = v;
      b[i + 2] = (v + 8).clamp(0, 255);
      b[i + 3] = 255;
    }
  }
  return b;
}

Uint8List _crop(Uint8List page, int w, int y0, int h) {
  final stride = w * 4;
  return Uint8List.fromList(page.sublist(y0 * stride, (y0 + h) * stride));
}

Uint8List _linear(Uint8List src, double a, double b) {
  final out = Uint8List(src.length);
  for (var i = 0; i < src.length; i += 4) {
    for (var c = 0; c < 3; c++) {
      out[i + c] = (src[i + c] * a + b).round().clamp(0, 255);
    }
    out[i + 3] = src[i + 3];
  }
  return out;
}

bool _rowsEqual(Uint8List a, int aOff, Uint8List b, int bOff, int bytes) {
  for (var i = 0; i < bytes; i++) {
    if (a[aOff + i] != b[bOff + i]) return false;
  }
  return true;
}

void main() {
  const w = 200;
  const h = 500;
  const pageH = 3000;
  const step = 300; // 200px overlap between consecutive frames

  final page = _page(w, pageH, 7);
  final offsets = <int>[for (var y0 = 0; y0 + h <= pageH; y0 += step) y0];
  final covered = offsets.last + h;

  test('stitches a scrolling page and reproduces every row exactly', () {
    final stitcher = ScrollStitcher();
    for (final y0 in offsets) {
      stitcher.push(_crop(page, w, y0, h), w, h);
    }
    final result = stitcher.result!;
    expect(result.width, w);
    expect((result.height - covered).abs(), lessThanOrEqualTo(2));
    expect(stitcher.hadGap, isFalse);
    for (var y = 0; y < result.height; y++) {
      expect(
        _rowsEqual(result.rgba, y * w * 4, page, y * w * 4, w * 4),
        isTrue,
        reason: 'row $y should match the source page exactly',
      );
    }
  });

  test('NCC tolerates linear brightness/contrast changes per frame', () {
    final stitcher = ScrollStitcher();
    var k = 0;
    for (final y0 in offsets) {
      final frame = _crop(page, w, y0, h);
      stitcher.push(k.isOdd ? _linear(frame, 0.75, 30) : frame, w, h);
      k++;
    }
    final result = stitcher.result!;
    expect((result.height - covered).abs(), lessThanOrEqualTo(2));
    expect(stitcher.hadGap, isFalse);
  });

  test('tolerates small per-pixel noise', () {
    final stitcher = ScrollStitcher();
    final rng = math.Random(42);
    for (final y0 in offsets) {
      final frame = _crop(page, w, y0, h);
      for (var i = 0; i < frame.length; i += 4) {
        final delta = rng.nextInt(5) - 2;
        for (var c = 0; c < 3; c++) {
          frame[i + c] = (frame[i + c] + delta).clamp(0, 255);
        }
      }
      stitcher.push(frame, w, h);
    }
    expect((stitcher.result!.height - covered).abs(), lessThanOrEqualTo(3));
  });

  test('identical (static) frames are skipped, not duplicated', () {
    final stitcher = ScrollStitcher();
    stitcher.push(_crop(page, w, 0, h), w, h);
    final before = stitcher.canvasHeight;
    final step0 = stitcher.push(_crop(page, w, 0, h), w, h);
    expect(step0, ScrollStitchStep.noMatch);
    expect(stitcher.canvasHeight, before);
  });

  test('a frame with no overlap is dropped and flags a gap', () {
    final stitcher = ScrollStitcher();
    stitcher.push(_crop(page, w, 0, h), w, h);
    final unrelated = _page(w, h, 999);
    final step0 = stitcher.push(unrelated, w, h);
    expect(step0, ScrollStitchStep.noMatch);
    expect(stitcher.hadGap, isTrue);
    expect(stitcher.droppedFrames, 1);
  });

  test('a blank frame is ignored but does not count as a gap', () {
    final stitcher = ScrollStitcher();
    stitcher.push(_crop(page, w, 0, h), w, h);
    final blank = Uint8List(w * h * 4);
    for (var i = 0; i < blank.length; i += 4) {
      blank[i] = 250;
      blank[i + 1] = 250;
      blank[i + 2] = 250;
      blank[i + 3] = 255;
    }
    stitcher.push(blank, w, h);
    expect(stitcher.hadGap, isFalse);
  });

  test('a fixed header is kept once at the top while content scrolls', () {
    const headerH = 60;
    final header = _page(w, headerH, 555);
    Uint8List frame(int y0) {
      final content = _crop(page, w, y0, h - headerH);
      return Uint8List.fromList([...header, ...content]);
    }

    final stitcher = ScrollStitcher();
    final contentH = h - headerH;
    var lastY0 = 0;
    for (var y0 = 0; y0 + contentH <= pageH; y0 += step) {
      stitcher.push(frame(y0), w, h);
      lastY0 = y0;
    }
    final result = stitcher.result!;
    expect(
      (result.height - (headerH + lastY0 + contentH)).abs(),
      lessThanOrEqualTo(4),
    );
    expect(
      _rowsEqual(result.rgba, 10 * w * 4, header, 10 * w * 4, w * 4),
      isTrue,
    );
  });

  test('growable canvas keeps long captures exact', () {
    const lw = 300;
    const lh = 640;
    const lstep = 400;
    const lpageH = 12000;
    final big = _page(lw, lpageH, 3);
    final stitcher = ScrollStitcher();
    var n = 0;
    for (var y0 = 0; y0 + lh <= lpageH; y0 += lstep) {
      stitcher.push(_crop(big, lw, y0, lh), lw, lh);
      n++;
    }
    final result = stitcher.result!;
    expect(stitcher.hadGap, isFalse);
    final expected = (n - 1) * lstep + lh;
    expect((result.height - expected).abs(), lessThanOrEqualTo(2));
    for (var y = 0; y < result.height; y++) {
      expect(
        _rowsEqual(result.rgba, y * lw * 4, big, y * lw * 4, lw * 4),
        isTrue,
        reason: 'long row $y',
      );
    }
  });

  test('eraseRegionInPlace replaces the block with the slice above it', () {
    const w = 64;
    const h = 48;
    final frame = _page(w, h, 77);
    final before = Uint8List.fromList(frame);
    eraseRegionInPlace(frame, w, h, 20, 16, 20, 16);
    // 抹掉后，方块区域该等于上移 16 行的同一列内容。
    for (var y = 16; y < 32; y++) {
      for (var x = 20; x < 40; x++) {
        final i = (y * w + x) * 4;
        final s = ((y - 16) * w + x) * 4;
        expect(
          frame.sublist(i, i + 3),
          before.sublist(s, s + 3),
          reason: '$x,$y',
        );
      }
    }
    // 方块外面的像素不受影响。
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (x >= 20 && x < 40 && y >= 16 && y < 32) continue;
        final i = (y * w + x) * 4;
        expect(
          frame.sublist(i, i + 3),
          before.sublist(i, i + 3),
          reason: '$x,$y',
        );
      }
    }
  });

  test('eraseRegionInPlace clamps a partially off-frame cursor', () {
    const w = 64;
    const h = 48;
    final frame = Uint8List(w * h * 4);
    for (var i = 0; i < frame.length; i += 4) {
      frame[i] = (i >> 2) % 251;
      frame[i + 1] = (i ~/ 4) % 251;
      frame[i + 2] = 0;
      frame[i + 3] = 255;
    }
    // 方块大部分落在画面外：只应覆盖可见部分，不越界、不抛错。
    eraseRegionInPlace(frame, w, h, -10, -10, 40, 40);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = (y * w + x) * 4;
        final v = frame.sublist(i, i + 3);
        expect(v[3], 255);
        expect(
          v[0] <= 250 && v[1] <= 250 && v[0] >= 0 && v[1] >= 0 && v[2] == 0,
          isTrue,
          reason: '$x,$y',
        );
      }
    }
  });
}
