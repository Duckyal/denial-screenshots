import 'dart:typed_data';

import 'package:denial_flutter_sdk/input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'clipboard.dart';
import 'editor/commands.dart';
import 'editor_bus.dart';

/// 钉住的一张快照。
final class PinnedShot {
  const PinnedShot({
    required this.bytes,
    required this.commands,
    required this.sourceBytes,
    this.aspectRatio = 16 / 9,
  });

  final Uint8List bytes;
  final List<DrawCommand> commands;
  final Uint8List sourceBytes;

  /// 卡片宽度按屏幕短边比例算，高度由这个比例推导。
  final double aspectRatio;
}

/// 控制钉住卡片显示/隐藏的小总线（surface 与编辑器之间的桥）。
final class PinCardBus {
  PinCardBus._();

  static final PinCardBus instance = PinCardBus._();

  final ValueNotifier<PinnedShot?> shot = ValueNotifier<PinnedShot?>(null);

  void show(PinnedShot value) => shot.value = value;

  void hide() => shot.value = null;
}

/// 钉住的浮动卡片。
///
/// surface 本身占满输出（这样卡片可以在屏幕内自由拖动），但只有卡片区域
/// 注册输入，其余部分把指针与键盘交还给桌面。
class PinnedShotHost extends ConsumerStatefulWidget {
  const PinnedShotHost({super.key});

  @override
  ConsumerState<PinnedShotHost> createState() => _PinnedShotHostState();
}

class _PinnedShotHostState extends ConsumerState<PinnedShotHost> {
  Offset _offset = const Offset(80, 80);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PinnedShot?>(
      valueListenable: PinCardBus.instance.shot,
      builder: (BuildContext context, PinnedShot? shot, Widget? child) {
        final active = shot != null;
        // 输入区只包住卡片本身：surface 铺满输出是为了让卡片能拖到任意
        // 位置，但输入必须只占卡片，否则整个桌面都点不动。
        return Stack(
          children: <Widget>[
            if (shot != null)
              Positioned(
                left: _offset.dx,
                top: _offset.dy,
                child: ShellInputRegion(
                  debugLabel: 'Denial pinned screenshot',
                  active: active,
                  pointerPolicy: ShellPointerPolicy.childBounds,
                  keyboardPolicy: ShellKeyboardPolicy.none,
                  compositorPolicy: ShellCompositorPolicy.normal,
                  child: _PinnedCard(
                    shot: shot,
                    onDrag: (Offset delta) =>
                        setState(() => _offset = _offset + delta),
                    onContinue: _continueEditing,
                    onClose: PinCardBus.instance.hide,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  void _continueEditing() {
    final shot = PinCardBus.instance.shot.value;
    if (shot == null) return;
    PinCardBus.instance.hide();
    // 回到编辑器：用原始底图 + 已保存的标注命令恢复编辑状态。
    EditorReentryBus.instance.resume(
      EditorResumeRequest(
        imageBytes: shot.sourceBytes,
        commands: shot.commands,
      ),
    );
  }
}

class _PinnedCard extends StatelessWidget {
  const _PinnedCard({
    required this.shot,
    required this.onDrag,
    required this.onContinue,
    required this.onClose,
  });

  final PinnedShot shot;
  final ValueChanged<Offset> onDrag;
  final VoidCallback onContinue;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanUpdate: (DragUpdateDetails details) => onDrag(details.delta),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xffffffff),
          borderRadius: BorderRadius.circular(10),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 24,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(6),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.memory(
                  shot.bytes,
                  width: 360,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.high,
                ),
              ),
            ),
            _PinnedCardBar(
              onContinue: onContinue,
              onCopy: _copy,
              onClose: onClose,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _copy() => copyPngToClipboard(shot.bytes);
}

class _PinnedCardBar extends StatelessWidget {
  const _PinnedCardBar({
    required this.onContinue,
    required this.onCopy,
    required this.onClose,
  });

  final VoidCallback onContinue;
  final Future<void> Function() onCopy;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: const BoxDecoration(
        color: Color(0xfff2f2f2),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(10)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _barButton(Icons.edit_outlined, '继续编辑', onContinue),
          _barButton(Icons.content_copy, '复制', () => onCopy()),
          _barButton(Icons.close, '关闭', onClose),
        ],
      ),
    );
  }

  Widget _barButton(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 16, color: const Color(0xff333333)),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xff333333),
                decoration: TextDecoration.none,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
