import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'api_config_field.dart';
import 'clipboard.dart';
import 'editor/file_picker.dart';
import 'editor/settings.dart';
import 'editor/translate_service.dart';
import 'l10n.dart';
import 'panel_nav.dart';

/// 框选截图工具栏里的「设置」面板。
///
/// 只放框选流程真正用得上的项——翻译接口（在线 API 配置 / 本地模型管理）、
/// 翻译为、识字模型；编辑器专用的工具栏位置/快捷键/蒙版配色不在这里。改动
/// 立即生效并写盘（与编辑器共用同一份 [ScreenshotSettings]）。
class SelectionSettingsPanel extends StatefulWidget {
  const SelectionSettingsPanel({
    super.key,
    required this.settings,
    required this.translateService,
    required this.onChanged,
    required this.onClose,
    this.nav,
  });

  final ScreenshotSettings settings;
  final TranslateService translateService;
  final ValueChanged<ScreenshotSettings> onChanged;
  final VoidCallback onClose;
  final SelectionPanelNav? nav;

  @override
  State<SelectionSettingsPanel> createState() => _SelectionSettingsPanelState();
}

class _SelectionSettingsPanelState extends State<SelectionSettingsPanel> {
  late ScreenshotSettings _settings = widget.settings;

  bool _apiOpen = false;
  bool _modelsOpen = false;

  Map<(String, String), bool> _packInstalled = const {};
  (String, String) _packBusy = const ('', '');
  String _packMessage = '';

  Map<String, bool> _ocrInstalled = const {};
  String _ocrBusyKey = '';
  String _ocrMessage = '';

  /// 外部滚动注入工具（wtype / ydotool）的安装状态。
  Map<String, bool> _toolInstalled = const {};
  String _toolBusy = '';
  String _toolMessage = '';

  bool _apiTesting = false;
  String _apiTestResult = '';

  /// API 配置草稿：编辑只动草稿、不写盘；点「测试连接」成功后才写回设置生效。
  /// null 表示沿用已保存值。与编辑器设置面板同一套行为。
  String? _draftApiType;
  String? _draftApiEndpoint;
  String? _draftApiKey;
  String? _draftApiModel;
  String? _draftApiAppId;
  String get _apiTypeV => _draftApiType ?? _settings.apiType;
  String get _apiEndpointV => _draftApiEndpoint ?? _settings.apiEndpoint;
  String get _apiKeyV => _draftApiKey ?? _settings.apiKey;
  String get _apiModelV => _draftApiModel ?? _settings.apiModel;
  String get _apiAppIdV => _draftApiAppId ?? _settings.apiAppId;
  void _resetApiDraft() {
    _draftApiType = null;
    _draftApiEndpoint = null;
    _draftApiKey = null;
    _draftApiModel = null;
    _draftApiAppId = null;
  }

  /// M2M-100 多语言单模型的下载状态（本地翻译引擎用）。
  bool _m2mInstalled = false;
  bool _m2mBusy = false;
  String _m2mMessage = '';

  @override
  void initState() {
    super.initState();
    unawaited(_refreshPacks());
    unawaited(_refreshOcr());
    unawaited(_refreshTools());
    unawaited(_refreshM2m());
    widget.nav?.canGoBack = () => _apiOpen || _modelsOpen;
    widget.nav?.goBack = () => setState(() {
      _apiOpen = false;
      _modelsOpen = false;
    });
  }

  Future<void> _refreshM2m() async {
    final installed = await widget.translateService.isM2mInstalled();
    if (mounted) setState(() => _m2mInstalled = installed);
  }

  Future<void> _toggleM2m() async {
    setState(() {
      _m2mBusy = true;
      _m2mMessage = '';
    });
    try {
      if (_m2mInstalled) {
        await widget.translateService.deleteM2m();
      } else {
        await widget.translateService.installM2m(
          onStatus: (status) {
            if (mounted) setState(() => _m2mMessage = status);
          },
        );
      }
      await _refreshM2m();
    } on Object catch (error) {
      if (mounted) setState(() => _m2mMessage = '$error');
    }
    if (mounted) setState(() => _m2mBusy = false);
  }

  void _apply(ScreenshotSettings next) {
    setState(() => _settings = next);
    widget.onChanged(next);
  }

  /// 本地模型目录选择器的起始目录：已选优先，否则落到 OCR 模型根目录
  /// （含已下载的子目录），再退回主目录。
  String _ocrInitialDirectory() {
    final chosen = _settings.ocrLocalPath.trim();
    if (chosen.isNotEmpty) return chosen;
    if (Directory(TranslateService.ocrModelsRoot).existsSync()) {
      return TranslateService.ocrModelsRoot;
    }
    return Platform.environment['HOME'] ?? '/';
  }

  Future<void> _refreshPacks() async {
    final installed = <(String, String), bool>{};
    for (final (from, to, _) in TranslateService.packCatalog) {
      installed[(from, to)] = await widget.translateService.isPackInstalled(
        from,
        to,
      );
    }
    if (mounted) setState(() => _packInstalled = installed);
  }

  Future<void> _togglePack(String from, String to) async {
    setState(() {
      _packBusy = (from, to);
      _packMessage = '';
    });
    try {
      if (_packInstalled[(from, to)] ?? false) {
        await widget.translateService.deletePack(from, to);
      } else {
        await widget.translateService.installPack(
          from,
          to,
          onStatus: (status) {
            if (mounted) setState(() => _packMessage = status);
          },
        );
      }
      if (mounted) {
        setState(() {
          _packInstalled = {
            ..._packInstalled,
            (from, to): !(_packInstalled[(from, to)] ?? false),
          };
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _packMessage = '$error');
    }
    if (mounted) setState(() => _packBusy = const ('', ''));
  }

  Future<void> _refreshOcr() async {
    final installed = <String, bool>{};
    for (final (key, _, _) in TranslateService.ocrModelCatalog) {
      installed[key] = await widget.translateService.isOcrModelInstalled(key);
    }
    if (mounted) setState(() => _ocrInstalled = installed);
  }

  Future<void> _toggleOcr(String key) async {
    setState(() {
      _ocrBusyKey = key;
      _ocrMessage = '';
    });
    try {
      if (_ocrInstalled[key] ?? false) {
        await widget.translateService.deleteOcrModel(key);
      } else {
        await widget.translateService.installOcrModel(
          key,
          onStatus: (status) => setState(() => _ocrMessage = status),
        );
      }
      await _refreshOcr();
    } on Object catch (error) {
      setState(() => _ocrMessage = '$error');
    }
    if (mounted) setState(() => _ocrBusyKey = '');
  }

  Future<void> _refreshTools() async {
    final installed = <String, bool>{
      'wtype': await _commandExists('wtype'),
      'ydotool': await _commandExists('ydotool'),
    };
    if (mounted) setState(() => _toolInstalled = installed);
  }

  Future<bool> _commandExists(String name) async {
    try {
      final result = await Process.run('which', [name]);
      return result.exitCode == 0;
    } on Object {
      return false;
    }
  }

  /// 走系统包管理器安装外部注入工具。优先用 pkexec 提权；拿不到 pkexec 就
  /// 退化为提示手动安装命令。
  Future<void> _installTool(String tool) async {
    setState(() {
      _toolBusy = tool;
      _toolMessage = '正在安装 $tool…';
    });
    try {
      const managers = <String, List<String>>{
        'pacman': ['-S', '--noconfirm'],
        'apt-get': ['install', '-y'],
        'apt': ['install', '-y'],
        'dnf': ['install', '-y'],
        'zypper': ['install', '-y'],
        'apk': ['add'],
        'xbps-install': ['-y'],
      };
      String? manager;
      for (final name in managers.keys) {
        if (await _commandExists(name)) {
          manager = name;
          break;
        }
      }
      if (manager == null) {
        if (mounted) {
          setState(() => _toolMessage = '未找到包管理器，请手动安装 $tool');
        }
        return;
      }
      final args = <String>[...managers[manager]!, tool];
      if (await _commandExists('pkexec')) {
        final result = await Process.run('pkexec', [
          manager,
          ...args,
        ], environment: childProcessEnvironment());
        if (!mounted) return;
        setState(() {
          _toolMessage = result.exitCode == 0
              ? '$tool 安装完成'
              : '安装失败：${result.stderr.toString().trim()}';
        });
      } else {
        setState(() => _toolMessage = '请手动执行：sudo $manager ${args.join(' ')}');
      }
    } on Object catch (error) {
      if (mounted) setState(() => _toolMessage = '$error');
    } finally {
      if (mounted) {
        setState(() => _toolBusy = '');
        await _refreshTools();
      }
    }
  }

  String _target() {
    final configured = _settings.translateTarget;
    if (configured != 'system') return configured;
    return View.of(context).platformDispatcher.locale.languageCode;
  }

  Future<void> _runApiTest() async {
    if (_apiTesting) return;
    setState(() {
      _apiTesting = true;
      _apiTestResult = L.pick(context, '正在测试…', 'Testing…');
    });
    try {
      final result = await widget.translateService.translateViaApi(
        texts: const ['Hello, world'],
        target: _target(),
        apiType: _apiTypeV,
        endpoint: _apiEndpointV,
        apiKey: _apiKeyV,
        model: _apiModelV,
        apiAppId: _apiAppIdV,
      );
      if (!mounted) return;
      // 测通了才把草稿写回设置并生效。
      _apply(
        _settings.copyWith(
          apiType: _apiTypeV,
          apiEndpoint: _apiEndpointV,
          apiKey: _apiKeyV,
          apiModel: _apiModelV,
          apiAppId: _apiAppIdV,
        ),
      );
      _resetApiDraft();
      setState(() {
        _apiTesting = false;
        _apiTestResult = L.pick(
          context,
          '可用：Hello, world → ${result.first}',
          'Working: Hello, world → ${result.first}',
        );
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _apiTesting = false;
        _apiTestResult = '$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData.dark(useMaterial3: true),
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: Colors.white),
        child: Container(
          width: 380,
          constraints: const BoxConstraints(maxHeight: 520),
          decoration: BoxDecoration(
            color: const Color(0xE60F1419),
            borderRadius: BorderRadius.circular(12),
            boxShadow: const [
              BoxShadow(
                color: Colors.black38,
                blurRadius: 12,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 10, 6),
                child: Row(
                  children: [
                    Text(
                      L.pick(context, '设置', 'Settings'),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    InkWell(
                      onTap: widget.onClose,
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(
                          Icons.close,
                          size: 18,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _sections(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _sections() {
    return [
      ..._ocrSection(),
      _group(
        L.pick(context, '翻译接口', 'Translation backend'),
        _settings.translateBackend,
        const [
          ('api', '在线翻译 API', 'Online API'),
          ('local', '本地模型', 'Local model'),
        ],
        (value) {
          if (value == 'local') _apiOpen = false;
          if (value == 'api') _modelsOpen = false;
          _apply(_settings.copyWith(translateBackend: value));
        },
      ),
      if (_settings.translateBackend == 'api') ..._apiSection(),
      if (_settings.translateBackend == 'local') ..._engineSection(),
      if (_settings.translateBackend == 'local') ..._localModelsSection(),
      _group(
        L.pick(context, '翻译为', 'Translate to'),
        _settings.translateTarget,
        const [
          ('system', '跟随系统', 'System'),
          ('zh', '中文', '中文'),
          ('en', 'English', 'English'),
          ('ja', '日本語', '日本語'),
          ('ko', '한국어', '한국어'),
          ('fr', 'Français', 'Français'),
          ('de', 'Deutsch', 'Deutsch'),
          ('ru', 'Русский', 'Русский'),
          ('es', 'Español', 'Español'),
        ],
        (value) => _apply(_settings.copyWith(translateTarget: value)),
      ),
      if (_settings.translateBackend == 'local') _localTargetHint(),
      ..._scrollCaptureSection(),
    ];
  }

  /// 本地翻译引擎选择：Argos 逐语对（默认）/ M2M-100 单模型任意互译。
  List<Widget> _engineSection() {
    return [
      _group(
        L.pick(context, '翻译引擎', 'Translation engine'),
        _settings.translateEngine,
        const [
          ('argos', 'Argos 语言包（默认）', 'Argos dictionaries (default)'),
          ('m2m100', 'M2M-100 多语言单模型', 'M2M-100 multilingual model'),
        ],
        (value) => _apply(_settings.copyWith(translateEngine: value)),
      ),
      if (_settings.translateEngine == 'm2m100')
        if (_m2mBusy)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _m2mMessage,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: OutlinedButton(
              onPressed: _toggleM2m,
              child: Text(
                _m2mInstalled
                    ? L.pick(context, '删除 M2M 模型', 'Delete M2M model')
                    : L.pick(
                        context,
                        '下载 M2M 模型（约 490MB）',
                        'Download M2M model (~490MB)',
                      ),
              ),
            ),
          ),
    ];
  }

  /// 本地翻译的目标语言说明：讲清直连对 / 经英语中继 / M2M 的区别。
  Widget _localTargetHint() {
    final note = _settings.translateEngine == 'm2m100'
        ? L.pick(
            context,
            'M2M 单模型覆盖中↔日/韩/法德西俄等 12 语种互译，无需逐语对下载；'
                '源语言自动判定，混杂也能译。',
            'A single M2M model covers 12 languages (Zh↔Ja/Ko/Fr/De/Es/Ru…)'
                ' with no per-pair downloads; the source language is detected'
                ' automatically and mixed text still translates.',
          )
        : L.pick(
            context,
            'Argos 逐语对：源语言自动判定，没有直连对时经英语中继'
                '（如中→日需同时下载「中→英」和「英→日」两个包）。'
                '想要中↔日直接互译，把上面的引擎换成 M2M-100。',
            'Argos uses per-language pairs: the source is auto-detected, and'
                ' without a direct pair it relays through English (e.g. Zh→Ja'
                ' needs both the "Zh→En" and "En→Ja" packs). For direct'
                ' Zh↔Ja, switch the engine above to M2M-100.',
          );
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        note,
        style: const TextStyle(fontSize: 11, color: Colors.white60),
      ),
    );
  }

  List<Widget> _scrollCaptureSection() {
    return [
      Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 2),
        child: Text(
          L.pick(context, '长截图', 'Scrolling capture'),
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
      _group(
        L.pick(context, '滚动方式（是否自动滚动）', 'Scroll mode (auto or manual)'),
        _settings.autoScroll ? 'auto' : 'manual',
        const [
          ('auto', '自动滚动（默认）', 'Auto-scroll (default)'),
          ('manual', '手动滚动', 'Manual scroll'),
        ],
        (value) => _apply(_settings.copyWith(autoScroll: value == 'auto')),
      ),
      if (_settings.autoScroll) ...[
        _group(
          L.pick(context, '注入方式', 'Key injector'),
          _settings.scrollInjector,
          const [
            ('denial', 'denial 虚拟键盘（默认）', 'denial virtual keyboard (default)'),
            ('wtype', 'wtype', 'wtype'),
            ('ydotool', 'ydotool', 'ydotool'),
          ],
          (value) {
            _apply(_settings.copyWith(scrollInjector: value));
            unawaited(_refreshTools());
          },
        ),
        if (_settings.scrollInjector != 'denial') _toolInstallRow(),
        _group(
          L.pick(context, '滚动速度', 'Scroll speed'),
          _settings.autoScrollSpeed,
          const [
            ('fast', '快', 'Fast'),
            ('normal', '中', 'Medium'),
            ('slow', '慢', 'Slow'),
          ],
          (value) => _apply(_settings.copyWith(autoScrollSpeed: value)),
        ),
        _group(
          L.pick(context, '滚动按键', 'Scroll key'),
          _settings.autoScrollKey,
          const [('Down', '逐行 ↓', 'Line ↓'), ('space', '翻页 空格', 'Page space')],
          (value) => _apply(_settings.copyWith(autoScrollKey: value)),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            L.pick(
              context,
              '自动滚动靠向目标窗口注入按键实现，仅对浏览器、阅读器等'
                  '“方向键/空格可滚动”的应用有效；文本编辑器里按键可能改变光标。'
                  'wtype 直接连 Wayland 会话，ydotool 需要 ydotoold 守护进程。',
              'Auto-scroll injects keys into the target window, so it only works'
                  ' for apps that scroll with arrow/space keys (browsers, readers);'
                  ' in text editors the keys may move the caret. wtype talks to the'
                  ' Wayland session directly; ydotool needs the ydotoold daemon.',
            ),
            style: const TextStyle(fontSize: 11, color: Colors.white60),
          ),
        ),
      ],
    ];
  }

  /// 外部注入工具（wtype / ydotool）的安装状态行：已安装打勾，未安装给
  /// 「安装」按钮（走系统包管理器）。
  Widget _toolInstallRow() {
    final tool = _settings.scrollInjector;
    final installed = _toolInstalled[tool] ?? false;
    final busy = _toolBusy == tool;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Icon(
            installed ? Icons.check_circle_outline : Icons.error_outline,
            size: 15,
            color: installed ? Colors.lightGreenAccent : Colors.orangeAccent,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  installed
                      ? L.pick(context, '$tool 已安装', '$tool installed')
                      : L.pick(context, '$tool 未安装', '$tool not installed'),
                  style: const TextStyle(fontSize: 12, color: Colors.white),
                ),
                if (_toolMessage.isNotEmpty && !busy)
                  Text(
                    _toolMessage,
                    style: const TextStyle(fontSize: 11, color: Colors.white60),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          if (!installed)
            busy
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : TextButton(
                    onPressed: () => _installTool(tool),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    child: Text(
                      L.pick(context, '安装', 'Install'),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
        ],
      ),
    );
  }

  List<Widget> _apiSection() {
    final details = <String>[
      _apiTypeLabel(context, _settings.apiType),
      if (_settings.apiEndpoint.trim().isNotEmpty) _settings.apiEndpoint.trim(),
      if (_settings.apiModel.trim().isNotEmpty) _settings.apiModel.trim(),
      if (_settings.apiType == 'baidu' && _settings.apiAppId.trim().isNotEmpty)
        'APP ID ${_settings.apiAppId.trim()}',
      _settings.apiKey.trim().isNotEmpty
          ? L.pick(context, '密钥已填', 'Key set')
          : L.pick(context, '密钥未填', 'No key'),
    ];
    return [
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          L.pick(
            context,
            '当前接口：${details.join(' · ')}',
            'Current: ${details.join(' · ')}',
          ),
          style: const TextStyle(fontSize: 12, color: Colors.white70),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: OutlinedButton(
          onPressed: () {
            if (!_apiOpen) _resetApiDraft();
            setState(() => _apiOpen = !_apiOpen);
          },
          child: Text(
            _apiOpen
                ? L.pick(context, '收起配置', 'Hide config')
                : L.pick(context, '配置在线翻译 API', 'Configure online API'),
          ),
        ),
      ),
      if (_apiOpen) ...[
        _group(L.pick(context, '翻译协议', 'Protocol'), _apiTypeV, const [
          (
            'openai',
            'OpenAI 兼容（DeepSeek / OpenAI / Ollama…）',
            'OpenAI-compatible (DeepSeek / OpenAI / Ollama…)',
          ),
          ('baidu', '百度翻译', 'Baidu Translate'),
          ('deepl', 'DeepL', 'DeepL'),
          ('libre', 'LibreTranslate', 'LibreTranslate'),
        ], (value) => setState(() => _draftApiType = value)),
        if (_apiTypeV == 'openai') ...[
          _apiField(
            L.pick(context, 'API 地址', 'API endpoint'),
            _apiEndpointV,
            'https://api.deepseek.com',
            (value) => setState(() => _draftApiEndpoint = value),
          ),
          _apiField(
            L.pick(context, 'API 密钥', 'API key'),
            _apiKeyV,
            'sk-…',
            (value) => setState(() => _draftApiKey = value),
            obscure: true,
          ),
          _apiField(
            L.pick(context, '模型名', 'Model name'),
            _apiModelV,
            'deepseek-chat',
            (value) => setState(() => _draftApiModel = value),
          ),
        ] else if (_apiTypeV == 'baidu') ...[
          _apiField(
            'APP ID',
            _apiAppIdV,
            L.pick(
              context,
              '在 fanyi-api.baidu.com 免费申请',
              'Free at fanyi-api.baidu.com',
            ),
            (value) => setState(() => _draftApiAppId = value),
          ),
          _apiField(
            L.pick(context, '密钥', 'Secret key'),
            _apiKeyV,
            L.pick(context, '与 APP ID 配对', 'Paired with the APP ID'),
            (value) => setState(() => _draftApiKey = value),
            obscure: true,
          ),
        ] else if (_apiTypeV == 'deepl')
          _apiField(
            L.pick(context, '密钥', 'Secret key'),
            _apiKeyV,
            L.pick(context, '…:fx 结尾为免费版', 'ends with :fx for the free tier'),
            (value) => setState(() => _draftApiKey = value),
            obscure: true,
          )
        else ...[
          _apiField(
            L.pick(context, 'API 地址', 'API endpoint'),
            _apiEndpointV,
            'https://libretranslate.example.com',
            (value) => setState(() => _draftApiEndpoint = value),
          ),
          _apiField(
            L.pick(context, 'API 密钥', 'API key'),
            _apiKeyV,
            L.pick(context, '可留空', 'Optional'),
            (value) => setState(() => _draftApiKey = value),
            obscure: true,
          ),
        ],
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            L.pick(
              context,
              '改完点「测试连接」，成功后才会保存并生效。',
              'Edit, then press "Test connection"; it saves only on success.',
            ),
            style: TextStyle(
              fontSize: 11,
              color: Colors.white.withValues(alpha: 0.6),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: OutlinedButton(
            onPressed: _apiTesting ? null : _runApiTest,
            child: Text(
              _apiTesting
                  ? L.pick(context, '测试中…', 'Testing…')
                  : L.pick(context, '测试连接', 'Test connection'),
            ),
          ),
        ),
        if (_apiTestResult.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _apiTestResult,
              style: const TextStyle(fontSize: 12),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    ];
  }

  List<Widget> _localModelsSection() {
    return [
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: OutlinedButton(
          onPressed: () => setState(() => _modelsOpen = !_modelsOpen),
          child: Text(
            _modelsOpen
                ? L.pick(context, '收起模型列表', 'Hide model list')
                : L.pick(
                    context,
                    '管理本地翻译模型（下载/删除）',
                    'Manage local translation models (download/delete)',
                  ),
          ),
        ),
      ),
      if (_modelsOpen) ...[
        if (_packBusy != const ('', ''))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _packMessage,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        for (final (from, to, label) in TranslateService.packCatalog)
          ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            contentPadding: EdgeInsets.zero,
            title: Text(
              L.pick(context, label.zh, label.en),
              style: const TextStyle(fontSize: 13),
            ),
            trailing: _packBusy == (from, to)
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : TextButton(
                    onPressed: () => _togglePack(from, to),
                    child: Text(
                      (_packInstalled[(from, to)] ?? false)
                          ? L.pick(context, '删除', 'Delete')
                          : L.pick(context, '下载', 'Download'),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
          ),
      ],
    ];
  }

  List<Widget> _ocrSection() {
    return [
      Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 2),
        child: Text(
          L.pick(
            context,
            '识字模型（截图取字与翻译共用，CPU 推理）',
            'OCR model (shared by capture-to-text and translation, CPU inference)',
          ),
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
      RadioGroup<String>(
        groupValue: _settings.ocrModel,
        onChanged: (next) {
          if (next != null) {
            _apply(_settings.copyWith(ocrModel: next));
          }
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (key, label, note) in TranslateService.ocrModelCatalog)
              RadioListTile<String>(
                dense: true,
                visualDensity: VisualDensity.compact,
                contentPadding: EdgeInsets.zero,
                value: key,
                title: Text(
                  L.pick(context, label.zh, label.en),
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  TranslateService.isDownloadableOcr(key)
                      ? '${L.pick(context, note.zh, note.en)} · '
                            '${_ocrInstalled[key] ?? false ? L.pick(context, '已下载', 'Downloaded') : L.pick(context, '未下载', 'Not downloaded')}'
                      : L.pick(context, note.zh, note.en),
                  style: const TextStyle(fontSize: 11, color: Colors.white60),
                ),
              ),
          ],
        ),
      ),
      if (_settings.ocrModel == 'api')
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orangeAccent),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  size: 16,
                  color: Colors.orangeAccent,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    L.pick(
                      context,
                      '在线视觉模型识字：文字能读出来，但框的位置常常对不准'
                          '（漏行、粗框、把图标当文字），翻译蒙版可能盖偏或盖不全。'
                          '需要逐行精确定位，请改用上面的本地 PP-OCR 模型。',
                      'Online vision-model OCR: the text can be read, but the box '
                          'positions are often off (missed lines, coarse boxes, '
                          'icons mistaken for text), so the translation mask may be '
                          'misplaced or incomplete. For precise per-line positioning, '
                          'switch to a local PP-OCR model above.',
                    ),
                    style: const TextStyle(fontSize: 11, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ),
      if (_settings.ocrModel == 'api')
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _apiField(
              L.pick(context, 'OCR API 地址', 'OCR API endpoint'),
              _settings.ocrApiEndpoint,
              L.pick(
                context,
                '留空则复用翻译 API 地址',
                'Leave blank to reuse the translation endpoint',
              ),
              (v) => _apply(_settings.copyWith(ocrApiEndpoint: v)),
            ),
            _apiField(
              L.pick(context, 'OCR API 密钥', 'OCR API key'),
              _settings.ocrApiKey,
              L.pick(
                context,
                '留空则复用翻译 API 密钥',
                'Leave blank to reuse the translation key',
              ),
              (v) => _apply(_settings.copyWith(ocrApiKey: v)),
              obscure: true,
            ),
            _apiField(
              L.pick(context, 'OCR 模型名', 'OCR model name'),
              _settings.ocrApiModel,
              L.pick(
                context,
                '留空则复用翻译模型名（需支持图片输入）',
                'Leave blank to reuse the translation model (must accept images)',
              ),
              (v) => _apply(_settings.copyWith(ocrApiModel: v)),
            ),
          ],
        ),
      if (_settings.ocrModel == 'local')
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                L.pick(context, '本地模型目录', 'Local model directory'),
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _settings.ocrLocalPath.trim().isEmpty
                          ? L.pick(
                              context,
                              '未选择本地模型目录',
                              'No local model folder chosen',
                            )
                          : _settings.ocrLocalPath.trim(),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white70,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Builder(
                    builder: (BuildContext buttonContext) => OutlinedButton(
                      onPressed: () => showPathChooserPopup(
                        anchorContext: buttonContext,
                        title: L.pick(
                          context,
                          '选择本地 OCR 模型目录',
                          'Choose local OCR model folder',
                        ),
                        directoryMode: true,
                        requiresOcrModels: true,
                        initialDirectory: _ocrInitialDirectory(),
                        onSelected: (path) =>
                            _apply(_settings.copyWith(ocrLocalPath: path)),
                      ),
                      child: Text(L.pick(context, '选择目录', 'Choose folder')),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      if (_ocrBusyKey.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(_ocrMessage, style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
        )
      else if (TranslateService.isDownloadableOcr(_settings.ocrModel))
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: OutlinedButton(
            onPressed: () => _toggleOcr(_settings.ocrModel),
            child: Text(
              (_ocrInstalled[_settings.ocrModel] ?? false)
                  ? L.pick(context, '删除模型', 'Delete model')
                  : L.pick(context, '下载模型', 'Download model'),
            ),
          ),
        ),
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          L.pick(
            context,
            '默认 v3 自带离线、中英稳；v4/v5/v6 需下载，覆盖更全；'
                '「在线（视觉大模型）」复用翻译 API 端点识字，但框定位常不准。',
            'v3 ships offline and is solid for Chinese/English; v4/v5/v6 need '
                'download for broader coverage; "Online (vision LLM)" reuses the '
                'translation API endpoint for OCR, but box positions are often off.',
          ),
          style: const TextStyle(fontSize: 11, color: Colors.white60),
        ),
      ),
    ];
  }

  Widget _group(
    String title,
    String groupValue,
    List<(String, String, String)> options,
    ValueChanged<String> onChanged,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 2),
          child: Text(
            title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (value, zh, en) in options)
              _ChoiceChip(
                label: L.pick(context, zh, en),
                selected: value == groupValue,
                onTap: () => onChanged(value),
              ),
          ],
        ),
      ],
    );
  }

  Widget _apiField(
    String label,
    String value,
    String hint,
    ValueChanged<String> onChanged, {
    bool obscure = false,
  }) {
    return ApiConfigField(
      label: label,
      value: value,
      hint: hint,
      obscure: obscure,
      topPadding: 8,
      onChanged: onChanged,
    );
  }
}

String _apiTypeLabel(BuildContext context, String type) => switch (type) {
  'openai' => L.pick(context, 'OpenAI 兼容', 'OpenAI-compatible'),
  'baidu' => '百度翻译',
  'deepl' => 'DeepL',
  'libre' => 'LibreTranslate',
  _ => type,
};

class _ChoiceChip extends StatelessWidget {
  const _ChoiceChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? Colors.blue.withValues(alpha: 0.6)
              : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? Colors.blue : Colors.white24),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: selected ? Colors.white : Colors.white70,
          ),
        ),
      ),
    );
  }
}
