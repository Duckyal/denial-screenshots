import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'screenshot_tool.dart';

/// 独立运行入口：
/// - 无参数：内置演示图。
/// - `--image <路径>`：打开指定截图（denial 截图钩子会带新截图调用）。
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  Uint8List? captured;
  var imagePath = '';
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--image' && i + 1 < args.length) {
      imagePath = args[i + 1];
      break;
    }
  }
  if (imagePath.isNotEmpty) {
    try {
      captured = await File(imagePath).readAsBytes();
    } on IOException {
      captured = null;
    }
  }
  runApp(ScreenshotApp(
    capturedImage: captured ?? await _createDemoImage(),
    selectionRect: captured != null ? Rect.zero : const Rect.fromLTWH(0, 0, 1280, 800),
  ));
}

class ScreenshotApp extends StatelessWidget {
  const ScreenshotApp({
    required this.capturedImage,
    this.selectionRect = Rect.zero,
    super.key,
  });

  final Uint8List capturedImage;
  final Rect selectionRect;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Screenshot Tool',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: ScreenshotTool(
        capturedImage: capturedImage,
        selectionRect: Rect.fromLTWH(0, 0, 1280, 800),
      ),
    );
  }
}

Future<Uint8List> _createDemoImage() async {
  const double width = 1280;
  const double height = 800;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, width, height));
  final background = Paint()
    ..shader = const LinearGradient(
      colors: [Color(0xff16242b), Color(0xff466b69), Color(0xffd49c68)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ).createShader(const Rect.fromLTWH(0, 0, width, height));
  canvas.drawRect(const Rect.fromLTWH(0, 0, width, height), background);
  canvas.drawCircle(
    const Offset(930, 280),
    150,
    Paint()..color = const Color(0xfff0cf91).withOpacity(0.9),
  );
  final image =
      await recorder.endRecording().toImage(width.toInt(), height.toInt());
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}
