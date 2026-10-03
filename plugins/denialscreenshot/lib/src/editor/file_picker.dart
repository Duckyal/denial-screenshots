import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

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
      title: title.isEmpty ? (save ? '保存' : '打开') : title,
      save: save,
      initialDirectory: initial,
      initialFileName: filename,
      patterns: patterns,
    ),
  );
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
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 560,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                IconButton(
                  icon: const Icon(Icons.arrow_upward),
                  tooltip: '上级目录',
                  onPressed: () {
                    final parent = _directory.parent;
                    if (parent.path != _directory.path) _enter(parent);
                  },
                ),
                Expanded(
                  child: Text(
                    _directory.path,
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
                child: _entries.isEmpty
                    ? Center(
                        child: Text(_error ?? '空目录', style: theme.textTheme.bodySmall),
                      )
                    : ListView.builder(
                        itemCount: _entries.length,
                        itemBuilder: (BuildContext context, int index) {
                          final entity = _entries[index];
                          final isDirectory = entity is Directory;
                          final name = entity.uri.pathSegments.last;
                          return GestureDetector(
                            onDoubleTap: isDirectory ? null : _confirm,
                            child: ListTile(
                              dense: true,
                              leading: Icon(
                                isDirectory
                                    ? Icons.folder
                                    : Icons.image_outlined,
                              ),
                              title: Text(name),
                              onTap: () => _open(entity),
                              selected: !isDirectory &&
                                  name == _nameController.text.trim(),
                            ),
                          );
                        },
                      ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: '文件名',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (_) => _confirm(),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _confirm,
          child: Text(widget.save ? '保存' : '打开'),
        ),
      ],
    );
  }
}
