#!/usr/bin/env bash
# 安装"用 Denial 截图编辑器打开图片"的 freedesktop 关联。
#
# 装完后的效果：文件管理器双击 png/jpg/webp/bmp → 编辑器打开该图；
# 右键"打开方式"列表里也有它（可选为默认）。不抢现有默认关联——
# 想设默认再跑一次带 --default。
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
bin="${XDG_DATA_HOME:-$HOME/.local/share}/bin"

mkdir -p "$apps" "$bin"

install -m 0755 "$here/denial-screenshot-editor-open.sh" \
  "$bin/denial-screenshot-editor-open"
# Exec/TryExec 写绝对路径：shell 启动 .desktop 时的 PATH 未必包含
# ~/.local/share/bin，裸命令名会解析失败。
sed -e "s|^Exec=.*|Exec=$bin/denial-screenshot-editor-open %f|" \
    -e "s|^TryExec=.*|TryExec=$bin/denial-screenshot-editor-open|" \
    "$here/com.denial.ScreenshotEditor.desktop" > "$apps/com.denial.ScreenshotEditor.desktop"

update-desktop-database "$apps" 2>/dev/null || true

if [[ "${1:-}" == "--default" ]]; then
  for mime in image/png image/jpeg image/webp image/bmp; do
    xdg-mime default com.denial.ScreenshotEditor.desktop "$mime"
  done
  echo "set as default for png/jpeg/webp/bmp"
else
  echo "installed; pick it in 'Open With' or re-run with --default"
fi
