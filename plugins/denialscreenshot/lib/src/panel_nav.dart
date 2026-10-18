/// 浮层面板的「上一级」导航桥。
///
/// selection 浮层的 ESC 阶梯先问它：面板内部还有可返回的上一级（展开的 API
/// 配置 / 模型列表、文件浏览器的上级目录）时，ESC 先在面板里返回，都到顶了
/// 才关整个面板。面板在自己的 State 里注册 [canGoBack] / [goBack]。
class SelectionPanelNav {
  bool Function()? canGoBack;
  void Function()? goBack;
}
