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
    this.translateMaskMode = 'blur',
    this.translateTextColorMode = 'auto',
    this.ocrModel = 'builtin',
  });

  /// 工具栏停靠位置：'auto' | 'left' | 'right' | 'top' | 'bottom'。
  /// auto 时按图像大小自动选方向，放不下就隐藏，用快捷键唤出。
  final String dockPosition;

  /// 翻译蒙版模式：'blur'（模糊背景）| 'solid'（固定颜色）。
  /// 历史值 'auto'（取文字背景色）已随该功能删除，读入时归一成 'blur'。
  final String translateMaskMode;

  /// 翻译文字颜色模式：'auto'（提取图片里文字的原色）| 'fixed'（固定颜色）。
  final String translateTextColorMode;

  /// 识字用的 OCR 模型：'builtin'（组件自带的 PP-OCRv3）|
  /// 'v4mobile'（PP-OCRv4 移动版，需下载）| 'v4server'（服务器版，需下载）。
  final String ocrModel;

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
    'scrollCapture': 'super+r',
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
    String? translateMaskMode,
    String? translateTextColorMode,
    String? ocrModel,
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
      translateMaskMode: translateMaskMode ?? this.translateMaskMode,
      translateTextColorMode:
          translateTextColorMode ?? this.translateTextColorMode,
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
    'translateMaskMode': translateMaskMode,
    'translateTextColorMode': translateTextColorMode,
    'ocrModel': ocrModel,
  };

  factory ScreenshotSettings.fromJson(Map<String, dynamic> json) {
    return ScreenshotSettings(
      dockPosition:
          (json['dockPosition'] as String?) ??
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
      // 'auto' 蒙版取色已删除：老配置里的存值归一成 blur。
      translateMaskMode: (json['translateMaskMode'] as String?) == 'solid'
          ? 'solid'
          : 'blur',
      translateTextColorMode:
          json['translateTextColorMode'] as String? ?? 'auto',
      ocrModel: json['ocrModel'] as String? ?? 'builtin',
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