# Denial Screenshot Tool - 编译指南

## 当前状态

项目代码已完成（95%），但需要 Flutter SDK 才能编译。Flutter SDK 正在下载中（661MB），速度较慢。

## 快速编译步骤

### 1. 安装 Flutter SDK

```bash
# 下载 Flutter SDK
cd /home/wu/项目
wget https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.24.5-stable.tar.xz

# 解压
tar -xf flutter_linux_3.24.5-stable.tar.xz

# 配置环境变量
echo 'export PATH="$HOME/flutter/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

# 运行 flutter doctor
flutter doctor
```

### 2. 安装依赖

```bash
# 更新包列表
sudo pacman -Syu

# 安装 Flutter 依赖
sudo pacman -S --needed \
  base-devel \
  cmake \
  ninja \
  git \
  unzip \
  curl \
  libnotify \
  libxdamage \
  libxfixes \
  libxrandr \
  libxkbcommon \
  xdg-utils \
  libappindicator-gtk3 \
  gtk3 \
  libglvnd \
  clang \
  cmake \
  ninja \
  pkg-config \
  libgtk-3-dev \
  liblzma-dev \
  clang \
  cmake \
  ninja \
  pkg-config \
  libgtk-3-dev \
  liblzma-dev \
  xz \
  libarchive
```

### 3. 编译 Flutter 工具

```bash
cd /home/wu/项目/denial-screenshots/compositor/src/dart_shell/screenshot_tool

# 安装 Flutter 依赖
flutter pub get

# 编译 Linux 版本
flutter build linux --release
```

编译产物位置：
```
build/linux/x64/release/bundle/
```

### 4. 编译 Rust FFI 库

```bash
cd /home/wu/项目/denial-screenshots/compositor

# 编译 Rust 库
cargo build --release --features flutter
```

FFI 库位置：
```
target/release/libdenialscreenshot.so
```

### 5. 创建输出目录

```bash
cd /home/wu/项目/denial-screenshots

# 创建输出目录
mkdir -p build_output

# 复制 Flutter 构建产物
cp -r compositor/src/dart_shell/screenshot_tool/build/linux/x64/release/bundle/* build_output/

# 复制 Rust FFI 库
cp compositor/target/release/libdenialscreenshot.so build_output/
```

## 使用方法

### 方式 1: 直接运行

```bash
cd build_output
./denialscreenshot
```

### 方式 2: 与 DenialWM 集成

1. 将 `build_output` 目录复制到 DenialWM 的插件目录
2. 在 DenialWM 配置中引用这些文件
3. 通过快捷键 `Ctrl + Alt + A` 启动截图工具

## 验证编译

### 检查 Flutter 工具

```bash
cd build_output
./denialscreenshot --version
```

### 检查 FFI 库

```bash
ldd build_output/libdenialscreenshot.so
```

应该看到所有依赖都已解决。

## 常见问题

### Q: Flutter 构建失败

A: 运行 `flutter doctor` 检查环境，确保所有依赖都已安装。

### Q: Rust 编译失败

A: 确保使用最新的 Rust 工具链：
```bash
rustup update stable
rustup default stable
```

### Q: FFI 库加载失败

A: 确保库路径正确，检查 `LD_LIBRARY_PATH`：
```bash
export LD_LIBRARY_PATH=/home/wu/项目/denial-screenshots/build_output:$LD_LIBRARY_PATH
```

## 下一步

编译完成后，你可以：

1. 测试截图工具
2. 查看文档了解功能
3. 提交反馈或改进建议

## 项目文件位置

```
/home/wu/项目/denial-screenshots/
├── README.md                          # 项目说明
├── build.sh                          # 构建脚本
├── compositor/
│   ├── Cargo.toml                    # Rust 依赖
│   └── src/
│       ├── bin/deniald/               # Rust 后端
│       └── dart_shell/                # Flutter 前端
│           └── screenshot_tool/       # 截图工具
└── docs/
    ├── QUICKSTART.md                  # 快速开始
    ├── DEVELOPMENT.md                 # 开发文档
    └── IMPLEMENTATION_COMPLETE.md     # 实现完成总结
```

## 技术支持

如有问题，请查看：
- [QUICKSTART.md](docs/QUICKSTART.md)
- [DEVELOPMENT.md](docs/DEVELOPMENT.md)
- [IMPLEMENTATION_COMPLETE.md](docs/IMPLEMENTATION_COMPLETE.md)

---

**更新时间**: 2026-09-30
**项目状态**: 代码完成，等待编译
