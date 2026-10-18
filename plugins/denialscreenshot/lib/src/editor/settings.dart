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
    this.ocrModel = 'v3',
    this.ocrLocalPath = '',
    this.ocrApiEndpoint = '',
    this.ocrApiModel = '',
    this.ocrApiKey = '',
    this.translateEngine = 'argos',
    this.autoScroll = true,
    this.autoScrollKey = 'Down',
    this.scrollInjector = 'denial',
    this.autoScrollSpeed = 'normal',
  });

  /// 工具栏停靠位置：'auto' | 'left' | 'right' | 'top' | 'bottom'。
  /// auto 时按图像大小自动选方向，放不下就隐藏，用快捷键唤出。
  final String dockPosition;

  /// 翻译蒙版模式：'blur'（模糊背景）| 'solid'（固定颜色）。
  /// 历史值 'auto'（取文字背景色）已随该功能删除，读入时归一成 'blur'。
  final String translateMaskMode;

  /// 翻译文字颜色模式：'auto'（提取图片里文字的原色）| 'fixed'（固定颜色）。
  final String translateTextColorMode;

  /// 识字用的 OCR 模型（默认 'v3'）：'v3'（自带 PP-OCRv3 中英）|
  /// 'v4mobile'/'v4server'/'v5mobile'/'v5server'/'v6tiny'/'v6medium'（需下载）|
  /// 'builtin'（统一包内置 PP-OCRv6 small，多语言，自带离线）|
  /// 'api'（在线视觉大模型，复用翻译 API 的 OpenAI 兼容端点）。
  final String ocrModel;

  /// 自选本地 OCR 模型目录（含 det/rec 的 .onnx）；ocrModel=='local' 时生效。
  final String ocrLocalPath;

  /// OCR 独立在线 API（ocrModel=='api' 时用）：留空的字段回退到翻译 API 对应值，
  /// 常见用法是复用翻译 API 的地址/密钥、只换一个支持图片输入的视觉模型名。
  final String ocrApiEndpoint;
  final String ocrApiModel;
  final String ocrApiKey;

  /// 本地翻译引擎：'argos'（默认，逐语对语言包，中英最稳最快）|
  /// 'm2m100'（M2M-100 418M 单模型多语言，需下载，适合源语言未知/混杂的
  /// 截图，但英→中方向偏弱、CPU 上每句更慢）。
  final String translateEngine;

  /// 长截图是否自动滚动。开启后按 [autoScrollKey] 向聚焦的客户端注入
  /// 键盘按键来翻页，无需手动滚动（依赖目标应用认可该按键为滚动）。
  final bool autoScroll;

  /// 自动滚动注入的按键：'Down'（逐行，重叠更稳）| 'space'（翻页，步幅大）。
  /// 仅识别 denial 软件键盘支持的键名。
  final String autoScrollKey;

  /// 自动滚动的注入通道：'denial'（走 denial 桥接的虚拟键盘，默认）|
  /// 'wtype'（外部 wtype 注入键）| 'ydotool'（外部 ydotool 注入键）。
  /// wtype / ydotool 需要系统安装，插件只做检测与调用，不内嵌二进制。
  final String scrollInjector;

  /// 自动滚动速度：'fast'（快，停顿短，可能重叠多）| 'normal' | 'slow'（慢，停顿长，重叠少但更稳）。
  final String autoScrollSpeed;

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

  /// 传给 sidecar 的 OCR 模型值：'local' 时换成自选目录的绝对路径（load_ocr 里
  /// os.path.join 遇绝对路径直接当模型目录用），其余按目录 key 原样传。
  String get ocrModelForSidecar =>
      ocrModel == 'local' ? ocrLocalPath.trim() : ocrModel;

  /// OCR 在线 API 各字段：填了用自己的，留空回退到翻译 API。
  String get effectiveOcrApiEndpoint =>
      ocrApiEndpoint.trim().isNotEmpty ? ocrApiEndpoint : apiEndpoint;
  String get effectiveOcrApiModel =>
      ocrApiModel.trim().isNotEmpty ? ocrApiModel : apiModel;
  String get effectiveOcrApiKey =>
      ocrApiKey.trim().isNotEmpty ? ocrApiKey : apiKey;

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
    String? ocrLocalPath,
    String? ocrApiEndpoint,
    String? ocrApiModel,
    String? ocrApiKey,
    String? translateEngine,
    bool? autoScroll,
    String? autoScrollKey,
    String? scrollInjector,
    String? autoScrollSpeed,
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
      ocrModel: ocrModel ?? this.ocrModel,
      ocrLocalPath: ocrLocalPath ?? this.ocrLocalPath,
      ocrApiEndpoint: ocrApiEndpoint ?? this.ocrApiEndpoint,
      ocrApiModel: ocrApiModel ?? this.ocrApiModel,
      ocrApiKey: ocrApiKey ?? this.ocrApiKey,
      translateEngine: translateEngine ?? this.translateEngine,
      autoScroll: autoScroll ?? this.autoScroll,
      autoScrollKey: autoScrollKey ?? this.autoScrollKey,
      scrollInjector: scrollInjector ?? this.scrollInjector,
      autoScrollSpeed: autoScrollSpeed ?? this.autoScrollSpeed,
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
    'ocrLocalPath': ocrLocalPath,
    'ocrApiEndpoint': ocrApiEndpoint,
    'ocrApiModel': ocrApiModel,
    'ocrApiKey': ocrApiKey,
    'translateEngine': translateEngine,
    'autoScroll': autoScroll,
    'autoScrollKey': autoScrollKey,
    'scrollInjector': scrollInjector,
    'autoScrollSpeed': autoScrollSpeed,
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
      ocrModel: json['ocrModel'] as String? ?? 'v3',
      ocrLocalPath: json['ocrLocalPath'] as String? ?? '',
      ocrApiEndpoint: json['ocrApiEndpoint'] as String? ?? '',
      ocrApiModel: json['ocrApiModel'] as String? ?? '',
      ocrApiKey: json['ocrApiKey'] as String? ?? '',
      translateEngine: json['translateEngine'] as String? ?? 'argos',
      autoScroll: json['autoScroll'] as bool? ?? true,
      autoScrollKey: json['autoScrollKey'] as String? ?? 'Down',
      scrollInjector: switch (json['scrollInjector'] as String?) {
        'wtype' => 'wtype',
        'ydotool' => 'ydotool',
        _ => 'denial',
      },
      autoScrollSpeed: switch (json['autoScrollSpeed'] as String?) {
        'fast' => 'fast',
        'slow' => 'slow',
        _ => 'normal',
      },
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
