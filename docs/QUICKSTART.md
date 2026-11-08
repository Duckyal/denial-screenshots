# 快速开始指南

> 更新时间：2026-11-03。对齐插件架构（denialscreenshot 为纯 Dart 插件，
> 无 Rust / FFI / 独立 Flutter app 依赖）。

## 前提条件

- Denial 桌面（deniald）运行中，暴露 wlr-screencopy（默认有）
- 系统里有 `grim`（区域抓图）；`wl-copy` / `xclip` 任一（剪贴板复制）
- 本地 OCR / 离线翻译为可选能力：需要时再按主 README「配置翻译 API」一节
  准备模型目录或在线 API

## 安装

### 通过 Denial 的 Plugins 应用

运行 **Plugins** → 「添加插件」→ 粘贴仓库链接 → 「搜索插件」。

### 通过 denial-plugins CLI

```sh
denial-plugins --path plugins/denialscreenshot add <本仓库 Git URL>
denial-plugins plan
denial-plugins build <CANDIDATE_ID>
denial-plugins activate <CANDIDATE_ID>
```

### 本地开发（改一行看一行）

```sh
cd plugins/denialscreenshot
denial-plugins --local add "$PWD"
denial-plugins plan && denial-plugins build <ID> && denial-plugins activate <ID>
```

绑定快捷键：**Settings → Shortcuts → Denial actions → Screenshot Tool**
（例如「截图选区-推荐入口」→ `Ctrl+Alt+A`，「钉住剪贴板内容」→ `Super+S`）。

## 使用

1. 按绑定的截图键 → 框选区域（悬停窗口单击整窗选中，智能选窗）
2. 编辑器工具栏：光标 / 画笔 / 直线 / 箭头 / 矩形 / 椭圆 / 荧光笔 / 蒙版 /
   文字 / 橡皮，另有打开 / 保存 / 置顶 / 更多功能 / 设置
3. 文字工具：拖框 = 多行文本框（自动缩字号），单击 = 自由单行；双击已有
   文字就地改（PPT 式所见即所得），`Ctrl+Enter` 或点画布提交，`Esc` 取消
4. 光标模式在识别出的文字上拖拽选字，`Ctrl`+拖拽多选，`Ctrl+C` 按序复制
5. 完成后：`Enter` 保存、`Ctrl+C` 复制并关闭、置顶按钮钉成悬浮卡片
6. 长截图：`Super+R`（或工具栏触发），滚动页面自动拼接，再按一次结束
7. 更多功能（置顶旁）：拼图工作台——勾选多张（可跨目录）进框架工作台，拖框/调框/双击放大调取景，保存按包围盒出图；拆图工作台——设行列数确定后画面均分成不重叠方格，逐格调好后保存按「文件名+序号」导出 N 张（拼回即原图）

完整快捷键表见 [README.md](../README.md)「编辑器快捷键」一节。

## 故障排查（速查）

| 现象 | 处理 |
|---|---|
| `activate` 报 "No initial frame arrived within 20 seconds" | **先确认屏幕是亮的**（DPMS 熄屏时合成器无帧可等，必然超时并回落 packaged shell）；唤醒后重试。冷启动确实慢时先 `denialctl ui build` 拉热 AOT 再切 |
| 框选后截不到图 | 确认系统里有 `grim`，且合成器暴露 wlr-screencopy |
| 复制没进剪贴板 | 看 `/tmp/denial-screenshot-clipboard.log`；插件进程缺 `WAYLAND_DISPLAY` 时代码已兜底 |
| 长截图拼不上 / 不翻页 | 换翻页键（`Space`）、换注入通道（`wtype`/`ydotool`）或手动滚动 |
| 桌面样式变回官方默认 | plugin composition 回落了 packaged shell；重新 `activate` 本地 bundle |

更多见 [README.md](../README.md)「故障排查」与 [DEVELOPMENT.md](DEVELOPMENT.md)。

## 独立开发模式（可选）

`compositor/src/dart_shell/screenshot_tool/` 仍可作为独立 Linux app 跑，
用来快速调编辑器交互（不参与插件构建、不触发系统截图）：

```sh
./run_standalone.sh              # 编译并启动
BUILD_ONLY=1 ./run_standalone.sh # 只构建
```

## 下一步

- 开发流程与代码结构：[DEVELOPMENT.md](DEVELOPMENT.md)
- 功能清单：[FEATURES.md](FEATURES.md)
- 后续计划：[ROADMAP.md](ROADMAP.md)
