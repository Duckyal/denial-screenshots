# Changelog

All notable changes to the `denialscreenshot` plugin are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
