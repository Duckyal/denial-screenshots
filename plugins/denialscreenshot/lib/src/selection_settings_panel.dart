import 'dart:async';

import 'package:flutter/material.dart';

import 'editor/settings.dart';
import 'editor/translate_service.dart';

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
  });

  final ScreenshotSettings settings;
  final TranslateService translateService;
  final ValueChanged<ScreenshotSettings> onChanged;
  final VoidCallback onClose;

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

  bool _apiTesting = false;
  String _apiTestResult = '';

  @override
  void initState() {
    super.initState();
    unawaited(_refreshPacks());
    unawaited(_refreshOcr());
  }

  void _apply(ScreenshotSettings next) {
    setState(() => _settings = next);
    widget.onChanged(next);
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

  String _target() {
    final configured = _settings.translateTarget;
    if (configured != 'system') return configured;
    return View.of(context).platformDispatcher.locale.languageCode;
  }

  Future<void> _runApiTest() async {
    if (_apiTesting) return;
    setState(() {
      _apiTesting = true;
      _apiTestResult = '正在测试…';
    });
    try {
      final result = await widget.translateService.translateViaApi(
        texts: const ['Hello, world'],
        target: _target(),
        apiType: _settings.apiType,
        endpoint: _settings.apiEndpoint,
        apiKey: _settings.apiKey,
        model: _settings.apiModel,
        apiAppId: _settings.apiAppId,
      );
      if (!mounted) return;
      setState(() {
        _apiTesting = false;
        _apiTestResult = '可用：Hello, world → ${result.first}';
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
                    const Text(
                      '设置',
                      style: TextStyle(
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
      _group(
        '翻译接口',
        _settings.translateBackend,
        const [('api', '在线翻译 API'), ('local', '本地模型')],
        (value) {
          if (value == 'local') _apiOpen = false;
          if (value == 'api') _modelsOpen = false;
          _apply(_settings.copyWith(translateBackend: value));
        },
      ),
      if (_settings.translateBackend == 'api') ..._apiSection(),
      if (_settings.translateBackend == 'local') ..._localModelsSection(),
      _group('翻译为', _settings.translateTarget, const [
        ('system', '跟随系统'),
        ('zh', '中文'),
        ('en', 'English'),
        ('ja', '日本語'),
        ('ko', '한국어'),
        ('fr', 'Français'),
        ('de', 'Deutsch'),
        ('ru', 'Русский'),
        ('es', 'Español'),
      ], (value) => _apply(_settings.copyWith(translateTarget: value))),
      ..._ocrSection(),
    ];
  }

  List<Widget> _apiSection() {
    final details = <String>[
      _apiTypeLabel(_settings.apiType),
      if (_settings.apiEndpoint.trim().isNotEmpty) _settings.apiEndpoint.trim(),
      if (_settings.apiModel.trim().isNotEmpty) _settings.apiModel.trim(),
      if (_settings.apiType == 'baidu' && _settings.apiAppId.trim().isNotEmpty)
        'APP ID ${_settings.apiAppId.trim()}',
      _settings.apiKey.trim().isNotEmpty ? '密钥已填' : '密钥未填',
    ];
    return [
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          '当前接口：${details.join(' · ')}',
          style: const TextStyle(fontSize: 12, color: Colors.white70),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: OutlinedButton(
          onPressed: () => setState(() => _apiOpen = !_apiOpen),
          child: Text(_apiOpen ? '收起配置' : '配置在线翻译 API'),
        ),
      ),
      if (_apiOpen) ...[
        _group('翻译协议', _settings.apiType, const [
          ('openai', 'OpenAI 兼容（DeepSeek / OpenAI / Ollama…）'),
          ('baidu', '百度翻译'),
          ('deepl', 'DeepL'),
          ('libre', 'LibreTranslate'),
        ], (value) => _apply(_settings.copyWith(apiType: value))),
        if (_settings.apiType == 'openai') ...[
          _apiField(
            'API 地址',
            _settings.apiEndpoint,
            'https://api.deepseek.com',
            (value) => _apply(_settings.copyWith(apiEndpoint: value)),
          ),
          _apiField(
            'API 密钥',
            _settings.apiKey,
            'sk-…',
            (value) => _apply(_settings.copyWith(apiKey: value)),
            obscure: true,
          ),
          _apiField(
            '模型名',
            _settings.apiModel,
            'deepseek-chat',
            (value) => _apply(_settings.copyWith(apiModel: value)),
          ),
        ] else if (_settings.apiType == 'baidu') ...[
          _apiField(
            'APP ID',
            _settings.apiAppId,
            '在 fanyi-api.baidu.com 免费申请',
            (value) => _apply(_settings.copyWith(apiAppId: value)),
          ),
          _apiField(
            '密钥',
            _settings.apiKey,
            '与 APP ID 配对',
            (value) => _apply(_settings.copyWith(apiKey: value)),
            obscure: true,
          ),
        ] else if (_settings.apiType == 'deepl')
          _apiField(
            '密钥',
            _settings.apiKey,
            '…:fx 结尾为免费版',
            (value) => _apply(_settings.copyWith(apiKey: value)),
            obscure: true,
          )
        else ...[
          _apiField(
            'API 地址',
            _settings.apiEndpoint,
            'https://libretranslate.example.com',
            (value) => _apply(_settings.copyWith(apiEndpoint: value)),
          ),
          _apiField(
            'API 密钥',
            _settings.apiKey,
            '可留空',
            (value) => _apply(_settings.copyWith(apiKey: value)),
            obscure: true,
          ),
        ],
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: OutlinedButton(
            onPressed: _apiTesting ? null : _runApiTest,
            child: Text(_apiTesting ? '测试中…' : '测试连接'),
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
          child: Text(_modelsOpen ? '收起模型列表' : '管理本地翻译模型（下载/删除）'),
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
            title: Text(label, style: const TextStyle(fontSize: 13)),
            trailing: _packBusy == (from, to)
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : TextButton(
                    onPressed: () => _togglePack(from, to),
                    child: Text(
                      (_packInstalled[(from, to)] ?? false) ? '删除' : '下载',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
          ),
      ],
    ];
  }

  List<Widget> _ocrSection() {
    return [
      const Padding(
        padding: EdgeInsets.only(top: 10, bottom: 2),
        child: Text(
          '识字模型（截图取字与翻译共用，CPU 推理）',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
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
                title: Text(label, style: const TextStyle(fontSize: 13)),
                subtitle: Text(
                  key == 'builtin'
                      ? note
                      : '$note · ${_ocrInstalled[key] ?? false ? '已下载' : '未下载'}',
                  style: const TextStyle(fontSize: 11, color: Colors.white60),
                ),
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
      else if (_settings.ocrModel != 'builtin')
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: OutlinedButton(
            onPressed: () => _toggleOcr(_settings.ocrModel),
            child: Text(
              (_ocrInstalled[_settings.ocrModel] ?? false) ? '删除模型' : '下载模型',
            ),
          ),
        ),
    ];
  }

  Widget _group(
    String title,
    String groupValue,
    List<(String, String)> options,
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
            for (final (value, label) in options)
              _ChoiceChip(
                label: label,
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
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TextField(
        controller: TextEditingController(text: value)
          ..selection = TextSelection.collapsed(offset: value.length),
        obscureText: obscure,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
        onChanged: onChanged,
      ),
    );
  }
}

String _apiTypeLabel(String type) => switch (type) {
  'openai' => 'OpenAI 兼容',
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
