local M = {}

local defaultApps = {
  { processName = "Spotify", scriptName = "Spotify" },
  { processName = "Music", scriptName = "Music" },
}

local function appleScriptString(value)
  return string.format("%q", value)
end

local function pressPlayPauseKey()
  hs.eventtap.event.newSystemKeyEvent("PLAY", true):post()
  hs.eventtap.event.newSystemKeyEvent("PLAY", false):post()
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
      if hs.application.get(app.processName) ~= nil then
        local script = string.format([[
tell application %s
  if player state is playing then
    pause
    return "paused"
  end if
  return player state as string
end tell
]], appleScriptString(app.scriptName))

        local ok, result = hs.osascript.applescript(script)
        self.logger(string.format("checked %s: ok=%s result=%s", app.processName, tostring(ok), tostring(result)))

        if ok and result == "paused" then
          return {
            kind = "app",
            processName = app.processName,
            scriptName = app.scriptName,
          }
        end
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
]], appleScriptString(token.scriptName))

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
