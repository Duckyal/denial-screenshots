# denial-screenshots

QQ / Snipaste 风格的截图标注工具，按 [denial-plugins](https://github.com/denialwm/denial-plugins)
规范实现为 denial 插件，跑在 shell 进程内。

[English](README.en.md) | 简体中文

## 这是什么

插件自带一套框选截图：全屏压暗 → 拖拽选区（边/角可微调）→ 就地用
`grim`（wlr-screencopy）取图 → 弹工具栏（识字 / 翻译 / 长截屏 / 编辑 /
复制 / 保存 / 置顶）。**不经过合成器的选区流程**，也不依赖任何独立 app。

合成器 `deniald` 的内置截图链路仍然兼容：它 screencopy 后把 PNG 写到
`~/Pictures/Screenshots/Screenshot-{秒}-{毫秒}.png` 并发布剪贴板，插件监听
该目录，新图落盘即自动打开编辑器（框选流程进行中会自动挂起，避免误弹）。

```
[插件 plugins/denialscreenshot]
  框选截图（推荐）  全屏压暗选区 → grim 取图 → 选区工具栏
  长截图            框选区域 → 自动/手动滚动连拍 → 拼接成一张长图
  钉剪贴板          把剪贴板最近的图或文字钉成桌面悬浮卡（可叠多张）
  标注编辑器        全屏编辑平面（含打开合成器/本地图片）
        ▲
        │ 目录监听（兼容）
[合成器 deniald]
  screencopy → ~/Pictures/Screenshots/Screenshot-{秒}-{毫秒}.png → 剪贴板
```

贡献点（provider 名统一为 `Screenshot Tool`，在
**Settings → Shortcuts → Denial actions** 里可绑按键）：

| 类型 | ID | 说明 |
|---|---|---|
| `ShellAction` | `denialscreenshot.capture` | 截图选区（推荐入口） |
| `ShellAction` | `denialscreenshot.longCapture` | 长截图（框选后自动滚动拼接） |
| `ShellAction` | `denialscreenshot.pinFromClipboard` | 钉住剪贴板内容（可叠加多张） |
| `ShellSurface` | `denialscreenshot.capture` | 框选 / 选区工具栏平面 |
| `ShellSurface` | `denialscreenshot.editor` | 全屏标注编辑器平面 |
| `ShellSurface` | `denialscreenshot.pin` | 置顶快照浮窗平面 |

## 功能

| 分类 | 说明 |
|---|---|
| 截图取图 | 全屏压暗框选 + 边/角微调；`grim`（wlr-screencopy）截活画面；兼容合成器截图目录 |
| 标注工具 | 选择、画笔、直线、箭头、矩形、圆、文字、**荧光笔**、马赛克（模糊 / 纯色两种）、橡皮 |
| 图形编辑 | 撤销 / 重做、选中已有图形后改颜色与粗细、删除选中；光标模式下**双击文字可就地修改**（清空即删除）；`Alt+滚轮`缩放画布、方向键平移视角 |
| 选区工具栏 | 识字 / 翻译 / 长截屏 / 编辑 / 复制 / 保存 / 置顶 / 设置，框选完就地处理 |
| 长截图 | 框选滚动区域后自动连拍拼接；滚动注入默认为 denial 虚拟键盘，可切 `wtype` / `ydotool` 或手动滚动，翻页键（Down / Space）与速度可在设置里改；右上角有实时缩略图小窗 |
| 输出 | 保存 / 另存 / 打开图片（文件面板）、`Enter` 保存；「复制」按钮合并复制并关闭，用图标和颜色反馈「复制中 / 已复制 / 失败」；`Esc` 只关窗不覆盖剪贴板；图片剪贴板不可用时兜底复制文件路径文本 |
| 置顶快照 | 标注结果或剪贴板内容变成可拖动小卡片浮在桌面，边缘/角落**锁比例缩放**，双击回编辑器继续画，文字卡可就地选字复制 |
| OCR | 本地 RapidOCR（PP-OCRv3 自带零下载；v4/v5/v6 可下载；统一包内置多语言；也可自选本地模型目录），**或在线视觉大模型**（可复用翻译 API 的地址/密钥，单独填模型名） |
| 翻译 | **本地离线**（Argos 逐语对 / M2M-100 二选一）或在线 API（OpenAI 兼容 / 百度 / DeepL / LibreTranslate）；译文按原图位置贴回，蒙版可模糊或纯色，文字颜色可提取原色或固定 |
| 过程可见 | 识字与翻译都有浮层进度：识字显示「已用 Ns / 已找到 N 段」，翻译显示「已用 Ns · 模型名」，失败给出具体原因（超时、连不上、401/429/余额不足…） |
| 设置 | 工具栏停靠位置、翻译后端与 API、OCR 模型、长截图滚动方式、蒙版颜色等全部持久化；中英双语界面跟随系统语言 |

设置文件：`~/.config/denial-screenshots/settings.json`。
截图目录可用环境变量 `DENIAL_SCREENSHOT_DIR` 覆盖（默认 `~/Pictures/Screenshots`）。
本地 OCR / 翻译模型下载目录：`~/.local/share/denial-screenshots/models`。

## 与同类工具对比

和常见的截图标注工具相比（✔ 支持 / ✘ 不支持 / — 视版本而定）：

| 维度 | denial-screenshots | mark-shot | QQ 截图 |
|---|---|---|---|
| 形态 | Denial shell **进程内插件**，无独立窗口 | 独立应用 | 随 QQ 客户端 |
| 平台 | Denial（Wayland / wlr-screencopy） | Linux（Wayland + X11）/ Windows | Windows（Linux 版功能受限） |
| 开源 | ✔ 开源 | ✔ 开源 | ✘ 闭源 |
| 标注工具 | 选择 / 画笔 / 直线 / 箭头 / 矩形 / 圆 / 文字 / 荧光笔 / 马赛克 / 橡皮 | 类似，另有激光笔、放大镜、反色矩形、步骤序号等 | 基础标注（矩形 / 箭头 / 文字 / 马赛克等） |
| 就地编辑已绘图形 | ✔ 选中改色与粗细、双击改文字 | — | — |
| 置顶贴图 | ✔ 图 + 文字，可叠多张、锁比例缩放 | ✔ | ✔ |
| 长截图 / 滚动拼接 | ✔ denial 虚拟键盘自动滚动注入 | ✔ portal 录制式 | ✔ |
| 文字识别 OCR | ✔ **本地离线多模型** + 在线视觉模型 | ✔ | ✔（联网） |
| 翻译 | ✔ **本地离线**（Argos / M2M）+ 4 种在线协议 | ✔ 仅在线（OpenAI / Gemini / Claude / 腾讯 / 百度 / 有道） | ✔（联网、腾讯） |
| 录屏 GIF/视频 | ✘ | ✔ | ✘ |
| 图床上传 / 扫码 | ✘ | ✔ | — |
| 完全离线可用 | ✔ | 部分（Linux 截屏链路外） | ✘ 需登录 QQ |
| 取字 / 翻译进度可见 | ✔ 浮层实时显示耗时与原因 | — | — |
| 界面多语言 | ✔ 中 / 英 | — | — |

差异点主要是三处：**嵌进合成器的插件形态**（不是又开一个 app）、
**本地离线的 OCR + 翻译**（不联网也能取字翻译，进度可见），以及
**就地编辑已绘图形 + 中英双语界面**。

## 安装

### 通过 Denial 的 Plugins 应用安装

- 运行 **Plugins** 应用
- 点击右上角「添加插件 / Add plugins」按钮
- 复制粘贴本仓库链接
- 点击「搜索插件 / Find plugins」按钮

### 通过 denial-plugins CLI

```sh
denial-plugins --path plugins/denialscreenshot add <本仓库 Git URL>
denial-plugins plan
denial-plugins build CANDIDATE_ID
denial-plugins activate CANDIDATE_ID
```

### 本地开发

```sh
cd plugins/denialscreenshot
denial-plugins --local add "$PWD"
denial-plugins plan
denial-plugins build CANDIDATE_ID
denial-plugins activate CANDIDATE_ID
```

声明 action 不会自动占用按键，装好后到
**Settings → Shortcuts → Denial actions** → `Screenshot Tool` 绑定快捷键
（例如把「截图选区-推荐入口」绑到 `Ctrl+Alt+A`，「钉住剪贴板内容」绑到 `Super+S`）。

### 若 activate 报 "No initial frame arrived within 20 seconds"

custom runtime 冷启动偶尔超过 20 秒硬超时。先把 AOT runtime 拉热再切换：

```sh
denialctl ui build
denialctl ui activate /home/wu/.local/state/denial/plugins/candidates/<CANDIDATE_ID>/bundle
```

重启后插件"消失"（UI 回落到 packaged）也是同一套动作即可恢复，无需重新 build。

## 编辑器快捷键（默认值，可改 settings.json 的 `shortcuts` 字段）

| 键 | 作用 |
|---|---|
| `V` `B` `L` `A` `R` `C` `T` `H` `M` `E` | 选择 / 画笔 / 直线 / 箭头 / 矩形 / 圆 / 文字 / 荧光笔 / 马赛克 / 橡皮 |
| `Tab` | 收起 / 唤出工具栏 |
| `Space` | 快捷键面板 |
| `Ctrl+Z` / `Ctrl+R` | 撤销 / 重做 |
| `Ctrl+C` | 复制并关闭（选中过 OCR 文字时改为复制所选文字） |
| `Super+R` | 长截图 |
| `Enter` | 保存（文件面板） |
| `Delete` / `Backspace` | 删除选中图形 |
| `[` / `]` | 笔触粗细微调 |
| `Alt+滚轮` | 缩放画布；放大后方向键平移视角 |
| `Esc` | 关闭编辑器（有选中时先取消选中；不写剪贴板） |

## 配置翻译 API

翻译有两条链路：**本地模型**（RapidOCR 识字 + Argos / M2M-100 离线翻译）和
**在线 API**。用在线 API 时：

1. 编辑器工具栏 → 齿轮「设置」→ 翻译接口选「在线翻译 API」。
2. 翻译协议选一个（默认 OpenAI 兼容）：

| 协议 | 要填的字段 | 说明 |
|---|---|---|
| OpenAI 兼容 | 地址 / 密钥 / 模型名 | DeepSeek、OpenAI、Moonshot、本地 Ollama 等都走这条；**模型名必填** |
| 百度翻译 | APP ID / 密钥 | 在 fanyi-api.baidu.com 免费申请 |
| DeepL | 密钥 | `…:fx` 结尾的是免费版 |
| LibreTranslate | 地址 / 密钥（可留空） | 自建或公共实例 |

3. 地址会自动补全：填 `https://api.deepseek.com` → 实际请求 `https://api.deepseek.com/v1/chat/completions`；地址已带版本段（`/v1`、智谱的 `/v4`…）就只补 `/chat/completions`；已经写全 `.../chat/completions` 则原样使用。
   例：智谱填 `https://open.bigmodel.cn/api/paas/v4`，模型点预设里的 `glm-4-flash`。
4. 模型名输入框下方有**预设 chips**（按地址猜厂商：智谱 / DeepSeek / 硅基流动 / Moonshot / 通义 / OpenAI），点一下即填，避免手抄错模型名。
5. 点「**测试连接**」——它会真的翻译一句 `Hello, world`，把译文（含耗时）或报错直接显示在按钮下方。**推荐先用它确认配置，不用先去截图。**

**识字也可以走在线**：OCR 模型选「在线视觉模型」后，识字复用 API 链路
（地址/密钥留空则回退到翻译 API 的对应值，只需单独填一个支持图片输入的
模型名，如 `glm-4v-flash`）。

调用 API 时的行为：

- 建连 10s、响应 60s 超时；超时会明确提示，不会一直转圈。
- 429 / 5xx 自动退避重试（2s、4s），浮层会写「限流/服务忙，Ns 后重试」；
  超时与断连同样重试。
- 失败提示带服务端给的原因，例如 `翻译失败（HTTP 429·请求太频繁或免费额度用尽）：您的账户已达到速率限制`。
- 智谱端点会自动关闭思考模式（`thinking: disabled`），否则 GLM-4.6/4.7 这类推理模型会把翻译拖到几十秒。

想先单独验证后端，可以用 curl：

```sh
curl https://api.deepseek.com/chat/completions \
  -H "Authorization: Bearer sk-你的key" \
  -H "Content-Type: application/json" \
  -d '{"model":"deepseek-chat","temperature":0,"messages":[{"role":"user","content":"1. hello"}]}'
```

注意事项：

- **翻译前先要 OCR**。用本地 OCR 时，首次使用会自动安装 `rapidocr`、
  `rapidocr-onnxruntime`、`ctranslate2`、`sentencepiece`、`pillow` 等依赖
  并下载模型（pip 优先走清华镜像，失败回退官方 PyPI），头一次可能要几分钟。
  想快一点就先手动装：
  `pip install rapidocr rapidocr-onnxruntime onnxruntime ctranslate2 sentencepiece pillow -i https://pypi.tuna.tsinghua.edu.cn/simple`
- 配置保存在 `~/.config/denial-screenshots/settings.json`
  （`apiType` / `apiEndpoint` / `apiKey` / `apiModel` / `apiAppId`，
  OCR 在线还有 `ocrApiEndpoint` / `ocrApiModel` / `ocrApiKey`），
  改完重启编辑器生效。
- 翻译**不写日志**，成功或失败都只在编辑器底部的提示条里显示一次（失败信息含 HTTP 状态码和服务端原因）。
- 翻译过程中浮层会每秒刷新已用秒数与模型名；识字过程中刷新已用秒数与已识别段数，看得见在跑还是卡住了。

## 依赖

| 用途 | 依赖 | 说明 |
|---|---|---|
| 框选 / 长截图取图 | `grim`（wlr-screencopy） | deniald 实现了 wlr-screencopy，grim 直接可用 |
| 复制图片 | `wl-clipboard`（`sudo pacman -S wl-clipboard`） | 缺失时退回 `xclip`，两者都缺则改为复制文件路径并提示 |
| 本地 OCR / 翻译 | Python + `rapidocr`、`rapidocr-onnxruntime`、`onnxruntime`、`ctranslate2`、`sentencepiece`、`PIL` | 首次使用会下载 OCR 模型与 Argos 语言包（走 HF 镜像） |
| 长截图自动滚动 | 默认 denial 虚拟键盘（零依赖） | 可切 `wtype` / `ydotool`（需自行安装），或改手动滚动 |
| API 翻译 / 在线 OCR | 任意 OpenAI 兼容端点等 | 在设置里填 endpoint / key / model |

sidecar 的 Python 源码已内嵌进插件（`lib/src/editor/sidecar_source.dart`），
不依赖打包资源。

## 目录

```
denial-screenshots/
├── plugins.yaml                  # 插件目录清单
├── plugins/denialscreenshot/     # 可独立选择的 Dart 插件包
│   ├── pubspec.yaml              # 插件清单（denial_plugin.provides）
│   ├── lib/denialscreenshot.dart # @Plugin() 入口 + @Provides 声明
│   ├── lib/src/
│   │   ├── selection_surface.dart    # 框选平面 + 选区工具栏（grim 取图）
│   │   ├── scroll_capture.dart       # 滚动连拍会话
│   │   ├── scroll_stitch.dart        # 长图拼接
│   │   ├── editor_surface.dart       # 编辑器 surface + 截图目录监听
│   │   ├── pin_surface.dart          # 置顶快照浮窗
│   │   ├── clipboard.dart            # wl-copy / xclip + 环境兜底
│   │   ├── exporter.dart             # 图片剪贴板封装与路径兜底
│   │   ├── screenshot_store.dart     # 截图目录 / 最新文件读取
│   │   ├── capture_flow_bus.dart     # action → 框选平面的进程内总线
│   │   ├── editor_bus.dart           # action ↔ 编辑器的事件总线
│   │   ├── l10n.dart                 # 中英双语
│   │   └── editor/                   # 编辑器 UI、命令栈、绘制、设置、
│   │                                 # 文件面板、翻译服务、sidecar 源码
│   └── docs/DEVELOPMENT.md       # 开发 / 验证步骤
├── compositor/src/dart_shell/    # 独立编辑器 app（UI 原型，不参与插件构建）
└── run_standalone.sh             # 独立 app 开发入口
```

## 独立开发模式

`compositor/src/dart_shell/screenshot_tool` 仍可作为独立 Linux app 跑，用来
调整编辑器交互；它不参与插件构建，也不触发系统截图。

```sh
./run_standalone.sh              # 编译并启动
BUILD_ONLY=1 ./run_standalone.sh
```

## 开发验证

每个 `plugins/PACKAGE_NAME/` 都是独立的 Dart package，Pub 与静态检查都在该
目录里跑（仓库根目录不是 Pub workspace）。

```sh
denial-plugins prepare
cd plugins/denialscreenshot
cp pubspec_overrides.yaml.example pubspec_overrides.yaml   # 把 /ABSOLUTE/RUNTIME 换成
                                                           # configuration.json 里的 runtime 路径
"$DENIAL_PLUGIN_FLUTTER" pub get
"$DENIAL_PLUGIN_DART" format --output=none --set-exit-if-changed lib
"$DENIAL_PLUGIN_DART" analyze --fatal-infos lib
```

## 故障排查

| 现象 | 处理 |
|---|---|
| 框选后截不到图 | 确认系统里有 `grim`，且合成器暴露 wlr-screencopy（deniald 默认有） |
| 复制没进剪贴板 | 看 `/tmp/denial-screenshot-clipboard.log`（会记录每次调用的退出码与 stderr）。常见原因是插件进程拿不到 `WAYLAND_DISPLAY`——代码已按 `$XDG_RUNTIME_DIR/wayland-N` 兜底 |
| 长截图拼不上 / 不翻页 | 目标应用可能不认注入键：在设置里把翻页键换成 `Space`、换注入通道（`wtype` / `ydotool`），或改手动滚动 |
| `prepare` / `plan` 报 kit 校验失败 | build-kit 副本被手工改过（例如往 `denial_desktop` 注入代码）。不要直接改 `~/.local/state/denial/plugins/build-kits/` 下的文件，重新 `denial-plugins prepare` 即可 |
| 置顶浮窗挡住整个桌面 | 输入区只应包住卡片本身，见 `lib/src/pin_surface.dart` |
| 桌面样式变回官方默认 | plugin composition 用的是 build-kit 里的官方插件组合，不含本地 workspace（`dart_shell/lib/main.dart`）的定制。把需要的部分做成插件并加进 selection |

`README_COMPLETE.md`、`PLUGIN_RESTRUCTURE.md` 是重构前的历史文档，仅作参考。
