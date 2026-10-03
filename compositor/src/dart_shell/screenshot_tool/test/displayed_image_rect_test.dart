import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screenshot_tool/commands.dart';

void main() {
  test('landscape image in portrait canvas letterboxes vertically', () {
    final rect = displayedImageRect(
      const Size(500, 1000),
      1000,
      500,
    );
    expect(rect.width, 500);
    expect(rect.height, 250);
    expect(rect.topLeft, const Offset(0, 375));
  });

  test('portrait image in landscape canvas letterboxes horizontally', () {
    final rect = displayedImageRect(
      const Size(1000, 500),
      500,
      1000,
    );
    expect(rect.width, 250);
    expect(rect.height, 500);
    expect(rect.topLeft, const Offset(375, 0));
  });

  test('matching aspect fills the canvas exactly', () {
    final rect = displayedImageRect(const Size(1280, 720), 1280, 720);
    expect(rect, Offset.zero & const Size(1280, 720));
  });

  test('degenerate image falls back to the full canvas', () {
    expect(displayedImageRect(const Size(300, 200), 0, 0),
        Offset.zero & const Size(300, 200));
  });
}
