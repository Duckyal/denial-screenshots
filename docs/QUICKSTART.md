# 快速开始指南

## 前提条件

- DenialWM 0.2.0 或更高版本
- Rust 1.70+
- Flutter 3.16+
- CMake 3.20+

## 构建步骤

### 1. 构建 Flutter 工具

```bash
cd compositor/src/dart_shell/screenshot_tool
flutter pub get
flutter build linux --release
```

构建产物位于：`build/linux/x64/release/bundle/`

### 2. 构建 Rust FFI 库

```bash
cd compositor
cargo build --release --features flutter
```

FFI 库位于：`target/release/libdenialscreenshot.so`

### 3. 集成到 DenialWM

在 `deniald.rs` 中添加模块声明：

```rust
#[cfg(feature = "flutter")]
mod screenshot;
#[cfg(feature = "flutter")]
mod screenshot_trigger;
#[cfg(feature = "flutter")]
mod shortcut_manager;
#[cfg(feature = "flutter")]
mod screenshot_plugin;
#[cfg(feature = "flutter")]
mod screenshot_ffi;
```

在 `RuntimeState` 中初始化：

```rust
#[cfg(feature = "flutter")]
pub struct RuntimeState {
    screenshot_manager: ScreenshotManager,
    shortcut_manager: ShortcutManager,
}
```

### 4. 启动截图工具

```bash
# 方式 1: 快捷键
Ctrl + Alt + A

# 方式 2: 命令行
denialctl screenshot start

# 方式 3: 通过 FFI 调用
screenshot_tool_start()
```

## 使用说明

### 工具栏操作

1. **选择工具**：点击工具栏上的图标
   - 🖌️ 画笔
   - → 箭头
   - ⬜ 矩形
   - ⭕ 圆形
   - T 文字
   - 🔍 马赛克
   - 🗑️ 橡皮

2. **选择颜色**：点击颜色圆圈

3. **调整粗细**：拖动滑块

4. **撤销/重做**：点击撤销或重做按钮

5. **保存截图**：点击保存按钮或按 Enter

6. **取消截图**：点击取消按钮或按 Esc

7. **复制截图**：点击复制按钮或按 Ctrl+C

### 快捷键（可选）

| 快捷键 | 功能 |
|--------|------|
| Enter | 保存 |
| Esc | 取消 |
| Ctrl+C | 复制 |
| Ctrl+Z | 撤销 |
| Ctrl+Shift+Z | 重做 |
| B | 画笔 |
| A | 箭头 |
| R | 矩形 |
| C | 圆形 |
| T | 文字 |
| M | 马赛克 |
| E | 橡皮 |
| [ | 粗细减小 |
| ] | 粗细增大 |

## 故障排除

### Flutter UI 无法启动

1. 检查 Flutter 环境是否正确安装
2. 运行 `flutter doctor` 检查依赖
3. 查看日志输出

### FFI 库加载失败

1. 确保 Rust 库已正确编译
2. 检查库路径是否正确
3. 查看系统日志

### 截图功能不工作

1. 确认 DenialWM 已启用 Flutter 特性
2. 检查 Wayland 协议支持
3. 查看错误日志

## 开发调试

### 启用详细日志

```bash
RUST_LOG=debug cargo run
```

### Flutter 调试模式

```bash
cd compositor/src/dart_shell/screenshot_tool
flutter run --debug
```

### 测试 FFI 通信

```bash
# 使用 strace 查看 FFI 调用
strace -e trace=openat,read,write deniald 2>&1 | grep screenshot
```

## 下一步

- 阅读完整文档：[DEVELOPMENT.md](DEVELOPMENT.md)
- 查看功能清单：[FEATURES.md](FEATURES.md)
- 提交问题：[GitHub Issues](https://github.com/your-repo/denial-screenshots/issues)

## 示例配置

### ~/.config/denial/plugins.json

```json
{
  "plugins": [
    {
      "name": "default-screenshot",
      "enabled": true
    }
  ]
}
```

### 环境变量

```bash
export DENIAL_SCREENSHOT_DIR=/custom/path/screenshots
```

## 贡献

欢迎提交 PR 和 Issue！

---

**更新时间**：2026-09-30
