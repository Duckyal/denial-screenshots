import 'dart:io';

/// 「用 Denial 截图编辑器打开图片」的 freedesktop 集成自注册。
///
/// 平台没有插件 post-install hook（denial-plugins 只安装密封 bundle，
/// 清单 schema 无注册脚本字段），所以由插件在编辑器 surface 启动时
/// 自己幂等落盘。语义分两层，都不打扰用户现有配置：
///
/// 1. `.desktop` 条目 + 投递脚本**始终注册**（`NoDisplay=true`，不进
///    应用菜单，只让右键「打开方式」列表里有它）——纯增量，零侵入。
/// 2. **默认打开方式只在原本没有时补位**：注册前逐 MIME 探测
///    `xdg-mime query default`，只有返回空（这台机器上 png/jpeg/…
///    压根没有默认应用）才把我们设为默认；已有别人的默认（gwenview、
///    浏览器…）一律不动，用户手动改回去后也永不再抢。
///
/// 显式退出：`DENIAL_SCREENSHOT_NO_OPEN_WITH=1`。
/// 与 tools/ 下的模板同源；那边是仓库源，这里是运行时内嵌副本。
class OpenWithIntegration {
  const OpenWithIntegration._();

  static const _desktopId = 'com.denial.ScreenshotEditor';

  /// 脚本文件名与 tools/install-image-open.sh 完全一致：两条安装路径
  /// 收敛到同一个文件，不会各装一份互相看不见。
  static const _scriptName = 'denial-screenshot-editor-open';

  /// 投递目录名：编辑器 surface 监听同一目录（editor_surface.dart）。
  static const _spoolDirName = 'denial-screenshot-editor-open';

  static const _mimeTypes = [
    'image/png',
    'image/jpeg',
    'image/webp',
    'image/bmp',
  ];

  /// 环境变量硬关（高级用户/无人值守场景）；设置面板开关是主入口，
  /// 两者任一关都不注册。
  static bool get _envOptedOut =>
      Platform.environment['DENIAL_SCREENSHOT_NO_OPEN_WITH'] == '1';

  static String _xdgDataHome() {
    final env = Platform.environment;
    final data = env['XDG_DATA_HOME'] ?? '';
    if (data.startsWith('/')) return data;
    return '${env['HOME'] ?? ''}/.local/share';
  }

  /// 用户/系统是否**显式**设过该 MIME 的默认应用：只认 mimeapps.list 的
  /// `[Default Applications]` 段。不能用 `xdg-mime query default`——它在
  /// 无显式默认时回落到 mimeinfo.cache，而我们的 `.desktop` 一注册就进
  /// cache、会被排到（"意外上位"），把"从没设过默认"误判成"已有默认"
  /// 或反过来。显式条目才是用户亲手选过的证据；cache 里漂着的浏览器
  /// 兜底不算。
  static bool _hasExplicitDefault(String mime) {
    final env = Platform.environment;
    final configHome = (env['XDG_CONFIG_HOME'] ?? '').startsWith('/')
        ? env['XDG_CONFIG_HOME']!
        : '${env['HOME'] ?? ''}/.config';
    final dataHome = (env['XDG_DATA_HOME'] ?? '').startsWith('/')
        ? env['XDG_DATA_HOME']!
        : '${env['HOME'] ?? ''}/.local/share';
    final candidates = [
      // 新规范位置优先，旧位置与系统级兜底（对齐 xdg 解析顺序）。
      '$dataHome/applications/mimeapps.list',
      '$configHome/mimeapps.list',
      '/etc/xdg/mimeapps.list',
    ];
    final prefix = '$mime=';
    for (final path in candidates) {
      try {
        var inDefaults = false;
        for (final line in File(path).readAsLinesSync()) {
          final t = line.trim();
          if (t.startsWith('[') && t.endsWith(']')) {
            inDefaults = t == '[Default Applications]';
            continue;
          }
          if (!inDefaults) continue;
          if (t.startsWith(prefix) && t.substring(prefix.length).isNotEmpty) {
            return true;
          }
        }
      } on FileSystemException {
        continue;
      }
    }
    return false;
  }

  /// 确保集成与 [enabled] 一致：开→注册（不抢已有默认），关→撤销。
  /// 任何失败静默——它是锦上添花，绝不拖垮编辑器。
  static Future<void> sync({required bool enabled}) async {
    if (enabled && !_envOptedOut) {
      await _register();
    } else if (!enabled) {
      await _unregister();
    }
  }

  static Future<void> _register() async {
    final home = Platform.environment['HOME'] ?? '';
    if (home.isEmpty) return;
    try {
      // ① 先探测"用户没亲手设过默认"的 MIME（写文件前，见注释）。
      final orphans = <String>[];
      for (final mime in _mimeTypes) {
        if (!_hasExplicitDefault(mime)) orphans.add(mime);
      }
      print('[open-with] orphans=${orphans.join(',')}');

      // ② 幂等落盘：脚本 + .desktop 条目。
      final binDir = Directory('${_xdgDataHome()}/bin');
      final appsDir = Directory('${_xdgDataHome()}/applications');
      await binDir.create(recursive: true);
      await appsDir.create(recursive: true);

      final script = File('${binDir.path}/$_scriptName');
      final scriptBody = _scriptBody();
      if (!script.existsSync() || await script.readAsString() != scriptBody) {
        await script.writeAsString(scriptBody);
        await Process.run('chmod', ['0755', script.path]);
      }

      final desktop = File('${appsDir.path}/$_desktopId.desktop');
      final desktopBody = _desktopBody(script.path);
      if (!desktop.existsSync() ||
          await desktop.readAsString() != desktopBody) {
        await desktop.writeAsString(desktopBody);
        await Process.run('update-desktop-database', [appsDir.path]);
      }

      // ③ 只给"原本就没有默认应用"的 MIME 补位；别人的默认永不动。
      for (final mime in orphans) {
        final result = await Process.run('xdg-mime', [
          'default',
          '$_desktopId.desktop',
          mime,
        ]);
        print(
          '[open-with] set-default $mime exit=${result.exitCode} '
          'err=${result.stderr.toString().trim()}',
        );
      }
    } catch (error) {
      // 注册失败不影响任何截图功能，但要能在日志里看到为什么。
      print('[open-with] failed: $error');
    }
  }

  /// 撤销注册：删 .desktop 条目与投递脚本，并从 mimeapps.list 的
  /// [Default Applications] 段里**只删指向我们自己的行**——别的默认
  /// 是用户选的，绝不越权清理（我们本来也从不覆盖它们）。
  static Future<void> _unregister() async {
    final dataHome = _xdgDataHome();
    final desktop = File('$dataHome/applications/$_desktopId.desktop');
    final script = File('$dataHome/bin/$_scriptName');
    try {
      if (desktop.existsSync()) await desktop.delete();
      if (script.existsSync()) await script.delete();
      await Process.run('update-desktop-database', ['$dataHome/applications']);
    } catch (_) {}
    // 清掉指向我们的默认项（幂等重写文件）。
    final env = Platform.environment;
    final configHome = (env['XDG_CONFIG_HOME'] ?? '').startsWith('/')
        ? env['XDG_CONFIG_HOME']!
        : '${env['HOME'] ?? ''}/.config';
    final ours = '$_desktopId.desktop';
    for (final path in [
      '$dataHome/applications/mimeapps.list',
      '$configHome/mimeapps.list',
    ]) {
      final file = File(path);
      try {
        if (!file.existsSync()) continue;
        final lines = file.readAsLinesSync();
        final kept = <String>[];
        var changed = false;
        for (final line in lines) {
          final t = line.trim();
          final isOursDefault = t.startsWith('image/') && t.endsWith('=$ours');
          if (isOursDefault) {
            changed = true;
            continue;
          }
          kept.add(line);
        }
        if (changed) {
          await file.writeAsString('${kept.join('\n')}\n');
        }
      } on FileSystemException {
        continue;
      }
    }
  }

  static String _scriptBody() =>
      '''
#!/usr/bin/env bash
# denial-screenshot-editor-open — freedesktop 打开图片 → Denial 截图编辑器
# 由 denial-screenshots 插件自动注册（与 tools/ 模板同源）。把图片绝对
# 路径写进投递目录，编辑器 surface 监听该目录、读后即删；插件没跑时
# 请求留在这里等下次启动排空。
set -euo pipefail

[[ \$# -ge 1 ]] || { echo "usage: \$0 <image-file>" >&2; exit 1; }

target="\$1"
[[ "\$target" == file://* ]] && target="\${target#file://}"

[[ -f "\$target" ]] || { echo "not a file: \$target" >&2; exit 1; }
target="\$(realpath "\$target")"

ext="\${target##*.}"
case "\${ext,,}" in
  png|jpg|jpeg|webp|bmp) ;;
  *) echo "unsupported image type: \$ext" >&2; exit 1 ;;
esac

dir="\${XDG_CONFIG_HOME:-\$HOME/.config}/$_spoolDirName"
mkdir -p "\$dir"
name="\$(date +%s%N)-\$\$.open"
printf '%s' "\$target" > "\$dir/\$name"
''';

  static String _desktopBody(String exec) =>
      '''
[Desktop Entry]
Type=Application
Version=1.0
Name=Denial Screenshot Editor
Name[zh_CN]=Denial 截图编辑器
Comment=Open images in the Denial screenshot annotation editor
Comment[zh_CN]=用 Denial 截图标注编辑器打开图片
Exec=$exec %f
TryExec=$exec
Icon=accessories-screenshot
Terminal=false
NoDisplay=true
MimeType=image/png;image/jpeg;image/jpg;image/webp;image/bmp;
Categories=Graphics;
''';
}
