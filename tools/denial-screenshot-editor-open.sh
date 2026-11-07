#!/usr/bin/env bash
# denial-screenshot-editor-open — freedesktop 打开图片 → Denial 截图编辑器
#
# 文件管理器双击图片时，xdg 按 mimeapps 默认应用执行本脚本并把图片路径
# 传进来（%f）。编辑器是 shell 内插件 surface、不是独立进程，所以这里
# 只做投递：把绝对路径写进约定目录，编辑器 surface 监听该目录、读后即
# 删。投递失败（编辑器没跑）也没关系——请求文件留着，插件启动时排空。
set -euo pipefail

[[ $# -ge 1 ]] || { echo "usage: $0 <image-file>" >&2; exit 1; }

target="$1"
# URI 形式（%U 传 file:// 时）也兼容。
[[ "$target" == file://* ]] && target="${target#file://}"

[[ -f "$target" ]] || { echo "not a file: $target" >&2; exit 1; }
# 绝对路径：编辑器与调用方工作目录无关。
target="$(realpath "$target")"

ext="${target##*.}"
case "${ext,,}" in
  png|jpg|jpeg|webp|bmp) ;;
  *) echo "unsupported image type: $ext" >&2; exit 1 ;;
esac

dir="${XDG_CONFIG_HOME:-$HOME/.config}/denial-screenshot-editor-open"
mkdir -p "$dir"
# 直接写最终文件（唯一名）。监听端在文件创建时即被唤醒，可能读到空
# 内容（还没 close），它会短重试；不用 mv：Dart 的目录监听对 rename
# （MOVED_TO）的转发不可靠，实测收不到。
name="$(date +%s%N)-$$.open"
printf '%s' "$target" > "$dir/$name"
