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

  /// 连拍间隔；太快会拍到滚动动画的中间帧。
  static const _interval = Duration(milliseconds: 450);

  /// 单次会话的帧数上限（防失控），超出自动收尾。
  static const _maxFrames = 40;

  /// 拼接画布的高度上限（像素）。
  static const _maxCanvasHeight = 30000;

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
    if (!isActive || _frames.length >= _maxFrames) {
      if (_frames.length >= _maxFrames) {
        unawaited(stop());
      }
      return;
    }
    final sequence = _sequence++;
    final path =
        '${_framesDir!.path}/frame-${sequence.toString().padLeft(3, '0')}.png';
    final geometry =
        '${_region.left.round()},${_region.top.round()},'
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

  /// 顺序拼接：以第一帧为底，后续每帧在画布底部找重叠条带，把新增行追加
  /// 进画布。匹配在 4 倍降采样的亮度图上做粗搜，再全分辨率细分。
  static Future<Uint8List?> _stitch(List<String> frames, Rect region) async {
    final base = await _decodeRgba(frames.first);
    if (base == null) return null;
    var canvas = base.$1;
    final canvasWidth = base.$2;
    var canvasHeight = base.$3;

    for (final path in frames.skip(1)) {
      if (canvasHeight >= _maxCanvasHeight) break;
      final frame = await _decodeRgba(path);
      if (frame == null) continue;
      final shift = _matchScrollOffset(
        canvas,
        canvasWidth,
        canvasHeight,
        frame.$1,
        frame.$2,
        frame.$3,
      );
      if (shift == null || shift <= 0 || shift >= frame.$3) {
        continue;
      }
      // 新帧从重叠结束处往下的行都是新内容。
      final newRows = frame.$3 - shift;
      final merged = Uint8List(canvasWidth * (canvasHeight + newRows) * 4);
      merged.setAll(0, canvas);
      merged.setRange(
        canvas.length,
        canvas.length + newRows * canvasWidth * 4,
        frame.$1.sublist(shift * canvasWidth * 4),
      );
      canvas = merged;
      canvasHeight += newRows;
    }

    // 画布宽度必须与新帧一致（grim 区域固定，理论恒等；防御一下）。
    if (canvas.length != canvasWidth * canvasHeight * 4) {
      return null;
    }
    return _encodePng(canvas, canvasWidth, canvasHeight);
  }

  /// 在 [frameRgba]（尺寸 frameW×frameH）里找画布底部条带的最佳纵向偏移：
  /// 返回帧内匹配起点 y（帧的 [y, y+strip) 与画布底部条带对齐），失败返回
  /// null。返回值同时就是新内容的起始行。
  static int? _matchScrollOffset(
    Uint8List canvas,
    int canvasW,
    int canvasH,
    Uint8List frame,
    int frameW,
    int frameH,
  ) {
    if (frameW != canvasW || frameH < 16 || canvasH < 16) {
      return null;
    }
    const downsample = 4;
    final canvasLuma = _lumaDownsampled(canvas, canvasW, canvasH, downsample);
    final frameLuma = _lumaDownsampled(frame, frameW, frameH, downsample);
    final strip = math.min(12, canvasLuma.$3);
    if (frameLuma.$3 <= strip) {
      return null;
    }
    final canvasStartRow = canvasLuma.$3 - strip;
    var bestY = -1;
    var bestScore = double.infinity;
    for (var y = 0; y <= frameLuma.$3 - strip; y++) {
      var total = 0.0;
      var count = 0;
      for (var row = 0; row < strip; row += 1) {
        final cRow = (canvasStartRow + row) * canvasLuma.$2;
        final fRow = (y + row) * frameLuma.$2;
        for (var col = 0; col < canvasLuma.$2; col += 2) {
          total += (canvasLuma.$1[cRow + col] - frameLuma.$1[fRow + col]).abs();
          count++;
        }
      }
      if (count == 0) continue;
      final score = total / count;
      if (score < bestScore) {
        bestScore = score;
        bestY = y;
      }
    }
    if (bestY < 0 || bestScore > 26) {
      return null;
    }
    // 全分辨率细分：粗匹配 ±4px 内逐行精搜。
    const stripFull = 48;
    var refineY = bestY * downsample;
    var refineScore = double.infinity;
    final coarse = bestY * downsample;
    final searchFrom = math.max(0, coarse - downsample * 4);
    final searchTo = math.min(frameH - stripFull, coarse + downsample * 4);
    for (var y = searchFrom; y <= searchTo; y++) {
      var total = 0.0;
      var count = 0;
      for (var row = 0; row < stripFull; row += 2) {
        final cRow = (canvasH - stripFull + row) * canvasW;
        final fRow = (y + row) * frameW;
        for (var col = 0; col < canvasW; col += 4) {
          total += _lumaAt(canvas, cRow + col) - _lumaAt(frame, fRow + col);
          count++;
        }
      }
      if (count == 0) continue;
      final score = total / count;
      if (score < refineScore) {
        refineScore = score;
        refineY = y;
      }
    }
    if (refineScore > 30) {
      return null;
    }
    return refineY;
  }

  static double _lumaAt(Uint8List rgba, int offset) {
    return (rgba[offset] * 3 + rgba[offset + 1] * 4 + rgba[offset + 2]) / 8.0;
  }

  /// 降采样亮度图：返回 (bytes, 宽, 高)。
  static (Uint8List, int, int) _lumaDownsampled(
    Uint8List rgba,
    int width,
    int height,
    int step,
  ) {
    final w = width ~/ step;
    final h = height ~/ step;
    final out = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        out[y * w + x] = _lumaAt(
          rgba,
          ((y * step) * width + x * step) * 4,
        ).round();
      }
    }
    return (out, w, h);
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
