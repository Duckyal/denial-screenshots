# denial-screenshots

QQ 风格截图标注工具，按 [denial-plugins](https://github.com/denialwm/denial-plugins)
规范实现为 denial 插件。

[English](README.en.md) | 简体中文

> 想把它搬到别的桌面？见 [docs/PORTING.md](docs/PORTING.md)：多桌面适配计划（暂缓实施）。

## 这是什么

捕获、区域选择、写 PNG、发布剪贴板全部由合成器 `deniald` 完成；
本插件只负责「读取最新截图 → 在 shell 内标注 → 保存 / 复制 / 置顶」。

```
[合成器 deniald]
  screencopy → ~/Pictures/Screenshots/Screenshot-{秒}-{毫秒}.png → 剪贴板
        │
        ▼
[插件 plugins/denialscreenshot]
  ShellAction  denialscreenshot.capture      截图并标注
  ShellAction  denialscreenshot.editLatest   编辑最新截图
  ShellSurface denialscreenshot.editor       全屏标注编辑器
  ShellSurface denialscreenshot.pin          置顶快照浮窗
```

四个贡献点的 provider 名都是 `Screenshot Tool`，在
**Settings → Shortcuts → Denial actions** 里能找到。

## 功能

| 分类 | 说明 |
|---|---|
| 标注工具 | 选择、画笔、直线、箭头、矩形、圆、文字、马赛克、橡皮 |
| 图形编辑 | 撤销 / 重做、选中已有图形后改颜色与粗细、删除选中；光标模式下**双击文字可就地修改**（清空即删除） |
| 工具栏 | 可停靠 `auto` / `left` / `right` / `top` / `bottom`；`Tab` 收起或唤出 |
| 输出 | 保存 / 另存（文件选择器）、复制 PNG 到剪贴板；复制按钮会用图标和颜色反馈「复制中 / 已复制 / 失败」，默认复制成功后自动关闭编辑器（可在设置里关掉） |
| 置顶快照 | 标注结果变成可拖动的小卡片浮在桌面，可继续编辑或关闭 |
| OCR + 翻译 | 本地 RapidOCR + Argos sidecar，或 OpenAI 兼容 API；结果贴回原处 |
| 过程可见 | 识字与翻译都有浮层进度：识字显示「已用 Ns / 已找到 N 段」，翻译显示「已用 Ns · 模型名」，失败给出具体原因（超时、连不上、401/429/余额不足…） |
| 自动打开 | 监听截图目录，新截图落盘即自动打开编辑器 |
| 设置 | 快捷键、工具栏位置、复制后是否自动关闭、翻译后端与 API 全部可配置并持久化 |

设置文件：`~/.config/denial-screenshots/settings.json`。
截图目录可用环境变量 `DENIAL_SCREENSHOT_DIR` 覆盖（默认 `~/Pictures/Screenshots`）。

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
（例如把「截图并标注」绑到 `Ctrl+Alt+A`）。

### 若 activate 报 "No initial frame arrived within 20 seconds"

custom runtime 冷启动偶尔超过 20 秒硬超时。先把 AOT runtime 拉热再切换：

```sh
denialctl ui build
denialctl ui activate /home/wu/.local/state/denial/plugins/candidates/<CANDIDATE_ID>/bundle
```

重启后插件"消失"（UI 回落到 packaged）也是同一套动作即可恢复，无需重新 build。

## 快捷键（默认，可在设置里改）

| 键 | 作用 |
|---|---|
| `V` `B` `L` `A` `R` `C` `T` `M` `E` | 选择 / 画笔 / 直线 / 箭头 / 矩形 / 圆 / 文字 / 马赛克 / 橡皮 |
| `Tab` | 收起 / 唤出工具栏 |
| `Space` | 快捷键面板 |
| `Ctrl+Z` / `Ctrl+R` | 撤销 / 重做 |
| `[` / `]` | 笔触粗细微调 |
| `Enter` | 保存 |
| `Delete` / `Backspace` | 删除选中图形 |
| `Esc` | 关闭编辑器 |

## 配置翻译 API

翻译有两条链路：**本地模型**（RapidOCR + Argos sidecar）和**在线 API**。用在线 API 时：

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

调用 API 时的行为：

- 建连 10s、响应 60s 超时；超时会明确提示，不会一直转圈。
- 429 / 5xx 自动退避重试 2 次（2s、4s），浮层会写「限流/服务忙，Ns 后重试」。
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

- **翻译前先要 OCR**（本地 sidecar）。首次使用会自动安装 `rapidocr-onnxruntime` 等依赖并下载模型，头一次可能要几分钟。想快一点就先手动装：
  `pip install rapidocr-onnxruntime ctranslate2 sentencepiece pillow -i https://pypi.tuna.tsinghua.edu.cn/simple`
- 配置保存在 `~/.config/denial-screenshots/settings.json`（`apiType` / `apiEndpoint` / `apiKey` / `apiModel` / `apiAppId`），改完重启编辑器生效。
- 翻译**不写日志**，成功或失败都只在编辑器底部的提示条里显示一次（失败信息含 HTTP 状态码和服务端原因）。
- 翻译过程中浮层会每秒刷新已用秒数与模型名；识字过程中刷新已用秒数与已识别段数，看得见在跑还是卡住了。

## 依赖

| 用途 | 依赖 | 说明 |
|---|---|---|
| 复制图片 | `wl-clipboard`（`sudo pacman -S wl-clipboard`） | 缺失时退回 `xclip`，两者都缺则复制失败并提示 |
| 本地翻译 | Python + `rapidocr-onnxruntime`、`ctranslate2`、`sentencepiece`、`PIL` | 首次使用会下载 OCR 模型与 Argos 语言包（走 HF 镜像） |
| API 翻译 | 任意 OpenAI 兼容端点 | 在设置里填 endpoint / key / model |

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
│   │   ├── clipboard.dart        # 剪贴板（wl-copy / xclip + 环境兜底）
│   │   ├── editor_surface.dart   # 编辑器 surface + 截图目录监听
│   │   ├── pin_surface.dart      # 置顶快照浮窗
│   │   ├── screenshot_store.dart # 最新截图读取
│   │   ├── editor_bus.dart       # 插件内部事件总线
│   │   └── editor/               # 编辑器 UI、命令栈、设置、翻译服务
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
| 复制没进剪贴板 | 看 `/tmp/denial-screenshot-clipboard.log`（会记录每次调用的退出码与 stderr）。常见原因是插件进程拿不到 `WAYLAND_DISPLAY`——代码已按 `$XDG_RUNTIME_DIR/wayland-N` 兜底 |
| `prepare` / `plan` 报 kit 校验失败 | build-kit 副本被手工改过（例如往 `denial_desktop` 注入代码）。不要直接改 `~/.local/state/denial/plugins/build-kits/` 下的文件，重新 `denial-plugins prepare` 即可 |
| 置顶浮窗挡住整个桌面 | 输入区只应包住卡片本身，见 `lib/src/pin_surface.dart` |
| 桌面样式变回官方默认 | plugin composition 用的是 build-kit 里的官方插件组合，不含本地 workspace（`dart_shell/lib/main.dart`）的定制。把需要的部分做成插件并加进 selection |

`README_COMPLETE.md`、`PLUGIN_RESTRUCTURE.md` 是重构前的历史文档，仅作参考。
