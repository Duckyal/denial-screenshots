import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../l10n.dart';
import 'dialog_style.dart';

/// 取路径的末段名：Directory 的 uri 带结尾斜杠，用 pathSegments.last 会得到
/// 空串（文件夹名字不显示），这里统一按 '/' 切。根目录返回 '/'。
String _basename(String path) {
  final segments = path.split('/').where((s) => s.isNotEmpty).toList();
  return segments.isEmpty ? '/' : segments.last;
}

/// 插件内置的文件选择对话框。
///
/// 编辑器运行在合成器的 aboveWindows 层，外部程序（zenity）的窗口会被这层
/// 盖住，因此保存/打开必须在 shell 内部完成，不再拉起外部文件选择器。
///
/// 参数沿用原 zenity 命令行数组，调用方无需改动：
/// * `--save` 表示保存（否则为打开）；
/// * `--title=…`、`--filename=…`、`--file-filter=名称 | *.png …`。
Future<String?> choosePathWithDialog({
  required BuildContext context,
  required List<String> arguments,
}) {
  var save = false;
  var title = '';
  var filename = '';
  var patterns = const <String>[];
  for (final argument in arguments) {
    if (argument == '--save') {
      save = true;
    } else if (argument.startsWith('--title=')) {
      title = argument.substring('--title='.length);
    } else if (argument.startsWith('--filename=')) {
      filename = argument.substring('--filename='.length);
    } else if (argument.startsWith('--file-filter=')) {
      final value = argument.substring('--file-filter='.length);
      final separator = value.contains('|') ? '|' : '｜';
      patterns = value
          .split(separator)
          .last
          .split(RegExp(r'\s+'))
          .where((pattern) => pattern.startsWith('*.'))
          .map((pattern) => pattern.substring(1).toLowerCase())
          .toList(growable: false);
    }
  }

  final home = Platform.environment['HOME'] ?? '/';
  final initial = save ? '$home/Pictures/Screenshots' : '$home/Pictures';

  return showDialog<String>(
    context: context,
    barrierColor: const Color(0x66000000),
    builder: (BuildContext dialogContext) => _PathChooser(
      title: title.isEmpty
          ? (save
                ? L.pick(context, '保存', 'Save')
                : L.pick(context, '打开', 'Open'))
          : title,
      save: save,
      initialDirectory: initial,
      initialFileName: filename,
      patterns: patterns,
    ),
  );
}

/// 在触发按钮附近贴边弹出一个独立悬浮菜单（子菜单风格），用于选本地模型目录。
///
/// 与编辑器「保存」按钮那套一致：不是把选择 UI 塞进按钮所在面板，也不是居中
/// 模态窗（遮罩会压暗画面、风格割裂），而是就近浮出一个暗色圆角面板，点面板
/// 外空白处收起。[anchorContext] 用触发按钮自身的 context，保证贴在按钮旁。
void showPathChooserPopup({
  required BuildContext anchorContext,
  required String title,
  required bool directoryMode,
  required String initialDirectory,
  bool requiresOcrModels = false,
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
  const panelWidth = 340.0;
  const panelHeight = 380.0;
  const margin = 8.0;

  // 贴边：优先放按钮右侧，放不下就放左侧；垂直与按钮对齐并按屏幕夹取。
  var left = button.right + 4;
  if (left + panelWidth > screen.width - margin) {
    left = (button.left - panelWidth - 4).clamp(margin, screen.width - margin);
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
        // 透明点击层：吞掉外部点击并收起，不压暗背景。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: close,
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          left: left,
          top: top,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            child: Theme(
              data: ThemeData.dark(useMaterial3: true),
              child: Material(
                color: Colors.transparent,
                child: Container(
                  width: panelWidth,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.82),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black38,
                        blurRadius: 10,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          title,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      PathChooserPanel(
                        title: title,
                        save: false,
                        directoryMode: directoryMode || requiresOcrModels,
                        requiresOcrModels: requiresOcrModels,
                        width: panelWidth - 20,
                        height: panelHeight - 70,
                        initialDirectory: initialDirectory,
                        initialFileName: initialFileName,
                        patterns: patterns,
                        onSelected: (path) {
                          close();
                          onSelected(path);
                        },
                        onCancel: close,
                      ),
                    ],
                  ),
                ),
              ),
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

/// 目录/文件悬浮菜单当前是否展开（供上层 Esc 关闭层级判断）。
bool isPathChooserPopupOpen() => _popupEntry != null;

/// 收起悬浮菜单（若在展开状态）。返回是否真的收起了一个。
bool closePathChooserPopup() {
  final entry = _popupEntry;
  if (entry == null) return false;
  entry.remove();
  _popupEntry = null;
  return true;
}

class _PathChooser extends StatefulWidget {
  const _PathChooser({
    required this.title,
    required this.save,
    required this.initialDirectory,
    required this.initialFileName,
    required this.patterns,
  });

  final String title;
  final bool save;
  final String initialDirectory;
  final String initialFileName;
  final List<String> patterns;

  @override
  State<_PathChooser> createState() => _PathChooserState();
}

class _PathChooserState extends State<_PathChooser> {
  late Directory _directory;
  late final TextEditingController _nameController;
  List<FileSystemEntity> _entries = const <FileSystemEntity>[];
  String? _error;

  @override
  void initState() {
    super.initState();
    _directory = Directory(widget.initialDirectory);
    _nameController = TextEditingController(text: widget.initialFileName);
    _refresh();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  bool _matches(FileSystemEntity entity) {
    if (entity is Directory) return true;
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
                  !entity.uri.pathSegments.last.startsWith('.'),
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

  void _open(FileSystemEntity entity) {
    if (entity is Directory) {
      _enter(entity);
      return;
    }
    setState(() => _nameController.text = entity.uri.pathSegments.last);
  }

  void _confirm() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop('${_directory.path}/$name');
  }

  @override
  Widget build(BuildContext context) {
    return editorDialogTheme(
      child: AlertDialog(
        backgroundColor: editorDialogBackground,
        shape: editorDialogShape,
        title: Text(widget.title),
        content: _PathChooserContent(
          directory: _directory,
          entries: _entries,
          nameController: _nameController,
          error: _error,
          save: widget.save,
          onEnter: _enter,
          onOpen: _open,
          onConfirm: _confirm,
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(L.pick(context, '取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: _confirm,
            child: Text(
              widget.save
                  ? L.pick(context, '保存', 'Save')
                  : L.pick(context, '打开', 'Open'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 可复用的文件选择面板内容（不含对话框外壳），供工具栏二级面板嵌入使用。
class _PathChooserContent extends StatelessWidget {
  const _PathChooserContent({
    required this.directory,
    required this.entries,
    required this.nameController,
    required this.error,
    required this.save,
    this.directoryMode = false,
    this.showValidation = false,
    this.width = 460,
    this.height = 360,
    required this.onEnter,
    required this.onOpen,
    required this.onConfirm,
  });

  final Directory directory;
  final List<FileSystemEntity> entries;
  final TextEditingController nameController;
  final String? error;
  final bool save;
  final bool directoryMode;

  /// 目录校验模式：在底部按钮上方展示校验失败的红字提示（列表非空时也能看到）。
  final bool showValidation;
  final double width;
  final double height;
  final void Function(Directory) onEnter;
  final void Function(FileSystemEntity) onOpen;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: width,
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              IconButton(
                icon: const Icon(Icons.arrow_upward),
                tooltip: L.pick(context, '上级目录', 'Parent folder'),
                onPressed: () {
                  final parent = directory.parent;
                  if (parent.path != directory.path) onEnter(parent);
                },
              ),
              Expanded(
                child: Text(
                  directory.path,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: theme.dividerColor),
                borderRadius: BorderRadius.circular(8),
              ),
              child: entries.isEmpty
                  ? Center(
                      child: Text(
                        error ?? L.pick(context, '空目录', 'Empty folder'),
                        style: theme.textTheme.bodySmall,
                      ),
                    )
                  : ListView.builder(
                      itemCount: entries.length,
                      itemBuilder: (BuildContext context, int index) {
                        final entity = entries[index];
                        final isDirectory = entity is Directory;
                        final name = _basename(entity.path);
                        return GestureDetector(
                          onDoubleTap: isDirectory ? null : onConfirm,
                          child: ListTile(
                            dense: true,
                            leading: Icon(
                              isDirectory ? Icons.folder : Icons.image_outlined,
                            ),
                            title: Text(name),
                            onTap: () => onOpen(entity),
                            selected:
                                !isDirectory &&
                                name == nameController.text.trim(),
                          ),
                        );
                      },
                    ),
            ),
          ),
          const SizedBox(height: 12),
          if (directoryMode) ...<Widget>[
            if (showValidation && error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  error!,
                  style: const TextStyle(
                    color: Color(0xFFFF6B6B),
                    fontSize: 12,
                  ),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    L.pick(
                      context,
                      '进入含 det/rec .onnx 的目录后选择',
                      'Enter the folder with det/rec .onnx files, then choose',
                    ),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                FilledButton(
                  onPressed: onConfirm,
                  child: Text(L.pick(context, '选择此文件夹', 'Choose folder')),
                ),
              ],
            ),
          ] else
            TextField(
              controller: nameController,
              decoration: InputDecoration(
                labelText: L.pick(context, '文件名', 'File name'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (_) => onConfirm(),
            ),
        ],
      ),
    );
  }
}

/// 可嵌入工具栏二级面板的文件选择器，使用回调代替 Navigator.pop。
class PathChooserPanel extends StatefulWidget {
  const PathChooserPanel({
    super.key,
    required this.title,
    required this.save,
    required this.initialDirectory,
    required this.initialFileName,
    required this.patterns,
    required this.onSelected,
    required this.onCancel,
    this.directoryMode = false,
    this.requiresOcrModels = false,
    this.width = 460,
    this.height = 360,
  });

  final String title;
  final bool save;
  final String initialDirectory;
  final String initialFileName;
  final List<String> patterns;
  final void Function(String path) onSelected;
  final VoidCallback onCancel;

  /// 目录选择模式：只显示/进入文件夹，确认返回当前目录本身（选本地模型目录用）。
  final bool directoryMode;

  /// 本地 OCR 模型目录模式：在目录模式基础上，额外列出目录里的 .onnx 文件，
  /// 点「选择此文件夹」时校验必须同时存在 det 和 rec 两个 .onnx，缺失则报红、
  /// 不放行——选错目录当场就能发现，不用等识别时才回退到内置模型。
  final bool requiresOcrModels;
  final double width;
  final double height;

  @override
  State<PathChooserPanel> createState() => _PathChooserPanelState();
}

class _PathChooserPanelState extends State<PathChooserPanel> {
  late Directory _directory;
  late final TextEditingController _nameController;
  List<FileSystemEntity> _entries = const <FileSystemEntity>[];
  String? _error;

  @override
  void initState() {
    super.initState();
    _directory = Directory(widget.initialDirectory);
    _nameController = TextEditingController(text: widget.initialFileName);
    _refresh();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  /// 目录模式（含 OCR 模型目录）：只能选文件夹本身，文件条目仅供查看。
  bool get _dirMode => widget.directoryMode || widget.requiresOcrModels;

  bool _matches(FileSystemEntity entity) {
    if (entity is Directory) return true;
    // OCR 模型目录：把 .onnx 列出来，方便确认这个目录到底有没有模型文件。
    if (widget.requiresOcrModels) {
      return entity.path.toLowerCase().endsWith('.onnx');
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

  void _open(FileSystemEntity entity) {
    if (entity is Directory) {
      _enter(entity);
      return;
    }
    // 目录/模型模式下文件不可点选（只是展示），只有普通文件对话框才回填文件名。
    if (_dirMode) return;
    setState(() => _nameController.text = entity.uri.pathSegments.last);
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

  void _confirm() {
    if (_dirMode) {
      if (widget.requiresOcrModels) {
        final error = _validateOcrDir();
        if (error != null) {
          setState(() => _error = error);
          return;
        }
      }
      widget.onSelected(_directory.path);
      return;
    }
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    widget.onSelected('${_directory.path}/$name');
  }

  @override
  Widget build(BuildContext context) {
    return _PathChooserContent(
      directory: _directory,
      entries: _entries,
      nameController: _nameController,
      error: _error,
      save: widget.save,
      directoryMode: _dirMode,
      showValidation: widget.requiresOcrModels,
      width: widget.width,
      height: widget.height,
      onEnter: _enter,
      onOpen: _open,
      onConfirm: _confirm,
    );
  }
}
