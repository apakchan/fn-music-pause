# fn-music-pause

Pause media while holding `Fn`, resume when you release it.

This is a small [Hammerspoon](https://www.hammerspoon.org/) utility for macOS voice-input workflows. It was built for cases where you hold `Fn` to speak, but background music keeps playing while you are talking.

## How It Works

By default, `fn-music-pause` listens for macOS `Fn` flag changes:

- Short `Fn` tap: do nothing, so input methods and system shortcuts can use it normally.
- Hold `Fn` for at least `0.2` seconds: check supported media apps and browser tabs across open browser windows; pause only if something is currently playing.
- `Fn` up after a hold-triggered pause: resume only the source that was paused.

If the current source is already paused or stopped, pressing `Fn` leaves it paused.

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
  mode = "app",
  holdDelay = 0.2,
  alert = true,
  log = true,
}

require("fn_music_pause")
```

Options:

- `mode = "app"`: default. Uses app-specific AppleScript control for Spotify, Apple Music, Safari, Google Chrome, Brave Browser, Microsoft Edge, and Arc.
- `mode = "mediaKey"`: compatibility mode. Uses the system Play/Pause media key as a toggle.
- `holdDelay = 0.2`: seconds to hold `Fn` before media pause starts. Lower it, for example to `0.12` or `0.15`, if media starts pausing too late when you begin speaking.
- `mediaKeyFallback = true`: when `mode = "app"`, fall back to the media key only if no supported app is running.
- `alert = false`: disable the Hammerspoon startup alert.
- `log = false`: disable `~/.hammerspoon/fn-music-pause.log`.
- `logPath = "/path/to/log"`: use a custom log path.
- `autoStart = false`: load the module without starting the listener.

## Known Limitations

The default `app` mode only controls supported apps. Browser support targets media elements across open tabs, and depends on AppleScript/Automation permissions. Safari may also require enabling "Allow JavaScript from Apple Events" in the Develop menu.

The `mediaKey` mode is intentionally simple and low-latency, but it is a toggle. If the current media source is paused, pressing `Fn` can start playback. Use it only when you explicitly want the old media-key behavior.

## Test

With Hammerspoon running and the `hs` CLI installed:

```bash
./scripts/run-tests.sh
```

Expected output:

```text
fn_music_pause_core_test: ok
fn_music_pause_player_test: ok
fn_music_pause_test: ok
```

## License

MIT
