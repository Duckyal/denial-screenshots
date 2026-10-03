# AGENTS.md - Screenshot plugin

Denial plugin that annotates the compositor's screenshots inside the shell.

## Repository workflow

Trusted development lands on `dev` first. Run validation before pushing.
For plugin development, refer to `docs/DEVELOPMENT.md` and the
[Denial plugin development guide](https://github.com/denialwm/denial/blob/dev/docs/PLUGIN_DEVELOPMENT.md).

## Plugin structure

This repository follows the [denial-plugins](https://github.com/denialwm/denial-plugins)
collection format:

- `plugins/denialscreenshot/` — the installable Dart package
- `plugins.yaml` — discovery catalog for Denial's Plugin Manager
- `compositor/` — legacy standalone editor app, kept for UI prototyping only

The plugin is a plain Dart package. It contains no Rust, no FFI and no
standalone Flutter application: capture belongs to `deniald`.

## Validate

```sh
cd plugins/denialscreenshot
"$DENIAL_PLUGIN_FLUTTER" pub get
"$DENIAL_PLUGIN_DART" format --output=none --set-exit-if-changed lib
"$DENIAL_PLUGIN_DART" analyze --fatal-infos lib
```

## Install and apply

```sh
denial-plugins --local add "$PWD"
denial-plugins plan
denial-plugins build CANDIDATE_ID
denial-plugins activate CANDIDATE_ID
```

## Rules

- Contribution classes (`@Provides`) stay in `lib/denialscreenshot.dart`; the
  composition generator only scans the entry library.
- Never import `denial_dart_shell` or any package's `lib/src`. Use
  `denial_sdk` / `denial_flutter_sdk` public libraries only.
- Disposables (`ui.Image`, controllers, subscriptions) are owned by their
  widget or surface state.
- Do not add runtime plugin scanning, reflection, or dynamic registries.

## Graphical session control

Never log out, terminate, restart, or otherwise stop the user's local graphical
session on the user's behalf. When testing requires a fresh local Denial
session, tell the user that a restart is required and wait for the user to log
off and return to their display manager themselves.

## User-owned visual validation

The user performs all visual validation. Never capture or inspect screenshots,
judge rendered output, launch applications for visual inspection, or create UI
state for visual QA without explicit user authorization.
