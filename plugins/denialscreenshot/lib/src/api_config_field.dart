import 'package:flutter/material.dart';

/// API 配置里的一个文本框：自持 [TextEditingController]，只在外部值变化时同步。
///
/// 早先两处设置面板都是每次 build 现造 `TextEditingController(text: value)`，
/// 配合 onChanged→setState 的整页重建，EditableText 会在换 controller 时把刚
/// 输入的字符重新插入，表现为「敲一个字母出好几个」。controller 归 State 持有
/// 后，重建不再换 controller，输入恢复正常；点模型预设 chip 等外部回填仍生效。
class ApiConfigField extends StatefulWidget {
  const ApiConfigField({
    super.key,
    required this.label,
    required this.value,
    required this.hint,
    required this.onChanged,
    this.obscure = false,
    this.topPadding = 4,
  });

  final String label;
  final String value;
  final String hint;
  final ValueChanged<String> onChanged;
  final bool obscure;
  final double topPadding;

  @override
  State<ApiConfigField> createState() => _ApiConfigFieldState();
}

class _ApiConfigFieldState extends State<ApiConfigField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.value,
  );

  @override
  void didUpdateWidget(covariant ApiConfigField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 用户敲字时 onChanged 已把 widget.value 更新成 controller.text，二者相等
    // 不会覆盖光标；只有外部改动（如点模型预设 chip 回填）才需要同步进来。
    if (widget.value != _controller.text) {
      _controller.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: widget.topPadding),
      child: TextField(
        controller: _controller,
        obscureText: widget.obscure,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          labelText: widget.label,
          hintText: widget.hint,
          border: const OutlineInputBorder(),
        ),
        onChanged: widget.onChanged,
      ),
    );
  }
}
