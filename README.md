# fn-music-pause

Pause media while holding `Fn`, resume when you release it.

This is a small [Hammerspoon](https://www.hammerspoon.org/) utility for macOS voice-input workflows. It was built for cases where you hold `Fn` to speak, but background music keeps playing while you are talking.

## How It Works

By default, `fn-music-pause` listens for macOS `Fn` flag changes:

- `Fn` down: send the system Play/Pause media key once.
- `Fn` up: send the system Play/Pause media key once again.

The listener does not swallow the `Fn` event, so your voice input method can still receive it.

## Requirements

- macOS
- Hammerspoon
- Hammerspoon Accessibility permission in macOS System Settings
- The `hs` CLI is optional for tests, but useful:

```lua
hs.ipc.cliInstall()
```

## Install

Clone the repo and run:

```bash
./install.sh
```

Then open or reload Hammerspoon.

The installer copies the Lua modules into `~/.hammerspoon`. If `~/.hammerspoon/init.lua` already exists, it creates a timestamped backup before appending:

```lua
require("fn_music_pause")
```

## Manual Install

Copy these files into `~/.hammerspoon`:

```text
hammerspoon/fn_music_pause.lua
hammerspoon/fn_music_pause_core.lua
hammerspoon/fn_music_pause_player.lua
```

Then add this to `~/.hammerspoon/init.lua`:

```lua
require("fn_music_pause")
```

Reload Hammerspoon.

## Configuration

Optional configuration can be set before `require("fn_music_pause")`:

```lua
fnMusicPauseConfig = {
  mode = "mediaKey",
  alert = true,
  log = true,
}

require("fn_music_pause")
```

Options:

- `mode = "mediaKey"`: default. Uses the system Play/Pause media key.
- `mode = "app"`: experimental. Attempts app-specific AppleScript control for Spotify and Apple Music.
- `mediaKeyFallback = true`: when `mode = "app"`, fall back to the media key if no supported app is detected as playing.
- `alert = false`: disable the Hammerspoon startup alert.
- `log = false`: disable `~/.hammerspoon/fn-music-pause.log`.
- `logPath = "/path/to/log"`: use a custom log path.
- `autoStart = false`: load the module without starting the listener.

## Known Limitations

The default `mediaKey` mode is intentionally simple and low-latency, but it is a toggle. Use it when media is already playing before you press `Fn`.

If nothing is playing, pressing `Fn` may start the current media source until you release `Fn`.

The experimental `app` mode avoids that toggle behavior for supported apps, but AppleScript support can vary by app and can block if a player is unresponsive.

## Test

With Hammerspoon running and the `hs` CLI installed:

```bash
./scripts/run-tests.sh
```

Expected output:

```text
fn_music_pause_core_test: ok
```

## License

MIT
