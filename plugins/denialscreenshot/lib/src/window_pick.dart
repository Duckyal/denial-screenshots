import 'dart:async';

import 'package:denial_flutter_sdk/models.dart'
    show DenialWindow, DenialWindowSnapshot;
import 'package:denial_flutter_sdk/platform.dart' show DenialBridge;
import 'package:denial_flutter_sdk/state.dart' show denialBridgeProvider;
import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter/widgets.dart' show Offset, Rect;
import 'package:flutter_riverpod/flutter_riverpod.dart' show WidgetRef;

/// 框选阶段的「智能选窗」数据源（QQ / 微信截图式）：维护合成器的窗口快照，
/// 按指针位置命中最上层的用户窗口——悬停高亮整窗，单击即整窗成区。
///
/// 数据来源是 denial bridge 的 `windowSnapshots` 广播流；该流只在原生推送
/// 时发、不重放初值，因此另走 `listWindows` 拉一次快照（2s 超时返回兜底，
/// bridge 未就绪时拿到空表，收到 `windowsChanged` 后自动再试）。命中矩形用
/// `DenialWindow.geometry`——合成器给出的窗口屏幕几何（场景全局逻辑坐标），
/// 与官方 desktop 插件的输入命中同源。
///
/// 坐标换算：窗口几何是场景全局逻辑坐标，surface 的 local 坐标是输出内
/// 坐标；命中前减去 `output.logicalRect.topLeft`（与壳层 surface plane 把
/// 场景坐标搬进输出坐标的做法一致）。
///
/// 生命周期：每个框选 surface 实例 [start] 一次、[stop] 一次，不跨实例共享
/// （selection surface 是逐输出挂载的，共享单例会让多实例互相顶掉订阅）。
final class WindowPickStore extends ChangeNotifier {
  WindowPickStore();

  List<DenialWindow> _windows = const [];
  StreamSubscription<DenialWindowSnapshot>? _snapshots;
  StreamSubscription<void>? _changed;
  bool _haveSnapshot = false;
  bool _stopped = false;

  /// 开始跟踪窗口快照。[ref] 由 surface 的 ConsumerState 提供。
  void start(WidgetRef ref) {
    _stopped = false;
    _haveSnapshot = false;
    _snapshots?.cancel();
    _changed?.cancel();
    final bridge = ref.read(denialBridgeProvider);
    _snapshots = bridge.windowSnapshots.listen((snapshot) {
      if (_stopped) return;
      _windows = snapshot.windows;
      _haveSnapshot = true;
      notifyListeners();
    });
    // 快照流不重放初值：主动拉一次兜底；失败就在 windowsChanged 时再试。
    unawaited(_pull(bridge));
    _changed = bridge.windowsChanged.listen((_) {
      if (!_haveSnapshot && !_stopped) unawaited(_pull(bridge));
    });
  }

  Future<void> _pull(DenialBridge bridge) async {
    if (_stopped || _haveSnapshot) return;
    try {
      final snapshot = await bridge.listWindows(const <DenialWindow>[]);
      if (_stopped || _haveSnapshot) return;
      if (snapshot.windows.isEmpty) return;
      _windows = snapshot.windows;
      _haveSnapshot = true;
      notifyListeners();
    } on Object {
      // bridge 未就绪：等 windowsChanged / 快照推送。
    }
  }

  /// surface 销毁时停掉，避免僵尸订阅与销毁后 notify。
  void stop() {
    _stopped = true;
    _snapshots?.cancel();
    _snapshots = null;
    _changed?.cancel();
    _changed = null;
    _haveSnapshot = false;
    _windows = const [];
  }

  /// 命中 [local]（输出内逻辑坐标）处最上层可截取的窗口矩形（同一坐标
  /// 空间）；没有则 null。[outputRect] 是本 surface 所在输出的全局逻辑
  /// 矩形，用于坐标平移；[workspaceId] 非空时只认该工作区的窗口。
  ///
  /// 过滤：非用户窗口（layer-shell 壁纸/面板/桌面宠物、popup、系统 UI、
  /// shell 自己的窗口）与最小化、过小的窗口全部跳过；命中顺序与合成器
  /// 输入命中同序——列表尾部为上层，先命中先返回。
  Rect? windowAt(Offset local, {required Rect outputRect, int? workspaceId}) {
    if (!_haveSnapshot) return null;
    for (final window in _windows.reversed) {
      if (!window.isUserApp || window.minimized) continue;
      if (workspaceId != null && window.workspaceId != workspaceId) continue;
      final rect = _localRect(window, outputRect);
      if (rect == null) continue;
      if (rect.contains(local)) return rect;
    }
    return null;
  }

  Rect? _localRect(DenialWindow window, Rect outputRect) {
    // 用 `geometry`（geometryX/Y/W/H）：合成器把窗口屏幕几何减去 atlas 原点
    // 后编码进来，就是场景全局逻辑坐标。`presentationCoordinateRect` 走
    // surfaceX/Y 字段，本地窗口路径编码为 (0,0) 原点（只含尺寸），它服务于
    // 贴图/呈现坐标空间，不能用来做屏幕命中；官方 desktop 插件的输入命中
    // 同样用 geometry。顶栏/面板的遮挡已反映在合成器给的几何里，无需补。
    final scene = window.geometry;
    if (scene == null) return null;
    if (!scene.width.isFinite || !scene.height.isFinite) return null;
    if (scene.width < 2 || scene.height < 2) return null;
    return scene.shift(-outputRect.topLeft);
  }
}
