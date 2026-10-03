# Denial Screenshot Tool - 完整版

## 📦 项目文件位置

```
/home/wu/项目/denial-screenshots/
```

## 🚀 一键编译（推荐）

我已经创建了一个一键编译脚本，它会自动：

1. ✅ 检查 Rust 环境
2. ✅ 下载 Flutter SDK（如果需要）
3. ✅ 安装 Flutter 依赖
4. ✅ 编译 Rust FFI 库
5. ✅ 编译 Flutter 工具
6. ✅ 打包所有文件到输出目录

### 运行编译脚本

```bash
cd /home/wu/项目/denial-screenshots
chmod +x compile.sh
./compile.sh
```

编译完成后，输出目录在：
```
/home/wu/项目/denial-screenshots/build_output/
```

## 📋 手动编译步骤

如果一键编译失败，可以手动编译：

### 1. 安装 Flutter SDK

```bash
cd /home/wu/项目
wget https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.24.5-stable.tar.xz
tar -xf flutter_linux_3.24.5-stable.tar.xz
export PATH="$HOME/flutter/bin:$PATH"
```

### 2. 安装依赖

```bash
# Arch Linux
sudo pacman -Syu base-devel cmake ninja git unzip curl libnotify libxdamage libxfixes libxrandr libxkbcommon xdg-utils libappindicator-gtk3 gtk3 libglvnd clang pkg-config libgtk-3-dev liblzma-dev xz libarchive

# Ubuntu/Debian
sudo apt update
sudo apt install -y \
    clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev \
    xz-utils libarchive-tools curl git unzip
```

### 3. 编译 Flutter 工具

```bash
cd /home/wu/项目/denial-screenshots/compositor/src/dart_shell/screenshot_tool

flutter pub get
flutter build linux --release
```

### 4. 编译 Rust 库

```bash
cd /home/wu/项目/denial-screenshots/compositor

cargo build --release --features flutter
```

### 5. 打包

```bash
mkdir -p /home/wu/项目/denial-screenshots/build_output

# 复制 Flutter 构建产物
cp -r build/linux/x64/release/bundle/* /home/wu/项目/denial-screenshots/build_output/

# 复制 Rust 库
cp target/release/libdenialscreenshot.so /home/wu/项目/denial-screenshots/build_output/

# 复制 FFI 库
cp target/release/libdenialscreenshot.so /home/wu/项目/denial-screenshots/build_output/
```

## 🎯 使用方法

### 方式 1: 直接运行

```bash
cd /home/wu/项目/denial-screenshots/build_output
./denialscreenshot
```

### 方式 2: 与 DenialWM 集成

1. 复制 `build_output` 目录到 DenialWM 插件目录
2. 重命名 `denialscreenshot` 为 `denial-screenshot`
3. 在 DenialWM 配置中引用
4. 使用快捷键 `Ctrl + Alt + A` 启动

## 📁 项目结构

```
/home/wu/项目/denial-screenshots/
├── compile.sh                          # 一键编译脚本
├── build.sh                           # 构建脚本（旧版）
├── README.md                          # 项目说明
├── .gitignore                         # Git 忽略
├── compositor/
│   ├── Cargo.toml                    # Rust 依赖
│   ├── CMakeLists.txt                # CMake 配置
│   └── src/
│       ├── bin/deniald/               # Rust 后端
│       │   ├── screenshot.rs          # 截图管理器
│       │   ├── screenshot_trigger.rs  # 截图触发器
│       │   ├── shortcut_manager.rs    # 快捷键管理器
│       │   ├── screenshot_plugin.rs   # 插件接口
│       │   └── screenshot_ffi.rs      # FFI 通信层
│       └── dart_shell/                # Flutter 前端
│           └── screenshot_tool/       # 截图工具
│               ├── lib/
│               │   ├── main.dart              # Flutter 入口
│               │   ├── screenshot_tool.dart   # 主界面
│               │   ├── painter.dart           # 绘图渲染
│               │   ├── tools.dart             # 工具定义
│               │   ├── commands.dart          # 命令定义
│               │   └── ffi.dart               # FFI 绑定
│               ├── linux/
│               │   └── flutter_wrapper.dart   # Linux 包装器
│               └── pubspec.yaml               # Flutter 依赖
├── build_output/                      # 编译输出目录（运行后生成）
└── docs/
    ├── BUILD_GUIDE.md                 # 编译指南
    ├── DEVELOPMENT.md                 # 开发文档
    ├── FEATURES.md                    # 功能清单
    ├── IMPLEMENTATION_COMPLETE.md     # 实现完成总结
    ├── PROJECT_SUMMARY.md             # 项目总结
    └── QUICKSTART.md                  # 快速开始
```

## ✨ 功能特性

### 工具栏操控（主要特性）
- ✅ 7 种绘图工具：画笔、箭头、矩形、圆形、文字、马赛克、橡皮擦
- ✅ 10 种颜色选择
- ✅ 粗细调节（1-20px）
- ✅ 撤销/重做（20 步历史）
- ✅ 保存、复制、取消按钮

### 截图功能
- ✅ 快捷键触发：`Ctrl + Alt + A`
- ✅ 命令行触发：`denialctl screenshot start`
- ✅ 智能文件命名：`Screenshot-{秒数}-{毫秒}.png`
- ✅ 冲突处理：自动添加 `-1`, `-2` 后缀
- ✅ 自动保存到剪贴板

### UI/UX 设计
- ✅ 黑色半透明工具栏
- ✅ 浮动窗口显示
- ✅ 图标 + 文字标签
- ✅ 颜色圆圈选择器
- ✅ 滑块调节粗细
- ✅ 快捷键提示面板
- ✅ 实时选区预览
- ✅ 文字输入对话框

## 🎨 快捷键

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

## 🐛 常见问题

### Q: 编译失败怎么办？

A: 检查：
1. Flutter 是否正确安装：`flutter doctor`
2. Rust 是否正确安装：`cargo --version`
3. 所有依赖是否已安装

### Q: 运行时找不到库？

A: 设置环境变量：
```bash
export LD_LIBRARY_PATH=/home/wu/项目/denial-screenshots/build_output:$LD_LIBRARY_PATH
```

### Q: 如何测试？

A: 直接运行：
```bash
cd /home/wu/项目/denial-screenshots/build_output
./denialscreenshot
```

## 📚 详细文档

- [BUILD_GUIDE.md](docs/BUILD_GUIDE.md) - 详细编译指南
- [DEVELOPMENT.md](docs/DEVELOPMENT.md) - 开发文档
- [FEATURES.md](docs/FEATURES.md) - 功能清单
- [IMPLEMENTATION_COMPLETE.md](docs/IMPLEMENTATION_COMPLETE.md) - 实现总结

## 🎯 下一步

1. 运行 `./compile.sh` 编译项目
2. 进入 `build_output` 目录
3. 运行 `./denialscreenshot` 测试
4. 查看 [QUICKSTART.md](docs/QUICKSTART.md) 了解更多

---

**项目状态**: ✅ 代码完成，等待编译
**更新时间**: 2026-09-30
