enum ScreenshotToolType {
  select,
  brush,
  line,
  arrow,
  rect,
  circle,
  text,
  mask,
  eraser,
}

/// 蒙版填充方式：blur 模糊背景，solid 固定颜色。
enum MaskStyle { blur, solid }

extension ScreenshotToolTypeIndex on ScreenshotToolType {
  int toInt() => index;
}