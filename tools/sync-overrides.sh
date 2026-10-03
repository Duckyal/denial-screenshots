#!/usr/bin/env bash
# 用 Plugin Manager 记录的 runtime 路径刷新本地 SDK 覆盖文件。
# 每次 `denial-plugins prepare` 之后（build kit 变更）都要跑一次。
set -euo pipefail

STATE="${XDG_STATE_HOME:-$HOME/.local/state}/denial/plugins"
CONFIG="$STATE/configuration.json"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/plugins/denialscreenshot"

if [[ ! -f "$CONFIG" ]]; then
  echo "找不到 $CONFIG，先运行：denial-plugins prepare" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "需要 jq 读取 configuration.json" >&2
  exit 1
fi

RUNTIME="$(jq -er '.runtime' "$CONFIG")"

cat >"$PACKAGE/pubspec_overrides.yaml" <<EOF
dependency_overrides:
  denial_sdk:
    path: $RUNTIME/packages/denial_sdk
  denial_flutter_sdk:
    path: $RUNTIME/packages/denial_flutter_sdk
EOF

echo "已更新 $PACKAGE/pubspec_overrides.yaml"
echo "runtime: $RUNTIME"
