local core = require("fn_music_pause_core")
local Player = require("fn_music_pause_player")

local M = {}

local userConfig = rawget(_G, "fnMusicPauseConfig") or {}
local logPath = userConfig.logPath or (hs.configdir .. "/fn-music-pause.log")

local function log(message)
  if userConfig.log == false then
    return
  end

  local file = io.open(logPath, "a")
  if file then
    file:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. tostring(message) .. "\n")
    file:close()
  end
end

local function secureInputEnabled()
  local ok, result = pcall(hs.eventtap.isSecureInputEnabled)
  if ok then
    return result
  end
  return "unknown"
end

local player = Player.new({
  mode = userConfig.mode or "mediaKey",
  mediaKeyFallback = userConfig.mediaKeyFallback == true,
  logger = log,
})

local controller = core.newController(player)

function M.start()
  if M.tap then
    M.tap:stop()
  end

  M.tap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(event)
    local flags = event:getFlags()
    core.handleFnFlag(controller, flags.fn == true)
    return false
  end)

  M.tap:start()

  log(string.format(
    "started accessibility=%s secureInput=%s mode=%s",
    tostring(hs.accessibilityState()),
    tostring(secureInputEnabled()),
    tostring(userConfig.mode or "mediaKey")
  ))

  if userConfig.alert ~= false then
    if hs.accessibilityState() then
      hs.alert.show("Fn music pause loaded", 1)
    else
      hs.alert.show("Fn music pause needs Accessibility", 4)
    end
  end
end

function M.stop()
  if M.tap then
    M.tap:stop()
    M.tap = nil
  end
  log("stopped")
end

function M.isRunning()
  return M.tap ~= nil and M.tap:isEnabled()
end

if userConfig.autoStart ~= false then
  M.start()
end

return M
