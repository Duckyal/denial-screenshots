# denial-screenshots

A QQ-style screenshot annotation tool for [Denial](https://github.com/denialwm/denial),
implemented as a Denial plugin per the
[denial-plugins](https://github.com/denialwm/denial-plugins) spec.

English | [简体中文](README.md)

> Porting this to other desktops? See [docs/PORTING.md](docs/PORTING.md) — multi-desktop plan (on hold).

## What it is

Capture, region selection, PNG encoding and clipboard publishing are all done by
the compositor (`deniald`). This plugin only reads the newest capture, annotates
it inside the shell, and saves / copies / pins the result.

```
[compositor deniald]
  screencopy -> ~/Pictures/Screenshots/Screenshot-{sec}-{ms}.png -> clipboard
        |
        v
[plugin plugins/denialscreenshot]
  ShellAction  denialscreenshot.capture      Take a screenshot and annotate it
  ShellAction  denialscreenshot.editLatest   Edit the newest screenshot
  ShellSurface denialscreenshot.editor       Full-output annotation editor
  ShellSurface denialscreenshot.pin          Floating pinned snapshot
```

All four contributions are published under the provider name `Screenshot Tool`,
which is what you look for in **Settings → Shortcuts → Denial actions**.

## Features

| Area | Details |
|---|---|
| Tools | Select, brush, line, arrow, rectangle, circle, text, mosaic, eraser |
| Editing | Undo / redo, select an existing shape to recolor or resize it, delete selection |
| Toolbar | Dockable at `auto` / `left` / `right` / `top` / `bottom`; `Tab` collapses or reveals it |
| Output | Save / save-as (file picker), copy PNG to clipboard; the copy button shows its state (copying / copied / failed) with icon and color, and by default closes the editor after a successful copy (toggle in settings) |
| Pin | Turn the annotated snapshot into a small draggable card, keep editing or close it |
| OCR + translation | Local RapidOCR + Argos sidecar, or any OpenAI-compatible API; the result is painted back over the original text |
| Auto-open | Watches the screenshot directory and opens the editor as soon as a new capture lands |
| Settings | Shortcuts, toolbar dock, close-after-copy, translation backend and API are configurable and persisted |

Settings file: `~/.config/denial-screenshots/settings.json`.
Set `DENIAL_SCREENSHOT_DIR` to override the capture directory
(default `~/Pictures/Screenshots`).

## Install

### From the Denial Plugins app

- Run the **Plugins** app
- Click **Add plugins** in the top-right corner
- Paste this repository's URL
- Click **Find plugins**

### From the denial-plugins CLI

```sh
denial-plugins --path plugins/denialscreenshot add <this repository Git URL>
denial-plugins plan
denial-plugins build CANDIDATE_ID
denial-plugins activate CANDIDATE_ID
```

### Local development

```sh
cd plugins/denialscreenshot
denial-plugins --local add "$PWD"
denial-plugins plan
denial-plugins build CANDIDATE_ID
denial-plugins activate CANDIDATE_ID
```

Declaring an action does not bind a key. After installing, open
**Settings → Shortcuts → Denial actions** → `Screenshot Tool` and assign a
shortcut (for example `Ctrl+Alt+A` for "Take a screenshot and annotate it").

### If activate fails with "No initial frame arrived within 20 seconds"

A cold custom runtime occasionally exceeds the hard 20 s timeout. Warm the AOT
runtime first, then switch:

```sh
denialctl ui build
denialctl ui activate /home/wu/.local/state/denial/plugins/candidates/<CANDIDATE_ID>/bundle
```

The same two commands restore the plugin after a reboot (when the UI falls back
to the packaged build); no rebuild is needed.

## Shortcuts (defaults, configurable)

| Key | Action |
|---|---|
| `V` `B` `L` `A` `R` `C` `T` `M` `E` | Select / brush / line / arrow / rect / circle / text / mosaic / eraser |
| `Tab` | Collapse / reveal the toolbar |
| `Space` | Shortcut cheat sheet |
| `Ctrl+Z` / `Ctrl+R` | Undo / redo |
| `[` / `]` | Nudge stroke width |
| `Enter` | Save |
| `Delete` / `Backspace` | Delete the selected shape |
| `Esc` | Close the editor |

## Configuring the translation API

Translation has two paths: **local models** (RapidOCR + Argos sidecar) and an **online API**. To use an online API:

1. Editor toolbar → gear "Settings" → set Translation backend to "Online translation API".
2. Pick a protocol (defaults to OpenAI-compatible):

| Protocol | Fields | Notes |
|---|---|---|
| OpenAI-compatible | Endpoint / Key / Model | DeepSeek, OpenAI, Moonshot, local Ollama…; **model name is required** |
| Baidu | APP ID / Key | Free tier at fanyi-api.baidu.com |
| DeepL | Key | Keys ending in `…:fx` are the free tier |
| LibreTranslate | Endpoint / Key (optional) | Self-hosted or public instance |

3. The endpoint is completed automatically: `https://api.deepseek.com` → requests `https://api.deepseek.com/v1/chat/completions`; if the URL already contains `/v1`, only `/chat/completions` is appended; a full `.../chat/completions` URL is used as-is.
4. Press **"Test connection"** — it actually translates `Hello, world` and shows the result or the error right below the button. **Use this to validate your config before taking any screenshot.**

To validate the backend on its own first:

```sh
curl https://api.deepseek.com/chat/completions \
  -H "Authorization: Bearer sk-your-key" \
  -H "Content-Type: application/json" \
  -d '{"model":"deepseek-chat","temperature":0,"messages":[{"role":"user","content":"1. hello"}]}'
```

Notes:

- **OCR runs before translation** (local sidecar). The first run installs `rapidocr-onnxruntime` and friends and downloads the model — expect a few minutes. To speed it up, pre-install:
  `pip install rapidocr-onnxruntime ctranslate2 sentencepiece pillow -i https://pypi.tuna.tsinghua.edu.cn/simple`
- Config lives in `~/.config/denial-screenshots/settings.json` (`apiType` / `apiEndpoint` / `apiKey` / `apiModel` / `apiAppId`); restart the editor after editing it by hand.
- Translation **writes no log**; success and failure appear once in the editor's bottom snackbar (failures include the HTTP status and response body).

## Dependencies

| Purpose | Requirement | Notes |
|---|---|---|
| Copy image | `wl-clipboard` (`sudo pacman -S wl-clipboard`) | Falls back to `xclip`; if neither works the copy fails with a message |
| Local translation | Python with `rapidocr-onnxruntime`, `ctranslate2`, `sentencepiece`, `PIL` | First run downloads the OCR model and Argos language packs (HF mirror) |
| API translation | Any OpenAI-compatible endpoint | Fill in endpoint / key / model in the settings |

The Python sidecar is embedded in the plugin
(`lib/src/editor/sidecar_source.dart`), so no packaged assets are needed.

## Layout

```
denial-screenshots/
├── plugins.yaml                  # plugin catalog entry
├── plugins/denialscreenshot/     # independently selectable Dart package
│   ├── pubspec.yaml              # plugin manifest (denial_plugin.provides)
│   ├── lib/denialscreenshot.dart # @Plugin() entry point + @Provides declarations
│   ├── lib/src/
│   │   ├── clipboard.dart        # clipboard (wl-copy / xclip + env fallback)
│   │   ├── editor_surface.dart   # editor surface + capture directory watcher
│   │   ├── pin_surface.dart      # floating pinned snapshot
│   │   ├── screenshot_store.dart # newest-capture lookup
│   │   ├── editor_bus.dart       # in-plugin event bus
│   │   └── editor/               # editor UI, command stack, settings, translation
│   └── docs/DEVELOPMENT.md       # development and verification steps
├── compositor/src/dart_shell/    # standalone editor app (UI prototype, not built as a plugin)
└── run_standalone.sh             # entry point for the standalone app
```

## Standalone development

`compositor/src/dart_shell/screenshot_tool` can still run as a standalone Linux
app for iterating on the editor UI. It is not part of the plugin build and does
not trigger system captures.

```sh
./run_standalone.sh              # build and run
BUILD_ONLY=1 ./run_standalone.sh
```

## Development checks

Every `plugins/PACKAGE_NAME/` is an independent Dart package: run Pub and the
analyzer from that directory (the repository root is neither a Pub workspace nor
a plugin).

```sh
denial-plugins prepare
cd plugins/denialscreenshot
cp pubspec_overrides.yaml.example pubspec_overrides.yaml   # replace /ABSOLUTE/RUNTIME with
                                                           # the runtime path from configuration.json
"$DENIAL_PLUGIN_FLUTTER" pub get
"$DENIAL_PLUGIN_DART" format --output=none --set-exit-if-changed lib
"$DENIAL_PLUGIN_DART" analyze --fatal-infos lib
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| Copy does not reach the clipboard | Check `/tmp/denial-screenshot-clipboard.log` (exit codes and stderr of every attempt). A common cause is the plugin process having no `WAYLAND_DISPLAY`; the code now falls back to `$XDG_RUNTIME_DIR/wayland-N` |
| `prepare` / `plan` fail kit validation | The build-kit copy was edited by hand (for example injecting code into `denial_desktop`). Never edit files under `~/.local/state/denial/plugins/build-kits/`; run `denial-plugins prepare` again |
| Pinned card blocks the whole desktop | The input region must wrap only the card, see `lib/src/pin_surface.dart` |
| Desktop looks like the stock shell | A plugin composition uses the official plugins from the build-kit; customizations that live in your local workspace (`dart_shell/lib/main.dart`) are not included. Turn them into plugins and add them to the selection |

`README_COMPLETE.md` and `PLUGIN_RESTRUCTURE.md` are pre-refactor documents kept
for reference only.
