import 'dart:io';

import 'package:flutter/material.dart';

import 'panel_nav.dart';

/// 框选工具栏里的「保存」面板。
///
/// 参照 [SelectionSettingsPanel] 的浮层样式：宽 380、深色卡片、可滚动内容，
/// 直接嵌在选区浮层内，而不是拉起外部路径对话框。支持：
/// * 目录浏览（进入子目录 / 返回上级 / 回到主目录）；
/// * 手动输入文件名；
/// * 确认后由调用方把 PNG 写到该路径。
class SelectionSavePanel extends StatefulWidget {
  const SelectionSavePanel({
    super.key,
    required this.initialDirectory,
    required this.initialFileName,
    required this.onConfirm,
    required this.onClose,
    this.nav,
  });

  final String initialDirectory;
  final String initialFileName;
  final ValueChanged<String> onConfirm;
  final VoidCallback onClose;
  final SelectionPanelNav? nav;

  @override
  State<SelectionSavePanel> createState() => _SelectionSavePanelState();
}

class _SelectionSavePanelState extends State<SelectionSavePanel> {
  late String _directory = widget.initialDirectory;
  late final TextEditingController _nameController = TextEditingController(
    text: widget.initialFileName,
  );

  List<Directory> _subDirs = const [];
  String _error = '';

  @override
  void initState() {
    super.initState();
    _refresh();
    widget.nav?.canGoBack = () =>
        Directory(_directory).parent.path != _directory;
    widget.nav?.goBack = _up;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _refresh() {
    final dir = Directory(_directory);
    try {
      final entries = dir.listSync(followLinks: false);
      final dirs =
          entries
              .whereType<Directory>()
              .where((d) => !_basename(d.path).startsWith('.'))
              .toList()
            ..sort(
              (a, b) =>
                  _basename(a.path)
                      .toLowerCase()
                      .compareTo(_basename(b.path).toLowerCase()),
            );
      _subDirs = dirs;
      _error = '';
    } on Object catch (error) {
      _subDirs = const [];
      _error = '$error';
    }
  }

  static String _basename(String path) {
    final normalized = path.endsWith('/') && path.length > 1
        ? path.substring(0, path.length - 1)
        : path;
    final index = normalized.lastIndexOf('/');
    return index < 0 ? normalized : normalized.substring(index + 1);
  }

  void _enter(String path) {
    setState(() {
      _directory = path;
      _refresh();
    });
  }

  void _up() {
    final parent = Directory(_directory).parent.path;
    if (parent != _directory) _enter(parent);
  }

  void _home() {
    final home = Platform.environment['HOME'] ?? '/';
    _enter(home);
  }

  void _confirm() {
    var name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请输入文件名');
      return;
    }
    if (!name.toLowerCase().endsWith('.png')) name = '$name.png';
    final path = _directory.endsWith('/')
        ? '$_directory$name'
        : '$_directory/$name';
    widget.onConfirm(path);
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
                      '保存截图',
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
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
                child: TextField(
                  controller: _nameController,
                  style: const TextStyle(fontSize: 13, color: Colors.white),
                  decoration: InputDecoration(
                    labelText: '文件名',
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
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
                child: Row(
                  children: [
                    _iconButton(Icons.home, '主目录', _home),
                    const SizedBox(width: 6),
                    _iconButton(Icons.arrow_upward, '上级', _up),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _directory,
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
                  margin: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white24),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: _subDirs.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            _error.isEmpty ? '（没有子目录）' : _error,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.white54,
                            ),
                          ),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          itemCount: _subDirs.length,
                          itemBuilder: (context, index) {
                            final path = _subDirs[index].path;
                            return InkWell(
                              onTap: () => _enter(path),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                                child: Row(
                                  children: [
                                    const Icon(
                                      Icons.folder,
                                      size: 16,
                                      color: Colors.amberAccent,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        _basename(path),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 13),
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
              if (_error.isNotEmpty && _subDirs.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
                  child: Text(
                    _error,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.redAccent,
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: widget.onClose,
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(onPressed: _confirm, child: const Text('保存')),
                  ],
                ),
              ),
            ],
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
