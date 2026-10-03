# Developing the screenshot plugin

Each `plugins/PACKAGE_NAME/` directory is an independently selectable Dart
package. Run Pub and analysis from that package directory. The repository root
is not a Pub workspace or a plugin.

## 1. Prepare Denial's matching tools

```sh
denial-plugins prepare
DENIAL_PLUGIN_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/denial/plugins"
DENIAL_PLUGIN_FLUTTER="$(jq -er '.flutter' "$DENIAL_PLUGIN_STATE/configuration.json")"
DENIAL_PLUGIN_RUNTIME="$(jq -er '.runtime' "$DENIAL_PLUGIN_STATE/configuration.json")"
DENIAL_PLUGIN_DART="$(jq -er '.dart' "$DENIAL_PLUGIN_STATE/configuration.json")"
```

## 2. Open the package

```sh
cd plugins/denialscreenshot
```

## 3. Write local SDK overrides

Copy `pubspec_overrides.yaml.example` to `pubspec_overrides.yaml` and replace
`/ABSOLUTE/RUNTIME` with `"$DENIAL_PLUGIN_RUNTIME"`.

## 4. Resolve and check

```sh
"$DENIAL_PLUGIN_FLUTTER" pub get
"$DENIAL_PLUGIN_DART" format --output=none --set-exit-if-changed lib
"$DENIAL_PLUGIN_DART" analyze --fatal-infos lib
```

## 5. Build and install

```sh
denial-plugins --local add "$PWD"
denial-plugins plan
denial-plugins build CANDIDATE_ID
denial-plugins activate CANDIDATE_ID
```

Leave the reference desktop selected: it hosts `ShellSurface` and `ShellAction`
providers.

## Architecture

Capture and saving stay in the compositor. The plugin only:

| Concern | Owner |
|---|---|
| screencopy, region selection, PNG write, clipboard publish | compositor (`deniald`) |
| trigger the capture | `ImageClipboard`/bridge: `denialBridgeProvider.takeScreenshot()` |
| read the newest capture | `ScreenshotStore` (`~/Pictures/Screenshots`, `DENIAL_SCREENSHOT_DIR`) |
| annotation UI | `ScreenshotEditorView` inside a `ShellSurface` |
| drawing/encoding | `ScreenshotPainter` (`PictureRecorder` → PNG) |
| clipboard hand-off | `ImageClipboard` (`wl-copy` → `xclip` → text path) |

Actions talk to the surface through `DenialScreenshotEditorBus`; the
composition wires providers at build time, so no runtime registry is involved.

### Why there is no Rust backend

Denial plugins are plain Dart packages compiled into the shell. Compositor-side
Rust, FFI and standalone Flutter apps are not plugin contributions, and the
compositor already implements capture. Anything needing a new native capability
belongs upstream in `deniald`, not in this package.

## Clipboard notes

Denial's Flutter platform channel accepts `text/plain` only, so image delivery
uses the compositor's `ext/zwlr-data-control` support through `wl-copy`
(preferred) or `xclip` (XWayland). Without either tool the editor saves the
annotated PNG and copies its path as text.
