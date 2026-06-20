local core = require("fn_music_pause_core")
local Player = require("fn_music_pause_player")

local M = {}

local userConfig = rawget(_G, "fnMusicPauseConfig") or {}
local logPath = userConfig.logPath or (hs.configdir .. "/fn-music-pause.log")
local holdDelay = tonumber(userConfig.holdDelay) or 0.15

if holdDelay < 0 then
  holdDelay = 0
end

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
  mode = userConfig.mode or "app",
  mediaKeyFallback = userConfig.mediaKeyFallback == true,
  logger = log,
})

local controller = core.newController(player)
local pendingTimers = {}
local pendingFnDownTimer = nil
local fnPauseActive = false

local function removePendingTimer(timer)
  for index, pendingTimer in ipairs(pendingTimers) do
    if pendingTimer == timer then
      table.remove(pendingTimers, index)
      return
    end
  end
end

local function stopPendingTimer(timer)
  if timer == nil then
    return
  end

  timer:stop()
  removePendingTimer(timer)
end

local function scheduleAfter(delay, callback)
  if hs.timer == nil or hs.timer.doAfter == nil then
    callback()
    return
  end

  local timer
  timer = hs.timer.doAfter(delay, function()
    removePendingTimer(timer)
    callback()
  end)
  table.insert(pendingTimers, timer)

  return timer
end

local function scheduleFnFlag(isDown)
  if isDown then
    if pendingFnDownTimer ~= nil or fnPauseActive then
      return
    end

    pendingFnDownTimer = scheduleAfter(holdDelay, function()
      pendingFnDownTimer = nil
      fnPauseActive = true
      core.handleFnFlag(controller, true)
    end)
    return
  end

  if pendingFnDownTimer ~= nil then
    stopPendingTimer(pendingFnDownTimer)
    pendingFnDownTimer = nil
    log("skipped short Fn press")
    return
  end

  if fnPauseActive then
    fnPauseActive = false
    scheduleAfter(0, function()
      core.handleFnFlag(controller, false)
    end)
  end
end

function M.start()
  if M.tap then
    M.tap:stop()
  end

  M.tap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(event)
    local flags = event:getFlags()
    scheduleFnFlag(flags.fn == true)
    return false
  end)

  M.tap:start()

  log(string.format(
    "started accessibility=%s secureInput=%s mode=%s holdDelay=%s",
    tostring(hs.accessibilityState()),
    tostring(secureInputEnabled()),
    tostring(userConfig.mode or "app"),
    tostring(holdDelay)
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

  for _, timer in ipairs(pendingTimers) do
    timer:stop()
  end
  pendingTimers = {}
  pendingFnDownTimer = nil
  fnPauseActive = false

  log("stopped")
end

function M.isRunning()
  return M.tap ~= nil and M.tap:isEnabled()
end

if userConfig.autoStart ~= false then
  M.start()
end

return M
