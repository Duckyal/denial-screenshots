# Denial Screenshot Tool

嵌在 denial shell 进程里的截图全流程插件：框选截图（含智能选窗）、标注编辑、
滚动长截图、置顶贴图、本地 OCR + 翻译。

> 按 [denial-plugins](https://github.com/denialwm/denial-plugins) 规范实现的
> 纯 Dart 插件。**功能叙事、快捷键全表、翻译 API 配置与故障排查以仓库根的
> [README.md](../../README.md) 为准**，本页只留插件级事实，避免两处文档各自腐烂。

## 它做什么

| 环节 | 谁负责 |
|---|---|
| 区域选择 + 取图 | **本插件**：全屏压暗框选，`grim`（wlr-screencopy）截活画面 |
| 智能选窗 | **本插件**：悬停高亮窗口、单击整窗成区（合成器窗口快照 + geometry 命中） |
| 滚动长截图 | **本插件**：grim 连拍 + 探针静止沿触发 + 拼接器；滚动注入走 denial 虚拟键盘（可换 wtype / ydotool / 手动） |
| 标注编辑、绘图、PNG 编码 | **本插件**（`PictureRecorder` + `toByteData`），shell 场景内渲染 |
| 复制到剪贴板 | `wl-copy`（首选）/ `xclip`（XWayland）/ 复制文件路径文本（兜底） |
| 内置截图兼容路径 | 合成器 `deniald`：screencopy 写 `~/Pictures/Screenshots/Screenshot-{秒}-{毫秒}.png`，插件监听目录自动开编辑器 |

## 提供的贡献（3 action + 3 surface）

provider 名统一为 `Screenshot Tool`，在 Settings → Shortcuts → Denial actions
里绑按键（声明 action 不会自动占用按键）。

| 类型 | ID | 说明 |
|---|---|---|
| `ShellAction` | `denialscreenshot.capture` | 截图选区（推荐入口） |
| `ShellAction` | `denialscreenshot.longCapture` | 长截图（框选后自动滚动拼接） |
| `ShellAction` | `denialscreenshot.pinFromClipboard` | 钉住剪贴板内容（可叠多张） |
| `ShellSurface` | `denialscreenshot.capture` | 框选 / 选区工具栏平面（`aboveWindows` 层） |
| `ShellSurface` | `denialscreenshot.editor` | 全屏标注编辑平面 |
| `ShellSurface` | `denialscreenshot.pin` | 置顶快照浮窗平面 |

## 安装

在 Plugins 应用里 Add plugins → 粘贴**本仓库**（denial-screenshots）Git URL →
Find plugins → 选 `plugins/denialscreenshot` → Apply。CLI 等价：

```sh
denial-plugins --path plugins/denialscreenshot add <本仓库 Git URL>
denial-plugins plan
denial-plugins build CANDIDATE_ID
denial-plugins activate CANDIDATE_ID
```

本地开发目录：

```sh
cd plugins/denialscreenshot
denial-plugins --local add "$PWD"
denial-plugins plan
denial-plugins build CANDIDATE_ID
denial-plugins activate CANDIDATE_ID
```

保留 reference desktop 处于启用状态，它负责承载 `ShellSurface` 与 `ShellAction`。

## 编辑器

10 种工具（选择 / 画笔 / 直线 / 箭头 / 矩形 / 圆 / 文字 / 荧光笔 / 马赛克
[模糊或纯色] / 橡皮），撤销重做、就地编辑已绘图形、双击改文字、缩放平移、
OCR / 翻译贴回原处、保存 / 复制并关闭 / 置顶。快捷键默认值与全部细节见
[主 README](../../README.md)。

## 剪贴板

denial 的 Flutter 平台通道只接受 `text/plain`，图片需要 `wl-clipboard`
（提供 `wl-copy`）：

```sh
sudo pacman -S wl-clipboard    # Arch / CachyOS / Omarchy
```

没有 `wl-copy` 时退到 `xclip -t image/png`（XWayland），两者都没有时保存文件
并复制路径文本。每次调用的退出码与 stderr 记在
`/tmp/denial-screenshot-clipboard.log`。

## 结构

```
plugins/denialscreenshot/
├── pubspec.yaml                  # 插件清单（denial_plugin.provides: 3+3）
├── lib/denialscreenshot.dart     # @Plugin() 入口，声明全部 @Provides
└── lib/src/
    ├── selection_surface.dart    # 框选平面 + 选区工具栏（grim 取图）
    ├── window_pick.dart          # 智能选窗（窗口快照 + geometry 命中）
    ├── scroll_capture.dart       # 长截图连拍会话（探针静止沿触发）
    ├── scroll_stitch.dart        # 长图拼接器（描述子 + NCC）
    ├── editor_surface.dart       # 编辑器宿主（bridge、目录监听、生命周期）
    ├── pin_surface.dart          # 置顶快照浮窗（图 / 文字卡片）
    ├── clipboard.dart            # wl-copy / xclip + 环境兜底
    ├── exporter.dart             # 图片剪贴板封装与路径兜底
    ├── screenshot_store.dart     # 截图目录 / 最新文件读取
    ├── capture_flow_bus.dart     # action → 框选平面的总线
    ├── editor_bus.dart           # action ↔ 编辑器的事件总线
    ├── l10n.dart                 # 中英双语取值器
    ├── selection_*_panel.dart    # 框选阶段的设置 / 保存面板
    └── editor/                   # 编辑器 UI（7.4k 行）、命令栈、绘制、
                                  # 设置、文件面板、翻译服务、sidecar 源码
```

开发步骤见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。
