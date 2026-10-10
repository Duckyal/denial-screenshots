import 'package:flutter/material.dart';

/// 编辑器模态对话框的统一暗色外壳。
///
/// 外层 MaterialApp 用的是浅色主题，`AlertDialog` 默认渲染成白底，和暗色
/// 工具栏/设置面板摆在一起风格割裂。这里统一套暗色 Theme，并把底色/圆角
/// 对齐设置面板，保证各处弹窗观感一致。
Widget editorDialogTheme({required Widget child}) =>
    Theme(data: ThemeData.dark(useMaterial3: true), child: child);

/// 对话框底色：与设置面板同源的近黑半透明。
const Color editorDialogBackground = Color(0xE6000000);

/// 对话框圆角，与设置面板一致。
final RoundedRectangleBorder editorDialogShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.circular(12),
);
