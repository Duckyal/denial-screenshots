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

extension ScreenshotToolTypeIndex on ScreenshotToolType {
  int toInt() => index;
}
