import 'dart:async';

/// 启动插件自有的「框选 → 工具栏」截图流程（mark-shot 式）。
///
/// 与官方截图不同，这条链路完全由插件 surface 完成：全屏压暗后拖动框选，
/// 松手后选区可继续微调，并就地弹出工具栏（识字/翻译/长截屏/编辑/复制/
/// 保存/置顶/关闭）。取图走 `grim`（wlr-screencopy），不经过合成器的选区流程。
final class CaptureFlowBus {
  CaptureFlowBus._();

  static final CaptureFlowBus instance = CaptureFlowBus._();

  final StreamController<void> _controller = StreamController<void>.broadcast();

  Stream<void> get requests => _controller.stream;

  void begin() => _controller.add(null);
}
