# Denial Screenshot Tool

给 denial 桌面加一个 QQ 风格的截图标注编辑器。

> 已按 [denial-plugins](https://github.com/denialwm/denial-plugins) 规范重构为纯 Dart 插件。
> 捕获与保存由合成器完成，本插件只负责「读完截图 → 在 shell 内标注 → 保存/复制」。

## 它做什么

| 环节 | 谁负责 |
|---|---|
| screencopy、区域选择、写 PNG、发布剪贴板 | 合成器 `deniald`（存到 `~/Pictures/Screenshots/Screenshot-{秒}-{毫秒}.png`） |
| 触发截图 | 本插件的 action，走 `denialBridgeProvider.takeScreenshot()` |
| 标注编辑 | 本插件的 `ShellSurface`，在 shell 场景内渲染 |
| 绘图层、PNG 编码 | 本插件（`PictureRecorder` + `toByteData`） |
| 复制到剪贴板 | `wl-copy`（首选）/ `xclip`（XWayland）/ 复制文件路径（兜底） |

## 提供的贡献

| 类型 | ID | 说明 |
|---|---|---|
| `ShellAction` | `denialscreenshot.capture` | 启动合成器截图，捕获完成后自动打开标注编辑器 |
| `ShellAction` | `denialscreenshot.editLatest` | 直接编辑最新一张截图 |
| `ShellSurface` | `denialscreenshot.editor` | 全屏编辑平面（`aboveWindows` 层） |

## 安装

在 Plugins 里 Add plugin → 输入本仓库 Git URL → 选择 `plugins/denialscreenshot` → Apply。
CLI 等价形式：

```sh
denial-plugins --path plugins/denialscreenshot add https://github.com/denialwm/denial-plugins.git
denial-plugins submit apply
```

本地开发目录：

```sh
cd plugins/denialscreenshot
denial-plugins --local add "$PWD"
denial-plugins submit apply
```

保留 reference desktop 处于启用状态，它负责承载 `ShellSurface` 与 `ShellAction`。

## 绑定快捷键

声明 action **不会**自动占用快捷键。到
Settings → Shortcuts → Denial actions，给 `Screenshot Tool` 下的动作分配按键，
例如把 `Ctrl+Alt+A` 绑到「截图并标注」。

## 编辑器功能

- 7 种工具：画笔、箭头、矩形、圆形、文字、蒙版、橡皮
- 10 种颜色、1–20 px 粗细、20 步撤销/重做
- 保存（另存为 `Screenshot-{秒}-{毫秒}-edited.png`）、复制、取消
- 快捷键：`Enter` 保存、`Esc` 取消、`Ctrl+C` 复制、`Ctrl+Z` 撤销、`Ctrl+Shift+Z` 重做、
  `B/A/R/C/T/M/E` 切工具、`[` `]` 调粗细

## 剪贴板

denial 的 Flutter 平台通道只接受 `text/plain`，图片走合成器的
`ext/zwlr-data-control`，因此需要 `wl-clipboard`（提供 `wl-copy`）才能复制图片：

```sh
sudo pacman -S wl-clipboard    # Arch / CachyOS / Omarchy
```

没有 `wl-copy` 时会退到 `xclip -t image/png`（XWayland），两者都没有时保存文件并复制路径。

## 结构

```
plugins/denialscreenshot/
├── pubspec.yaml              # 插件清单（denial_plugin.provides）
├── lib/denialscreenshot.dart # @Plugin() 入口，声明全部 @Provides
└── lib/src/
    ├── editor_bus.dart       # action ↔ surface 的进程内总线
    ├── editor_surface.dart   # 编辑器宿主（bridge、文件监听、生命周期）
    ├── screenshot_store.dart # 截图目录 / 最新文件 / 保存
    ├── exporter.dart         # 剪贴板降级链
    └── editor/               # 纯 Flutter 编辑器（tools/painter/view）
```

开发步骤见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。
