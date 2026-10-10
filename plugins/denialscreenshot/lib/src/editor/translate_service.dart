import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Color, Rect;

import 'package:crypto/crypto.dart';

import 'sidecar_source.dart';

/// 翻译 sidecar 的宿主：管理 venv、按需安装依赖、spawn Python 进程并
/// 流式读取 JSON 行事件。
/// 在线翻译 API 的单次请求超时（秒）。UI 的超时提示也引用它，避免两处不一致。
const int apiTimeoutSeconds = 60;

/// 建连超时：连不上就快点失败，别让用户对着一个「转圈」等一整分钟。
const int apiConnectTimeoutSeconds = 10;

/// API 返回非 200：带上服务端给的原因（限流、余额不足、模型不存在…），
/// UI 直接展示，用户不用去猜。
class ApiTranslateException implements Exception {
  ApiTranslateException({
    required this.statusCode,
    required this.serverMessage,
    required this.raw,
  });

  final int statusCode;
  final String serverMessage;
  final String raw;

  @override
  String toString() => serverMessage.isNotEmpty
      ? 'API HTTP $statusCode: $serverMessage'
      : 'API HTTP $statusCode: $raw';
}

class TranslateService {
  TranslateService();

  /// 常驻 sidecar 进程与请求队列：OCR/翻译只 spawn 一次 Python，模型在
  /// 进程内复用（onnx 加载是初始识别最耗时的一步）。进程一次只服务一个
  /// 请求，并发调用按序排队，避免两个请求抢读同一路 stdout。
  Process? _proc;
  bool _procAlive = false;
  final List<String> _lineQueue = <String>[];
  Completer<String>? _lineWait;
  Future<void> _serialTail = Future<void>.value();

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

  /// OCR 模型下载源：RapidAI 官方 ModelScope 仓库（国内直连）。
  static const _ocrModelRepo =
      'https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/master';

  /// 可选 OCR 模型：(key, 标签, 说明)。builtin 无需下载。
  static const ocrModelCatalog = <(String, String, String)>[
    ('builtin', '内置标准（PP-OCRv3）', '随识别组件自带，无需下载'),
    ('v4mobile', '高精度（PP-OCRv4 移动版）', '约 16MB，精度更高、速度接近'),
    ('v4server', '超高精度（PP-OCRv4 服务器版）', '约 204MB，CPU 识别明显变慢'),
  ];

  static String _ocrModelDir(String key) => '$dataDir/models/ocr/$key';

  static String? _ocrModelFile(String key, String part) {
    final suffix = switch (key) {
      'v4server' => 'server',
      'v4mobile' => 'mobile',
      _ => null,
    };
    if (suffix == null) return null;
    return 'ch_PP-OCRv4_${part}_$suffix.onnx';
  }

  /// 高精度 OCR 模型（det+rec 两个文件）是否已下载就绪。
  Future<bool> isOcrModelInstalled(String key) async {
    if (key == 'builtin') return true;
    for (final part in ['det', 'rec']) {
      final name = _ocrModelFile(key, part);
      if (name == null) return true;
      if (!await File('${_ocrModelDir(key)}/$name').exists()) return false;
    }
    return true;
  }

  /// 下载所选 OCR 模型（[onStatus] 汇报进度）。
  Future<void> installOcrModel(
    String key, {
    void Function(String)? onStatus,
  }) async {
    for (final part in ['det', 'rec']) {
      final name = _ocrModelFile(key, part);
      if (name == null) return;
      final dest = File('${_ocrModelDir(key)}/$name');
      if (await dest.exists()) continue;
      onStatus?.call('下载 $name…');
      await Directory(_ocrModelDir(key)).create(recursive: true);
      await _download('$_ocrModelRepo/onnx/PP-OCRv4/$part/$name', dest);
    }
  }

  /// 删除已下载的 OCR 模型（回到内置模型）。
  Future<void> deleteOcrModel(String key) async {
    final dir = Directory(_ocrModelDir(key));
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  static const _languagePacks = ['translate-en_zh', 'translate-zh_en'];

  static String get home => Platform.environment['HOME'] ?? '/';
  static String get dataDir => '$home/.local/share/denial-screenshots';
  static String get venvPython => '$dataDir/venv/bin/python';
  static String get sidecarScript => '$dataDir/sidecar/translate.py';

  Future<bool>? _readyCache;

  /// 依赖是否就绪（venv + sidecar 脚本 + 关键包）。会话内缓存：每次判定
  /// 都要跑一个 python -c import 子进程（约 0.5s），进编辑器一上来就看
  /// 后台 OCR + run 各调一次，缓存能省下这半秒。
  Future<bool> isReady() => _readyCache ??= _probeReady();

  Future<bool> _probeReady() async {
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

  /// 把内嵌的 sidecar 源码同步到数据目录（内容不同才写盘）。
  ///
  /// 插件运行时没有"应用目录"这一概念，Python 源码随插件一起编译
  /// （[translateSidecarSource]），因此不再读取相对路径。
  Future<void> deploySidecar() async {
    final target = File(sidecarScript);
    await target.parent.create(recursive: true);
    if (!await target.exists() ||
        await target.readAsString() != translateSidecarSource) {
      await target.writeAsString(translateSidecarSource);
    }
  }

  /// 安装/修复依赖。事件流汇报进度；完成时发出 ready=true。
  Stream<TranslateSetupEvent> install() async* {
    _readyCache = null;
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
        final create = await Process.run('python3', [
          '-m',
          'venv',
          '$dataDir/venv',
        ]);
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
        yield TranslateSetupEvent('error', '依赖安装失败：$stderr'.trim());
        return;
      }

      yield const TranslateSetupEvent('status', '部署翻译服务…');
      await deploySidecar();

      for (final pack in _languagePacks) {
        final pair = pack.replaceFirst('translate-', '');
        // zip 里有顶层目录，metadata 可能落在 models/<pair>/ 或其子目录。
        final pairDir = Directory('$dataDir/models/$pair');
        final alreadyInstalled =
            await pairDir.exists() &&
            await pairDir
                .list(recursive: true)
                .any((entry) => entry.path.endsWith('metadata.json'));
        if (alreadyInstalled) continue;
        final archive = File('$dataDir/$pack.argosmodel');
        yield TranslateSetupEvent('status', '下载语言包 $pair（约 70MB，走 HF 镜像）…');
        try {
          await _download('$_packRepo/$pack.argosmodel', archive);
        } on Object catch (error) {
          yield TranslateSetupEvent('error', '语言包下载失败：$error');
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

  /// 本地语言包只翻译文本：OCR 结果由编辑器后台缓存复用，不再识别。
  /// 返回与 [texts] 对齐的 (译文, 是否跳过) 列表——原文已是目标语言时
  /// 跳过（不盖"自己盖自己"的无意义蒙版）。
  Future<List<(String, bool)>> translateTextsLocal(
    List<String> texts,
    String target, {
    void Function(String message)? onStatus,
  }) async {
    if (!await isReady()) {
      throw Exception('翻译组件未安装，请先在设置中安装');
    }
    final events = await _serialized(() async {
      await _ensureStarted();
      return _requestEvents({
        'target': target,
        'mode': 'texts',
        'texts': texts,
      });
    });

    List<(String, bool)>? translations;
    String? errorMessage;
    for (final event in events) {
      switch (event['event']) {
        case 'done':
          translations = [
            for (final raw in event['translations'] as List? ?? [])
              (
                (raw as Map)['translated'] as String? ?? '',
                raw['skip'] as bool? ?? false,
              ),
          ];
        case 'error':
          errorMessage = event['message'] as String? ?? '翻译失败';
        case 'status':
          onStatus?.call(event['message'] as String? ?? '');
      }
    }
    if (errorMessage != null) throw Exception(errorMessage);
    if (translations == null) throw Exception('翻译组件没有返回结果');
    return translations;
  }

  /// 启动（或在进程退出后重启）常驻 sidecar，并挂上 stdout 逐行分发。
  Future<void> _ensureStarted() async {
    if (_procAlive) return;
    _lineQueue.clear();
    _lineWait = null;
    final process = await Process.start(venvPython, [sidecarScript]);
    _proc = process;
    _procAlive = true;
    final lines = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    unawaited(_drainLines(lines, process));
    unawaited(
      process.exitCode.whenComplete(() {
        _procAlive = false;
        final waiting = _lineWait;
        if (waiting != null) {
          _lineWait = null;
          waiting.complete('{"event":"error","message":"翻译进程已退出"}');
        }
      }),
    );
  }

  Future<void> _drainLines(Stream<String> lines, Process process) async {
    try {
      await for (final line in lines) {
        final waiting = _lineWait;
        if (waiting != null) {
          _lineWait = null;
          waiting.complete(line);
        } else {
          _lineQueue.add(line);
        }
      }
    } on Object {
      // 进程被结束/崩溃：标记失效，下次请求按需重启。
    }
    _procAlive = false;
  }

  /// 取 sidecar 应答的下一行。请求按序串行，抢读/排队逻辑在此收敛。
  Future<String> _nextLine() {
    if (_lineQueue.isNotEmpty) {
      return Future.value(_lineQueue.removeAt(0));
    }
    if (!_procAlive) {
      return Future.value('{"event":"error","message":"翻译进程已退出"}');
    }
    final completer = Completer<String>();
    _lineWait = completer;
    return completer.future;
  }

  /// 常驻进程一次只服务一个请求：把并发调用按序排队，避免两个请求抢读
  /// 同一条 stdout。
  Future<T> _serialized<T>(Future<T> Function() action) {
    final run = _serialTail.then((_) => action());
    _serialTail = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  /// 向常驻进程发送一个 JSON 请求，收齐本次响应行（读到 done/error 停）。
  Future<List<Map<String, dynamic>>> _requestEvents(
    Map<String, dynamic> request,
  ) async {
    final process = _proc;
    if (process == null || !_procAlive) {
      throw Exception('翻译进程不可用');
    }
    process.stdin.writeln(jsonEncode(request));
    await process.stdin.flush();
    final events = <Map<String, dynamic>>[];
    while (true) {
      final line = await _nextLine();
      if (line.trim().isEmpty) continue;
      Map<String, dynamic> event;
      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map) continue;
        event = decoded.cast<String, dynamic>();
      } on FormatException {
        continue;
      }
      events.add(event);
      if (event['event'] == 'done' || event['event'] == 'error') break;
    }
    return events;
  }

  /// 释放常驻翻译进程（编辑器关闭时调用）。
  void dispose() {
    final process = _proc;
    _proc = null;
    _procAlive = false;
    if (process != null) {
      try {
        process.stdin
          ..writeln(jsonEncode({'quit': true}))
          ..close();
      } on Object {
        // 已退出/没有 stdin 属正常。
      }
      process.kill();
    }
  }

  /// 运行一次翻译。[imagePath] 传裁剪后的快照，[target] 是目标语言码。
  /// [mode] = 'translate'（本地 OCR+翻译）或 'ocr'（只识别，翻译走 API）。
  /// 事件流：status 进度 / region 单块结果 / done 汇总 / error 失败。
  Stream<TranslateEvent> run({
    required String imagePath,
    required String target,
    String mode = 'translate',
    String ocrModel = 'builtin',
  }) async* {
    final ready = await isReady();
    if (!ready) {
      yield const TranslateEvent('error', message: '翻译组件未安装，请先在设置中安装');
      return;
    }
    final tempInput = File('$dataDir/translate-input.png');
    await tempInput.parent.create(recursive: true);
    await tempInput.writeAsBytes(await File(imagePath).readAsBytes());

    final events = await _serialized(() async {
      await _ensureStarted();
      return _requestEvents({
        'image': tempInput.path,
        'target': target,
        'mode': mode,
        'ocr_model': ocrModel,
      });
    });

    for (final event in events) {
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
        yield TranslateEvent(
          'error',
          message: event['message'] as String? ?? '',
        );
      } else if (type == 'status') {
        yield TranslateEvent(
          'status',
          message: event['message'] as String? ?? '',
        );
      }
    }
  }

  static Future<void> _download(String url, File dest) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      // ModelScope/HF 对缺少 User-Agent 的请求直接 403；Dart HttpClient 默认
      // 不发 UA，这里显式伪装成浏览器，否则镜像下载全部失败。
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (X11; Linux x86_64) denial-screenshots',
      );
      request.followRedirects = true;
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
    void Function(String note)? onRetry,
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
        results.add(await _libreTranslate(text, target, endpoint, apiKey));
      }
      return results;
    }
    return _openAiBatchTranslate(
      texts,
      target,
      endpoint,
      apiKey,
      model,
      onRetry: onRetry,
    );
  }

  /// 从响应体里挖出服务端给的中文原因（智谱会放在 error.message）。
  ApiTranslateException _apiErrorOf(int status, String body) {
    var serverMessage = '';
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map) {
          serverMessage = (error['message'] ?? '').toString();
        } else {
          serverMessage = (decoded['message'] ?? '').toString();
        }
      }
    } on Object catch (_) {
      // 响应体不是 JSON（网关错误页之类）就用原文。
    }
    return ApiTranslateException(
      statusCode: status,
      serverMessage: serverMessage,
      raw: body,
    );
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
      final request = await client.postUrl(Uri.parse('$base/translate'));
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'q': text,
          'source': 'auto',
          'target': target,
          'format': 'text',
          if (apiKey.isNotEmpty) 'api_key': apiKey,
        }),
      );
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
    String model, {
    void Function(String note)? onRetry,
  }) async {
    if (model.trim().isEmpty) {
      throw Exception('未配置模型名，请在设置中填写');
    }
    var url = endpoint.trim().replaceAll(RegExp(r'/+$'), '');
    if (!url.contains('chat/completions')) {
      // 路径已经带版本段（DeepSeek 的 /v1、智谱的 /v4…）就只补
      // chat/completions，否则按 OpenAI 默认补 /v1/chat/completions。
      final path = Uri.parse(url).path;
      url = path.contains('/v1') || RegExp(r'/v\d+$').hasMatch(path)
          ? '$url/chat/completions'
          : '$url/v1/chat/completions';
    }
    final uri = Uri.parse(url);
    // 智谱的 GLM-4.6/4.7/5 默认带思考，翻译这种活儿会把几十秒全花在推理上
    // （表现就是「一直转圈不出结果」），显式关掉。
    final disableThinking =
        uri.host.endsWith('bigmodel.cn') || uri.host.endsWith('z.ai');

    final targetName = _languageNames[target] ?? target;
    final numbered = [
      for (var i = 0; i < texts.length; i++) '${i + 1}. ${texts[i]}',
    ].join('\n');

    // 限流（429）和网关错误（5xx）多半是暂时的，退避重试比直接报错有用；
    // 401/404/400 这种配置错误重试多少次都一样，立刻失败。
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        final wait = attempt * 2;
        onRetry?.call('限流/服务忙，${wait}s 后重试（第 $attempt 次）');
        await Future<void>.delayed(Duration(seconds: wait));
      }
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: apiConnectTimeoutSeconds);
      try {
        final request = await client.postUrl(uri);
        request.headers.contentType = ContentType.json;
        if (apiKey.isNotEmpty) {
          request.headers.set('Authorization', 'Bearer $apiKey');
        }
        request.write(
          jsonEncode({
            'model': model.trim(),
            'temperature': 0,
            if (disableThinking) 'thinking': {'type': 'disabled'},
            'messages': [
              {
                'role': 'system',
                'content':
                    'You are a translation engine. Translate each '
                    'numbered line into $targetName. Reply with the same '
                    'numbered lines ("N. text"), one per input line, no '
                    'explanations, no merging or splitting.',
              },
              {'role': 'user', 'content': numbered},
            ],
          }),
        );
        final response = await request.close().timeout(
          const Duration(seconds: apiTimeoutSeconds),
        );
        final body = await response.transform(utf8.decoder).join();
        if (response.statusCode != HttpStatus.ok) {
          final error = _apiErrorOf(response.statusCode, body);
          // 限流和网关错误退避重试；401/404/400 重试也没用，直接抛。
          if (attempt < 2 &&
              (response.statusCode == 429 || response.statusCode >= 500)) {
            lastError = error;
            continue;
          }
          throw error;
        }
        final content =
            ((((jsonDecode(body) as Map<String, dynamic>)['choices'] as List?)
                            ?.first
                        as Map<String, dynamic>?)?['message']
                    as Map<String, dynamic>?)?['content']
                as String?;
        if (content == null || content.trim().isEmpty) {
          throw Exception('API 返回为空');
        }
        // 有些模型会把结果包在 markdown 代码块里，或不用「1. 」这种编号。
        // 先剥围栏，再按编号对齐；编号解析不出来时按行顺序兜底，避免整批
        // 退回原文（表现为「调了 API 但画布没变化」）。
        final lines = content
            .replaceAll(RegExp(r'```[A-Za-z0-9]*'), '')
            .split('\n')
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty)
            .toList();
        final pattern = RegExp(r'^\s*(\d+)\s*[.、)\]:：]\s*(.*)$');
        final translated = List<String>.filled(texts.length, '');
        final unmatched = <String>[];
        for (final line in lines) {
          final match = pattern.firstMatch(line);
          final index = match == null ? null : int.tryParse(match.group(1)!);
          if (index == null || index < 1 || index > texts.length) {
            unmatched.add(line);
            continue;
          }
          translated[index - 1] = match!.group(2)!.trim();
        }
        var cursor = 0;
        for (
          var i = 0;
          i < translated.length && cursor < unmatched.length;
          i++
        ) {
          if (translated[i].isEmpty) {
            translated[i] = unmatched[cursor++];
          }
        }
        return [
          for (var i = 0; i < texts.length; i++)
            translated[i].isNotEmpty ? translated[i] : texts[i],
        ];
      } on ApiTranslateException {
        rethrow;
      } on Object catch (error) {
        // 超时/连接抖动值得一试，其余（解析失败之类）立刻抛出。
        if (attempt < 2 &&
            (error is TimeoutException || error is SocketException)) {
          lastError = error;
          continue;
        }
        rethrow;
      } finally {
        client.close();
      }
    }
    throw lastError ?? Exception('翻译 API 调用失败（已重试 2 次）');
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
    final url =
        'https://fanyi-api.baidu.com/api/trans/vip/translate'
        '?q=${Uri.encodeQueryComponent(q)}'
        '&from=auto&to=${Uri.encodeQueryComponent(to)}'
        '&appid=${Uri.encodeQueryComponent(id)}'
        '&salt=$salt&sign=$sign';
    final effectiveEndpoint = endpoint.trim().isEmpty
        ? url
        : Uri.parse(endpoint.trim())
              .replace(
                queryParameters: {
                  'q': q,
                  'from': 'auto',
                  'to': to,
                  'appid': id,
                  'salt': salt,
                  'sign': sign,
                },
              )
              .toString();

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
      final items = (json['trans_result'] as List?)
          ?.cast<Map<String, dynamic>>();
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
      request.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
      );
      request.add(utf8.encode(query));
      final response = await request.close().timeout(
        const Duration(seconds: 60),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) {
        throw Exception('DeepL HTTP ${response.statusCode}: $body');
      }
      final translations =
          ((jsonDecode(body) as Map<String, dynamic>)['translations']
              as List?) ??
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

  /// 缺失时返回空列表：调用方据 background.isEmpty 走各自的回退配色，
  /// 不能在这里偷偷替成白色，否则"自动取背景色"永远拿不到缺失信号。
  static List<int> _color(dynamic raw) {
    final list = (raw as List?)?.cast<num>();
    if (list == null || list.isEmpty) return const [];
    return [for (final channel in list.take(3)) channel.round().clamp(0, 255)];
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
