import 'dart:io';

import 'package:flutter/material.dart';

import '../l10n.dart';
import '../panel_nav.dart';

/// 取路径的末段名：Directory 的 uri 带结尾斜杠，用 pathSegments.last 会得到
/// 空串（文件夹名字不显示），这里统一按 '/' 切。根目录返回 '/'。
String _basename(String path) {
  final segments = path.split('/').where((s) => s.isNotEmpty).toList();
  return segments.isEmpty ? '/' : segments.last;
}

/// 内置文件/目录面板的统一观感：四处宿主（编辑器保存/打开、选区保存、
/// 设置里的本地模型目录选择）都用这套尺寸与底色，不再各配各的。
const double kPathChooserWidth = 380;
const double kPathChooserMaxHeight = 520;
const Color kPathChooserBackground = Color(0xE60F1419);

/// 悬浮菜单式的目录/文件选择器：贴锚点弹出 [PathChooserPanel]。
///
/// 用于设置面板里的"选择本地模型目录"这类目录选择（以及历史上 zenity 的
/// 命令行参数入口，现已收敛到内置面板）。同一时刻只开一个，重复调用先收
/// 旧的。[anchorRect] 给了整块宿主面板的外沿时按它边对边贴放。
void showPathChooserPopup({
  required BuildContext anchorContext,
  required String title,
  required bool directoryMode,
  required String initialDirectory,
  bool requiresOcrModels = false,
  bool requiresTranslateModels = false,
  Future<String?> Function(String path)? translateValidator,
  Rect? anchorRect,
  Color background = kPathChooserBackground,
  String initialFileName = '',
  List<String> patterns = const <String>[],
  required void Function(String path) onSelected,
}) {
  final overlay = Overlay.maybeOf(anchorContext);
  final render = anchorContext.findRenderObject();
  if (overlay == null || render is! RenderBox) return;
  closePathChooserPopup();
  final screen = MediaQuery.of(anchorContext).size;
  final button = render.localToGlobal(Offset.zero) & render.size;
  // 与编辑器/选区的保存、打开面板同宽同高（PathChooserPanel 默认值），
  // 四处共用一套卡片观感。
  const panelWidth = kPathChooserWidth;
  const panelHeight = kPathChooserMaxHeight;
  const margin = 8.0;
  const gap = 2.0;

  // 贴边：以整块面板（[anchorRect]，如设置面板）的外沿为准，尽量边对边贴着
  // 放，而不是压在按钮/面板上。优先放右侧，右侧放不下放左侧；两侧都放不下
  // （空间不足的特殊情况）就夹回屏幕边缘、允许少量重叠。垂直与按钮对齐并夹取。
  final panel = anchorRect ?? button;
  var left = panel.right + gap;
  if (left + panelWidth > screen.width - margin) {
    left = panel.left - panelWidth - gap;
  }
  if (left < margin) {
    left = (screen.width - panelWidth - margin) > margin
        ? margin
        : (screen.width - panelWidth - margin);
  }
  final top = (button.top - 8).clamp(
    margin,
    screen.height - panelHeight - margin,
  );

  void close() => closePathChooserPopup();

  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (BuildContext context) => Stack(
      children: <Widget>[
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: close,
          ),
        ),
        Positioned(
          left: left,
          top: top,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            child: PathChooserPanel(
              title: title,
              save: false,
              directoryMode:
                  directoryMode || requiresOcrModels || requiresTranslateModels,
              requiresOcrModels: requiresOcrModels,
              requiresTranslateModels: requiresTranslateModels,
              translateValidator: translateValidator,
              background: background,
              width: panelWidth,
              height: panelHeight,
              initialDirectory: initialDirectory,
              initialFileName: initialFileName,
              patterns: patterns,
              onSelected: (path) {
                close();
                onSelected(path);
              },
              onCancel: close,
            ),
          ),
        ),
      ],
    ),
  );
  _popupEntry = entry;
  overlay.insert(entry);
}

OverlayEntry? _popupEntry;

/// 目录/文件悬浮菜单当前是否展开（供上层 ESC 关闭层级判断）。
bool isPathChooserPopupOpen() => _popupEntry != null;

/// 收起悬浮菜单（若在展开状态）。返回是否真的收起了一个。
bool closePathChooserPopup() {
  final entry = _popupEntry;
  if (entry == null) return false;
  _popupEntry = null;
  entry.remove();
  return true;
}

/// 唯一的内置文件/目录选择面板，所有宿主统一用它：编辑器工具栏的
/// 「保存 / 打开图片」浮层、框选工具栏的「保存截图」浮层、设置面板的
/// 悬浮目录选择菜单（[showPathChooserPopup]）。此前编辑器嵌半截内容
/// （缺标题与确认按钮）、选区另写一套，观感与行为都不一致，现已合并。
///
/// 自带深色主题与卡片外壳（[background]/[width]/[height] 可配），普通
/// 模式底部是「取消 + 保存/打开」按钮行（文件名缺后缀自动补 patterns
/// 首项），目录模式底部是提示 + 「选择此文件夹」（可挂 OCR/翻译模型
/// 校验）。标题旁有关闭按钮；传 [nav] 则 ESC 可先在面板里返回上级目录。
class PathChooserPanel extends StatefulWidget {
  const PathChooserPanel({
    super.key,
    this.title = '',
    required this.save,
    this.directoryMode = false,
    this.requiresOcrModels = false,
    this.requiresTranslateModels = false,
    this.translateValidator,
    required this.initialDirectory,
    this.initialFileName = '',
    this.patterns = const <String>[],
    this.background = kPathChooserBackground,
    this.width = kPathChooserWidth,
    this.height = kPathChooserMaxHeight,
    this.nav,
    required this.onSelected,
    required this.onCancel,
  });

  /// 面板标题；空串不显示标题行。
  final String title;

  /// true：保存模式（确认按钮"保存"，文件名自动补后缀）；false：打开模式
  /// （"打开"）或目录模式（[directoryMode]，按钮"选择此文件夹"）。
  final bool save;

  /// 目录选择模式：只显示/进入文件夹，确认返回当前目录本身（选本地模型目录用）。
  final bool directoryMode;

  /// 本地 OCR 模型目录模式：在目录模式基础上，额外列出目录里的 .onnx 文件，
  /// 点「选择此文件夹」时校验必须同时存在 det 和 rec 两个 .onnx，缺失则报红、
  /// 不放行——选错目录当场就能发现，不用等识别时才回退到内置模型。
  final bool requiresOcrModels;

  /// 本地翻译模型目录模式：在目录模式基础上，点「选择此文件夹」时把目录交给
  /// [translateValidator]（由调用方注入，走 sidecar 的发现逻辑）当场校验，
  /// 返回错误信息则报红、不放行。校验判据与运行时加载共用同一套，绝不出现
  /// 「选的时候过、翻译的时候挂」。
  final bool requiresTranslateModels;

  /// 翻译模型目录校验器：返回 null 表示可用，返回字符串即错误提示（已本地化）。
  /// 由调用方注入（持有 TranslateService 的地方），异步执行、不加载模型权重。
  final Future<String?> Function(String path)? translateValidator;
  final String initialDirectory;
  final String initialFileName;
  final List<String> patterns;
  final Color background;
  final double width;

  /// 卡片最大高度：内容自适应（列表 Flexible 伸缩），不是固定高。
  final double height;

  /// ESC 逐级返回桥：面板注册 canGoBack/goBack（返回上级目录），宿主浮层
  /// 的 ESC 阶梯先问它再关面板。与 [SelectionSettingsPanel] 同一套机制。
  final SelectionPanelNav? nav;

  final void Function(String path) onSelected;
  final VoidCallback onCancel;

  @override
  State<PathChooserPanel> createState() => _PathChooserPanelState();
}

class _PathChooserPanelState extends State<PathChooserPanel> {
  late Directory _directory;
  late final TextEditingController _nameController;
  List<FileSystemEntity> _entries = const <FileSystemEntity>[];
  String? _error;

  /// 翻译模型目录正在异步校验（调用 sidecar 发现逻辑）：期间禁用「选择此文件夹」
  /// 并转圈，避免重复点击与选到未校验的目录。
  bool _validating = false;

  @override
  void initState() {
    super.initState();
    _directory = Directory(widget.initialDirectory);
    _nameController = TextEditingController(text: widget.initialFileName);
    // 选中高亮 = 输入框里挂着的文件名；手输名字也要能点亮对应行。
    _nameController.addListener(_onNameChanged);
    _refresh();
    // ESC 逐级返回：上级目录可回就交给宿主浮层的 ESC 阶梯。
    widget.nav?.canGoBack = () => _directory.parent.path != _directory.path;
    widget.nav?.goBack = _up;
  }

  void _onNameChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _nameController.removeListener(_onNameChanged);
    _nameController.dispose();
    super.dispose();
  }

  /// 目录模式（含 OCR/翻译模型目录）：只能选文件夹本身，文件条目仅供查看。
  bool get _dirMode =>
      widget.directoryMode ||
      widget.requiresOcrModels ||
      widget.requiresTranslateModels;

  bool _matches(FileSystemEntity entity) {
    if (entity is Directory) return true;
    // OCR 模型目录：把 .onnx 列出来，方便确认这个目录到底有没有模型文件。
    if (widget.requiresOcrModels) {
      return entity.path.toLowerCase().endsWith('.onnx');
    }
    // 翻译模型目录：把 .bin（CTranslate2 权重）列出来，同样方便确认。
    if (widget.requiresTranslateModels) {
      return entity.path.toLowerCase().endsWith('.bin');
    }
    if (_dirMode) return false;
    if (widget.patterns.isEmpty) return true;
    final name = entity.uri.pathSegments.last.toLowerCase();
    return widget.patterns.any((extension) => name.endsWith(extension));
  }

  void _refresh() {
    final List<FileSystemEntity> entries = <FileSystemEntity>[];
    try {
      entries.addAll(
        _directory
            .listSync()
            .where(_matches)
            .where(
              (FileSystemEntity entity) =>
                  // 目录模式放行 . 开头的文件夹：本地模型常在 ~/.local 下。
                  _dirMode || !entity.uri.pathSegments.last.startsWith('.'),
            ),
      );
    } on FileSystemException catch (error) {
      _error = error.message;
    }
    entries.sort((FileSystemEntity a, FileSystemEntity b) {
      if (a is Directory && b is! Directory) return -1;
      if (a is! Directory && b is Directory) return 1;
      return a.path.compareTo(b.path);
    });
    setState(() => _entries = entries);
  }

  void _enter(Directory directory) {
    setState(() {
      _directory = directory;
      _error = null;
    });
    _refresh();
  }

  void _up() {
    final parent = _directory.parent;
    if (parent.path != _directory.path) _enter(parent);
  }

  void _home() {
    _enter(Directory(Platform.environment['HOME'] ?? '/'));
  }

  void _open(FileSystemEntity entity) {
    if (entity is Directory) {
      _enter(entity);
      return;
    }
    // 目录/模型模式下文件不可点选（只是展示），只有普通文件对话框才回填文件名。
    if (_dirMode) return;
    setState(() => _nameController.text = entity.uri.pathSegments.last);
  }

  /// 双击文件 = 回填名字并直接确认（打开模式选中即所选；保存模式选中同名覆盖）。
  void _openAndConfirm(FileSystemEntity entity) {
    if (entity is Directory || _dirMode) return;
    _nameController.text = entity.uri.pathSegments.last;
    _confirm();
  }

  /// 校验当前目录是否是可用的本地 OCR 模型目录：det、rec 两个 .onnx 都得在。
  /// 与 sidecar 的 load_ocr 判据一致（按文件名含 det/rec 匹配 *.onnx）。
  String? _validateOcrDir() {
    try {
      final onnx = _directory
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.onnx'))
          .toList();
      final hasDet = onnx.any(
        (f) => _basename(f.path).toLowerCase().contains('det'),
      );
      final hasRec = onnx.any(
        (f) => _basename(f.path).toLowerCase().contains('rec'),
      );
      if (hasDet && hasRec) return null;
      return L.pick(
        context,
        '这个目录里没有完整的 det/rec .onnx 模型，换不了',
        'No complete det/rec .onnx model in this folder',
      );
    } on FileSystemException catch (error) {
      return error.message;
    }
  }

  /// 校验当前目录是否是可用的本地翻译模型根：交给调用方注入的
  /// [PathChooserPanel.translateValidator]（走 sidecar 发现逻辑，判据与运行时
  /// 加载一致）。返回 null 放行，返回字符串即红字提示。
  Future<String?> _validateTranslateDir() async {
    final path = _directory.path;
    setState(() {
      _error = null;
      _validating = true;
    });
    try {
      return await widget.translateValidator?.call(path);
    } on Object catch (error) {
      return '$error';
    } finally {
      if (mounted) setState(() => _validating = false);
    }
  }

  /// 保存模式下缺后缀的文件名自动补 patterns 首项（默认 .png），不会保存出
  /// 无后缀文件；已有任何后缀则尊重用户输入。
  String _normalizedSaveName(String name) {
    if (!widget.save || _dirMode) return name;
    if (name.contains('.')) return name;
    final extension = widget.patterns.isEmpty ? '.png' : widget.patterns.first;
    return '$name$extension';
  }

  Future<void> _confirm() async {
    if (_dirMode) {
      if (widget.requiresOcrModels) {
        final error = _validateOcrDir();
        if (error != null) {
          setState(() => _error = error);
          return;
        }
      }
      if (widget.requiresTranslateModels) {
        if (_validating) return;
        final error = await _validateTranslateDir();
        if (!mounted) return;
        if (error != null) {
          setState(() => _error = error);
          return;
        }
      }
      widget.onSelected(_directory.path);
      return;
    }
    final raw = _nameController.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = L.s('请输入文件名', 'Enter a file name'));
      return;
    }
    final name = _normalizedSaveName(raw);
    widget.onSelected('${_directory.path}/$name');
  }

  @override
  Widget build(BuildContext context) {
    final dirHint = widget.requiresOcrModels
        ? L.pick(
            context,
            '进入含 det/rec .onnx 的目录后选择',
            'Enter the folder with det/rec .onnx files, then choose',
          )
        : widget.requiresTranslateModels
        ? L.pick(
            context,
            '选择带有 model.bin 的模型目录',
            'Choose a model folder that has model.bin',
          )
        : null;
    final confirmLabel = _dirMode
        ? L.pick(context, '选择此文件夹', 'Choose folder')
        : widget.save
        ? L.pick(context, '保存', 'Save')
        : L.pick(context, '打开', 'Open');
    return Theme(
      data: ThemeData.dark(useMaterial3: true),
      // 面板自带 Material 祖先：标题关闭叉 / 列表行 / 导航图标都是 InkWell，
      // 构建时强制要求 Material 祖先。宿主场景（编辑器、选区）里有兜底的
      // Material，但悬浮菜单挂在 Navigator 的 Overlay 上、位于路由子树之外，
      // 缺了这条会整块渲染成 ErrorWidget（黄色双下划线标题）。
      child: Material(
        type: MaterialType.transparency,
        child: DefaultTextStyle.merge(
          style: const TextStyle(color: Colors.white),
          child: Container(
            width: widget.width,
            constraints: BoxConstraints(maxHeight: widget.height),
            decoration: BoxDecoration(
              color: widget.background,
              borderRadius: BorderRadius.circular(12),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black38,
                  blurRadius: 12,
                  offset: Offset(0, 3),
                ),
              ],
            ),
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.title.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        InkWell(
                          onTap: widget.onCancel,
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
                if (!_dirMode) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextField(
                      controller: _nameController,
                      style: const TextStyle(fontSize: 13, color: Colors.white),
                      decoration: InputDecoration(
                        labelText: L.pick(context, '文件名', 'File name'),
                        labelStyle: const TextStyle(color: Colors.white70),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 10,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onSubmitted: (_) => _confirm(),
                    ),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      _iconButton(
                        Icons.home,
                        L.pick(context, '主目录', 'Home'),
                        _home,
                      ),
                      const SizedBox(width: 6),
                      _iconButton(
                        Icons.arrow_upward,
                        L.pick(context, '上级', 'Up'),
                        _up,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _directory.path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white60,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white24),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: _entries.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              _error ?? L.pick(context, '空目录', 'Empty folder'),
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.white54,
                              ),
                            ),
                          )
                        : ListView.builder(
                            shrinkWrap: true,
                            padding: EdgeInsets.zero,
                            itemCount: _entries.length,
                            itemBuilder: (BuildContext context, int index) {
                              final entity = _entries[index];
                              final isDirectory = entity is Directory;
                              final name = _basename(entity.path);
                              // 选中态：文件名与该行的输入框内容一致。深色面板上
                              // InkWell 的默认高亮几乎不可见，所以提亮整行背景、
                              // 加左侧对比色条并把图标染亮，一眼能认出挂着谁。
                              final selected =
                                  !isDirectory &&
                                  !_dirMode &&
                                  name == _nameController.text.trim();
                              return InkWell(
                                onDoubleTap: isDirectory || _dirMode
                                    ? null
                                    : () => _openAndConfirm(entity),
                                onTap: () => _open(entity),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 90),
                                  curve: Curves.easeOut,
                                  color: selected
                                      ? const Color(0x334C9AFF)
                                      : Colors.transparent,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 7,
                                  ),
                                  child: Row(
                                    children: [
                                      // 左侧对比条：只有选中行出现，未选中时留同宽
                                      // 透明位，文字不横跳。
                                      SizedBox(
                                        width: 3,
                                        child: selected
                                            ? Container(
                                                decoration: BoxDecoration(
                                                  color: const Color(
                                                    0xFF4C9AFF,
                                                  ),
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                        1.5,
                                                      ),
                                                ),
                                              )
                                            : null,
                                      ),
                                      const SizedBox(width: 7),
                                      Icon(
                                        isDirectory
                                            ? Icons.folder
                                            : Icons.image_outlined,
                                        size: 16,
                                        color: selected
                                            ? const Color(0xFF8AB8FF)
                                            : isDirectory
                                            ? Colors.amberAccent
                                            : Colors.white70,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 13,
                                            color: selected
                                                ? Colors.white
                                                : null,
                                            fontWeight: selected
                                                ? FontWeight.w600
                                                : FontWeight.normal,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ),
                if (_error != null && _entries.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      _error!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.redAccent,
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: _dirMode
                      ? Row(
                          children: [
                            Expanded(
                              child: Text(
                                dirHint ??
                                    L.pick(
                                      context,
                                      '进入目标目录后选择',
                                      'Enter the folder, then choose',
                                    ),
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.white60,
                                ),
                              ),
                            ),
                            FilledButton(
                              onPressed: _validating ? null : _confirm,
                              child: _validating
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : Text(confirmLabel),
                            ),
                          ],
                        )
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: widget.onCancel,
                              child: Text(L.pick(context, '取消', 'Cancel')),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              onPressed: _confirm,
                              child: Text(confirmLabel),
                            ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _iconButton(IconData icon, String tooltip, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 18, color: Colors.white70),
        ),
      ),
    );
  }
}
