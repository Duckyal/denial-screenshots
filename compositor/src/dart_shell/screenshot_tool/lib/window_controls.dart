import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native window controls backed by the patched Linux runner
/// (linux/my_application.cc, channel "denial/screenshot_window").
class ScreenshotWindowControls {
  static const MethodChannel _channel = MethodChannel(
    'denial/screenshot_window',
  );

  /// Called when the native pin card's 继续编辑 button brought the editor
  /// window back.
  VoidCallback? onPinContinued;

  ScreenshotWindowControls() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'pinContinued') {
        onPinContinued?.call();
      }
      return null;
    });
  }

  /// Asks the runner to show the rendered PNG as a floating pin card — a
  /// transient child window of the editor, which keeps it out of tiling
  /// layouts (denialwm excludes transient windows) — and to hide the editor
  /// window meanwhile.
  ///
  /// Returns false when the native side is missing or failed, so the caller
  /// can fall back to the in-window card (stock runner / IDE debugging).
  Future<bool> showPinCard(String pngPath) async {
    try {
      return await _channel.invokeMethod<bool>('showPinCard', [pngPath]) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Best-effort window nudge (X11, in-window fallback drag). Wayland ignores
  /// client-side moves; the compositor's own window drag applies there.
  Future<void> moveBy(double dx, double dy) => _invoke('moveBy', [dx, dy]);

  /// Closes the window, ending the tool.
  Future<void> quit() => _invoke('quit', <double>[]);

  Future<void> _invoke(String method, List<Object> arguments) async {
    try {
      await _channel.invokeMethod<bool>(method, arguments);
    } on PlatformException {
      // Runner rejected the call — stay in the local fallback.
    } on MissingPluginException {
      // Stock runner without the pin channel.
    }
  }
}
