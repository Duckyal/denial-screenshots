import 'dart:math' as math;
import 'dart:typed_data';

/// 滚动长截图的纯算法核心：不依赖 `dart:ui` / Flutter，只吃 RGBA 字节，
/// 方便单测与后续替换匹配核。采集、编解码留在 `scroll_capture.dart`。
///
/// 设计对照 mark-shot 的滚动拼接器，但把匹配核从「3 带平均亮度的绝对差」
/// 升级为「多带 RGB 描述子 + 零均值归一化互相关（NCC）」：
///   - 每帧每行只算一次描述子（左/中/右…… N 条横向采样带，每条带取均色），
///     匹配/定位全程复用；
///   - NCC 对亮度 / 对比度 / 主题变化免疫，且置信度天然落在 [0, 2]（0 最好），
///     比裸绝对差稳定得多；
///   - 相邻帧先按上次位移预测再向两侧搜索（滚动有惯性），失配就改在整个
///     长图里找位置兜底；仍无法可信对齐的帧宁可丢弃并置 `hadGap`，也不
///     盲贴（盲贴要么重复要么断层）；
///   - 画布用可增长缓冲（容量翻倍），追加是摊还 O(1)，长图不再每帧整体拷贝；
///   - 学习吸顶 / 吸底固定带，匹配时排除、追加时裁掉旧的固定带。

/// 单帧在拼接管线里的归属。
enum ScrollStitchStep {
  /// 种子帧，已建立长图画布。
  firstFrame,

  /// 追加了新的纵向内容。
  appended,

  /// 帧落在已拼接的内容内，仅重新锚定（防止重复粘贴）。
  insideKnown,

  /// 无法建立可信重叠 / 帧无效，已丢弃。
  noMatch,
}

/// 拼接结果：RGBA8888，行优先。[rgba] 可能指向拼接器的内部缓冲，需要长期
/// 保留时请自行拷贝；一般直接编码 PNG 即可。
final class ScrollStitchResult {
  const ScrollStitchResult(this.rgba, this.width, this.height);

  final Uint8List rgba;
  final int width;
  final int height;
}

/// 拼接参数，作用于 0..255 尺度。默认值针对 150ms 连拍的手动滚动会话。
final class ScrollStitchConfig {
  const ScrollStitchConfig({
    this.minOverlap = 80,
    this.acceptCost = 0.12,
    this.sharpCost = 0.015,
    this.peakMargin = 0.02,
    this.minAppend = 12,
    this.bandCount = 8,
    this.bandSamples = 24,
    this.knownCoarse = 8,
    this.topRatio = 0.10,
    this.bottomRatio = 0.08,
    this.minIgnorePx = 16,
    this.maxBandDivisor = 3,
    this.maxCanvasHeight = 30000,
    this.minScrollForDetect = 12,
    this.fixedRowMaxDiff = 6.0,
    this.blankSpan = 2.0,
    this.dropUnmatched = true,
  });

  /// 重叠行数达到多少才信这次匹配。
  final int minOverlap;

  /// NCC 代价上限：代价 = 1 - 相关系数，越小越像。超过即判失真。
  final double acceptCost;

  /// 差异低到接近 0 时几乎不存在伪峰（重复行除外），相邻帧搜索里遇到即可
  /// 提前收工。
  final double sharpCost;

  /// 可信偏移必须比次优偏移"尖"出的代价：真正的对齐处是谷底，噪声背景
  /// 到处都差不多低。第二优与最优差值小过它就不信。
  final double peakMargin;

  /// 净新增行数少于它就不落笔（防滚动抖动把碎片反复贴进去）。
  final int minAppend;

  /// 行签名横向采样带数。
  final int bandCount;

  /// 每条采样带的横向采样列数。
  final int bandSamples;

  /// 已知位置粗搜步长。
  final int knownCoarse;

  /// 比例边缘忽略：顶部/底部各占帧高的比例与下限像素。
  final double topRatio;
  final double bottomRatio;
  final int minIgnorePx;

  /// 固定带最多占帧高的 1/3。
  final int maxBandDivisor;

  /// 长图高度上限（像素）。
  final int maxCanvasHeight;

  /// 判定固定带所需的滚动位移，太小说明不了"固定"。
  final int minScrollForDetect;

  /// 固定带"行相同"的平均色差上限。
  final double fixedRowMaxDiff;

  /// 空白/纯色帧判定：描述子跨度低于它就直丢。
  final double blankSpan;

  /// 相邻与整图都对齐不上时：true 丢弃该帧并置 `hadGap`；false 退回旧的
  /// "整帧当新内容贴到底部"（可能重复/断层）。
  final bool dropUnmatched;

  /// 每行描述子宽度（R/G/B 三通道 × 采样带数）。
  int get descriptorWidth => bandCount * 3;
}

/// mark-shot 风格的滚动拼接器：长图 + 每帧行描述子，先相邻预测、再整图定位，
/// 带 NCC 信任门槛、固定带学习与已见内容的重锚定。
final class ScrollStitcher {
  ScrollStitcher({this.config = const ScrollStitchConfig()});

  final ScrollStitchConfig config;

  Uint8List? _pixels;
  int _capRows = 0;
  int _canvasW = 0;
  int _canvasH = 0;
  Float32List? _sigs;
  int _sigCapRows = 0;
  _BandCols? _bandCols;

  Float32List? _lastSigs;
  Uint8List? _lastFull;
  int _lastH = 0;
  int _anchorPos = 0;
  int _lastOff = 0;
  int _dropped = 0;

  final _BandState _fixedTop = _BandState();
  final _BandState _fixedBottom = _BandState();

  int get canvasHeight => _canvasH;

  /// 是否出现过无法对齐、被丢弃的帧（长图可能有缺失段落）。
  bool get hadGap => _dropped > 0;

  /// 被丢弃的帧数。
  int get droppedFrames => _dropped;

  /// 当前长图内容；无有效帧返回 null。
  ScrollStitchResult? get result {
    final pixels = _pixels;
    if (pixels == null || _canvasW == 0 || _canvasH == 0) return null;
    final length = _canvasH * _canvasW * 4;
    final bytes = pixels.length == length
        ? pixels
        : Uint8List.sublistView(pixels, 0, length);
    return ScrollStitchResult(bytes, _canvasW, _canvasH);
  }

  /// 复用一次 `Float32List` 视图比较：静止帧（用户还没滚或刚停下）不进匹配。
  ScrollStitchStep push(Uint8List rgba, int width, int height) {
    if (width <= 0 || height <= 0 || height < config.minOverlap) {
      return ScrollStitchStep.noMatch;
    }
    _bandCols ??= _BandCols(width, config);
    if (_bandCols!.width != width) return ScrollStitchStep.noMatch;
    final sigs = _rowSigs(rgba, width, height, _bandCols!);
    if (_pixels == null) {
      _canvasW = width;
      _canvasH = height;
      _capRows = height;
      _pixels = Uint8List.fromList(rgba);
      _sigs = sigs;
      _sigCapRows = height;
      _lastSigs = sigs;
      _lastFull = rgba;
      _lastH = height;
      _anchorPos = 0;
      _lastOff = 0;
      _dropped = 0;
      _fixedTop.reset();
      _fixedBottom.reset();
      return ScrollStitchStep.firstFrame;
    }
    if (width != _canvasW) return ScrollStitchStep.noMatch;
    final lastSigs = _lastSigs;
    if (lastSigs != null && _identicalSigs(lastSigs, sigs)) {
      return ScrollStitchStep.noMatch;
    }
    final (off, cost, peak) = _findOffset(lastSigs!, _lastH, sigs, height);
    var pos = _anchorPos + off;
    if (cost > config.acceptCost || peak < config.peakMargin) {
      // 相邻匹配不可靠：先在整个长图里找这帧该放的位置，坏帧只丢这一帧。
      final (knownPos, knownCost, knownPeak) = _findPlacement(
        sigs,
        height,
        pos,
      );
      if (knownCost <= config.acceptCost &&
          knownPeak >= config.peakMargin &&
          knownPos >= 0) {
        pos = knownPos;
      } else if (config.dropUnmatched) {
        // 全画布都对齐不上（多半是快滚跨帧，前帧已滚出窗外）：无法可信
        // 定位就直接丢弃并标记缺口，宁可少一段也不错贴重影。
        if (!_blankFrame(sigs)) _dropped++;
        return ScrollStitchStep.noMatch;
      } else {
        final capRoom = config.maxCanvasHeight - _canvasH;
        if (capRoom < config.minAppend) return ScrollStitchStep.noMatch;
        if (_blankFrame(sigs)) return ScrollStitchStep.noMatch;
        final amount = math.min(height, capRoom);
        return _appendBottom(
          rgba,
          sigs,
          height,
          amount,
          _canvasH,
          _canvasH - _anchorPos,
        );
      }
    }
    final move = pos - _anchorPos;
    final lastFull = _lastFull;
    if (lastFull != null && move.abs() >= config.minScrollForDetect) {
      final (top, bottom) = _detectFixedBands(lastFull, rgba, width, height);
      _fixedTop.update(top);
      _fixedBottom.update(bottom);
    }
    _lastFull = rgba;
    _lastSigs = sigs;
    _lastH = height;
    _lastOff = move;
    final amount = pos + height - _canvasH;
    if (amount >= config.minAppend) {
      return _appendBottom(rgba, sigs, height, amount, pos, move);
    }
    if (pos >= 0) {
      // 帧落在已拼接内容里（含底部不足 minAppend 的碎片）：只重锚不重贴。
      _anchorPos = pos;
      return ScrollStitchStep.insideKnown;
    }
    return ScrollStitchStep.noMatch;
  }

  bool _blankFrame(Float32List sigs) {
    var minS = sigs.first;
    var maxS = sigs.first;
    for (final v in sigs) {
      if (v < minS) {
        minS = v;
      } else if (v > maxS) {
        maxS = v;
      }
    }
    return maxS - minS < config.blankSpan;
  }

  void _ensurePixelCapacity(int rows) {
    if (rows <= _capRows) return;
    var cap = _capRows == 0 ? rows : _capRows;
    while (cap < rows) {
      cap *= 2;
    }
    final grown = Uint8List(cap * _canvasW * 4);
    grown.setRange(0, _canvasH * _canvasW * 4, _pixels!);
    _pixels = grown;
    _capRows = cap;
  }

  void _ensureSigCapacity(int rows) {
    if (rows <= _sigCapRows) return;
    final dw = config.descriptorWidth;
    var cap = _sigCapRows == 0 ? rows : _sigCapRows;
    while (cap < rows) {
      cap *= 2;
    }
    final grown = Float32List(cap * dw);
    grown.setRange(0, _canvasH * dw, _sigs!);
    _sigs = grown;
    _sigCapRows = cap;
  }

  /// 追加：先裁掉长图尾部残留的旧固定带（会被新切片里相同的行覆盖），
  /// 再附上这一帧底部新增的 [amount] 行。
  ScrollStitchStep _appendBottom(
    Uint8List frame,
    Float32List sigs,
    int fh,
    int amount,
    int pos,
    int move,
  ) {
    final capRoom = config.maxCanvasHeight - _canvasH;
    if (amount > capRoom) amount = capRoom;
    if (amount < config.minAppend) {
      _anchorPos = pos;
      return ScrollStitchStep.insideKnown;
    }
    var bottomTrim = 0;
    if (_fixedBottom.committed > 0) {
      final maxTrim = math.max(
        0,
        math.min(
          fh ~/ config.maxBandDivisor,
          math.min(_canvasH ~/ config.maxBandDivisor, _canvasH - 1),
        ),
      );
      bottomTrim = math.min(_fixedBottom.committed, maxTrim);
    }
    final newH = _canvasH - bottomTrim + amount;
    _ensurePixelCapacity(newH);
    _ensureSigCapacity(newH);
    final dstRow = _canvasH - bottomTrim;
    final stride = _canvasW * 4;
    final pixelDst = dstRow * stride;
    final pixelSrc = (fh - amount) * stride;
    _pixels!.setRange(pixelDst, pixelDst + amount * stride, frame, pixelSrc);
    final dw = config.descriptorWidth;
    final sigDst = dstRow * dw;
    final sigSrc = (fh - amount) * dw;
    _sigs!.setRange(sigDst, sigDst + amount * dw, sigs, sigSrc);
    _canvasH = newH;
    _anchorPos = pos;
    _lastSigs = sigs;
    _lastH = fh;
    _lastOff = move;
    _lastFull = frame;
    return ScrollStitchStep.appended;
  }

  /// 相邻帧偏移搜索：以最近一次位移为预测中心，由近及远扫遍全部可行偏移，
  /// 同分时先到者胜（连续滚动假设），遇到几乎完全重合的强匹配提前收工
  /// （平滑背景/重复行会产生大量伪峰，全范围线性扫会被伪峰截胡）。
  /// 返回 (偏移, 代价, 峰度)，偏移>0 表示滚向下方/新内容；峰度 = 次优−
  /// 最优，太小说明到处都是候选、不可信。
  (int, double, double) _findOffset(
    Float32List last,
    int lastH,
    Float32List frame,
    int fh,
  ) {
    final fixedTop = _fixedTop.committed;
    final fixedBottom = _fixedBottom.committed;
    final maxOff = math.max(0, lastH - config.minOverlap);
    final predicted = _lastOff.clamp(-maxOff, maxOff).toInt();
    var best = predicted;
    var bestCost = double.infinity;
    var second = double.infinity;
    void consider(int o, double d) {
      if (d < bestCost) {
        second = bestCost;
        best = o;
        bestCost = d;
      } else if (d < second) {
        second = d;
      }
    }

    for (var delta = 0; delta <= maxOff; delta++) {
      final plus = predicted + delta;
      if (plus <= maxOff) {
        final d = _overlapCost(
          last,
          lastH,
          frame,
          fh,
          plus,
          fixedTop,
          fixedBottom,
        );
        consider(plus, d);
        if (d < config.sharpCost) return (best, bestCost, second - bestCost);
      }
      if (delta != 0) {
        final minus = predicted - delta;
        if (minus >= -maxOff) {
          final d = _overlapCost(
            last,
            lastH,
            frame,
            fh,
            minus,
            fixedTop,
            fixedBottom,
          );
          consider(minus, d);
          if (d < config.sharpCost) return (best, bestCost, second - bestCost);
        }
      }
    }
    return (best, bestCost, second - bestCost);
  }

  /// 在整个长图里找这帧的可信位置（含越过底边的新内容），粗搜 + 精化，
  /// 偏好离预测位置最近的可信落点。返回 (绝对行, 代价, 峰度)。
  (int, double, double) _findPlacement(
    Float32List frame,
    int fh,
    int predictedPos,
  ) {
    final canvasSigs = _sigs!;
    if (canvasSigs.length < _canvasH * config.descriptorWidth) {
      return (0, double.infinity, 0);
    }
    final fixedTop = _fixedTop.committed;
    final fixedBottom = _fixedBottom.committed;
    final maxPos = math.max(0, _canvasH - config.minOverlap);
    final minPos = config.minOverlap - fh;
    var bestPos = predictedPos.clamp(minPos, maxPos).toInt();
    var bestCost = double.infinity;
    var second = double.infinity;
    var bestGoodPos = bestPos;
    var bestGoodCost = double.infinity;
    var bestGoodDist = 0x7fffffff;
    void visit(int p) {
      p = p.clamp(minPos, maxPos).toInt();
      final d = _overlapCost(
        canvasSigs,
        _canvasH,
        frame,
        fh,
        p,
        fixedTop,
        fixedBottom,
      );
      if (d < bestCost) {
        second = bestCost;
        bestCost = d;
        bestPos = p;
      } else if (d < second) {
        second = d;
      }
      if (d <= config.acceptCost) {
        final dist = (p - predictedPos).abs();
        if (dist < bestGoodDist || (dist == bestGoodDist && d < bestGoodCost)) {
          bestGoodDist = dist;
          bestGoodCost = d;
          bestGoodPos = p;
        }
      }
    }

    visit(predictedPos);
    visit(_anchorPos);
    visit(0);
    visit(math.max(0, maxPos));
    visit(minPos);
    for (var p = math.max(0, minPos); p <= maxPos; p += config.knownCoarse) {
      visit(p);
    }
    final refineFrom = math.max(minPos, bestPos - config.knownCoarse);
    final refineTo = math.min(maxPos, bestPos + config.knownCoarse);
    for (var p = refineFrom; p <= refineTo; p++) {
      visit(p);
    }
    if (bestGoodCost <= config.acceptCost) {
      return (bestGoodPos, bestGoodCost, second - bestCost);
    }
    return (bestPos, bestCost, second - bestCost);
  }

  /// 行描述子：每行在 [bandCount] 条横向采样带上的平均 R/G/B，
  /// 长度 = h * bandCount * 3。
  Float32List _rowSigs(Uint8List rgba, int width, int height, _BandCols cols) {
    final bands = cols.bands;
    final out = Float32List(height * config.descriptorWidth);
    for (var y = 0; y < height; y++) {
      final rowBase = y * width * 4;
      final sigBase = y * config.descriptorWidth;
      for (var g = 0; g < bands.length; g++) {
        final xs = bands[g];
        var r = 0.0;
        var gg = 0.0;
        var b = 0.0;
        for (final x in xs) {
          final i = rowBase + x * 4;
          r += rgba[i];
          gg += rgba[i + 1];
          b += rgba[i + 2];
        }
        final n = xs.length;
        final o = sigBase + g * 3;
        out[o] = r / n;
        out[o + 1] = gg / n;
        out[o + 2] = b / n;
      }
    }
    return out;
  }

  /// 零均值归一化互相关（NCC）代价：对重叠窗口内所有可用行、所有描述子分量
  /// 做一次全局标准化，代价 = 1 - 相关系数（0 最好，最大 2）。对亮度 / 对比度
  /// 线性变化免疫；窗口内几乎没有起伏（纯色）时直接返回无穷大，不作为锚点。
  double _overlapCost(
    Float32List a,
    int aRows,
    Float32List b,
    int bRows,
    int offset,
    int fixedTop,
    int fixedBottom,
  ) {
    final len = offset >= 0
        ? math.min(aRows - offset, bRows)
        : math.min(aRows, bRows + offset);
    if (len < config.minOverlap) return double.infinity;
    final h = math.min(aRows, bRows);
    final softCrop =
        len >=
        config.minOverlap + _contentTopIgnore(h) + _contentBottomIgnore(h);
    final startA = offset >= 0 ? offset : 0;
    final startB = offset >= 0 ? 0 : -offset;
    final dw = config.descriptorWidth;
    var sumA = 0.0;
    var sumB = 0.0;
    var sumAA = 0.0;
    var sumBB = 0.0;
    var sumAB = 0.0;
    var count = 0;
    var rows = 0;
    for (var i = 0; i < len; i++) {
      final y1 = startA + i;
      final y2 = startB + i;
      if (!_usableRow(y1, aRows, fixedTop, fixedBottom, softCrop) ||
          !_usableRow(y2, bRows, fixedTop, fixedBottom, softCrop)) {
        continue;
      }
      rows++;
      final i1 = y1 * dw;
      final i2 = y2 * dw;
      for (var c = 0; c < dw; c++) {
        final av = a[i1 + c];
        final bv = b[i2 + c];
        sumA += av;
        sumB += bv;
        sumAA += av * av;
        sumBB += bv * bv;
        sumAB += av * bv;
      }
      count += dw;
    }
    final required = softCrop
        ? math.max(24, config.minOverlap ~/ 2)
        : config.minOverlap;
    if (count == 0 || rows < required) return double.infinity;
    final n = count.toDouble();
    final cov = sumAB - sumA * sumB / n;
    final varA = sumAA - sumA * sumA / n;
    final varB = sumBB - sumB * sumB / n;
    if (varA <= 1e-6 || varB <= 1e-6) return double.infinity;
    final ncc = cov / math.sqrt(varA * varB);
    if (ncc > 1.0) return 0.0;
    if (ncc < -1.0) return 2.0;
    return 1.0 - ncc;
  }

  bool _usableRow(int y, int h, int fixedTop, int fixedBottom, bool softCrop) {
    if (y < fixedTop || y >= h - fixedBottom) return false;
    return !softCrop || _isContentRow(y, h);
  }

  int _contentTopIgnore(int h) => h < 80
      ? 0
      : math.min(
          h ~/ 4,
          math.max(config.minIgnorePx, (h * config.topRatio).round()),
        );
  int _contentBottomIgnore(int h) => h < 80
      ? 0
      : math.min(
          h ~/ 4,
          math.max(config.minIgnorePx, (h * config.bottomRatio).round()),
        );
  bool _isContentRow(int y, int h) =>
      y >= _contentTopIgnore(h) && y < h - _contentBottomIgnore(h);

  /// 学习吸顶/吸底固定带：跳过两侧滚动条，逐行比对两帧同一 y 的差异。
  (int, int) _detectFixedBands(Uint8List prev, Uint8List cur, int w, int h) {
    final limit = h ~/ config.maxBandDivisor;
    final side = _sideIgnore(w);
    var top = 0;
    while (top < limit) {
      final o = top * w * 4;
      if (_rowAbsDiff(prev, cur, w, o, o, side) > config.fixedRowMaxDiff) {
        break;
      }
      top++;
    }
    var bottom = 0;
    while (bottom < limit) {
      final o = (h - 1 - bottom) * w * 4;
      if (_rowAbsDiff(prev, cur, w, o, o, side) > config.fixedRowMaxDiff) {
        break;
      }
      bottom++;
    }
    return (top, bottom);
  }

  double _rowAbsDiff(
    Uint8List a,
    Uint8List b,
    int w,
    int oa,
    int ob,
    int side,
  ) {
    final roi = w - side * 2;
    if (roi <= 0) return double.infinity;
    final step = math.max(1, roi ~/ 256);
    var sum = 0.0;
    var count = 0;
    for (var x = side; x < side + roi; x += step) {
      final ia = oa + x * 4;
      final ib = ob + x * 4;
      sum += (a[ia] - b[ib]).abs();
      sum += (a[ia + 1] - b[ib + 1]).abs();
      sum += (a[ia + 2] - b[ib + 2]).abs();
      count += 3;
    }
    return count > 0 ? sum / count : double.infinity;
  }

  int _sideIgnore(int w) {
    if (w <= 0) return 0;
    final wide = math.min(math.max(50, w ~/ 20), w ~/ 3);
    return math.min(wide, math.max(0, (w - 1) ~/ 2));
  }

  static bool _identicalSigs(Float32List a, Float32List b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// 把一帧里 [rect]（像素坐标，就地裁剪到帧边界内）的像素抹掉：优先用同帧
/// 上方等高的内容覆盖，上方不够改用下方，上下都不够就退化为左右列覆盖。
///
/// 用途：长截图把鼠标指针一起合成进了帧里。指针在屏幕上位置固定，滚动时它
/// 压在不断变化的页面内容上，会让两帧在同一屏行出现差异、破坏帧间匹配
/// （表现为“帧过快、匹配失败”）。抹掉一小块并复制邻近内容，视觉上通常
/// 不可见，却能让描述子重新只反映页面本身的滚动。
void eraseRegionInPlace(
  Uint8List rgba,
  int width,
  int height,
  int left,
  int top,
  int rectWidth,
  int rectHeight,
) {
  if (width <= 0 || height <= 0) return;
  final x0 = left.clamp(0, width);
  final y0 = top.clamp(0, height);
  final x1 = (left + rectWidth).clamp(0, width);
  final y1 = (top + rectHeight).clamp(0, height);
  if (x1 <= x0 || y1 <= y0) return;
  final w = x1 - x0;
  final h = y1 - y0;
  final stride = width * 4;
  void copyRows(int dstTop, int srcTop) {
    for (var row = 0; row < h; row++) {
      final d = (dstTop + row) * stride;
      final s = (srcTop + row) * stride;
      rgba.setRange(d + x0 * 4, d + x1 * 4, rgba, s + x0 * 4);
    }
  }

  if (y0 - h >= 0) {
    copyRows(y0, y0 - h);
    return;
  }
  if (y1 + h <= height) {
    copyRows(y0, y1);
    return;
  }
  final gapLeft = x0;
  final gapRight = width - x1;
  if (gapLeft >= w || gapRight >= w) {
    final srcX = gapLeft >= w ? x0 - w : x1;
    for (var row = 0; row < h; row++) {
      final base = (y0 + row) * stride;
      rgba.setRange(base + x0 * 4, base + x1 * 4, rgba, base + srcX * 4);
    }
  }
}

/// 固定带（吸顶/吸底）学习：候选变大需连续两次确认，变小立即采纳。
final class _BandState {
  bool _hasSample = false;
  int _pending = -1;
  int _pendingCount = 0;
  int _committed = 0;

  int get committed => _committed;

  void reset() {
    _hasSample = false;
    _pending = -1;
    _pendingCount = 0;
    _committed = 0;
  }

  void update(int candidate) {
    if (!_hasSample) {
      _committed = candidate;
      _hasSample = true;
      _pending = -1;
      _pendingCount = 0;
      return;
    }
    if (candidate <= _committed) {
      _committed = candidate;
      _pending = -1;
      _pendingCount = 0;
      return;
    }
    if (candidate != _pending) {
      _pending = candidate;
      _pendingCount = 1;
      return;
    }
    _pendingCount++;
    if (_pendingCount >= 2 && _pending > _committed) {
      _committed = _pending;
    }
  }
}

/// 横向采样带：把内容区（跳过两侧边缘）均分成 [bandCount] 条，每条带内
/// 均匀取 [bandSamples] 列。两侧边缘（滚动条 / 圆角）不参与。
final class _BandCols {
  _BandCols(int width, ScrollStitchConfig config)
    : width = width,
      bands = _buildBands(width, config);

  final int width;
  final List<Int32List> bands;

  static List<Int32List> _buildBands(int width, ScrollStitchConfig config) {
    if (width <= 0 || config.bandCount <= 0) return const [];
    const lo = 0.08;
    const hi = 0.92;
    const span = hi - lo;
    return [
      for (var g = 0; g < config.bandCount; g++)
        () {
          final bLo = lo + span * g / config.bandCount;
          final bHi = lo + span * (g + 1) / config.bandCount;
          final start = (width * bLo).round().clamp(0, width - 1).toInt();
          final end = (width * bHi).round().clamp(start, width - 1).toInt();
          final count = math.min(config.bandSamples, end - start + 1);
          final step = count > 1 ? (end - start) / (count - 1) : 0.0;
          final col = Int32List(count);
          for (var i = 0; i < count; i++) {
            col[i] = (start + i * step).round().clamp(0, width - 1).toInt();
          }
          return col;
        }(),
    ];
  }
}
