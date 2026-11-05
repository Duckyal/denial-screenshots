# Changelog

All notable changes to the `denialscreenshot` plugin are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.2.0] — 2026-11-01

Synced from `dev`: PPT-style live text editing, OCR text multi-select, unified file panels, smart window picking, and a rebuilt scrolling-capture loop.

### Added
- **Live text editing (WYSIWYG)**: text renders as you type with the exact committed layout — drag a box for a wrapping text frame (auto font shrink to fit), click for a free line; double-click any text to edit in place. Toolbar color / size / font / bold / background apply instantly to the text being edited. `Enter` = newline, `Ctrl+Enter` or clicking the canvas = commit, `Esc` = cancel (original untouched).
- **Text background color**: a new "A" toolbar button with a preset palette (six translucent + five solid) plus a "none" cell; the panel lays out 2×6 or 6×2 following the toolbar dock direction; applies with the same priority as color (editing command > selected object > new-text default).
- **OCR text multi-select in cursor mode**: drag over recognized text to select; `Ctrl`+drag appends ranges (a new range on the same line replaces the old one); each range carries a ✕ anchor (screen-size-stable geometry) — `Ctrl`+click it to drop that range; `Ctrl+C` copies all ranges joined in selection order.
- **Smart window picking at capture**: hovering a window in region-select mode highlights it, single click takes the whole window (QQ / WeChat style).
- **Unified file panels**: save / open / model-directory pickers now share one `PathChooserPanel` shell (same size, colors, keyboard nav); the selected file row highlights live as you type; missing `.png` is auto-appended on save; `Esc` walks the directory history back.
- **Bold toggle** for text and translations (`textBold`, historical commands default to bold).

### Changed
- **Scrolling capture rebuilt around probe observation**: a 4px probe band detects page movement — full frames are only grabbed on settle edges (no more motion-blurred frames), and bottom detection no longer wastes double captures; the pointer stays visible throughout (needed to hit the "finish" button) and is erased from every stitched frame.
- Toolbar clicks no longer commit an in-progress text edit — only clicks on the canvas (outside every editor UI overlay: dock, options row, palette, font / background panels, cheat sheet, settings, file panel) commit.
- Background OCR completion no longer interrupts typing (stable `GlobalKey` / `ValueKey` identities keep the live editor's element alive when the selection layer mounts).
- Undo/redo tooltips read the actual configured bindings; dead code cleaned up, `--fatal-infos` restored green.

### Fixed
- Anchor ✕ glyph: the second stroke had its endpoint on the wrong side, drawing a hook instead of a cross; the anchor radius is now scale-invariant (constant ~9 screen px) so it stays crisp when the canvas fits down.
- Text-edit focus and commit edge cases: selection state no longer leaks between the text and cursor tools (clicking empty canvas clears the stale selected object); background changes refresh a brand-new draft instantly; the selection outline shows for objects picked with the text tool (frame only, no resize handles).
- Manifest `provides` counts realigned with code (3 ShellAction + 3 ShellSurface).
- Bilingual coverage completed for settings-panel, OCR and translation-progress strings.

### Documentation
- READMEs (zh/en): shortcut table extended with live-text and multi-select keys; plugin README slimmed to match reality; `AGENTS.md` capture-ownership corrected; roadmap doc (`docs/ROADMAP.md`) added.

## [0.1.0] — 2026-10-18

### Added
- Bilingual UI (zh/en) across the plugin, following the shell locale via the inline `L.pick` / `L.s` helper.
- Highlighter editor tool (drawn as a straight stroke, custom width, colored cursor).
- Local translation model folder override, validated through the sidecar's model-discovery logic.
- Optional local OCR model directory plus a dedicated OCR API config (falls back to the translation API).
- Multiple local OCR models (PP-OCR v3/v4/v5/v6) and an online vision-model OCR path.
- Cursor-free region capture: borrows the shell's hide-cursor signal so static frames don't leak the pointer.
- Smart system cursor in select mode: resize handles, image-text I-beam, and default arrow picked by what's under the pointer.
- Scroll-based long screenshot with automatic stitching.

### Changed
- Stroke-width range for brush and shapes narrowed to a shared 2–10.
- Text box default font size adapts to the box; font steps follow Excel size tiers.
- Copy button reports copying / copied / failed with icon and color.
- Toolbar dock and mask secondary menu refined; second-level palette no longer repeats black.
- Editor can open an in-memory capture directly, skipping the directory poll.

### Fixed
- Chinese locale no longer crashes `TextField` into a grey block (mount `GlobalMaterialLocalizations` delegates).
- Selection toolbar avoids stacking on the same screen edge as the result window.
- OCR/translation progress, and failures, now surface the real cause (timeout, unreachable, 401/429, out of credit) instead of a bare spinner.
- Bilingual coverage completed for settings-panel, OCR and directory-selection strings, including the sidecar's progress and error messages.

### Documentation
- Added a feature-comparison table against mark-shot and QQ Snapshot to both READMEs.
