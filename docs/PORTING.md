# 多桌面适配计划

> 状态：**设计稿，暂缓实施**。等仓库有实际需求（issue / star / 有人要在别的桌面用）再开工。
> 本文只记录结论与方案，不含代码改动。最后更新：2026-10-03。

## 0. 一句话结论

**核心能共享（几乎零改动），窗口层不能一份代码通吃。**
推荐路线：**抽 `shot_editor_core` → 包装成独立 Flutter Linux 应用（一套二进制覆盖所有桌面）→ Denial 插件退化为调用 core 的薄壳。**
不建议去碰 Wayland `layer-shell`（需要改 Flutter 嵌入器，投入产出比极差）。

---

## 1. 现状：耦合度到底有多低

实测数据（2026-10-03）：

| 项 | 值 |
|---|---|
| 插件 Dart 总量 | 5742 行 |
| import `denial_flutter_sdk` 的文件 | **3 个**（`denialscreenshot.dart`、`src/editor_surface.dart`、`src/pin_surface.dart`） |
| import 总处数 | **5 处** |
| `editor/` 下（画布/工具/绘制/撤销/文字/OCR/翻译/设置） | **约 4400 行，零 Denial 依赖** |
| `editor/ffi.dart` | `start/save/switchTool/...` **全部是空操作** |

关键架构特征：

```
宿主截图 → PNG 落到 ~/Pictures/Screenshots → 编辑器监听目录 → 打开编辑
```

编辑器**不调用任何 Denial 截图 API**，只负责"读文件 + 画 + 落盘/复制"。
`ffi.dart` 里那些空操作是因为截屏、选区、保存全交给宿主了。

这意味着接缝已经天然存在：**别的桌面只要能把 PNG 写到某处、能拉起一个窗口，就能接上**。

---

## 2. 推荐架构

```
packages/shot_editor_core/      纯 Flutter，无任何桌面依赖（那 4400 行）
packages/shot_adapter/          接口：capture / surface / trigger / dialog
apps/shot_desktop/              独立应用 + CLI：--region | --fullscreen | --edit-latest
adapters/shot_denial/           Denial 插件（薄壳，只负责挂载 core）
```

`shot_desktop` 是主力（全桌面通用），Denial 插件变成可选前端。
Denial 上甚至可以不装插件，直接把快捷键绑到 App 二进制。

---

## 3. 能力矩阵

| 能力 | Denial（现状） | X11 | wlr（Hyprland/Sway/niri） | GNOME / KDE |
|---|---|---|---|---|
| 取图 | 内置 `captureRegion` 落盘 | `XGetImage` / `import` | `grim`（wlr-screencopy） | xdg-desktop-portal `Screenshot` |
| 显示 | `ShellSurfaceLayer.aboveWindows` + `ShellInputRegion` | 全屏无装饰窗口 | 全屏无装饰窗口（可选 layer-shell） | 全屏无装饰窗口 + keep-above |
| 触发 | `shortcuts.json` pluginAction | `XGrabKey` | 系统设置绑 CLI | 系统设置绑 CLI / portal GlobalShortcuts |
| 保存/打开 | shell 内置对话框 | GTK 原生对话框 | GTK / portal FileChooser | portal FileChooser |
| 剪贴板 | `wl-copy` / `xclip` | 同左（**已通用，不用改**） | 同左 | 同左 |

---

## 4. 两条路线对比

| | 路线 A：插件多适配器 | 路线 B：独立应用 |
|---|---|---|
| 窗口层 | 每个桌面一套 | **一套（GTK 全屏无装饰窗口）** |
| 迭代方式 | 改 → build → activate → 重登 → 重试（5–15 分钟/次，常失败） | **改 → 编译 → 直接跑**（1–2 分钟） |
| 选区 | Denial 的 `captureRegion` 白给 | **要自己写**（先截全屏 → App 内框选 → 编辑） |
| 分发 | 只有 Denial 能用 | AppImage / Flatpak / deb，谁都能装 |
| 置顶浮窗 | 真 layer | keep-above，可能被盖（降级但可用） |
| 自测可行性 | 依赖真机激活 | Xvfb 能跑通 X11 路径，可自动截图比对 |

---

## 5. 分阶段实施（每步可交付、可回退）

| 阶段 | 内容 | AI 产出 | 挂钟（含真机验证） |
|---|---|---|---|
| 0 | 抽 `shot_editor_core`，Denial 侧行为必须完全不变 | 0.5 天 | 0.5 天 |
| 1 | App 外壳 + CLI 启动流程 | 0.5 天 | 0.5 天 |
| 2 | 选区 UI（框选状态机，复用 `selectionRect` 逻辑） | 0.5–1 天 | 1 天 |
| 3 | 截图后端：X11 / portal / `grim` 兜底 | 1–1.5 天 | 1.5–2 天 |
| 4 | 窗口细节：多屏几何、缩放、keep-above | 0.5 天 | 1 天 |
| 5 | 打包（AppImage / Flatpak） | 0.5 天 | 0.5 天 |
| 可选 | Denial 插件改为 core 薄壳 | 0.5 天 | 1 天 |
| **合计** | | **2.5–4 天** | **3–5 天** |

只做一条线的话：**X11 半天**、**wlr 1–1.5 天**、加 GNOME/KDE 各 +1.5 天。

插件多适配器路线（路线 A）对应成本为 **3–5 天**，且慢在每次改动都要走一遍 build + activate + 重登。

---

## 6. 明确不做的事

- **Wayland `layer-shell` 真层**：Flutter Linux 官方嵌入器是 GTK，拿不到 `wl_surface`，做不了 `zwlr_layer_shell_v1`。要做就得改嵌入器，额外 +3~5 天且不可控。
- **全局抓键**：Wayland 下客户端不能全局抓键。统一走"用户在系统设置里把快捷键绑到可执行文件"，零代码且全通用。
- **往 build-kit 里 `denial_desktop` 打补丁**：会破坏 plugin manager 的 kit 校验（已踩过）。

---

## 7. 风险与取舍

| 风险 | 说明 | 缓解 |
|---|---|---|
| Wayland 截图权限 | GNOME 的 portal 会弹授权（可记住） | 提供 `grim` 兜底路径 |
| wlr 无 portal 实现 | Hyprland/Sway 多数没实现 portal Screenshot | 直接调 `grim`（wlr-screencopy 现成实现） |
| 选区阶段多一次交互 | App 必须先截全屏再框选 | 可接受，Flameshot / Ksnip 都是这个流程 |
| 多屏与缩放 | 截图与窗口坐标要对齐 | 用 GTK monitor 信息 + device pixel ratio |
| 覆盖层被遮挡 | 非 wlr 桌面 keep-above 可能被盖 | 降级可用；wlr 下可另开 layer-shell 作为增强 |
| 我（AI）看不到屏幕 | GUI 正确性只能靠人工反馈 | 先做自测基建（Xvfb + golden test），每轮反馈从 30 分钟缩到 5 分钟 |

---

## 8. 验收清单

- [ ] `shot-desktop --region` 在 X11 / wlr / GNOME 上都能拿到 PNG 并进入编辑
- [ ] 框选后进入编辑器，底图尺寸与显示器几何一致（多屏、缩放正确）
- [ ] 保存走系统文件对话框，复制进 `Super+V` 可见编辑后的图
- [ ] 置顶浮窗在各桌面上"基本可见"（允许被盖，但必须能关闭）
- [ ] 打包产物在干净机器上可直接运行（无需 Denial）

---

## 9. 什么时候值得开工

- 有人在 issue 里要求 GNOME / KDE / Hyprland 版本
- 或者 star / fork 出现明显增长（说明有非 Denial 用户在关注）
- 在此之前，Denial 插件照常用，代码保持现状
