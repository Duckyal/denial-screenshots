import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Color, Rect;
import 'package:crypto/crypto.dart';

/// 翻译 sidecar 的宿主：管理 venv、按需安装依赖、spawn Python 进程并
/// 流式读取 JSON 行事件。
class TranslateService {
  TranslateService();

  static const _mirror = 'https://pypi.tuna.tsinghua.edu.cn/simple';
  static const _packages = [
    'rapidocr-onnxruntime',
    'ctranslate2',
    'sentencepiece',
    'pillow',
  ];

  /// 语言包：Argos 官方站被墙，走 HF 镜像仓库 shethjenil/argostranslate。
  static const _hfMirror = 'https://hf-mirror.com';
  static const _packRepo = '$_hfMirror/shethjenil/argostranslate/resolve/main';
  static const _languagePacks = ['translate-en_zh', 'translate-zh_en'];

  static String get home => Platform.environment['HOME'] ?? '/';
  static String get dataDir => '$home/.local/share/denial-screenshots';
  static String get venvPython => '$dataDir/venv/bin/python';
  static String get sidecarScript => '$dataDir/sidecar/translate.py';

  /// 依赖是否就绪（venv + sidecar 脚本 + 关键包）。
  Future<bool> isReady() async {
    if (!await File(venvPython).exists()) return false;
    // 每次都同步部署 sidecar：开发迭代频繁，部署的旧脚本曾导致运行崩溃。
    await deploySidecar();
    if (!await File(sidecarScript).exists()) return false;
    try {
      final result = await Process.run(venvPython, [
        '-c',
        'import rapidocr_onnxruntime, ctranslate2, sentencepiece, PIL',
      ]);
      return result.exitCode == 0;
    } on Object {
      return false;
    }
  }

  /// 把仓库里的 sidecar/translate.py 同步到数据目录（内容不同才写盘）。
  Future<void> deploySidecar() async {
    final source = File('sidecar/translate.py');
    if (!await source.exists()) return;
    final target = File(sidecarScript);
    await target.parent.create(recursive: true);
    final sourceText = await source.readAsString();
    if (!await target.exists() || await target.readAsString() != sourceText) {
      await target.writeAsString(sourceText);
    }
  }

  /// 安装/修复依赖。事件流汇报进度；完成时发出 ready=true。
  Stream<TranslateSetupEvent> install() async* {
    try {
      yield const TranslateSetupEvent('status', '创建 Python 环境…');
      final directory = Directory(dataDir);
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      if (!await File(venvPython).exists()) {
        final venv = await Process.run('python3', ['--version']);
        if (venv.exitCode != 0) {
          yield const TranslateSetupEvent('error', '系统缺少 python3');
          return;
        }
        final create = await Process.run(
          'python3',
          ['-m', 'venv', '$dataDir/venv'],
        );
        if (create.exitCode != 0) {
          yield TranslateSetupEvent(
            'error',
            '创建 venv 失败：${create.stderr}'.trim(),
          );
          return;
        }
      }

      yield const TranslateSetupEvent('status', '安装 OCR 与翻译模型…');
      final pip = await Process.start(venvPython, [
        '-m',
        'pip',
        'install',
        '--quiet',
        '-i',
        _mirror,
        ..._packages,
      ]);
      pip.stdout.transform(utf8.decoder).listen((_) {});
      final stderr = StringBuffer();
      pip.stderr.transform(utf8.decoder).listen(stderr.write);
      final code = await pip.exitCode;
      if (code != 0) {
        yield TranslateSetupEvent(
          'error',
          '依赖安装失败：$stderr'.trim(),
        );
        return;
      }

      yield const TranslateSetupEvent('status', '部署翻译服务…');
      if (!await File('sidecar/translate.py').exists()) {
        yield const TranslateSetupEvent(
          'error',
          '缺少 sidecar/translate.py（需要从应用目录运行）',
        );
        return;
      }
      await deploySidecar();

      for (final pack in _languagePacks) {
        final pair = pack.replaceFirst('translate-', '');
        // zip 里有顶层目录，metadata 可能落在 models/<pair>/ 或其子目录。
        final pairDir = Directory('$dataDir/models/$pair');
        final alreadyInstalled = await pairDir.exists() &&
            await pairDir
                .list(recursive: true)
                .any((entry) => entry.path.endsWith('metadata.json'));
        if (alreadyInstalled) continue;
        final archive = File('$dataDir/$pack.argosmodel');
        yield TranslateSetupEvent(
          'status',
          '下载语言包 $pair（约 70MB，走 HF 镜像）…',
        );
        try {
          await _download('$_packRepo/$pack.argosmodel', archive);
        } on Object catch (error) {
          yield TranslateSetupEvent(
            'error',
            '语言包下载失败：$error',
          );
          return;
        }
        yield TranslateSetupEvent('status', '解压语言包 $pair…');
        final extract = await Process.run(venvPython, [
          '-c',
          'import zipfile, sys; '
              'zipfile.ZipFile(r"${archive.path}").extractall('
              'r"$dataDir/models/$pair")',
        ]);
        await archive.delete();
        if (extract.exitCode != 0) {
          yield TranslateSetupEvent(
            'error',
            '语言包解压失败：${extract.stderr}'.trim(),
          );
          return;
        }
      }

      final ready = await isReady();
      if (!ready) {
        yield const TranslateSetupEvent('error', '依赖校验失败');
        return;
      }
      yield const TranslateSetupEvent('ready', '翻译组件就绪');
    } on Object catch (error) {
      yield TranslateSetupEvent('error', '安装失败：$error');
    }
  }

  /// 运行一次翻译。[imagePath] 传裁剪后的快照，[target] 是目标语言码。
  /// [mode] = 'translate'（本地 OCR+翻译）或 'ocr'（只识别，翻译走 API）。
  /// 事件流：status 进度 / region 单块结果 / done 汇总 / error 失败。
  Stream<TranslateEvent> run({
    required String imagePath,
    required String target,
    String mode = 'translate',
  }) async* {
    final ready = await isReady();
    if (!ready) {
      yield const TranslateEvent(
        'error',
        message: '翻译组件未安装，请先在设置中安装',
      );
      return;
    }
    final tempInput = File('$dataDir/translate-input.png');
    await tempInput.parent.create(recursive: true);
    await tempInput.writeAsBytes(await File(imagePath).readAsBytes());

    final process = await Process.start(venvPython, [
      sidecarScript,
    ]);
    process.stdin.writeln(jsonEncode({
      'image': tempInput.path,
      'target': target,
      'mode': mode,
    }));
    await process.stdin.close();

    final lines =
        process.stdout.transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      Map<String, dynamic> event;
      try {
        event = jsonDecode(line) as Map<String, dynamic>;
      } on FormatException {
        continue;
      }
      final type = event['event'] as String? ?? '';
      if (type == 'region') {
        final rect = (event['rect'] as List).cast<num>();
        yield TranslateEvent(
          'region',
          region: TranslateRegion(
            rect: Rect.fromLTRB(
              rect[0].toDouble(),
              rect[1].toDouble(),
              rect[0].toDouble() + rect[2].toDouble(),
              rect[1].toDouble() + rect[3].toDouble(),
            ),
            source: event['source'] as String? ?? '',
            translated: event['translated'] as String? ?? '',
            background: _color(event['bg']),
            foreground: _color(event['fg']),
          ),
        );
      } else if (type == 'done') {
        final regions = (event['regions'] as List? ?? []).map((raw) {
          final map = raw as Map<String, dynamic>;
          final rect = (map['rect'] as List).cast<num>();
          return TranslateRegion(
            rect: Rect.fromLTRB(
              rect[0].toDouble(),
              rect[1].toDouble(),
              rect[0].toDouble() + rect[2].toDouble(),
              rect[1].toDouble() + rect[3].toDouble(),
            ),
            source: map['source'] as String? ?? '',
            translated: map['translated'] as String? ?? '',
            background: _color(map['bg']),
            foreground: _color(map['fg']),
          );
        }).toList();
        yield TranslateEvent('done', regions: regions);
      } else if (type == 'error') {
        yield TranslateEvent('error',
            message: event['message'] as String? ?? '');
      } else if (type == 'status') {
        yield TranslateEvent('status',
            message: event['message'] as String? ?? '');
      }
    }
    await process.exitCode;
  }

  static Future<void> _download(String url, File dest) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      final sink = dest.openWrite();
      await response.pipe(sink);
    } finally {
      client.close();
    }
  }

  /// 可下载的语言包目录（HF 镜像仓库均存在，已逐一探测）。
  static const packCatalog = <(String, String, String)>[
    ('en', 'zh', '英语 → 中文'),
    ('zh', 'en', '中文 → 英语'),
    ('en', 'ja', '英语 → 日语'),
    ('ja', 'en', '日语 → 英语'),
    ('en', 'ko', '英语 → 韩语'),
    ('ko', 'en', '韩语 → 英语'),
    ('en', 'fr', '英语 → 法语'),
    ('fr', 'en', '法语 → 英语'),
    ('en', 'de', '英语 → 德语'),
    ('de', 'en', '德语 → 英语'),
    ('en', 'ru', '英语 → 俄语'),
    ('ru', 'en', '俄语 → 英语'),
    ('en', 'es', '英语 → 西班牙语'),
    ('es', 'en', '西班牙语 → 英语'),
  ];

  static String _packDir(String from, String to) =>
      '$dataDir/models/${from}_$to';

  Future<bool> isPackInstalled(String from, String to) async {
    final dir = Directory(_packDir(from, to));
    if (!await dir.exists()) return false;
    return await dir
        .list(recursive: true)
        .any((entry) => entry.path.endsWith('metadata.json'));
  }

  /// 下载并解压语言包（走 HF 镜像）。[onStatus] 汇报进度。
  Future<void> installPack(
    String from,
    String to, {
    void Function(String)? onStatus,
  }) async {
    final pack = 'translate-${from}_$to';
    onStatus?.call('下载 $from→$to 语言包…');
    final archive = File('$dataDir/$pack.argosmodel');
    await Directory(dataDir).create(recursive: true);
    await _download('$_packRepo/$pack.argosmodel', archive);
    onStatus?.call('解压 $from→$to 语言包…');
    final extract = await Process.run(venvPython, [
      '-c',
      'import zipfile; '
          'zipfile.ZipFile(r"${archive.path}").extractall('
          'r"${_packDir(from, to)}")',
    ]);
    await archive.delete();
    if (extract.exitCode != 0) {
      throw Exception('解压失败：${extract.stderr}');
    }
  }

  Future<void> deletePack(String from, String to) async {
    final dir = Directory(_packDir(from, to));
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  /// 在线翻译 API：把 [texts] 逐条翻译，返回与输入对齐的结果。
  Future<List<String>> translateViaApi({
    required List<String> texts,
    required String target,
    required String apiType,
    required String endpoint,
    required String apiKey,
    required String model,
    String apiAppId = '',
  }) async {
    if (apiType == 'baidu') {
      if (apiKey.trim().isEmpty) {
        throw Exception('未配置百度翻译密钥，请在设置中填写');
      }
      return _baiduBatchTranslate(
        texts,
        target,
        endpoint: endpoint,
        appId: apiAppId,
        appKey: apiKey,
      );
    }
    if (apiType == 'deepl') {
      if (apiKey.trim().isEmpty) {
        throw Exception('未配置 DeepL 密钥，请在设置中填写');
      }
      return _deeplBatchTranslate(texts, target, apiKey);
    }
    if (endpoint.trim().isEmpty) {
      throw Exception('未配置 API 地址，请在设置中填写');
    }
    if (apiType == 'libre') {
      final results = <String>[];
      for (final text in texts) {
        results.add(
          await _libreTranslate(text, target, endpoint, apiKey),
        );
      }
      return results;
    }
    return _openAiBatchTranslate(texts, target, endpoint, apiKey, model);
  }

  static const _languageNames = {
    'zh': 'Simplified Chinese',
    'en': 'English',
    'ja': 'Japanese',
    'ko': 'Korean',
    'fr': 'French',
    'de': 'German',
    'ru': 'Russian',
    'es': 'Spanish',
  };

  Future<String> _libreTranslate(
    String text,
    String target,
    String endpoint,
    String apiKey,
  ) async {
    final base = endpoint.trim().replaceAll(RegExp(r'/+$'), '');
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('$base/translate'),
      );
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({
        'q': text,
        'source': 'auto',
        'target': target,
        'format': 'text',
        if (apiKey.isNotEmpty) 'api_key': apiKey,
      }));
      final response = await request.close().timeout(
            const Duration(seconds: 30),
          );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) {
        throw Exception('LibreTranslate HTTP ${response.statusCode}: $body');
      }
      return (jsonDecode(body) as Map<String, dynamic>)['translatedText']
              as String? ??
          text;
    } finally {
      client.close();
    }
  }

  Future<List<String>> _openAiBatchTranslate(
    List<String> texts,
    String target,
    String endpoint,
    String apiKey,
    String model,
  ) async {
    if (model.trim().isEmpty) {
      throw Exception('未配置模型名，请在设置中填写');
    }
    var url = endpoint.trim().replaceAll(RegExp(r'/+$'), '');
    if (!url.contains('chat/completions')) {
      url = Uri.parse(url).path.contains('/v1')
          ? '$url/chat/completions'
          : '$url/v1/chat/completions';
    }
    final targetName = _languageNames[target] ?? target;
    final numbered = [
      for (var i = 0; i < texts.length; i++) '${i + 1}. ${texts[i]}',
    ].join('\n');

    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse(url));
      request.headers.contentType = ContentType.json;
      if (apiKey.isNotEmpty) {
        request.headers.set('Authorization', 'Bearer $apiKey');
      }
      request.write(jsonEncode({
        'model': model.trim(),
        'temperature': 0,
        'messages': [
          {
            'role': 'system',
            'content': 'You are a translation engine. Translate each '
                'numbered line into $targetName. Reply with the same '
                'numbered lines ("N. text"), one per input line, no '
                'explanations, no merging or splitting.',
          },
          {'role': 'user', 'content': numbered},
        ],
      }));
      final response = await request.close().timeout(
            const Duration(seconds: 90),
          );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) {
        throw Exception('API HTTP ${response.statusCode}: $body');
      }
      final content =
          ((((jsonDecode(body) as Map<String, dynamic>)['choices'] as List?)
                  ?.first as Map<String, dynamic>?)?['message']
              as Map<String, dynamic>?)?['content'] as String?;
      if (content == null || content.trim().isEmpty) {
        throw Exception('API 返回为空');
      }
      final pattern = RegExp(r'^\s*(\d+)[.、)\]]\s*(.*)$');
      final translated = List<String>.filled(texts.length, '');
      for (final line in content.split('\n')) {
        final match = pattern.firstMatch(line);
        if (match == null) continue;
        final index = int.tryParse(match.group(1)!);
        if (index == null || index < 1 || index > texts.length) continue;
        translated[index - 1] = match.group(2)!.trim();
      }
      return [
        for (var i = 0; i < texts.length; i++)
          translated[i].isNotEmpty ? translated[i] : texts[i],
      ];
    } finally {
      client.close();
    }
  }

  /// 百度语言代码与通用码的差异（ja/jp、ko/kor、fr/fra、es/spa）。
  static const _baiduCodes = {
    'zh': 'zh',
    'en': 'en',
    'ja': 'jp',
    'ko': 'kor',
    'fr': 'fra',
    'de': 'de',
    'ru': 'ru',
    'es': 'spa',
  };

  /// 百度翻译开放平台：多行合并为一次请求（免费版 1 QPS，别并发）。
  Future<List<String>> _baiduBatchTranslate(
    List<String> texts,
    String target, {
    required String endpoint,
    required String appId,
    required String appKey,
  }) async {
    if (appId.trim().isEmpty) {
      throw Exception('未配置百度 APP ID，请在设置中填写');
    }
    final id = appId.trim();
    final key = appKey.trim();
    final salt = DateTime.now().microsecondsSinceEpoch.toString();
    final q = texts.join('\n');
    final sign = md5.convert(utf8.encode('$id$q$salt$key')).toString();
    final to = _baiduCodes[target] ?? target;
    final url = 'https://fanyi-api.baidu.com/api/trans/vip/translate'
        '?q=${Uri.encodeQueryComponent(q)}'
        '&from=auto&to=${Uri.encodeQueryComponent(to)}'
        '&appid=${Uri.encodeQueryComponent(id)}'
        '&salt=$salt&sign=$sign';
    final effectiveEndpoint = endpoint.trim().isEmpty
        ? url
        : Uri.parse(endpoint.trim()).replace(queryParameters: {
            'q': q,
            'from': 'auto',
            'to': to,
            'appid': id,
            'salt': salt,
            'sign': sign,
          }).toString();

    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(effectiveEndpoint));
      final response = await request.close().timeout(
            const Duration(seconds: 30),
          );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) {
        throw Exception('百度翻译 HTTP ${response.statusCode}: $body');
      }
      final json = jsonDecode(body) as Map<String, dynamic>;
      final errorCode = json['error_code'] as String?;
      if (errorCode != null) {
        throw Exception('百度翻译错误 $errorCode: ${json['error_msg'] ?? ''}');
      }
      final items =
          (json['trans_result'] as List?)?.cast<Map<String, dynamic>>();
      if (items == null || items.isEmpty) {
        throw Exception('百度翻译返回为空');
      }
      final results = List<String>.filled(texts.length, '');
      // 返回条数可能少于请求（空行被合并），按 src 对齐。
      final bySource = <String, String>{};
      for (final item in items) {
        bySource[item['src'] as String? ?? ''] = item['dst'] as String? ?? '';
      }
      for (var i = 0; i < texts.length; i++) {
        results[i] = bySource[texts[i]] ?? texts[i];
      }
      return results;
    } finally {
      client.close();
    }
  }

  /// DeepL：按密钥后缀选免费/专业主机，文本以重复 text 参数提交。
  Future<List<String>> _deeplBatchTranslate(
    List<String> texts,
    String target,
    String apiKey,
  ) async {
    final key = apiKey.trim();
    final host = key.endsWith(':fx')
        ? 'https://api-free.deepl.com'
        : 'https://api.deepl.com';
    final code = _deeplCodes[target] ?? target.toUpperCase();
    final query = [
      for (final text in texts) 'text=${Uri.encodeQueryComponent(text)}',
      'target_lang=${Uri.encodeQueryComponent(code)}',
    ].join('&');
    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse('$host/v2/translate'));
      request.headers.set('Authorization', 'DeepL-Auth-Key $key');
      request.headers.contentType =
          ContentType('application', 'x-www-form-urlencoded');
      request.add(utf8.encode(query));
      final response = await request.close().timeout(
            const Duration(seconds: 60),
          );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) {
        throw Exception('DeepL HTTP ${response.statusCode}: $body');
      }
      final translations = ((jsonDecode(body)
              as Map<String, dynamic>)['translations'] as List?) ??
          <dynamic>[];
      if (translations.isEmpty) {
        throw Exception('DeepL 返回为空');
      }
      return [
        for (final item in translations)
          (item as Map<String, dynamic>)['text'] as String? ?? '',
      ];
    } finally {
      client.close();
    }
  }

  static const _deeplCodes = {
    'zh': 'ZH',
    'en': 'EN-US',
    'ja': 'JA',
    'ko': 'KO',
    'fr': 'FR',
    'de': 'DE',
    'ru': 'RU',
    'es': 'ES',
  };

  static List<int> _color(dynamic raw) {
    final list = (raw as List?)?.cast<num>() ?? const [255, 255, 255];
    return [
      for (final channel in list.take(3)) channel.round().clamp(0, 255),
    ];
  }
}

class TranslateSetupEvent {
  const TranslateSetupEvent(this.type, this.message);

  /// status | error | ready
  final String type;
  final String message;
}

class TranslateEvent {
  const TranslateEvent(
    this.type, {
    this.message,
    this.region,
    this.regions = const [],
  });

  /// status | region | done | error
  final String type;
  final String? message;
  final TranslateRegion? region;
  final List<TranslateRegion> regions;
}

class TranslateRegion {
  const TranslateRegion({
    required this.rect,
    required this.source,
    required this.translated,
    required this.background,
    required this.foreground,
  });

  final Rect rect;
  final String source;
  final String translated;
  final List<int> background;
  final List<int> foreground;

  Color get backgroundColor => Color.fromARGB(
        255,
        background.isNotEmpty ? background[0] : 255,
        background.length > 1 ? background[1] : 255,
        background.length > 2 ? background[2] : 255,
      );

  Color get foregroundColor => Color.fromARGB(
        255,
        foreground.isNotEmpty ? foreground[0] : 0,
        foreground.length > 1 ? foreground[1] : 0,
        foreground.length > 2 ? foreground[2] : 0,
      );
}
