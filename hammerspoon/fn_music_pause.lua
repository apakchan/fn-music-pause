local core = require("fn_music_pause_core")
local Player = require("fn_music_pause_player")

local M = {}

local userConfig = rawget(_G, "fnMusicPauseConfig") or {}
local logPath = userConfig.logPath or (hs.configdir .. "/fn-music-pause.log")
local holdDelay = tonumber(userConfig.holdDelay) or 0.15
local appleScriptTimeout = tonumber(userConfig.appleScriptTimeout) or nil
local appleScriptConcurrency = tonumber(userConfig.appleScriptConcurrency) or nil
local browserTabChunkSize = tonumber(userConfig.browserTabChunkSize) or nil
local rightOptionKeyCode = 61
local triggerKeySettingName = "fnMusicPause.triggerKey"
local triggerKeyLabels = {
  fn = "Fn",
  rightOption = "Right Option",
}

local function validTriggerKey(value)
  return value == "fn" or value == "rightOption"
end

local function storedTriggerKey()
  if hs.settings == nil or hs.settings.get == nil then
    return nil
  end

  local ok, value = pcall(function()
    return hs.settings.get(triggerKeySettingName)
  end)

  if ok and validTriggerKey(value) then
    return value
  end

  return nil
end

local function configuredTriggerKey()
  local stored = storedTriggerKey()
  if stored ~= nil then
    return stored
  end

  if validTriggerKey(userConfig.triggerKey) then
    return userConfig.triggerKey
  end

  return "fn"
end

local triggerKey = configuredTriggerKey()

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
  appleScriptTimeout = appleScriptTimeout,
  appleScriptConcurrency = appleScriptConcurrency,
  browserTabChunkSize = browserTabChunkSize,
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

local function scheduleTriggerFlag(isDown)
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
    log(string.format("skipped short %s press", triggerKey))
    return
  end

  if fnPauseActive then
    fnPauseActive = false
    scheduleAfter(0, function()
      core.handleFnFlag(controller, false)
    end)
  end
end

local function triggerFlagForEvent(event)
  local flags = event:getFlags()

  if triggerKey == "rightOption" then
    if event.getKeyCode == nil or event:getKeyCode() ~= rightOptionKeyCode then
      return nil
    end

    return flags.alt == true
  end

  return flags.fn == true
end

local function saveTriggerKey(value)
  if hs.settings == nil or hs.settings.set == nil then
    return
  end

  pcall(function()
    hs.settings.set(triggerKeySettingName, value)
  end)
end

local function triggerKeyLabel(value)
  return triggerKeyLabels[value] or tostring(value)
end

local function triggerKeyMenu()
  return {
    { title = "Trigger Key: " .. triggerKeyLabel(triggerKey), disabled = true },
    { title = "Fn", checked = triggerKey == "fn", fn = function() M.setTriggerKey("fn") end },
    { title = "Right Option", checked = triggerKey == "rightOption", fn = function() M.setTriggerKey("rightOption") end },
  }
end

local function refreshMenu()
  if userConfig.menuBar == false or hs.menubar == nil or hs.menubar.new == nil then
    return
  end

  if M.menu == nil then
    M.menu = hs.menubar.new()
  end

  if M.menu == nil then
    return
  end

  M.menu:setTitle("Fn Pause")
  M.menu:setMenu(triggerKeyMenu())
end

function M.setTriggerKey(value)
  if not validTriggerKey(value) then
    return false
  end

  local changed = triggerKey ~= value
  triggerKey = value
  saveTriggerKey(value)

  if changed and M.isRunning ~= nil and M.isRunning() then
    M.stop()
    M.start()
  else
    refreshMenu()
  end

  log(string.format("set triggerKey=%s", triggerKey))
  return true
end

function M.start()
  if M.tap then
    M.tap:stop()
  end

  M.tap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(event)
    local isDown = triggerFlagForEvent(event)

    if isDown ~= nil then
      scheduleTriggerFlag(isDown)
    end

    return false
  end)

  M.tap:start()
  refreshMenu()

  log(string.format(
    "started accessibility=%s secureInput=%s mode=%s holdDelay=%s triggerKey=%s",
    tostring(hs.accessibilityState()),
    tostring(secureInputEnabled()),
    tostring(userConfig.mode or "app"),
    tostring(holdDelay),
    tostring(triggerKey)
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
