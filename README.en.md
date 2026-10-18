# denial-screenshots

A QQ / Snipaste-style screenshot annotation tool for [Denial](https://github.com/denialwm/denial),
implemented as a Denial plugin per the
[denial-plugins](https://github.com/denialwm/denial-plugins) spec. It runs inside
the shell process.

English | [简体中文](README.md)

## What it is

The plugin ships its own region capture: dim the whole output, drag a selection
(fine-tune it via edge/corner handles), grab the live pixels with `grim`
(wlr-screencopy), then get a toolbar right there (OCR / translate / scrolling
capture / edit / copy / save / pin). It does **not** go through the compositor's
selection flow and needs no separate app.

The compositor (`deniald`) path is still supported: its screencopy writes
`~/Pictures/Screenshots/Screenshot-{sec}-{ms}.png` and publishes the clipboard,
and the plugin watches that directory and opens the editor as soon as a new
capture lands (auto-open is suspended while a selection flow is running, so it
never pops up by accident).

```
[plugin plugins/denialscreenshot]
  Region capture (recommended)  dim + drag-select -> grab with grim -> selection toolbar
  Scrolling capture             select a region -> auto/manual scroll burst -> stitch into one long image
  Pin clipboard                 pin the newest clipboard image or text as a floating card (stack several)
  Annotation editor             full-output editing plane (also opens compositor/local images)
        ^
        | directory watch (compat path)
[compositor deniald]
  screencopy -> ~/Pictures/Screenshots/Screenshot-{sec}-{ms}.png -> clipboard
```

Contributions (all published under the provider name `Screenshot Tool`, which is
what you look for in **Settings → Shortcuts → Denial actions**):

| Kind | ID | Purpose |
|---|---|---|
| `ShellAction` | `denialscreenshot.capture` | Region capture (recommended entry point) |
| `ShellAction` | `denialscreenshot.longCapture` | Scrolling capture (select, then auto-scroll + stitch) |
| `ShellAction` | `denialscreenshot.pinFromClipboard` | Pin clipboard content (stackable cards) |
| `ShellSurface` | `denialscreenshot.capture` | Selection / toolbar plane |
| `ShellSurface` | `denialscreenshot.editor` | Full-output annotation editor plane |
| `ShellSurface` | `denialscreenshot.pin` | Floating pinned-snapshot plane |

## Features

| Area | Details |
|---|---|
| Capture | Dimmed full-output selection with edge/corner resizing; live pixels grabbed with `grim` (wlr-screencopy); still compatible with the compositor's capture directory |
| Tools | Select, brush, line, arrow, rectangle, circle, text, **highlighter**, mosaic (blur / solid fill), eraser |
| Editing | Undo / redo, select an existing shape to recolor or resize it, delete selection; in cursor mode **double-click a text to edit it in place** (clearing it deletes the text); `Alt+scroll` zooms the canvas, arrows pan when zoomed in |
| Selection toolbar | OCR / translate / scrolling capture / edit / copy / save / pin / settings, right where you selected |
| Scrolling capture | Burst-captures the framed region and stitches it; scroll injection defaults to Denial's virtual keyboard and can switch to `wtype` / `ydotool` or manual scrolling — paging key (Down / Space) and speed are configurable; a live thumbnail window floats in the top-right corner |
| Output | Save / save-as / open image via the in-editor file panel, `Enter` saves; the copy button is copy-and-close in one, reporting copying / copied / failed with icon and color; `Esc` closes without touching the clipboard; when no image clipboard is available it copies the file path as text instead |
| Pin | Turns the annotated snapshot — or clipboard content — into a draggable card, resized from the edges/corners **with a locked aspect ratio**; double-click returns to the editor, text cards allow selecting and copying individual words |
| OCR | Local RapidOCR (PP-OCRv3 built in, zero download; v4/v5/v6 downloadable; the unified package's multilingual model; or your own local model directory), **or an online vision model** (reuses the translation API's endpoint/key, only needs its own model name) |
| Translation | **Local offline** (Argos per-language packs / M2M-100) or online API (OpenAI-compatible / Baidu / DeepL / LibreTranslate); translations are painted back over the original text positions, with a blur or solid mask and auto-extracted or fixed text color |
| Visible progress | Both OCR and translation show a status overlay: OCR reports "elapsed Ns / N blocks found", translation reports "elapsed Ns · model", and failures name the actual cause (timeout, unreachable, 401/429, out of credit…) |
| Settings | Toolbar dock, translation backend and API, OCR model, scrolling-capture mode, mask colors and more are all persisted; bilingual (zh/en) UI that follows the shell locale |

Settings file: `~/.config/denial-screenshots/settings.json`.
Set `DENIAL_SCREENSHOT_DIR` to override the capture directory
(default `~/Pictures/Screenshots`).
Local OCR / translation models download to `~/.local/share/denial-screenshots/models`.

## How it compares

Versus common screenshot annotation tools (✔ supported / ✘ not supported / — version-dependent):

| Dimension | denial-screenshots | mark-shot | QQ Snapshot |
|---|---|---|---|
| Form | **In-process Denial shell plugin**, no separate window | Standalone app | Bundled with the QQ client |
| Platform | Denial (Wayland / wlr-screencopy) | Linux (Wayland + X11) / Windows | Windows (feature-limited on Linux) |
| Open source | ✔ | ✔ | ✘ Closed source |
| Tools | Select / brush / line / arrow / rect / circle / text / highlighter / mosaic / eraser | Similar, plus laser pointer, magnifier, inverted rectangle, step badges, etc. | Basic annotation (rectangle / arrow / text / mosaic, etc.) |
| Edit drawn shapes | ✔ Recolor / resize on select, double-click to edit text | — | — |
| Pin to desktop | ✔ Images + text, stackable, aspect-locked resize | ✔ | ✔ |
| Scrolling capture | ✔ Auto-scroll injected via Denial's virtual keyboard | ✔ Portal-recording based | ✔ |
| OCR | ✔ **Local offline, multiple models** + online vision model | ✔ | ✔ (online) |
| Translation | ✔ **Local offline** (Argos / M2M) + 4 online protocols | ✔ Online only (OpenAI / Gemini / Claude / Tencent / Baidu / Youdao) | ✔ (online, Tencent) |
| Screen recording (GIF/video) | ✘ | ✔ | ✘ |
| Image-host upload / QR scan | ✘ | ✔ | — |
| Fully offline | ✔ | Partially (outside the Linux capture paths) | ✘ Requires QQ login |
| Visible OCR/translation progress | ✔ Real-time elapsed time and cause in an overlay | — | — |
| UI languages | ✔ Chinese / English | — | — |

The main differentiators: it's a **plugin embedded in the compositor** (not yet
another app), it does **local offline OCR + translation** with visible progress,
and it can **edit already-drawn shapes** in a **bilingual (zh/en) UI**.

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
shortcut (for example `Ctrl+Alt+A` for "Region capture (recommended)" and
`Super+S` for "Pin clipboard content").

### If activate fails with "No initial frame arrived within 20 seconds"

A cold custom runtime occasionally exceeds the hard 20 s timeout. Warm the AOT
runtime first, then switch:

```sh
denialctl ui build
denialctl ui activate /home/wu/.local/state/denial/plugins/candidates/<CANDIDATE_ID>/bundle
```

The same two commands restore the plugin after a reboot (when the UI falls back
to the packaged build); no rebuild is needed.

## Editor shortcuts (defaults; edit the `shortcuts` field in settings.json)

| Key | Action |
|---|---|
| `V` `B` `L` `A` `R` `C` `T` `H` `M` `E` | Select / brush / line / arrow / rect / circle / text / highlighter / mosaic / eraser |
| `Tab` | Collapse / reveal the toolbar |
| `Space` | Shortcut cheat sheet |
| `Ctrl+Z` / `Ctrl+R` | Undo / redo |
| `Ctrl+C` | Copy and close (copies the selected OCR text instead when text is selected) |
| `Super+R` | Scrolling capture |
| `Enter` | Save (file panel) |
| `Delete` / `Backspace` | Delete the selected shape |
| `[` / `]` | Nudge stroke width |
| `Alt+scroll` | Zoom the canvas; arrows pan the view once zoomed in |
| `Esc` | Close the editor (deselects first when a shape is selected; never writes the clipboard) |

## Configuring the translation API

Translation has two paths: **local models** (RapidOCR for recognition + Argos /
M2M-100 for offline translation) and an **online API**. To use an online API:

1. Editor toolbar → gear "Settings" → set Translation backend to "Online translation API".
2. Pick a protocol (defaults to OpenAI-compatible):

| Protocol | Fields | Notes |
|---|---|---|
| OpenAI-compatible | Endpoint / Key / Model | DeepSeek, OpenAI, Moonshot, local Ollama…; **model name is required** |
| Baidu | APP ID / Key | Free tier at fanyi-api.baidu.com |
| DeepL | Key | Keys ending in `…:fx` are the free tier |
| LibreTranslate | Endpoint / Key (optional) | Self-hosted or public instance |

3. The endpoint is completed automatically: `https://api.deepseek.com` → requests `https://api.deepseek.com/v1/chat/completions`; if the URL already ends with a version segment (`/v1`, Zhipu's `/v4`, …) only `/chat/completions` is appended; a full `.../chat/completions` URL is used as-is.
   Example: Zhipu — endpoint `https://open.bigmodel.cn/api/paas/v4`, model `glm-4-flash`.
4. Below the model field there are **preset chips** (guessed from the endpoint: Zhipu / DeepSeek / SiliconFlow / Moonshot / Qwen / OpenAI). Click one to fill it in instead of typing the model name by hand.
5. Press **"Test connection"** — it actually translates `Hello, world` and shows the result (with the round-trip time) or the error right below the button. **Use this to validate your config before taking any screenshot.**

**Recognition can go online too**: choose "online vision model" as the OCR
model and recognition reuses the API path (leave its endpoint/key blank to fall
back to the translation API's values and only supply a model that accepts image
input, e.g. `glm-4v-flash`).

What happens during an API call:

- 10s connect timeout, 60s response timeout; a timeout says so instead of spinning forever.
- 429 / 5xx are retried with backoff (2s, 4s) and the overlay says "rate limited, retrying in Ns"; timeouts and dropped connections are retried the same way.
- Failures quote the server's own reason, e.g. `translation failed (HTTP 429 · rate limited or out of credit): your account has reached the rate limit`.
- Zhipu endpoints get `thinking: disabled` automatically — otherwise reasoning models like GLM-4.6/4.7 spend tens of seconds on a translation.

To validate the backend on its own first:

```sh
curl https://api.deepseek.com/chat/completions \
  -H "Authorization: Bearer sk-your-key" \
  -H "Content-Type: application/json" \
  -d '{"model":"deepseek-chat","temperature":0,"messages":[{"role":"user","content":"1. hello"}]}'
```

Notes:

- **OCR runs before translation.** With local OCR, the first run installs `rapidocr`,
  `rapidocr-onnxruntime`, `ctranslate2`, `sentencepiece`, `pillow` and downloads
  the model (pip prefers the Tsinghua mirror, falling back to official PyPI) —
  expect a few minutes. To speed it up, pre-install:
  `pip install rapidocr rapidocr-onnxruntime onnxruntime ctranslate2 sentencepiece pillow -i https://pypi.tuna.tsinghua.edu.cn/simple`
- Config lives in `~/.config/denial-screenshots/settings.json`
  (`apiType` / `apiEndpoint` / `apiKey` / `apiModel` / `apiAppId`, plus
  `ocrApiEndpoint` / `ocrApiModel` / `ocrApiKey` for online OCR); restart the
  editor after editing it by hand.
- Translation **writes no log**; success and failure appear once in the editor's bottom snackbar (failures include the HTTP status and the server's reason).
- While translating, the overlay refreshes every second with the elapsed time and model name; while recognizing text it shows elapsed time and the number of blocks found, so you can tell "working" from "stuck".

## Dependencies

| Purpose | Requirement | Notes |
|---|---|---|
| Region / scrolling capture | `grim` (wlr-screencopy) | deniald implements wlr-screencopy, so grim works out of the box |
| Copy image | `wl-clipboard` (`sudo pacman -S wl-clipboard`) | Falls back to `xclip`; if neither works the file path is copied as text instead |
| Local OCR / translation | Python with `rapidocr`, `rapidocr-onnxruntime`, `onnxruntime`, `ctranslate2`, `sentencepiece`, `PIL` | First run downloads the OCR model and Argos language packs (HF mirror) |
| Auto-scroll for long captures | Denial virtual keyboard by default (no dependency) | Can switch to `wtype` / `ydotool` (install them yourself) or manual scrolling |
| API translation / online OCR | Any OpenAI-compatible endpoint, etc. | Fill in endpoint / key / model in the settings |

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
│   │   ├── selection_surface.dart    # selection plane + region toolbar (grim)
│   │   ├── scroll_capture.dart       # scrolling burst session
│   │   ├── scroll_stitch.dart        # long-image stitcher
│   │   ├── editor_surface.dart       # editor surface + capture directory watcher
│   │   ├── pin_surface.dart          # floating pinned snapshot
│   │   ├── clipboard.dart            # wl-copy / xclip + environment fallback
│   │   ├── exporter.dart             # image clipboard wrapper with path fallback
│   │   ├── screenshot_store.dart     # capture directory / newest-file lookup
│   │   ├── capture_flow_bus.dart     # action -> selection plane bus
│   │   ├── editor_bus.dart           # action <-> editor event bus
│   │   ├── l10n.dart                 # zh/en bilingual helper
│   │   └── editor/                   # editor UI, command stack, painting,
│   │                                 # settings, file panel, translation, sidecar
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
analyzer from that directory (the repository root is not a Pub workspace).

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
| No pixels after selecting | Make sure `grim` is installed and the compositor exposes wlr-screencopy (deniald does by default) |
| Copy does not reach the clipboard | Check `/tmp/denial-screenshot-clipboard.log` (exit codes and stderr of every attempt). A common cause is the plugin process having no `WAYLAND_DISPLAY`; the code now falls back to `$XDG_RUNTIME_DIR/wayland-N` |
| Long capture won't stitch / page | The target app may ignore the injected key: switch the paging key to `Space` in settings, change the injector (`wtype` / `ydotool`), or use manual scrolling |
| `prepare` / `plan` fail kit validation | The build-kit copy was edited by hand (for example injecting code into `denial_desktop`). Never edit files under `~/.local/state/denial/plugins/build-kits/`; run `denial-plugins prepare` again |
| Pinned card blocks the whole desktop | The input region must wrap only the card, see `lib/src/pin_surface.dart` |
| Desktop looks like the stock shell | A plugin composition uses the official plugins from the build-kit; customizations that live in your local workspace (`dart_shell/lib/main.dart`) are not included. Turn them into plugins and add them to the selection |

`README_COMPLETE.md` and `PLUGIN_RESTRUCTURE.md` are pre-refactor documents kept
for reference only.
