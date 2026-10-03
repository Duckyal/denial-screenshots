#!/usr/bin/env bash
# 安装"denial 截图自动打开编辑器"钩子：
#   1. 监听脚本 → ~/.local/bin/denial-screenshot-editor-hook
#   2. 当前编辑器 bundle → ~/.local/share/denial-screenshots/editor/
#   3. 自启动入口 → ~/.config/autostart/denial-screenshot-editor-hook.desktop
# 卸载：删掉上述三个文件即可。

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$HOME/.local/bin"
DATA_DIR="$HOME/.local/share/denial-screenshots"
AUTOSTART_DIR="$HOME/.config/autostart"

mkdir -p "$BIN_DIR" "$DATA_DIR/editor" "$AUTOSTART_DIR"

install -m 755 "$REPO/tools/screenshot-editor-watch.sh" \
  "$BIN_DIR/denial-screenshot-editor-hook"

BUNDLE="$REPO/compositor/src/dart_shell/screenshot_tool/build/linux/x64/release/bundle"
if [[ ! -x "$BUNDLE/screenshot_tool" ]]; then
  echo "编辑器 bundle 不存在：$BUNDLE（先运行 run_standalone.sh 构建）" >&2
  exit 1
fi
rm -rf "$DATA_DIR/editor"
cp -r "$BUNDLE" "$DATA_DIR/editor"

cat > "$AUTOSTART_DIR/denial-screenshot-editor-hook.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Denial Screenshot Editor Hook
Comment=用标注编辑器自动打开 denial 的新截图
Exec=%HOME%/.local/bin/denial-screenshot-editor-hook
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
sed -i "s|%HOME%|$HOME|" "$AUTOSTART_DIR/denial-screenshot-editor-hook.desktop"

echo "已安装："
echo "  钩子    $BIN_DIR/denial-screenshot-editor-hook"
echo "  编辑器  $DATA_DIR/editor/screenshot_tool"
echo "  自启动  $AUTOSTART_DIR/denial-screenshot-editor-hook.desktop"
echo "日志：$DATA_DIR/hook.log"
echo "立即启动：$BIN_DIR/denial-screenshot-editor-hook &"
