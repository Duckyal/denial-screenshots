# 开发文档

## 独立 Flutter 编辑器

在 Denial shell 接口尚未开放时，可以直接运行编辑器 app 开发和验证 UI：

```bash
./run_standalone.sh
```

app 默认载入 demo 图；使用工具栏的“打开”载入本地图像，绘制后选择“保存”导出 PNG。打开/保存文件选择需要 `zenity`；“复制”通过 `wl-copy` 或 `xclip` 写入 Linux 图像剪贴板。用 `BUILD_ONLY=1 ./run_standalone.sh` 只构建 release bundle，不启动窗口。

独立 app 仅覆盖 Flutter 编辑器、绘制、导入和导出行为，不代表 Denial 系统截图已接通；真实桌面捕获和从选区转入编辑器仍依赖 compositor/shell 的可扩展接口。

## 架构设计

### 1. 整体架构

```
┌─────────────────────────────────────────────────────────┐
│                   用户交互层                            │
│  - 鼠标点击/拖动 (选区)                                  │
│  - 工具栏点击 (绘图)                                     │
│  - 颜色选择                                              │
└────────────────────┬────────────────────────────────────┘
                     ↓
┌─────────────────────────────────────────────────────────┐
│              Flutter UI 层                              │
│  - ScreenshotTool (主界面)                              │
│  - DrawPainter (绘图渲染)                                │
│  - 工具栏/颜色选择器                                      │
└────────────────────┬────────────────────────────────────┘
                     ↓
┌─────────────────────────────────────────────────────────┐
│              Rust Compositor 层                         │
│  - ScreenshotManager (截图管理)                          │
│  - ScreenshotTrigger (触发器)                            │
│  - ShortcutManager (快捷键)                              │
│  - ScreenshotEditPlugin (插件接口)                       │
└────────────────────┬────────────────────────────────────┘
                     ↓
┌─────────────────────────────────────────────────────────┐
│              Wayland 层                                  │
│  - Screencopy (截图协议)                                │
│  - DMA-BUF (共享内存)                                    │
│  - Layer-Surface (浮动窗口)                              │
└─────────────────────────────────────────────────────────┘
```

### 2. 数据流

#### 截图流程

```
1. 用户触发快捷键 Ctrl+Alt+A
   ↓
2. ScreenshotTrigger 接收事件
   ↓
3. ScreenshotManager 开始选区
   ↓
4. Wayland Screencopy 协议捕获屏幕
   ↓
5. 合成到临时 Atlas
   ↓
6. 生成缩略图发送到 Flutter UI
   ↓
7. Flutter UI 显示编辑界面
   ↓
8. 用户使用工具栏绘图
   ↓
9. 用户点击"保存"按钮
   ↓
10. ScreenshotManager 写入 PNG
    ↓
11. 复制到剪贴板
    ↓
12. 通知插件执行
    ↓
13. 截图完成
```

#### 绘图流程

```
1. 用户选择工具 (如画笔)
   ↓
2. 工具栏更新 UI 状态
   ↓
3. 用户在截图上拖动鼠标
   ↓
4. Flutter 记录绘图命令
   ↓
5. DrawPainter 实时渲染
   ↓
6. 用户点击"撤销/重做"
   ↓
7. DrawPainter 重新渲染历史
```

## 核心模块说明

### 1. Flutter UI (screenshot_tool)

#### ScreenshotTool

主界面组件，管理：
- 工具状态
- 颜色选择
- 粗细调节
- 撤销/重做历史
- UI 显示/隐藏

#### DrawPainter

自定义绘制器，负责：
- 渲染所有绘图命令
- 支持多种工具
- 实时更新

#### 工具实现

- **Brush**: Path 绘制
- **Arrow**: 自定义箭头绘制逻辑
- **Rect**: Canvas.drawRect
- **Circle**: Canvas.drawCircle
- **Text**: TextPainter
- **Mosaic**: 像素块采样
- **Eraser**: 透明绘制

### 2. Rust Compositor (deniald)

#### ScreenshotManager

截图流程管理：
- 等待输出刷新
- 合成到 Atlas
- 生成 PNG
- 复制到剪贴板
- 插件调用

#### ScreenshotTrigger

截图触发器：
- 监听快捷键
- 监听鼠标事件
- 管理选区
- 启动/取消/完成

#### ShortcutManager

快捷键管理：
- 快捷键映射
- 事件分发
- 动作执行

#### ScreenshotEditPlugin

插件接口：
- on_capture: 编辑像素
- on_save: 保存前处理
- on_complete: 完成后处理

## API 设计

### Flutter to Rust (FFI)

```rust
// Rust 端
#[no_mangle]
pub extern "C" fn screenshot_save(path: *const c_char) -> bool {
    let path = unsafe { CStr::from_ptr(path).to_str().unwrap() };
    // 保存逻辑
}

// Dart 端
extern "C"
double screenshotSave(String path) native "screenshot_save";
```

### Rust to Flutter

```rust
// Rust 端发送数据到 Flutter
self.display_handle.flush_clients()?;

// Flutter 端接收
// TODO: 实现 FFI 通信
```

## 性能优化

### 1. 渲染优化

- **离屏绘制**: 使用 Offscreen Canvas
- **图层合成**: 减少 Canvas 切换
- **批量绘制**: 合并相似命令

### 2. 内存优化

- **像素数据**: 按需加载
- **历史记录**: 限制步数 (20步)
- **图片缓存**: LRU 缓存

### 3. 交互优化

- **实时预览**: 绘图时立即渲染
- **轻量级更新**: 只重绘变化部分
- **延迟加载**: 大图片懒加载

## 测试策略

### 1. 单元测试

```rust
#[cfg(test)]
mod tests {
    #[test]
    fn test_shortcut_manager() {
        // 测试快捷键映射
    }

    #[test]
    fn test_plugin_metadata() {
        // 测试插件元数据
    }
}
```

### 2. 集成测试

```dart
testWidgets('Screenshot tool saves correctly', (tester) async {
  // 测试保存功能
});
```

### 3. UI 测试

```dart
testWidgets('Toolbar shows correct tools', (tester) async {
  // 测试工具栏显示
});
```

## 待实现功能

### 高优先级

1. **FFI 通信**: Flutter 与 Rust 通信
2. **实时选区**: 鼠标拖动时显示选区
3. **文字输入**: 弹出对话框输入文字
4. **保存功能**: 实现真正的保存逻辑

### 中优先级

5. **更多颜色**: 调色板
6. **笔刷预设**: 快速切换粗细
7. **透明度**: Alpha 通道支持
8. **撤销限制**: 可配置撤销步数

### 低优先级

9. **云存储**: 上传到云服务
10. **批量处理**: 批量截图
11. **快捷键自定义**: 用户自定义快捷键
12. **导出格式**: PDF, SVG 等

## 已知问题

1. **FFI 通信未实现**: Flutter 与 Rust 之间没有数据传输
2. **文字输入缺失**: 文字工具无法输入文字
3. **选区预览缺失**: 鼠标拖动时没有实时选区框
4. **内存占用**: 大图片时内存占用较高

## 调试技巧

### Flutter 调试

```bash
cd compositor/src/dart_shell/screenshot_tool
flutter run --debug
```

### Rust 调试

```bash
RUST_LOG=debug cargo build
```

### 端到端测试

1. 启动 denialwm
2. 按 Ctrl+Alt+A 触发截图
3. 测试工具栏功能
4. 验证保存结果

## 贡献指南

1. Fork 项目
2. 创建特性分支
3. 提交更改
4. 推送到分支
5. 创建 Pull Request

## 联系方式

- Issue: [GitHub Issues](https://github.com/your-repo/denial-screenshots/issues)
- Discussion: [GitHub Discussions](https://github.com/your-repo/denial-screenshots/discussions)
