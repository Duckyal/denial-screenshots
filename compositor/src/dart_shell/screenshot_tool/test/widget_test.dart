import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screenshot_tool/main.dart';

/// 1x1 白色 PNG。flutter_tester 中 `Image.toByteData(format: png)` 永不完成，
/// 测试不能用 PictureRecorder 现编码 PNG，只能内嵌已编码的字节。
const String _whitePngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4//8/AAX+Av4N70a4AAAAAElFTkSuQmCC';

Uint8List _createPng() => base64Decode(_whitePngBase64).buffer.asUint8List();

void main() {
  testWidgets('editor opens and supports annotation gestures', (tester) async {
    await tester.pumpWidget(ScreenshotApp(capturedImage: _createPng()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 800x600 测试窗口放 1280x800 图像，自动模式无留白 → 工具栏默认隐藏，
    // 按 Tab（默认面板显隐快捷键）唤出。
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 停靠工具栏是图标化的（标签在 Tooltip 里），按图标断言。
    expect(find.byIcon(Icons.near_me), findsOneWidget);
    expect(find.byIcon(Icons.brush), findsOneWidget);
    expect(find.byIcon(Icons.arrow_forward), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_forward));
    await tester.pump();
    await tester.dragFrom(const Offset(400, 300), const Offset(520, 360));
    await tester.pump();
    // 绘图开始会立即收起唤出的工具栏，撤销前再唤出一次。
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byIcon(Icons.undo));
    await tester.pump();

    // 1 秒无交互后工具栏自动收起。
    await tester.pump(const Duration(seconds: 2));
    expect(find.byIcon(Icons.check), findsNothing);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
