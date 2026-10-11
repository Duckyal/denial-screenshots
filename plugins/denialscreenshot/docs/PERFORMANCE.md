# 长截图性能审查

记录时间：2026-10-11（对应提交 `a4f0fda`）。

范围：`scroll_stitch.dart`（拼接算法核）、`scroll_capture.dart`（采集/编解码/
预览）、`pin_surface.dart`（提示浮层）以及设置面板。按收益/风险排序。

## 高优先级

### 1. `_findOffset` 全范围线性扫（`scroll_stitch.dart`）
- 每一档偏移都对整个重叠窗口重算一遍 NCC（`_overlapCost`），最坏
  `O(maxOff × overlapRows × descriptorWidth)`，`maxOff≈帧高`、
  `descriptorWidth=24`。命中页时靠 `sharpCost` 提前收工，但**页面花、无强
  匹配**时会扫满，是单帧最大 CPU 开销。
- 建议：粗到细。先按步长（如 4px）扫一遍定位谷底，再在 `best±4` 精扫；
  或对偏移做滑动增量更新——相邻偏移的重叠窗口只差首尾各一行，可以把
  `sumA/sumB/sumAA/sumBB/sumAB/count` 增量维护，把每个偏移降到 `O(dw)`。
  预计在难例上 4~10×。
- 注意固定带/软裁剪的行过滤（`_usableRow`）会破坏简单增量，需要按行维护
  可用性或在粗扫阶段忽略软裁剪、只在精扫阶段过滤。

### 2. `grim` 每帧落盘再读回（`scroll_capture.dart` `_captureFrame`/`_decodeRgba`）
- 现在每帧：`grim … -t png <tmpfile>` 写盘 → `readAsBytes` 读回 → PNG 解码
  成 RGBA。等于每帧多一次磁盘写+读，5~7fps 下持续抖动。
- 建议：`grim -` 直接输出到 stdout，从 `Process.stdout` 收字节在内存里解码
  （省掉临时文件）；或至少复用同一路径/句柄。
- `Process.start('grim', …)` 每帧 fork 一个进程，属固有成本；若合成器提供
  常驻抓帧接口可替换（设计项）。

### 3. 预览每帧全图重采样（`scroll_capture.dart` `_refreshPreview`/`_downscale`）
- 每追加一帧就把**整张长图**重新最近邻缩放到 ≤240×680 并新建一个
  `ui.Image`。画布越长，读的源缓冲越大（缓存不友好），且 `ImmutableBuffer`
  + codec 每帧分配。
- 建议：增量更新缩略图——只对新增的底部若干行做缩放并画进已有缩略图；
  或按时间/帧数节流（如 ≥300ms 或每 N 帧刷新一次）。

## 中优先级

### 4. `_findPlacement` 全画布扫（`scroll_stitch.dart`）
- 相邻匹配失败时对整个长图按 `knownCoarse=8` 扫一遍再精化，长画布上是第二
  大开销。
- 建议：用行描述子先做候选预筛选（例如取帧顶部若干行的描述子做哈希/最近
  邻），只在少量候选附近精扫，替代全画布线性扫。

### 5. 画布扩容时整体拷贝（`_ensurePixelCapacity`/`_ensureSigCapacity`）
- 容量翻倍虽然摊还 O(1)，但接近 `maxCanvasHeight=30000` 时单次拷贝可达
  几十 MB（480 宽 ×30000 行 ×4B ≈ 55MB），造成一次性延迟尖峰。
- 建议：按 `区域高 × 预期帧数` 预估预留，或让增长因子更大/预留上限；也可
  在内存吃紧时用分块（chunked）存储避免整块搬迁。

### 6. `_rowSigs` 每帧分配 + `_blankFrame` 全表扫
- `_rowSigs` 每帧新建 `Float32List(height×24)`；`_blankFrame` 在每次
  noMatch 时遍历整个描述子数组。
- 建议：复用固定尺寸 scratch 缓冲；`_blankFrame` 一旦跨度超过 `blankSpan`
  立即返回。

## 低优先级 / 清理项

- `pin_surface.dart` `_ScrollRegionMark`：`captured` 与 `preview` 两层
  `ValueListenableBuilder` 嵌套，每帧重建边框/浮层两次；合成一层即可。
- `pin_surface.dart` 钉住 host：整个 `Stack`（含长截图浮层）随
  `PinCardBus.cards` 变化重建；把长截图浮层移出该 builder 可避免卡片增删时
  连带重建。
- `selection_settings_panel.dart` `_refreshTools`：每次打开面板/切换注入方式
  都 `Process.run('which')` 两次；可缓存结果。
- `screenshot_tool.dart`：`_lastCanvasViewport = viewport` 在 LayoutBuilder
  构建期赋值（不触发重建，安全），但建议只在尺寸变化时赋值，减少无谓写入。

## 已做对的地方

- `push` 里对静止帧用 `_identicalSigs` 提前返回，避免无谓匹配。
- 描边/浮层画在采样矩形**外侧**，既可见又不进帧（无额外像素处理成本）。
- 指针抹除 `eraseRegionInPlace` 只处理小矩形，逐行 `setRange`，开销可忽略。
- 长图结果用 `Uint8List.sublistView` 零拷贝交给编码器。
