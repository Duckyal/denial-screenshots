import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';

import 'clipboard.dart';
import 'l10n.dart';
import 'pin_surface.dart';
import 'screenshot_store.dart';
import 'scroll_stitch.dart';

/// 自动滚动注入回调：调用一次 = 让聚焦的客户端向下一档。
///
/// 由调用方提供（通常是键盘注入 `bridge.sendKeyboardKey('Down')`）——插件
/// 侧不直接依赖 `denial_flutter_sdk`，保持本文件可用纯 Dart 校验。
typedef ScrollInjector = void Function();

/// 长截图的实时预览快照：当前长图缩略图 + 源图尺寸（用于显示进度）。
///
/// [image] 是已下采样的小图，直接交给 `RawImage` 即可；所有权归
/// [ScrollCaptureManager]，更新时会自动回收上一张。
final class ScrollPreview {
  const ScrollPreview(this.image, this.width, this.height);

  final ui.Image image;

  /// 源长图的像素宽高（不是 [image] 的缩略尺寸）。
  final int width;
  final int height;
}

/// 滚动长截图会话：按框定的屏幕区域用 grim 连拍（deniald 实现了
/// screencopy），结束后把各帧按重叠拼成一张长图，写回截图目录——编辑器会像
/// 普通新截图一样自动打开它。
///
/// 两种模式：
///   - 手动：用户自己滚动页面（未传 injector 时）。
///   - 自动：传入 [ScrollInjector]，按固定节奏注入键盘滚动键（`Down`/`space`，
///     denial 的软件键盘只支持这些），每滚一档停稳后抓一帧，到底/判满自动收尾。
///     是否启用、注入哪个键由调用方的设置决定。
///
/// 采集时逐帧增量送给 [ScrollStitcher]（描述子 + NCC 定位），既省去落盘全部
/// 帧，也能用返回的 [ScrollStitchStep] 判断"这一档有没有推动页面"来识别到底。
final class ScrollCaptureManager {
  ScrollCaptureManager._();

  static final ScrollCaptureManager instance = ScrollCaptureManager._();

  /// 会话状态（HUD 浮层据此显隐）。
  final ValueNotifier<bool> active = ValueNotifier(false);

  /// 当前是否是自动滚动会话（HUD 文案据此提示）。
  final ValueNotifier<bool> autoScrolling = ValueNotifier(false);

  /// 正在截取的屏幕区域（输出逻辑坐标）；会话结束后置空。选区提示浮层据此
  /// 描边，让用户知道长截图框的是哪一块。
  final ValueNotifier<Rect?> region = ValueNotifier(null);

  /// 会话内已成功进入拼接管线的帧数（提示浮层据此显示进度）。
  final ValueNotifier<int> captured = ValueNotifier(0);

  /// 实时拼接预览（缩略图）；会话结束后置空。
  final ValueNotifier<ScrollPreview?> preview = ValueNotifier(null);

  /// 手动模式连拍间隔：静止时省资源；一旦发现页面还在滚动（有新内容追加，
  /// 或有帧因重叠不足被丢弃），就切到更短的间隔，尽量让快滚时相邻帧仍重叠，
  /// 避免丢帧后整段内容接不上。
  static const _intervalIdle = Duration(milliseconds: 150);
  static const _intervalMoving = Duration(milliseconds: 50);

  /// 自动模式：注入一档后等待惯性滚动停稳，再抓帧。
  static const _autoSettleDefault = Duration(milliseconds: 450);
  Duration _autoSettle = _autoSettleDefault;

  /// 自动模式连续多少档页面都没动就认为到底（或按键没生效）。
  static const _autoStagnantLimit = 3;

  /// 单次会话的帧数上限（防失控）。
  static const _maxFrames = 150;

  /// 预览缩略图的最大尺寸（保持比例，超出即整体缩小）。
  static const _previewMaxWidth = 240;
  static const _previewMaxHeight = 680;

  /// 预览刷新最小间隔：连拍时每帧都重建缩略图（重采样整张长图 + 新建
  /// `ui.Image`）没必要，按这个间隔节流即可，观感几乎无差。
  static const _previewMinInterval = Duration(milliseconds: 250);

  /// 抹除鼠标指针用的保守包围盒边长（逻辑像素）。指针热点在左上，实际
  /// 尺寸随主题变化；取偏大的固定值以覆盖大多数主题，代价只是重复一小段
  /// 邻近内容。
  static const _cursorBoxLogical = 36.0;

  final ScreenshotStore _store = const ScreenshotStore();

  Rect _region = Rect.zero;
  ScrollStitcher? _stitcher;
  Future<void>? _sessionTask;
  ValueListenable<Offset?>? _cursor;
  bool _autoMode = false;
  bool _stopRequested = false;
  bool _finalizing = false;
  int _captured = 0;
  int _stagnant = 0;
  int _firstFrameHeight = 0;
  bool _previewBusy = false;
  bool _previewQueued = false;
  Timer? _previewTimer;
  DateTime _lastPreviewAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isActive => active.value;

  /// 开始会话：[region] 是编辑器/选区里框定图像在屏幕上的矩形（逻辑坐标）。
  /// [injector] 非空时进入自动滚动模式。[cursor] 是实时的系统指针位置
  /// （输出逻辑坐标），用于把合成进画面的鼠标指针抹掉，避免它破坏帧匹配。
  Future<void> start(
    Rect rect, {
    ScrollInjector? injector,
    ValueListenable<Offset?>? cursor,
    Duration? autoDelay,
  }) async {
    if (isActive || rect.isEmpty || rect.width < 8 || rect.height < 8) {
      return;
    }
    _region = rect;
    _cursor = cursor;
    _stitcher = ScrollStitcher();
    _captured = 0;
    _stagnant = 0;
    _firstFrameHeight = 0;
    _stopRequested = false;
    _finalizing = false;
    _autoMode = injector != null;
    _autoSettle = (_autoMode && autoDelay != null)
        ? autoDelay
        : _autoSettleDefault;
    _disposePreview();
    active.value = true;
    autoScrolling.value = _autoMode;
    region.value = rect;
    captured.value = 0;
    await _captureFrame();
    final task = injector == null ? _runManual() : _runAuto(injector);
    _sessionTask = task;
    unawaited(task);
  }

  /// 结束会话并拼接；结果写进截图目录。可重复调用（幂等）。
  Future<void> stop() async {
    if (!isActive && _sessionTask == null) return;
    _stopRequested = true;
    active.value = false;
    final task = _sessionTask;
    if (task != null) {
      await task;
    } else {
      await _finish();
    }
  }

  Future<void> _runManual() async {
    var interval = _intervalIdle;
    while (!_stopRequested && _captured < _maxFrames && _canvasRoom()) {
      final started = DateTime.now();
      final droppedBefore = _stitcher?.droppedFrames ?? 0;
      final step = await _captureFrame();
      if (_stopRequested) break;
      // 有新内容追加（页面在滚）或这一拍丢了帧（滚太快、重叠不足）都说明页面
      // 还在动，下一拍加快；只有真正静止时才放慢。
      final droppedNow = _stitcher?.droppedFrames ?? droppedBefore;
      final moving =
          droppedNow > droppedBefore ||
          step == ScrollStitchStep.firstFrame ||
          step == ScrollStitchStep.appended;
      interval = moving ? _intervalMoving : _intervalIdle;
      final wait = interval - DateTime.now().difference(started);
      if (wait > Duration.zero) {
        await Future<void>.delayed(wait);
      }
    }
    await _finish();
  }

  Future<void> _runAuto(ScrollInjector inject) async {
    while (!_stopRequested &&
        _captured < _maxFrames &&
        _stagnant < _autoStagnantLimit &&
        _canvasRoom()) {
      inject();
      await Future<void>.delayed(_autoSettle);
      if (_stopRequested) break;
      final step = await _captureFrame();
      if (step == null) {
        _stagnant++;
      } else if (step == ScrollStitchStep.appended ||
          step == ScrollStitchStep.firstFrame) {
        _stagnant = 0;
      } else {
        // insideKnown / noMatch：这一档没推进（到底、按键无效或页面纯色）。
        _stagnant++;
      }
    }
    await _finish();
  }

  bool _canvasRoom() {
    final s = _stitcher;
    return s == null || s.canvasHeight < s.config.maxCanvasHeight;
  }

  Future<void> _finish() async {
    if (_finalizing) return;
    _finalizing = true;
    _sessionTask = null;
    active.value = false;
    autoScrolling.value = false;
    region.value = null;
    captured.value = 0;
    _cursor = null;
    _disposePreview();
    final stitcher = _stitcher;
    _stitcher = null;
    final frameCount = _captured;
    if (stitcher == null || frameCount < 2) {
      PinCardBus.instance.showToast(
        L.s(
          '长截图失败：当前界面不能滚动/翻页',
          "Scroll capture failed: this view can't scroll or page",
        ),
      );
      return;
    }
    final result = stitcher.result;
    if (result == null ||
        result.rgba.length != result.width * result.height * 4) {
      PinCardBus.instance.showToast(
        L.s(
          '长截图失败：帧没有可对齐的重叠',
          'Scroll capture failed: no overlapping frames to align',
        ),
      );
      return;
    }
    // 页面一通到底没滚过：帧全是同一张原图（拼接管线一次都没推进），
    // 这种“异常退出”别写文件也别进编辑器，直接告诉用户界面不能滚动。
    if (result.height <= _firstFrameHeight) {
      PinCardBus.instance.showToast(
        L.s(
          '当前界面不能滚动/翻页，长截图失败',
          "This view can't scroll or page; scroll capture failed",
        ),
      );
      return;
    }
    final png = await _encodePng(result.rgba, result.width, result.height);
    if (png == null) {
      PinCardBus.instance.showToast(
        L.s(
          '长截图失败：帧没有可对齐的重叠',
          'Scroll capture failed: no overlapping frames to align',
        ),
      );
      return;
    }
    final dir = _store.directory;
    if (dir == null) {
      PinCardBus.instance.showToast(
        L.s(
          '找不到截图目录，长图未保存',
          'Screenshot folder not found; long image not saved',
        ),
      );
      return;
    }
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final path = '${dir.path}/Screenshot-scroll-$stamp.png';
    try {
      await File(path).writeAsBytes(png, flush: true);
    } on Object {
      PinCardBus.instance.showToast(
        L.s('长图保存失败', 'Failed to save the long image'),
      );
      return;
    }
    PinCardBus.instance.showToast(
      stitcher.hadGap
          ? L.s(
              '长截图完成（滚动太快，可能缺了内容），正在打开编辑器…',
              'Scroll capture done (scrolled too fast, content may be missing), opening editor…',
            )
          : L.s('长截图完成，正在打开编辑器…', 'Scroll capture done, opening editor…'),
    );
  }

  /// 抓一帧，增量送进拼接器。返回该帧在管线里的归属（供自动模式判进度），
  /// 失败返回 null。
  Future<ScrollStitchStep?> _captureFrame() async {
    final stitcher = _stitcher;
    if (!isActive || stitcher == null) return null;
    if (_captured >= _maxFrames) return null;
    final geometry =
        '${_region.left.round()},${_region.top.round()} '
        '${_region.width.round()}x${_region.height.round()}';
    Uint8List png;
    Offset? cursorAtCapture;
    try {
      // grim 直接输出到 stdout（`-`），免去每帧临时文件的写+读。
      final process = await Process.start('grim', [
        '-g',
        geometry,
        '-t',
        'png',
        '-',
      ], environment: childProcessEnvironment());
      // 抓帧有几十毫秒延迟，指针位置要在 grim 一起跑（画面即将被采样）时就取，
      // 不能等解码完再读——否则抹除框会滞后于画面里的指针，快速划动时尤其明显。
      cursorAtCapture = _cursor?.value;
      final outFuture = _drainBytes(process.stdout);
      final code = await process.exitCode.timeout(
        const Duration(seconds: 4),
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
      final bytes = await outFuture;
      if (code != 0 || bytes.isEmpty) return null;
      png = bytes;
    } on Object {
      // grim 缺失或连接失败：跳过这一帧，下一拍再试。
      return null;
    }
    final frame = await _decodeRgbaBytes(png);
    if (frame == null) return null;
    _eraseCursor(frame.$1, frame.$2, frame.$3, cursorAtCapture);
    _captured++;
    captured.value = _captured;
    final step = stitcher.push(frame.$1, frame.$2, frame.$3);
    if (step == ScrollStitchStep.firstFrame) {
      _firstFrameHeight = frame.$3;
    }
    if (step == ScrollStitchStep.firstFrame ||
        step == ScrollStitchStep.appended) {
      _requestPreview();
    }
    return step;
  }

  /// 把画面里的鼠标指针抹掉。[cursor] 是抓帧时刻的指针位置（输出逻辑坐标），
  /// 帧是物理像素，需按帧宽 / 区域逻辑宽换算出缩放与局部坐标。
  void _eraseCursor(Uint8List rgba, int width, int height, Offset? cursor) {
    if (cursor == null || _region.isEmpty) return;
    final scale = width / _region.width;
    if (!scale.isFinite || scale <= 0) return;
    final local = (cursor - _region.topLeft) * scale;
    if (!local.dx.isFinite || !local.dy.isFinite) return;
    final box = (_cursorBoxLogical * scale).ceil();
    // 指针（连包围盒）完全在画面外就没什么可抹。
    if (local.dx + box < 0 ||
        local.dx > width ||
        local.dy + box < 0 ||
        local.dy > height) {
      return;
    }
    // 指针热点近左上，包围盒取到热点右下；稍微外扩，覆盖热点在内部的形状。
    const pad = 4;
    final px = (local.dx - pad)
        .floor()
        .clamp(0, math.max(0, width - 1))
        .toInt();
    final py = (local.dy - pad)
        .floor()
        .clamp(0, math.max(0, height - 1))
        .toInt();
    eraseRegionInPlace(rgba, width, height, px, py, box + pad, box + pad);
  }

  /// 请求刷新预览：按 [_previewMinInterval] 节流；已有排队的定时器就等它。
  void _requestPreview() {
    if (!isActive || _previewTimer != null) return;
    final remaining =
        _previewMinInterval - DateTime.now().difference(_lastPreviewAt);
    if (remaining <= Duration.zero) {
      unawaited(_refreshPreview());
      return;
    }
    _previewTimer = Timer(remaining, () {
      _previewTimer = null;
      unawaited(_refreshPreview());
    });
  }

  /// 重建缩略图预览。代价很低（只采样到 ≤240×680 的小缓冲），但仍用
  /// 忙/排队标志合并重叠请求，避免慢解码堆积。
  Future<void> _refreshPreview() async {
    if (_previewBusy) {
      _previewQueued = true;
      return;
    }
    _previewBusy = true;
    _lastPreviewAt = DateTime.now();
    try {
      final result = _stitcher?.result;
      if (result == null) return;
      final (small, dw, dh) = _downscale(
        result.rgba,
        result.width,
        result.height,
      );
      final image = await _rgbaToImage(small, dw, dh);
      if (image == null) return;
      if (_stitcher == null) {
        image.dispose();
        return;
      }
      final previous = preview.value;
      preview.value = ScrollPreview(image, result.width, result.height);
      _retire(previous?.image);
    } finally {
      _previewBusy = false;
    }
    if (_previewQueued) {
      _previewQueued = false;
      _requestPreview();
    }
  }

  static (Uint8List, int, int) _downscale(
    Uint8List src,
    int width,
    int height,
  ) {
    final scale = math.min(
      1.0,
      math.min(_previewMaxWidth / width, _previewMaxHeight / height),
    );
    final dw = math.max(1, (width * scale).round());
    final dh = math.max(1, (height * scale).round());
    final out = Uint8List(dw * dh * 4);
    for (var y = 0; y < dh; y++) {
      final sy = (y * height ~/ dh).clamp(0, height - 1);
      final srcRow = sy * width * 4;
      final dstRow = y * dw * 4;
      for (var x = 0; x < dw; x++) {
        final sx = (x * width ~/ dw).clamp(0, width - 1);
        final si = srcRow + sx * 4;
        final di = dstRow + x * 4;
        out[di] = src[si];
        out[di + 1] = src[si + 1];
        out[di + 2] = src[si + 2];
        out[di + 3] = src[si + 3];
      }
    }
    return (out, dw, dh);
  }

  static Future<ui.Image?> _rgbaToImage(
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
      return frame.image;
    } on Object {
      return null;
    }
  }

  /// 延后到下一帧再释放图片：当前帧可能仍有层在引用它，立即 dispose 会崩。
  void _retire(ui.Image? image) {
    if (image == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => image.dispose());
  }

  void _disposePreview() {
    _previewTimer?.cancel();
    _previewTimer = null;
    _previewQueued = false;
    final current = preview.value;
    preview.value = null;
    _retire(current?.image);
  }

  static Future<(Uint8List, int, int)?> _decodeRgbaBytes(
    Uint8List bytes,
  ) async {
    try {
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

  /// 收干一个字节流（grim stdout），返回完整字节。
  static Future<Uint8List> _drainBytes(Stream<List<int>> stream) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    return builder.takeBytes();
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
