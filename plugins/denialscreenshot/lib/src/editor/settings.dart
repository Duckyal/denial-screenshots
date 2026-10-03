import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Color;

/// 编辑器工具栏与服务的用户设置，持久化在
/// ~/.config/denial-screenshots/settings.json。
class ScreenshotSettings {
  const ScreenshotSettings({
    this.dockPosition = 'auto',
    this.shortcuts = defaultShortcuts,
    this.translateBackend = 'local',
    this.translateTarget = 'system',
    this.apiType = 'openai',
    this.apiEndpoint = '',
    this.apiKey = '',
    this.apiModel = '',
    this.apiAppId = '',
    this.translateMaskColor = 'FFFFFF',
    this.translateTextColor = '000000',
    this.closeAfterCopy = true,
  });

  /// 工具栏停靠位置：'auto' | 'left' | 'right' | 'top' | 'bottom'。
  /// auto 时按图像大小自动选方向，放不下就隐藏，用快捷键唤出。
  final String dockPosition;

  /// 复制成功后自动关闭编辑器：进剪贴板就意味着这次标注结束了，省掉手动关。
  final bool closeAfterCopy;

  /// 动作 → 快捷键绑定（规范串：ctrl/shift/alt 前缀 + 小写键名）。
  /// 缺失的动作回落到 [defaultShortcuts]。
  final Map<String, String> shortcuts;

  static const defaultShortcuts = <String, String>{
    'dock': 'tab',
    'undo': 'ctrl+z',
    'redo': 'ctrl+r',
    'close': 'escape',
    'hints': 'space',
    'tool.select': 'v',
    'tool.brush': 'b',
    'tool.line': 'l',
    'tool.arrow': 'a',
    'tool.rect': 'r',
    'tool.circle': 'c',
    'tool.text': 't',
    'tool.mask': 'm',
    'tool.eraser': 'e',
  };

  String bindingFor(String action) =>
      shortcuts[action] ?? defaultShortcuts[action] ?? '';

  /// 翻译接口：'api'（在线翻译 API）| 'local'（本地模型）。
  final String translateBackend;

  /// 翻译目标语言：'system'（跟随系统）| 'zh' | 'en' | 'ja' …
  final String translateTarget;

  /// API 协议：'openai'（OpenAI 兼容 chat/completions）| 'libre'（LibreTranslate）。
  final String apiType;

  /// API 地址（OpenAI 兼容填 base URL，LibreTranslate 填服务根地址）。
  final String apiEndpoint;

  /// API 密钥（LibreTranslate 可留空）。
  final String apiKey;

  /// API 模型名（仅 OpenAI 兼容协议需要，如 deepseek-chat）。
  final String apiModel;

  /// APP ID（仅百度翻译需要，与密钥配对使用）。
  final String apiAppId;

  /// 翻译蒙版颜色（RRGGBB），默认白色。
  final String translateMaskColor;

  /// 翻译文字颜色（RRGGBB），默认黑色。
  final String translateTextColor;

  Color get translateMaskColorValue =>
      colorValueFromHex(translateMaskColor, 0xFFFFFFFF);

  Color get translateTextColorValue =>
      colorValueFromHex(translateTextColor, 0xFF000000);

  static Color colorValueFromHex(String hex, int fallback) {
    final value = int.tryParse(hex, radix: 16);
    if (value == null || value < 0 || value > 0xFFFFFF) {
      return Color(fallback);
    }
    return Color(0xFF000000 | value);
  }

  ScreenshotSettings copyWith({
    String? dockPosition,
    Map<String, String>? shortcuts,
    String? translateBackend,
    String? translateTarget,
    String? apiType,
    String? apiEndpoint,
    String? apiKey,
    String? apiModel,
    String? apiAppId,
    String? translateMaskColor,
    String? translateTextColor,
    bool? closeAfterCopy,
  }) {
    return ScreenshotSettings(
      dockPosition: dockPosition ?? this.dockPosition,
      shortcuts: shortcuts ?? this.shortcuts,
      translateBackend: translateBackend ?? this.translateBackend,
      translateTarget: translateTarget ?? this.translateTarget,
      apiType: apiType ?? this.apiType,
      apiEndpoint: apiEndpoint ?? this.apiEndpoint,
      apiKey: apiKey ?? this.apiKey,
      apiModel: apiModel ?? this.apiModel,
      apiAppId: apiAppId ?? this.apiAppId,
      translateMaskColor: translateMaskColor ?? this.translateMaskColor,
      translateTextColor: translateTextColor ?? this.translateTextColor,
      closeAfterCopy: closeAfterCopy ?? this.closeAfterCopy,
    );
  }

  Map<String, dynamic> toJson() => {
        'dockPosition': dockPosition,
        'shortcuts': shortcuts,
        'translateBackend': translateBackend,
        'translateTarget': translateTarget,
        'apiType': apiType,
        'apiEndpoint': apiEndpoint,
        'apiKey': apiKey,
        'apiModel': apiModel,
        'apiAppId': apiAppId,
        'translateMaskColor': translateMaskColor,
        'translateTextColor': translateTextColor,
        'closeAfterCopy': closeAfterCopy,
      };

  factory ScreenshotSettings.fromJson(Map<String, dynamic> json) {
    return ScreenshotSettings(
      dockPosition: (json['dockPosition'] as String?) ??
          // 旧版两个字段的迁移。
          (json['horizontalDock'] == 'top'
              ? 'top'
              : json['verticalDock'] == 'left'
                  ? 'left'
                  : 'auto'),
      shortcuts: {
        ...defaultShortcuts,
        ...((json['shortcuts'] as Map?)?.cast<String, String>() ?? const {}),
      },
      translateBackend: json['translateBackend'] as String? ?? 'local',
      translateTarget: json['translateTarget'] as String? ?? 'system',
      apiType: json['apiType'] as String? ?? 'openai',
      apiEndpoint: json['apiEndpoint'] as String? ?? '',
      apiKey: json['apiKey'] as String? ?? '',
      apiModel: json['apiModel'] as String? ?? '',
      apiAppId: json['apiAppId'] as String? ?? '',
      translateMaskColor: json['translateMaskColor'] as String? ?? 'FFFFFF',
      translateTextColor: json['translateTextColor'] as String? ?? '000000',
      closeAfterCopy: json['closeAfterCopy'] as bool? ?? true,
    );
  }

  static File _file() {
    final home = Platform.environment['HOME'] ?? '/';
    return File('$home/.config/denial-screenshots/settings.json');
  }

  static Future<ScreenshotSettings> load() async {
    try {
      final file = _file();
      if (!await file.exists()) return const ScreenshotSettings();
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return ScreenshotSettings.fromJson(json);
    } on Object {
      return const ScreenshotSettings();
    }
  }

  Future<void> save() async {
    try {
      final file = _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(toJson()));
    } on Object {
      // 设置写盘失败不影响编辑。
    }
  }
}
