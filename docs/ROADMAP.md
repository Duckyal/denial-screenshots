# 后续计划（Roadmap）

攒 feature 想法的地方。做完/废案归档时在对应条目下标注去向（提交号 / stash / 放弃原因）。

## 拼图与拆图

### 多图多形状拼图
- **一期已完成**（2026-11-03，feature/collage-split）：工具栏网格按钮 →
  `PathChooserPanel` 多选（跨目录、按勾选顺序）→ `editor/collage.dart`
  等比网格合成（单元格取最大宽高、contain 居中、12px 白底留白）→ 新画布。
- 二期候选：横排/竖排/自由摆放（拖拽+缩放定位）；留白背景色可选。

### 九宫格 / 四宫格拆分大图
- **做过又撤回**（2026-11-03）：均分版完整实现过（保存旁小面板：行列
  步进器 + 2×2/3×3 预设 + 边距；world 全分辨率重合成烙标注；
  `splitGrid` 均分导出 N 张），用户实测后决定撤回，代码已删。
- 若重做，先想清楚使用场景再动手；智能切分（按 OCR 行）同样未验证。

## 已尝试后回退的（stash 里有完整实现）

- **横向长截图**（`stash@{1}`）：影子双拼器定轴 + 转置复用匹配核。合成数据验证通过，
  真机翻车：每帧双管线 + 观察期整图重定位导致卡顿，预览小窗矮宽条不可读。
  重启的正确姿势：前几帧用探针位移方向**先探测再单跑**，不做双跑。
- **编辑器裁剪**（`stash@{0}`）：保留框内 / 删除条带（掐头去尾删中间段），undo 快照
  连带底图字节。功能本身可用，交互没打动用户。若重做，砍成"长截图会话内删段"
  单一场景，不做通用裁剪工具。

## 其他积压（等拍板）

- ~~`compositor/src/bin/deniald/` 孤儿 Rust 文件清理~~ **已完成**（2026-11-03，
  d7b168f：整 crate 从未构建、连 manifest 都解析不了，连同悬空 CMakeLists 删除）
- ~~`tools/*.sh` 遗留脚本去留~~ **已完成**（2026-11-03，a26e14d：钩子二脚本
  删除——插件架构后作废且实测未安装；`sync-overrides.sh` 保留——仍有效）
- ~~main 分支落后 dev 多个版本~~ **已完成**（c51459f：0.2.0 汇总单提交上 main）
- ~~`docs/*.md` 五份陈旧文档同步~~ **已完成**（2026-11-03：QUICKSTART /
  BUILD_GUIDE / DEVELOPMENT / FEATURES / PROJECT_SUMMARY 全部对齐插件架构，
  IMPLEMENTATION_COMPLETE 并入 PROJECT_SUMMARY 后删除；README 中英故障表
  补 "activate 报 No initial frame → 先确认屏幕亮"）
- wallpaper-engine 2 处 riverpod 修复未提交（另一个仓，等拍板）
