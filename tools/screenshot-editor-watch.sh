#!/usr/bin/env bash
# denial 截图 → 编辑器钩子：监听 denial 的截图目录，新截图落盘后自动
# 用标注编辑器打开它（denial 本身仍会保存文件并复制到剪贴板）。
#
# 由 tools/install-screenshot-hook.sh 安装为用户自启动服务；也可手动
# 运行调试：screenshot-editor-watch.sh [--once]

set -u

DIR="${DENIAL_SCREENSHOT_DIR:-$HOME/Pictures/Screenshots}"
LOG="${DENIAL_SCREENSHOT_HOOK_LOG:-$HOME/.local/share/denial-screenshots/hook.log}"
# 编辑器 bundle 位置：优先随钩子安装的副本，其次开发目录。
EDITOR="${DENIAL_SCREENSHOT_EDITOR:-$HOME/.local/share/denial-screenshots/editor/screenshot_tool}"
if [[ ! -x "$EDITOR" ]]; then
  EDITOR="$HOME/项目/denial-screenshots/compositor/src/dart_shell/screenshot_tool/build/linux/x64/release/bundle/screenshot_tool"
fi
POLL_SECONDS="${DENIAL_SCREENSHOT_HOOK_POLL:-0.5}"

mkdir -p "$DIR" "$HOME/.local/share/denial-screenshots"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }

if [[ ! -x "$EDITOR" ]]; then
  log "编辑器不存在：$EDITOR"
  exit 1
fi

# 已见文件表：路径 → 上次大小；连续两次扫描大小不变才认为写完。
declare -A seen_size
declare -A launched

scan() {
  local file size
  for file in "$DIR"/Screenshot-*.png; do
    [[ -f "$file" ]] || continue
    size=$(stat -c %s "$file" 2>/dev/null) || continue
    ((size > 0)) || continue
    if [[ -z "${seen_size[$file]:-}" ]]; then
      seen_size[$file]=$size
      continue
    fi
    ((seen_size[$file] == size)) || { seen_size[$file]=$size; continue; }
    [[ -n "${launched[$file]:-}" ]] && continue
    launched[$file]=1
    log "打开截图 $file"
    nohup "$EDITOR" --image "$file" >>"$LOG" 2>&1 &
  done
}

# 单实例锁：systemd/自启动/手动同时存在时只留一个。
exec 9>"$HOME/.local/share/denial-screenshots/hook.lock"
flock -n 9 || { log "已有实例在运行，退出"; exit 0; }

# 启动时把已有文件标记为已见+已打开，绝不打开历史截图。
for file in "$DIR"/Screenshot-*.png; do
  [[ -f "$file" ]] || continue
  seen_size[$file]=$(stat -c %s "$file" 2>/dev/null || echo 0)
  launched[$file]=1
done

log "监听 $DIR（编辑器：$EDITOR）"
if [[ "${1:-}" == "--once" ]]; then
  scan
  exit 0
fi
while true; do
  sleep "$POLL_SECONDS"
  scan
done
