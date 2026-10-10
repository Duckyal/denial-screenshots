import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'clipboard.dart';
import 'pin_surface.dart';
import 'screenshot_store.dart';

/// 滚动长截图会话：按框定的屏幕区域用 grim 连拍（deniald 实现了
/// screencopy），用户手动滚动页面，结束后把各帧按重叠拼成一张长图，
/// 写回截图目录——编辑器会像普通新截图一样自动打开它。
///
/// v1 是手动滚动版：自动注入滚动需要 ydotool/uinput 或 compositor 支持，
/// 拼接算法对两者通用，后续接入即可升级成全自动。
final class ScrollCaptureManager {
  ScrollCaptureManager._();

  static final ScrollCaptureManager instance = ScrollCaptureManager._();

  /// 会话状态（HUD 浮层据此显隐）。
  final ValueNotifier<bool> active = ValueNotifier(false);

  /// 连拍间隔。高频连拍保证帧间重叠充足，静止帧在校验签名时跳过，
  /// 不会浪费拼接；间隔太大才是"滚太快断档/滚太慢白拍"的病根。
  static const _interval = Duration(milliseconds: 150);

  /// 单次会话的帧数上限（防失控）。拍满只停止追加，等用户自己结束会话。
  static const _maxFrames = 150;

  final ScreenshotStore _store = const ScreenshotStore();
  Rect _region = Rect.zero;
  Directory? _framesDir;
  Timer? _timer;
  final List<String> _frames = <String>[];
  int _sequence = 0;

  bool get isActive => active.value;

  String get _framesPath => '${_dataDir()}/scroll-frames';

  static String _dataDir() =>
      Platform.environment['XDG_DATA_HOME'] ??
      '${Platform.environment['HOME'] ?? '/home'}/.local/share/denial-screenshots';

  /// 开始会话：[region] 是编辑器里框定图像在屏幕上的矩形（逻辑坐标）。
  Future<void> start(Rect region) async {
    if (isActive || region.isEmpty || region.width < 8 || region.height < 8) {
      return;
    }
    final dir = Directory(_framesPath);
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    dir.createSync(recursive: true);
    _framesDir = dir;
    _region = region;
    _frames.clear();
    _sequence = 0;
    active.value = true;
    await _captureFrame();
    _timer = Timer.periodic(_interval, (_) => _captureFrame());
  }

  /// 结束会话并拼接；结果写进截图目录，返回拼接后的文件路径。
  Future<String?> stop() async {
    if (!isActive) return null;
    _timer?.cancel();
    _timer = null;
    active.value = false;
    final frames = List<String>.from(_frames);
    final region = _region;
    _frames.clear();
    if (frames.length < 2) {
      PinCardBus.instance.showToast('长截图至少需要两帧，再滚动一下试试');
      await _cleanupFrames();
      return null;
    }
    // 拼接在主 isolate 跑：每帧匹配约几十毫秒，收尾一次性 PNG 编码可接受，
    // 避免 dart:ui 编解码跨 isolate 的坑。
    final png = await _stitch(frames, region);
    if (png == null) {
      PinCardBus.instance.showToast('长截图拼接失败，帧没有可对齐的重叠');
      await _cleanupFrames();
      return null;
    }
    final dir = _store.directory;
    if (dir == null) {
      PinCardBus.instance.showToast('找不到截图目录，长图未保存');
      await _cleanupFrames();
      return null;
    }
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final path = '${dir.path}/Screenshot-scroll-$stamp.png';
    await File(path).writeAsBytes(png, flush: true);
    PinCardBus.instance.showToast('长截图完成，正在打开编辑器…');
    await _cleanupFrames();
    return path;
  }

  Future<void> _cleanupFrames() async {
    final dir = _framesDir;
    _framesDir = null;
    if (dir != null && dir.existsSync()) {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // 清理失败不影响结果，临时目录下次会话会先清空。
      }
    }
  }

  Future<void> _captureFrame() async {
    if (!isActive) return;
    if (_frames.length >= _maxFrames) {
      // 拍满只是停下连拍，不自动收尾：用户随时还能手动结束会话。
      _timer?.cancel();
      _timer = null;
      return;
    }
    final sequence = _sequence++;
    final path =
        '${_framesDir!.path}/frame-${sequence.toString().padLeft(3, '0')}.png';
    final geometry =
        '${_region.left.round()},${_region.top.round()} '
        '${_region.width.round()}x${_region.height.round()}';
    try {
      final process = await Process.start('grim', [
        '-g',
        geometry,
        '-t',
        'png',
        path,
      ], environment: childProcessEnvironment());
      final code = await process.exitCode.timeout(
        const Duration(seconds: 4),
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
      if (code == 0 && File(path).existsSync()) {
        _frames.add(path);
      }
    } on Object {
      // grim 缺失或连接失败：跳过这一帧，下一拍再试。
    }
  }

  /// 顺序拼接：以第一帧为底，每帧用"行签名"在长图里定位并追加新增行。
  /// 算法对照 mark-shot 的滚动拼接器：
  ///   - 每帧只算一遍行签名（左/中/右三横向采样带），匹配/定位全程复用；
  ///   - 相邻帧先预测后搜索（滚动有惯性），失败就改在整个长图里找位置兜底，
  ///     坏帧只会丢这一帧，不会让整根画布歪掉；
  ///   - 重叠行数与平均色差都要过信任门槛，净新增行数不足 minAppend 不落笔，
  ///     防止滚动抖动把同一行反复贴进去；
  ///   - 学习吸顶/固定表头，匹配时排除、追加时把长图边缘旧的固定带裁掉。
  static Future<Uint8List?> _stitch(List<String> frames, Rect region) async {
    final base = await _decodeRgba(frames.first);
    if (base == null) return null;
    final stitcher = _ScrollStitcher();
    if (stitcher.push(base.$1, base.$2, base.$3) != _ScrollStep.firstFrame) {
      return null;
    }
    for (final path in frames.skip(1)) {
      if (stitcher.canvasHeight >= _StitchConfig.maxCanvasHeight) break;
      final frame = await _decodeRgba(path);
      if (frame == null) continue;
      stitcher.push(frame.$1, frame.$2, frame.$3);
    }
    final (rgba, width, height) = stitcher.fullImage();
    if (rgba == null || rgba.length != width * height * 4) {
      return null;
    }
    return _encodePng(rgba, width, height);
  }

  static Future<(Uint8List, int, int)?> _decodeRgba(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      final data = await frame.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      final width = frame.image.width;
      final height = frame.image.height;
      frame.image.dispose();
      if (data == null) return null;
      return (data.buffer.asUint8List(), width, height);
    } on Object {
      return null;
    }
  }

  static Future<Uint8List?> _encodePng(
    Uint8List rgba,
    int width,
    int height,
  ) async {
    try {
      final descriptor = await ui.ImageDescriptor.raw(
        await ui.ImmutableBuffer.fromUint8List(rgba),
        width: width,
        height: height,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      final codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      codec.dispose();
      descriptor.dispose();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      return data?.buffer.asUint8List();
    } on Object {
      return null;
    }
  }
}

/// 单帧在拼接管线里的归属。
enum _ScrollStep {
  /// 种子帧，已建立长图画布。
  firstFrame,

  /// 追加了新的纵向内容。
  appended,

  /// 帧落在已拼接的内容内，仅重新锚定（防止重复粘贴）。
  insideKnown,

  /// 无法建立可信重叠，丢弃该帧。
  noMatch,
}

/// 拼接参数：对照 mark-shot 的经验值，作用于 0..255 尺度的平均色差。
abstract final class _StitchConfig {
  /// 重叠行数达到多少才信这次匹配。
  static const int minOverlap = 80;

  /// 同内容判定：高可信的像素带平均色差上限。
  static const double acceptDiff = 9.0;

  /// 唯一强匹配阈值：差异低到接近 0 时几乎不存在伪峰（重复行除外），
  /// 相邻帧搜索里遇到即可提前收工。
  static const double sharpDiff = 1.0;

  /// 可信偏移必须比次优偏移"尖"出的量：真正的对齐处是谷底，噪声背景
  /// 到处都差不多低。第二优与最优差值小过它就不信，宁可整帧下移。
  static const double peakMargin = 3.0;

  /// 失守兜底（整帧下移）时帧内亮度跨度下限：空白/纯色帧没有内容，
  /// 直丢，别把一屏空像素贴进长图。
  static const double blankSpan = 2.0;

  /// 净新增行数少于它就不落笔（防滚动抖动把碎片反复贴进去）。
  static const int minAppend = 12;

  /// 判定固定带所需的滚动位移，太小说明不了"固定"。
  static const int minScrollForDetect = 12;

  /// 固定带"行相同"的平均色差上限。
  static const double fixedRowMaxDiff = 6.0;

  /// 行签名横向采样带数。
  static const int bandCount = 3;

  /// 每条采样带的横向采样列数。
  static const int bandSamples = 48;

  /// 已知位置粗搜步长。
  static const int knownCoarse = 8;

  /// 比例边缘忽略：顶部/底部各占帧高的比例与下限像素。
  static const double topRatio = 0.10;
  static const double bottomRatio = 0.08;
  static const int minIgnorePx = 16;

  /// 固定带最多占帧高的 1/3。
  static const int maxBandDivisor = 3;

  /// 长图高度上限（像素）。
  static const int maxCanvasHeight = 30000;
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

/// 横向采样带：三带覆盖左/中/右的页面结构区域，两侧边缘跳过。
final class _BandCols {
  _BandCols(int width) : width = width, bands = _buildBands(width);

  final int width;
  final List<Int32List> bands;

  static List<Int32List> _buildBands(int width) {
    if (width <= 0) return const [];
    const ranges = [(0.08, 0.32), (0.34, 0.66), (0.68, 0.92)];
    return [
      for (final (lo, hi) in ranges)
        () {
          final start = (width * lo).round().clamp(0, width - 1).toInt();
          final end = (width * hi).round().clamp(start, width - 1).toInt();
          final count = math.min(_StitchConfig.bandSamples, end - start + 1);
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

/// mark-shot 风格的滚动拼接器：长图 + 每帧行签名，先相邻预测、再整图定位，
/// 带信任门槛、固定带学习与已见内容的重锚定。
final class _ScrollStitcher {
  Uint8List? _canvas;
  int _canvasW = 0;
  int _canvasH = 0;
  Float32List? _canvasSigs;
  _BandCols? _bandCols;
  Float32List? _lastSigs;
  Uint8List? _lastFull;
  int _anchorPos = 0;
  int _lastOff = 0;
  final _BandState _fixedTop = _BandState();
  final _BandState _fixedBottom = _BandState();

  int get canvasHeight => _canvasH;

  _ScrollStep push(Uint8List frame, int w, int h) {
    if (w <= 0 || h <= 0 || h < _StitchConfig.minOverlap) {
      return _ScrollStep.noMatch;
    }
    _bandCols ??= _BandCols(w);
    if (_bandCols!.width != w) return _ScrollStep.noMatch;
    final sigs = _rowSigs(frame, w, h, _bandCols!);
    if (_canvas == null) {
      _canvas = frame;
      _canvasW = w;
      _canvasH = h;
      _canvasSigs = sigs;
      _lastSigs = sigs;
      _lastFull = frame;
      _anchorPos = 0;
      _lastOff = 0;
      _fixedTop.reset();
      _fixedBottom.reset();
      return _ScrollStep.firstFrame;
    }
    if (w != _canvasW) return _ScrollStep.noMatch;
    final lastSigs = _lastSigs;
    if (lastSigs != null && _identicalSigs(lastSigs, sigs)) {
      // 静止帧（用户还没滚或刚停下）：不进拼接器，避免白白背徕一次匹配。
      return _ScrollStep.noMatch;
    }
    final (off, conf, peak) = _findOffset(lastSigs!, h, sigs, h);
    var pos = _anchorPos + off;
    if (conf > _StitchConfig.acceptDiff || peak < _StitchConfig.peakMargin) {
      // 相邻匹配不可靠：先在整个长图里找这帧该放的位置，坏帧只丢这一帧。
      final (knownPos, knownDiff, knownPeak) = _findPlacement(sigs, h, pos);
      if (knownDiff <= _StitchConfig.acceptDiff &&
          knownPeak >= _StitchConfig.peakMargin &&
          knownPos >= 0) {
        pos = knownPos;
      } else {
        // 全画布都对齐不上（多半是快滚跨帧，前帧已经滚出窗外）：
        // 整帧看作画布底下新内容整段下落，宁可中间丢若干行也不错贴重影。
        final capRoom = _StitchConfig.maxCanvasHeight - _canvasH;
        if (capRoom < _StitchConfig.minAppend) return _ScrollStep.noMatch;
        var minS = sigs.first;
        var maxS = sigs.first;
        for (final v in sigs) {
          if (v < minS) {
            minS = v;
          } else if (v > maxS) {
            maxS = v;
          }
        }
        if (maxS - minS < _StitchConfig.blankSpan) {
          // 空白/纯色帧：没有可拼接内容，整帧丢弃。
          return _ScrollStep.noMatch;
        }
        final amount = math.min(h, capRoom);
        final below = _canvasH;
        _lastFull = frame;
        return _appendBottom(frame, sigs, h, amount, below, below - _anchorPos);
      }
    }
    final move = pos - _anchorPos;
    final lastFull = _lastFull;
    if (lastFull != null && move.abs() >= _StitchConfig.minScrollForDetect) {
      final (top, bottom) = _detectFixedBands(lastFull, frame, w, h);
      _fixedTop.update(top);
      _fixedBottom.update(bottom);
    }
    _lastFull = frame;
    final amount = pos + h - _canvasH;
    if (amount >= _StitchConfig.minAppend) {
      return _appendBottom(frame, sigs, h, amount, pos, move);
    }
    if (pos >= 0) {
      // 帧落在已拼接内容里（含底部不足 minAppend 的碎片）：只重锚不重贴。
      _anchorPos = pos;
      _lastSigs = sigs;
      _lastOff = move;
      return _ScrollStep.insideKnown;
    }
    return _ScrollStep.noMatch;
  }

  (Uint8List?, int, int) fullImage() {
    final canvas = _canvas;
    if (canvas == null) return (null, 0, 0);
    return (canvas, _canvasW, _canvasH);
  }

  /// 追加：先裁掉长图尾部残留的旧固定带（会被新切片里相同的行覆盖），
  /// 再附上这一帧底部新增的 [amount] 行。
  _ScrollStep _appendBottom(
    Uint8List frame,
    Float32List sigs,
    int fh,
    int amount,
    int pos,
    int move,
  ) {
    final capRoom = _StitchConfig.maxCanvasHeight - _canvasH;
    if (amount > capRoom) amount = capRoom;
    if (amount < _StitchConfig.minAppend) {
      _anchorPos = pos;
      _lastSigs = sigs;
      _lastOff = move;
      return _ScrollStep.insideKnown;
    }
    var bottomTrim = 0;
    if (_fixedBottom.committed > 0) {
      final maxTrim = math.max(
        0,
        math.min(
          fh ~/ _StitchConfig.maxBandDivisor,
          math.min(_canvasH ~/ _StitchConfig.maxBandDivisor, _canvasH - 1),
        ),
      );
      bottomTrim = math.min(_fixedBottom.committed, maxTrim);
    }
    final cut = bottomTrim * _canvasW * 4;
    final trimmed = bottomTrim > 0
        ? Uint8List.fromList(_canvas!.sublist(0, _canvas!.length - cut))
        : _canvas!;
    final sliceStart = (fh - amount) * _canvasW * 4;
    final merged = Uint8List(trimmed.length + amount * _canvasW * 4);
    merged.setAll(0, trimmed);
    merged.setRange(
      trimmed.length,
      trimmed.length + amount * _canvasW * 4,
      frame.sublist(sliceStart, sliceStart + amount * _canvasW * 4),
    );
    _canvas = merged;

    if (bottomTrim > 0) {
      final sigCut = bottomTrim * _StitchConfig.bandCount;
      _canvasSigs = Float32List.fromList(
        Float32List.sublistView(
          _canvasSigs!,
          0,
          _canvasSigs!.length - sigCut,
        ).toList(),
      );
    }
    final newSigRows = amount * _StitchConfig.bandCount;
    final sigSlice = Float32List.sublistView(
      sigs,
      (fh - amount) * _StitchConfig.bandCount,
      (fh - amount) * _StitchConfig.bandCount + newSigRows,
    );
    final sigMerged = Float32List(_canvasSigs!.length + newSigRows);
    sigMerged.setAll(0, _canvasSigs!);
    sigMerged.setRange(
      _canvasSigs!.length,
      _canvasSigs!.length + newSigRows,
      sigSlice,
    );
    _canvasSigs = sigMerged;
    _canvasH = _canvasH - bottomTrim + amount;
    _anchorPos = pos;
    _lastSigs = sigs;
    _lastOff = move;
    return _ScrollStep.appended;
  }

  /// 相邻帧偏移搜索：以最近一次位移为预测中心，由近及远扫遍全部可行偏移，
  /// 同分时先到者胜（连续滚动假设），遇到差异几乎为零的强匹配提前收工
  /// （平滑背景/重复行会产生大量伪峰，全范围线性扫会被伪峰截胡）。
  /// 返回 (偏移, 置信度, 峰度)，偏移>0 表示滚向下方/新内容；峰度 = 次优−
  /// 最优，太小说明到处都是候选、不可信。
  (int, double, double) _findOffset(
    Float32List last,
    int lastH,
    Float32List frame,
    int fh,
  ) {
    final fixedTop = _fixedTop.committed;
    final fixedBottom = _fixedBottom.committed;
    final maxOff = math.max(0, lastH - _StitchConfig.minOverlap);
    final predicted = _lastOff.clamp(-maxOff, maxOff).toInt();
    var best = predicted;
    var bestDiff = double.infinity;
    var second = double.infinity;
    void consider(int o, double d) {
      if (d < bestDiff) {
        second = bestDiff;
        best = o;
        bestDiff = d;
      } else if (d < second) {
        second = d;
      }
    }

    for (var delta = 0; delta <= maxOff; delta++) {
      final plus = predicted + delta;
      if (plus <= maxOff) {
        final d = _overlapDiff(
          last,
          lastH,
          frame,
          fh,
          plus,
          fixedTop,
          fixedBottom,
        );
        consider(plus, d);
        if (d < _StitchConfig.sharpDiff)
          return (best, bestDiff, second - bestDiff);
      }
      if (delta != 0) {
        final minus = predicted - delta;
        if (minus >= -maxOff) {
          final d = _overlapDiff(
            last,
            lastH,
            frame,
            fh,
            minus,
            fixedTop,
            fixedBottom,
          );
          consider(minus, d);
          if (d < _StitchConfig.sharpDiff)
            return (best, bestDiff, second - bestDiff);
        }
      }
    }
    return (best, bestDiff, second - bestDiff);
  }

  /// 在整个长图里找这帧的可信位置（含越过底边的新内容），粗搜 + 精化，
  /// 偏好离预测位置最近的可信落点。返回 (绝对行, 置信度, 峰度)。
  (int, double, double) _findPlacement(
    Float32List frame,
    int fh,
    int predictedPos,
  ) {
    final canvasSigs = _canvasSigs!;
    if (canvasSigs.length != _canvasH * _StitchConfig.bandCount) {
      return (0, double.infinity, 0);
    }
    final fixedTop = _fixedTop.committed;
    final fixedBottom = _fixedBottom.committed;
    final maxPos = math.max(0, _canvasH - _StitchConfig.minOverlap);
    final minPos = _StitchConfig.minOverlap - fh;
    var bestPos = predictedPos.clamp(minPos, maxPos).toInt();
    var bestDiff = double.infinity;
    var second = double.infinity;
    var bestGoodPos = bestPos;
    var bestGoodDiff = double.infinity;
    var bestGoodDist = 0x7fffffff;
    void visit(int p) {
      p = p.clamp(minPos, maxPos).toInt();
      final d = _overlapDiff(
        canvasSigs,
        _canvasH,
        frame,
        fh,
        p,
        fixedTop,
        fixedBottom,
      );
      if (d < bestDiff) {
        second = bestDiff;
        bestDiff = d;
        bestPos = p;
      } else if (d < second) {
        second = d;
      }
      if (d <= _StitchConfig.acceptDiff) {
        final dist = (p - predictedPos).abs();
        if (dist < bestGoodDist || (dist == bestGoodDist && d < bestGoodDiff)) {
          bestGoodDist = dist;
          bestGoodDiff = d;
          bestGoodPos = p;
        }
      }
    }

    visit(predictedPos);
    visit(_anchorPos);
    visit(0);
    visit(math.max(0, maxPos));
    visit(minPos);
    for (
      var p = math.max(0, minPos);
      p <= maxPos;
      p += _StitchConfig.knownCoarse
    ) {
      visit(p);
    }
    final refineFrom = math.max(minPos, bestPos - _StitchConfig.knownCoarse);
    final refineTo = math.min(maxPos, bestPos + _StitchConfig.knownCoarse);
    for (var p = refineFrom; p <= refineTo; p++) {
      visit(p);
    }
    if (bestGoodDiff <= _StitchConfig.acceptDiff) {
      return (bestGoodPos, bestGoodDiff, second - bestDiff);
    }
    return (bestPos, bestDiff, second - bestDiff);
  }

  /// 行签名：每行在三个横向采样带上的平均亮度，长度 = h * bandCount。
  Float32List _rowSigs(Uint8List rgba, int width, int height, _BandCols cols) {
    final out = Float32List(height * _StitchConfig.bandCount);
    for (var y = 0; y < height; y++) {
      final rowBase = y * width * 4;
      final sigBase = y * _StitchConfig.bandCount;
      for (var g = 0; g < _StitchConfig.bandCount; g++) {
        final xs = cols.bands[g];
        var sum = 0.0;
        for (final x in xs) {
          final i = rowBase + x * 4;
          sum += (rgba[i] * 3 + rgba[i + 1] * 4 + rgba[i + 2]) / 8.0;
        }
        out[sigBase + g] = sum / xs.length;
      }
    }
    return out;
  }

  double _overlapDiff(
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
    if (len < _StitchConfig.minOverlap) return double.infinity;
    final h = math.min(aRows, bRows);
    final softCrop =
        len >=
        _StitchConfig.minOverlap +
            _contentTopIgnore(h) +
            _contentBottomIgnore(h);
    final startA = offset >= 0 ? offset : 0;
    final startB = offset >= 0 ? 0 : -offset;
    var sum = 0.0;
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
      final i1 = y1 * _StitchConfig.bandCount;
      final i2 = y2 * _StitchConfig.bandCount;
      sum +=
          (a[i1] - b[i2]).abs() +
          (a[i1 + 1] - b[i2 + 1]).abs() +
          (a[i1 + 2] - b[i2 + 2]).abs();
      count += _StitchConfig.bandCount;
    }
    final required = softCrop
        ? math.max(24, _StitchConfig.minOverlap ~/ 2)
        : _StitchConfig.minOverlap;
    if (count == 0 || rows < required) return double.infinity;
    return sum / count;
  }

  bool _usableRow(int y, int h, int fixedTop, int fixedBottom, bool softCrop) {
    if (y < fixedTop || y >= h - fixedBottom) return false;
    return !softCrop || _isContentRow(y, h);
  }

  int _contentTopIgnore(int h) => h < 80
      ? 0
      : math.min(
          h ~/ 4,
          math.max(
            _StitchConfig.minIgnorePx,
            (h * _StitchConfig.topRatio).round(),
          ),
        );
  int _contentBottomIgnore(int h) => h < 80
      ? 0
      : math.min(
          h ~/ 4,
          math.max(
            _StitchConfig.minIgnorePx,
            (h * _StitchConfig.bottomRatio).round(),
          ),
        );
  bool _isContentRow(int y, int h) =>
      y >= _contentTopIgnore(h) && y < h - _contentBottomIgnore(h);

  /// 学习吸顶/吸底固定带：跳过两侧滚动条，逐行比对两帧同一 y 的差异。
  (int, int) _detectFixedBands(Uint8List prev, Uint8List cur, int w, int h) {
    final limit = h ~/ _StitchConfig.maxBandDivisor;
    final side = _sideIgnore(w);
    var top = 0;
    while (top < limit) {
      final o = top * w * 4;
      if (_rowAbsDiff(prev, cur, w, o, o, side) >
          _StitchConfig.fixedRowMaxDiff) {
        break;
      }
      top++;
    }
    var bottom = 0;
    while (bottom < limit) {
      final o = (h - 1 - bottom) * w * 4;
      if (_rowAbsDiff(prev, cur, w, o, o, side) >
          _StitchConfig.fixedRowMaxDiff) {
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
