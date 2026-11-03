# Denial Screenshot Tool - 项目总结

> 更新时间：2026-11-03。原 `IMPLEMENTATION_COMPLETE.md`（"完成度 95%、FFI
> 待实现"的 2026-09 快照）内容已全部落地或作废，并入本文；功能明细以
> [FEATURES.md](FEATURES.md) 为准，操作以 [QUICKSTART.md](QUICKSTART.md) /
> [BUILD_GUIDE.md](BUILD_GUIDE.md) 为准。

## 项目概述

Denial（Wayland）桌面的 QQ/Snipaste 式截图插件：框选抓屏 → 标注编辑 →
识字翻译 → 长截图 → 拼图 → 保存/复制/置顶，全部在 shell 插件层完成，
**纯 Dart、无 Rust、无 FFI、无独立 Flutter app**。

## 形态与边界

- 插件包：`plugins/denialscreenshot/`（denial-plugins 集合格式）
- 捕获归插件（grim / wlr-screencopy）；deniald 自身截图走目录 watcher 兼容
- 贡献点：3 ShellSurface（框选/编辑器/置顶卡）+ 3 ShellAction（区域/整屏/钉剪贴板）
- `compositor/src/dart_shell/` 是重构前的独立 app 原型，与插件已分叉，仅保留
  快速调交互的用途

## 技术亮点

- **所见即所得文字引擎**：`layoutTextBlock` 单一排版实现贯穿草稿预览、
  提交渲染、命中测试；透明前景 EditableText 叠 LiveTextPainter，编辑中
  即最终效果；框内自动缩字号
- **NCC 滚动拼接**：多带 RGB 行描述子 + 零均值归一化互相关（对亮度/主题
  免疫），相邻预测→整图定位→重同步三级兜底，固定带学习排除吸顶栏，
  失配丢帧绝不盲贴；探针轮询（4px 带）替代定时连拍，只在停稳沿抓帧
- **世界坐标体系**：一切命令/选区/锚点存图像像素坐标，FittedBox 统一
  适配，"屏幕恒定大小"元素按显示缩放反算——保存、置顶、命中天然一致
- **位图缓存管线**：已提交命令光栅化成 annotationImage（队列串行、
  可被更新任务顶替），橡皮增量烘焙，拖动对象走重放——大图长史不卡帧
- **锚定浮层 UI**：工具栏停靠四边/贴边隐藏，选项行/调色板/字体/背景/
  提示/设置/文件面板全部锚定摆位互不遮挡，与 zenity 等外部弹窗零依赖

## 关键设计决策

| 决策 | 理由 |
|---|---|
| 插件内 FFI 通道降级为空操作占位 | 宿主已负责捕获/选区/落盘，编辑器只管绘制；保签名兼容让编辑器代码零改动 |
| 撤销栈只回滚命令不回滚底图 | 底图字节大且换图即新画布（打开/拼图清历史）；"改底图"类操作需要快照连带字节（裁剪设计见 ROADMAP 的 stash 归档） |
| 视觉验证由用户执行 | 仓库规则：agent 不截图不判渲染，构建绿 + analyze 绿后交人目检 |
| 双语内联 `L.pick` 而非 .arb | 对齐上游 denial_taskbar 的做法，跟随 shell locale |
| 长截图横向方案回退 | 双管线开销真实页面卡顿；正确姿势是先探测方向再单跑（ROADMAP 归档） |

## 版本脉络

- 0.1.0（2026-10-18）：双语、荧光笔、本地 OCR 多模型 + 在线视觉 OCR、
  离线翻译与模型目录、无光标抓帧、智能系统光标、滚动长截图
- 0.2.0（2026-11-01）：PPT 式实时文本编辑、文本背景色、OCR 文字多选、
  智能选窗、长截图探针重构、文件面板统一
- 下一轮候选：拼图自由摆放、test/ 目录（见 ROADMAP；拆图做过又撤回）
