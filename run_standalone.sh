#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$ROOT_DIR/compositor/src/dart_shell/screenshot_tool"
APP_BIN="$APP_DIR/build/linux/x64/release/bundle/screenshot_tool"
FLUTTER_BIN="${FLUTTER_BIN:-$(command -v flutter || true)}"

if pgrep -f "^$APP_BIN$" >/dev/null; then
  printf 'Screenshot editor is still running. Close it before rebuilding the bundle.\n' >&2
  exit 1
fi

if [[ -z "$FLUTTER_BIN" && -x "$HOME/项目/flutter/bin/flutter" ]]; then
  FLUTTER_BIN="$HOME/项目/flutter/bin/flutter"
fi
if [[ -z "$FLUTTER_BIN" || ! -x "$FLUTTER_BIN" ]]; then
  printf 'Flutter not found. Set FLUTTER_BIN to a full Flutter SDK executable.\n' >&2
  exit 1
fi

# User-local gtk-layer-shell (no root install): lets the pinned snapshot
# card sit on the compositor's overlay layer so it never sinks on focus loss.
GTK_LAYER_SHELL_USR="$HOME/.local/opt/gtk-layer-shell/usr"
if [[ -d "$GTK_LAYER_SHELL_USR/lib/pkgconfig" ]]; then
  export PKG_CONFIG_PATH="$GTK_LAYER_SHELL_USR/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  export LD_LIBRARY_PATH="$GTK_LAYER_SHELL_USR/lib:${LD_LIBRARY_PATH:-}"
fi

CC_BIN="${CC:-$(command -v gcc || true)}"
CXX_BIN="${CXX:-$(command -v g++ || true)}"
if [[ -z "$CC_BIN" || -z "$CXX_BIN" ]]; then
  printf 'Linux desktop build requires gcc and g++.\n' >&2
  exit 1
fi

cd "$APP_DIR"
"$FLUTTER_BIN" pub get
CC="$CC_BIN" CXX="$CXX_BIN" cmake \
  -G Ninja \
  -S linux \
  -B build/linux/x64/release \
  -DCMAKE_BUILD_TYPE=Release \
  -DFLUTTER_TARGET_PLATFORM=linux-x64 \
  -DCMAKE_C_COMPILER="$CC_BIN" \
  -DCMAKE_CXX_COMPILER="$CXX_BIN"
CC="$CC_BIN" CXX="$CXX_BIN" "$FLUTTER_BIN" build linux --release
# Ship the user-local layer-shell library inside the bundle: the binary's
# RPATH is $ORIGIN/lib, so a direct bundle launch works without env setup.
if [[ -d "$GTK_LAYER_SHELL_USR/lib" ]]; then
  cp -f "$GTK_LAYER_SHELL_USR/lib/libgtk-layer-shell.so.0"* \
    "$APP_DIR/build/linux/x64/release/bundle/lib/" 2>/dev/null || true
fi

if [[ "${BUILD_ONLY:-0}" == "1" ]]; then
  exit 0
fi
exec "$APP_BIN"
