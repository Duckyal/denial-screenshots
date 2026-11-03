# 开发文档

> 更新时间：2026-11-03。插件架构（denialscreenshot = 纯 Dart 插件包）。
> 旧的「Flutter app + Rust FFI + compositor 集成」章节随孤儿 crate 删除作废。

## 仓库结构

```
denial-screenshots/
├── plugins.yaml                      # denial-plugins 发现目录
├── plugins/denialscreenshot/         # ★ 可安装的 Dart 插件包（一切功能以这里为准）
│   ├── lib/denialscreenshot.dart     # 入口库：全部 @Provides 贡献类只放这里
│   └── lib/src/
│       ├── selection_surface.dart    # 框选层：grim 抓屏 + 智能选窗 + 结果窗
│       ├── editor_surface.dart       # 编辑器 surface（shell 里嵌编辑器 widget）
│       ├── editor/
│       │   ├── screenshot_tool.dart  # 编辑器主体（工具栏/画布/OCR/翻译/长截图入口）
│       │   ├── commands.dart         # DrawCommand + layoutTextBlock 共享排版
│       │   ├── painter.dart          # 静态层/预览层/选区层各 CustomPainter
│       │   ├── collage.dart          # 拼图/拆图纯合成逻辑
│       │   ├── file_picker.dart      # PathChooserPanel（打开/保存/目录/多选共用）
│       │   ├── settings.dart         # 插件设置 + 可自定义快捷键
│       │   ├── translate_service.dart# sidecar 调用（OCR/翻译流式事件）
│       │   └── ffi.dart              # 旧 FFI 通道的空操作占位（保签名兼容）
│       ├── scroll_capture.dart       # 长截图会话：探针轮询 + 连拍 + 预览
│       ├── scroll_stitch.dart        # 拼接纯算法（NCC 匹配/固定带/重同步）
│       ├── window_pick.dart          # 悬停高亮窗口枚举与命中
│       ├── pin_surface.dart          # 置顶悬浮卡片 surface
│       ├── clipboard.dart            # wl-copy / xclip 兜底
│       └── screenshot_store.dart     # 截图目录解析（DENIAL_SCREENSHOT_DIR 优先）
├── compositor/src/dart_shell/screenshot_tool/   # 遗留独立 app（仅 UI 原型）
├── tools/sync-overrides.sh           # build-kit runtime 路径刷新
└── run_standalone.sh                 # 独立 app 入口
```

## 插件贡献点

入口库 `lib/denialscreenshot.dart` 声明（composition 生成器只扫入口库）：

- `@Provides(ShellSurface)` × 3：框选层、编辑器、置顶卡片
- `@Provides(ShellAction)` × 3：区域截图、整屏截图、钉住剪贴板

规则：`@Provides` 永远只在入口库；只用 `denial_sdk` / `denial_flutter_sdk`
公开库，不 import 其他包的 `lib/src`；不做运行时扫描/反射/动态注册。

## 数据流（现行）

```
ShellAction 触发（快捷键绑定在 Settings → Shortcuts → Denial actions）
  ↓
selection_surface：grim -g 抓全屏 → 框选层画选区
  （悬停窗口 = window_pick 枚举 + 高亮，单击整窗成区）
  ↓
框定 → grim -g <rect> 抓区域 PNG → editor_surface 打开编辑器
  ↓
editor/screenshot_tool：DrawCommand 列表 + StaticDrawPainter 位图缓存
  ├─ OCR/翻译：translate_service → python sidecar（流式 region/done 事件）
  ├─ 长截图：scroll_capture 探针轮询 → scroll_stitch NCC 拼接
  ├─ 拼图/拆图：editor/collage 纯合成
  └─ 保存/复制/置顶：dart:io + clipboard.dart + pin_surface
```

编辑器内坐标约定：**世界坐标 = 图像像素坐标**。画布用
`FittedBox(fit: contain, clipBehavior: Clip.hardEdge)` 适配窗口，所有
命令/选区/锚点都存世界坐标，显示缩放只发生在 FittedBox 一层——需要
"屏幕恒定大小"的元素（缩放手柄、✕ 锚点）按 `_canvasDisplayScale` 反算
世界尺寸。

## 实时文本编辑的关键约束

- 排版唯一实现 = `commands.dart` 的 `layoutTextBlock`（框内自动缩字号）；
  草稿层（LiveTextPainter）与提交渲染（drawCommand）共用它，逐像素一致。
- 编辑器是透明前景的 `EditableText` 叠在草稿上（只贡献光标/选区/输入）。
- 提交门控：`onTapOutside` 的事件坐标必须"在画布内且不在任何 UI 浮层内"
  （工具栏悬浮在图像上方，纯画布判定会把点色板误判成提交）。
- 可变 children 的动态层（编辑层、OCR 选区层、背景层）一律上
  `GlobalKey`/`ValueKey`：兄弟插拔平移索引会重建 `EditableText` 丢焦点。

## 构建与验证

见 [BUILD_GUIDE.md](BUILD_GUIDE.md)。红线：`dart analyze --fatal-infos lib`
零告警；`dart format` 干净；`pubspec.lock` 不混入镜像 URL。

## 独立 app（compositor/src/dart_shell）

`./run_standalone.sh` 仍可跑，用于快速调编辑器交互。注意：它是**另一份
代码**，改动不会同步进插件；插件与它已分叉，以插件侧为准。

## 测试现状

- `scroll_stitch.dart` / `collage.dart` 是纯 Dart 无 Flutter 依赖，可直接
  写 dart test（当前仓库未建 test/ 目录，属待补项）。
- 其余验证靠插件构建 + 用户桌面目检（视觉验证由用户执行是仓库规则）。

## 不要做的事

- 不改 `~/.local/state/denial/plugins/build-kits/` 下的任何文件（kit 校验
  会整包拒绝）。
- 不往 deniald 加截图逻辑——捕获归插件（grim / wlr-screencopy），deniald
  自身的截图只作为兼容路径由目录 watcher 接管。
- 不在插件里做运行时反射/扫描；贡献类静态声明。
