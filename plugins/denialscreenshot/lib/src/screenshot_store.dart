import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Filesystem access for the screenshots written by the compositor.
///
/// The compositor owns capture and saving (`~/Pictures/Screenshots`,
/// `Screenshot-{seconds}-{milliseconds}.png`). This plugin only reads the
/// newest capture and writes its annotated copies.
final class ScreenshotStore {
  const ScreenshotStore();

  /// The capture directory, matching the compositor's own resolution order.
  Directory? get directory {
    final override = Platform.environment['DENIAL_SCREENSHOT_DIR'];
    if (override != null && override.isNotEmpty) {
      return Directory(override);
    }
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return null;
    return Directory('$home/Pictures/Screenshots');
  }

  /// Newest `Screenshot-*.png` in the capture directory, if any.
  File? newest() {
    final dir = directory;
    if (dir == null || !dir.existsSync()) return null;
    File? best;
    DateTime? bestModified;
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.png')) continue;
      if (!entity.uri.pathSegments.last.startsWith('Screenshot-')) continue;
      final modified = entity.statSync().modified;
      if (bestModified == null || modified.isAfter(bestModified)) {
        best = entity;
        bestModified = modified;
      }
    }
    return best;
  }

  /// 等合成器把截图写完再读取。
  ///
  /// 目录监听在 create 事件到达时就触发，此时文件往往只有 0 字节；直接解码
  /// 会得到一张空白（黑）图。这里等到文件大小连续两次不变再读。
  Future<Uint8List?> readStable(
    File file, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    var previous = -1;
    var stableTicks = 0;
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < timeout) {
      if (file.existsSync()) {
        final size = file.statSync().size;
        if (size > 0 && size == previous) {
          stableTicks++;
          if (stableTicks >= 2) break;
        } else {
          stableTicks = 0;
        }
        previous = size;
      }
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    if (previous <= 0) return null;
    try {
      final bytes = await file.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } on IOException {
      return null;
    }
  }

  /// Decodes a PNG/JPEG file into a [ui.Image] the editor can paint.
  Future<ui.Image> decode(File file) async {
    final bytes = await file.readAsBytes();
    return decodeBytes(bytes);
  }

  Future<ui.Image> decodeBytes(Uint8List bytes) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromList(bytes, completer.complete);
    return completer.future;
  }

  /// Writes annotated PNG bytes next to the compositor's captures.
  ///
  /// Naming follows the compositor's scheme with an `-edited` suffix and the
  /// same collision fallback.
  Future<File> saveAnnotated(Uint8List bytes) async {
    final dir = directory;
    if (dir == null) {
      throw StateError('HOME is not set; cannot resolve a screenshot folder.');
    }
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final stem = 'Screenshot-${stamp ~/ 1000}-${stamp % 1000}-edited';
    for (var suffix = 0; suffix < 100; suffix++) {
      final name = suffix == 0 ? '$stem.png' : '$stem-$suffix.png';
      final file = File('${dir.path}/$name');
      if (!file.existsSync()) {
        return file..writeAsBytesSync(bytes);
      }
    }
    throw StateError('Too many annotated screenshots in ${dir.path}.');
  }
}
