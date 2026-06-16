local M = {}

local defaultApps = {
  { processName = "Spotify", scriptName = "Spotify", bundleID = "com.spotify.client" },
  { processName = "Music", scriptName = "Music", bundleID = "com.apple.Music" },
  { processName = "NetEase Cloud Music", scriptName = "NetEase Cloud Music", bundleID = "com.netease.163music" },
  { processName = "QQMusic", scriptName = "QQMusic", bundleID = "com.tencent.QQMusicMac" },
}

local pausedByFnMusicPause = "paused-by-fn-music-pause"

local function appleScriptString(value)
  return string.format("%q", value)
end

local function pressPlayPauseKey()
  hs.eventtap.event.newSystemKeyEvent("PLAY", true):post()
  hs.eventtap.event.newSystemKeyEvent("PLAY", false):post()
end

local function appleScriptTarget(app)
  if app.bundleID ~= nil then
    return "id " .. appleScriptString(app.bundleID)
  end

  return appleScriptString(app.scriptName or app.processName)
end

local function runningApplicationFor(app)
  for _, runningApp in ipairs(hs.application.runningApplications()) do
    local matchesBundleID = app.bundleID ~= nil
      and runningApp:bundleID() == app.bundleID
    local matchesProcessName = runningApp:name() == app.processName

    if matchesBundleID or matchesProcessName then
      return runningApp
    end
  end

  return nil
end

function M.new(options)
  options = options or {}

  local player = {
    apps = options.apps or defaultApps,
    mode = options.mode or "mediaKey",
    mediaKeyFallback = options.mediaKeyFallback == true,
    logger = options.logger or function() end,
  }

  function player:pauseIfPlaying()
    if self.mode == "mediaKey" then
      pressPlayPauseKey()
      self.logger("paused with media key")
      return { kind = "mediaKey" }
    end

    for _, app in ipairs(self.apps) do
      if runningApplicationFor(app) ~= nil then
        local scriptTarget = appleScriptTarget(app)
        local script = string.format([[
tell application %s
  if player state is playing then
    pause
    return %s
  end if
  return player state as string
end tell
]], scriptTarget, appleScriptString(pausedByFnMusicPause))

        local ok, result = hs.osascript.applescript(script)
        self.logger(string.format("checked %s: ok=%s result=%s", app.processName, tostring(ok), tostring(result)))

        if ok and result == pausedByFnMusicPause then
          return {
            kind = "app",
            processName = app.processName,
            scriptTarget = scriptTarget,
          }
        end
      else
        self.logger(string.format("skipped %s: not running", app.processName))
      end
    end

    if self.mediaKeyFallback then
      pressPlayPauseKey()
      self.logger("paused with media key fallback")
      return { kind = "mediaKey" }
    end

    self.logger("nothing playing; skipped pause")
    return nil
  end

  function player:resume(token)
    if token.kind == "app" then
      local script = string.format([[
tell application %s
  play
end tell
]], token.scriptTarget)

      local ok, result = hs.osascript.applescript(script)
      self.logger(string.format("resumed %s: ok=%s result=%s", token.processName, tostring(ok), tostring(result)))
      return ok
    end

    if token.kind == "mediaKey" then
      pressPlayPauseKey()
      self.logger("resumed with media key")
      return true
    end

    self.logger("unknown resume token; skipped")
    return false
  end

  return player
end

return M
