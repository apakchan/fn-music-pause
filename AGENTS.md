# Repository Guidelines

## Project Structure & Module Organization

This repository contains a small Hammerspoon utility for pausing media while `Fn` is held.

- `hammerspoon/fn_music_pause.lua`: Hammerspoon entry point, event tap setup, user configuration, and hold timing.
- `hammerspoon/fn_music_pause_core.lua`: pure controller state machine for `Fn` down/up behavior.
- `hammerspoon/fn_music_pause_player.lua`: player/browser integrations for Spotify, Music, Safari, Chrome-family browsers, and media-key fallback.
- `hammerspoon/*_test.lua`: Lua tests run through the Hammerspoon `hs` CLI.
- `scripts/run-tests.sh`: test runner that executes every `*_test.lua`.
- `install.sh`: copies runtime Lua files into `~/.hammerspoon`.

## Build, Test, and Development Commands

- `./scripts/run-tests.sh`: run the complete Hammerspoon test suite.
- `./install.sh`: install the current Lua modules into `~/.hammerspoon`.
- `hs -c 'hs.reload()'`: reload Hammerspoon after installing changes.

There is no separate build step. Development is edit, test, install, reload.

## Coding Style & Naming Conventions

Use plain Lua with two-space indentation. Keep modules small and return a module table named `M`. Prefer local helper functions for implementation details. Use snake_case file names matching existing module names, for example `fn_music_pause_player.lua`.

Keep event-tap callbacks fast and non-blocking. Any AppleScript, Accessibility, or media-control work should be deferred so the `Fn` event can pass through to input methods.

## Testing Guidelines

Tests are simple Lua scripts with local assertion helpers. Name new tests `hammerspoon/<module>_test.lua` so `scripts/run-tests.sh` picks them up automatically.

Prefer testing pure logic through stubs rather than controlling real apps. When stubbing global Hammerspoon APIs such as `_G.hs`, restore them with `pcall` cleanup so tests do not pollute the running Hammerspoon environment.

Run `./scripts/run-tests.sh` before installing or opening a pull request.

## Commit & Pull Request Guidelines

The current history uses a Conventional Commit style such as `feat: add fn music pause hammerspoon utility`. Keep commit subjects short, imperative, and scoped to one change.

Pull requests should include:

- A short behavior summary.
- Test output from `./scripts/run-tests.sh`.
- Notes for Hammerspoon permission or browser automation changes.
- Manual verification steps when media or browser behavior changes.

## Security & Configuration Tips

Avoid enabling broad fallbacks that can start paused media. Browser automation may require AppleScript/Automation permissions; document any new requirement in `README.md`.
