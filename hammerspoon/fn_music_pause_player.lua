local M = {}

local didPauseResult = "fn-music-pause:did-pause"
local didResumeResult = "fn-music-pause:did-resume"

local defaultApps = {
  { processName = "Spotify", scriptName = "Spotify", bundleID = "com.spotify.client", kind = "mediaApp" },
  { processName = "Music", scriptName = "Music", bundleID = "com.apple.Music", kind = "mediaApp" },
  { processName = "Safari", scriptName = "Safari", bundleID = "com.apple.Safari", kind = "safari" },
  { processName = "Google Chrome", scriptName = "Google Chrome", bundleID = "com.google.Chrome", kind = "chromium" },
  { processName = "Brave Browser", scriptName = "Brave Browser", bundleID = "com.brave.Browser", kind = "chromium" },
  { processName = "Microsoft Edge", scriptName = "Microsoft Edge", bundleID = "com.microsoft.edgemac", kind = "chromium" },
  { processName = "Arc", scriptName = "Arc", bundleID = "company.thebrowser.Browser", kind = "chromium" },
}

local function appleScriptString(value)
  return string.format("%q", value)
end

local function pressPlayPauseKey()
  hs.eventtap.event.newSystemKeyEvent("PLAY", true):post()
  hs.eventtap.event.newSystemKeyEvent("PLAY", false):post()
end

local function sleepBriefly()
  if hs.timer ~= nil and hs.timer.usleep ~= nil then
    hs.timer.usleep(80000)
  end
end

local function browserPauseJavaScript()
  return [[
(function () {
  var pausedAny = false;
  var media = Array.prototype.slice.call(document.querySelectorAll('video,audio'));

  media.forEach(function (element) {
    if (!element.paused && !element.ended) {
      element.dataset.fnMusicPausePaused = 'true';
      element.pause();
      pausedAny = true;
    }
  });

  return pausedAny ? ']] .. didPauseResult .. [[' : 'not-playing';
})()
]]
end

local function browserResumeJavaScript()
  return [[
(function () {
  var resumedAny = false;
  var media = Array.prototype.slice.call(document.querySelectorAll('video,audio'));

  media.forEach(function (element) {
    if (element.dataset.fnMusicPausePaused === 'true') {
      delete element.dataset.fnMusicPausePaused;
      element.play();
      resumedAny = true;
    }
  });

  return resumedAny ? ']] .. didResumeResult .. [[' : 'not-paused';
})()
]]
end

local function browserScriptErrorResult(result)
  return type(result) == "string" and string.sub(result, 1, 13) == "script-error:"
end

local function browserScript(app, javascript, successResult, emptyResult)
  if app.kind == "safari" then
    return string.format([[
tell application %s
  if not (exists front window) then
    return "not-running"
  end if

  set matchedAny to false
  set lastError to ""

  repeat with browserWindow in windows
    repeat with browserTab in tabs of browserWindow
      try
        set tabResult to do JavaScript %s in browserTab
        if tabResult is %s then
          set matchedAny to true
        end if
      on error errorMessage
        set lastError to errorMessage
      end try
    end repeat
  end repeat

  if matchedAny then
    return %s
  end if

  if lastError is not "" then
    return "script-error:" & lastError
  end if

  return %s
end tell
]], appleScriptString(app.scriptName), appleScriptString(javascript), appleScriptString(successResult), appleScriptString(successResult), appleScriptString(emptyResult))
  end

  return string.format([[
tell application %s
  if not (exists front window) then
    return "not-running"
  end if

  set matchedAny to false
  set lastError to ""

  repeat with browserWindow in windows
    repeat with browserTab in tabs of browserWindow
      try
        set tabResult to execute browserTab javascript %s
        if tabResult is %s then
          set matchedAny to true
        end if
      on error errorMessage
        set lastError to errorMessage
      end try
    end repeat
  end repeat

  if matchedAny then
    return %s
  end if

  if lastError is not "" then
    return "script-error:" & lastError
  end if

  return %s
end tell
]], appleScriptString(app.scriptName), appleScriptString(javascript), appleScriptString(successResult), appleScriptString(successResult), appleScriptString(emptyResult))
end

local function isMediaApp(app)
  return app.kind == nil or app.kind == "app" or app.kind == "mediaApp"
end

local function isBrowserApp(app)
  return app.kind == "safari" or app.kind == "chromium"
end

local function isSupportedApp(app)
  return isMediaApp(app) or isBrowserApp(app)
end

local function findRunningApplication(app)
  if hs.application.runningApplications == nil then
    return nil
  end

  local ok, runningApps = pcall(hs.application.runningApplications)
  if not ok then
    return nil
  end

  for _, runningApp in ipairs(runningApps) do
    local nameOk, name = pcall(function()
      return runningApp:name()
    end)
    local bundleOk, bundleID = pcall(function()
      return runningApp:bundleID()
    end)

    if app.bundleID ~= nil and bundleOk and bundleID == app.bundleID then
      return runningApp
    end

    if nameOk and name == app.processName then
      return runningApp
    end
  end

  return nil
end

local function appIsRunning(app)
  return findRunningApplication(app) ~= nil
end

local function osascriptErrorMessage(details)
  if type(details) ~= "table" then
    return nil
  end

  return details.NSLocalizedFailureReason
    or details.OSAScriptErrorBriefMessageKey
    or details.OSAScriptErrorMessageKey
    or details.NSLocalizedDescription
end

local function titleLooksAudible(title)
  if type(title) ~= "string" then
    return false
  end

  local indicators = {
    "playing audio",
    "audio playing",
    "Playing Audio",
    "Audio Playing",
    "正在播放音频",
    "正在播放音訊",
  }

  for _, indicator in ipairs(indicators) do
    if string.find(title, indicator, 1, true) ~= nil then
      return true
    end
  end

  return false
end

local function axAttributeValue(element, attribute)
  if element == nil then
    return nil
  end

  local ok, result = pcall(function()
    return element:attributeValue(attribute)
  end)

  if ok then
    return result
  end

  return nil
end

local function axElementHasAudibleIndicator(element)
  local textAttributes = {
    "AXTitle",
    "AXDescription",
    "AXValue",
    "AXHelp",
    "AXLabel",
  }

  for _, attribute in ipairs(textAttributes) do
    if titleLooksAudible(axAttributeValue(element, attribute)) then
      return true
    end
  end

  return false
end

local function axElementLooksAudible(element, depth, visited)
  if element == nil or depth > 12 then
    return false
  end

  local elementID = tostring(element)
  if visited[elementID] then
    return false
  end
  visited[elementID] = true

  if axElementHasAudibleIndicator(element) then
    return true
  end

  if axAttributeValue(element, "AXRole") == "AXWebArea" then
    return false
  end

  local childAttributes = {
    "AXFocusedWindow",
    "AXWindows",
    "AXChildren",
    "AXChildrenInNavigationOrder",
    "AXVisibleChildren",
  }

  for _, attribute in ipairs(childAttributes) do
    local childValue = axAttributeValue(element, attribute)
    if type(childValue) == "table" then
      for _, child in ipairs(childValue) do
        if axElementLooksAudible(child, depth + 1, visited) then
          return true
        end
      end
    elseif childValue ~= nil and type(childValue) ~= "string" then
      if axElementLooksAudible(childValue, depth + 1, visited) then
        return true
      end
    end
  end

  return false
end

local function browserAxRoot(app)
  if hs.axuielement == nil or hs.axuielement.applicationElement == nil then
    return nil
  end

  local runningApp = findRunningApplication(app)
  if runningApp == nil then
    return nil
  end

  local ok, root = pcall(hs.axuielement.applicationElement, runningApp)
  if not ok or root == nil then
    return nil
  end

  return root
end

local function browserLooksAudible(app)
  local root = browserAxRoot(app)
  if root == nil then
    return false
  end

  return axElementLooksAudible(root, 0, {})
end

local function addAudibleTab(tabs, seen, windowIndex, tabIndex)
  if windowIndex == nil or tabIndex == nil then
    return
  end

  local key = tostring(windowIndex) .. ":" .. tostring(tabIndex)
  if seen[key] then
    return
  end

  seen[key] = true
  table.insert(tabs, {
    windowIndex = windowIndex,
    tabIndex = tabIndex,
  })
end

local function axCollectAudibleTabs(element, depth, visited, tabs, seenTabs, windowIndex)
  if element == nil or depth > 12 then
    return
  end

  local elementID = tostring(element)
  if visited[elementID] then
    return
  end
  visited[elementID] = true

  if axAttributeValue(element, "AXRole") == "AXWebArea" then
    return
  end

  local childAttributes = {
    "AXFocusedWindow",
    "AXChildren",
    "AXChildrenInNavigationOrder",
    "AXVisibleChildren",
  }

  for _, attribute in ipairs(childAttributes) do
    local childValue = axAttributeValue(element, attribute)
    if type(childValue) == "table" then
      local radioIndex = 0

      for _, child in ipairs(childValue) do
        if type(child) ~= "string" and axAttributeValue(child, "AXRole") == "AXRadioButton" then
          radioIndex = radioIndex + 1

          if axElementHasAudibleIndicator(child) then
            addAudibleTab(tabs, seenTabs, windowIndex, radioIndex)
          end
        end
      end

      for _, child in ipairs(childValue) do
        if type(child) ~= "string" then
          axCollectAudibleTabs(child, depth + 1, visited, tabs, seenTabs, windowIndex)
        end
      end
    elseif childValue ~= nil and type(childValue) ~= "string" then
      axCollectAudibleTabs(childValue, depth + 1, visited, tabs, seenTabs, windowIndex)
    end
  end
end

local function browserAudibleTabs(app)
  local root = browserAxRoot(app)
  if root == nil then
    return {}
  end

  local tabs = {}
  local seenTabs = {}
  local windows = axAttributeValue(root, "AXWindows")

  if type(windows) == "table" and #windows > 0 then
    for windowIndex, window in ipairs(windows) do
      axCollectAudibleTabs(window, 0, {}, tabs, seenTabs, windowIndex)
    end
  else
    axCollectAudibleTabs(root, 0, {}, tabs, seenTabs, 1)
  end

  return tabs
end

local function browserActiveTabIndex(app, windowIndex)
  local script = string.format([[
tell application %s
  if (count of windows) < %d then
    return "not-running"
  end if

  return active tab index of window %d as string
end tell
]], appleScriptString(app.scriptName), windowIndex, windowIndex)

  local ok, result = hs.osascript.applescript(script)
  if ok then
    return tonumber(result)
  end

  return nil
end

local function setBrowserActiveTab(app, tab)
  local script = string.format([[
tell application %s
  if (count of windows) < %d then
    return "no-window"
  end if

  if (count of tabs of window %d) < %d then
    return "no-tab"
  end if

  set active tab index of window %d to %d
  return "ok"
end tell
]],
    appleScriptString(app.scriptName),
    tab.windowIndex,
    tab.windowIndex,
    tab.tabIndex,
    tab.windowIndex,
    tab.tabIndex
  )

  local ok, result = hs.osascript.applescript(script)
  return ok and result == "ok"
end

local function browserWindowIndices(tabs)
  local indices = {}
  local seen = {}

  for _, tab in ipairs(tabs) do
    if not seen[tab.windowIndex] then
      seen[tab.windowIndex] = true
      table.insert(indices, tab.windowIndex)
    end
  end

  return indices
end

local function toggleBrowserTabsWithMediaKey(app, tabs)
  local originalTabs = {}
  local toggledTabs = {}

  for _, windowIndex in ipairs(browserWindowIndices(tabs)) do
    originalTabs[windowIndex] = browserActiveTabIndex(app, windowIndex)
  end

  for _, tab in ipairs(tabs) do
    if setBrowserActiveTab(app, tab) then
      sleepBriefly()
      pressPlayPauseKey()
      sleepBriefly()
      table.insert(toggledTabs, {
        windowIndex = tab.windowIndex,
        tabIndex = tab.tabIndex,
      })
    end
  end

  for windowIndex, tabIndex in pairs(originalTabs) do
    if tabIndex ~= nil then
      setBrowserActiveTab(app, {
        windowIndex = windowIndex,
        tabIndex = tabIndex,
      })
    end
  end

  return toggledTabs
end

function M.new(options)
  options = options or {}

  local player = {
    apps = options.apps or defaultApps,
    mode = options.mode or "app",
    mediaKeyFallback = options.mediaKeyFallback == true,
    logger = options.logger or function() end,
  }

  function player:pauseMediaApp(app)
    local script = string.format([[
tell application %s
  if player state is playing then
    pause
    return %s
  end if
  return player state as string
end tell
]], appleScriptString(app.scriptName), appleScriptString(didPauseResult))

    local ok, result = hs.osascript.applescript(script)
    self.logger(string.format("checked %s: ok=%s result=%s", app.processName, tostring(ok), tostring(result)))

    if ok and result == didPauseResult then
      return {
        kind = "app",
        processName = app.processName,
        scriptName = app.scriptName,
        bundleID = app.bundleID,
      }
    end

    return nil
  end

  function player:pauseBrowserApp(app)
    local script = browserScript(app, browserPauseJavaScript(), didPauseResult, "not-playing")
    local ok, result, details = hs.osascript.applescript(script)
    local errorMessage = osascriptErrorMessage(details)

    if errorMessage ~= nil then
      self.logger(string.format(
        "checked %s media: ok=%s result=%s error=%s",
        app.processName,
        tostring(ok),
        tostring(result),
        tostring(errorMessage)
      ))
    elseif browserScriptErrorResult(result) then
      self.logger(string.format("checked %s media: ok=%s result=%s", app.processName, tostring(ok), tostring(result)))
    else
      self.logger(string.format("checked %s media: ok=%s result=%s", app.processName, tostring(ok), tostring(result)))
    end

    if ok and result == didPauseResult then
      return {
        kind = "browser",
        processName = app.processName,
        scriptName = app.scriptName,
        bundleID = app.bundleID,
        appKind = app.kind,
      }
    end

    local audibleTabs = {}
    if app.kind == "chromium" then
      audibleTabs = browserAudibleTabs(app)
    end

    if #audibleTabs > 0 then
      local toggledTabs = toggleBrowserTabsWithMediaKey(app, audibleTabs)
      if #toggledTabs > 0 then
        self.logger(string.format("paused %d audible %s tab(s) with media key fallback", #toggledTabs, app.processName))
        return {
          kind = "browserMediaKeyTabs",
          processName = app.processName,
          scriptName = app.scriptName,
          bundleID = app.bundleID,
          appKind = app.kind,
          source = "audibleBrowserTabs",
          tabs = toggledTabs,
        }
      end
    end

    if browserLooksAudible(app) then
      pressPlayPauseKey()
      self.logger(string.format("paused audible %s with media key fallback", app.processName))
      return {
        kind = "mediaKey",
        processName = app.processName,
        source = "audibleBrowser",
      }
    end

    return nil
  end

  function player:pauseApp(app)
    if isMediaApp(app) then
      return self:pauseMediaApp(app)
    end

    if isBrowserApp(app) then
      return self:pauseBrowserApp(app)
    end

    self.logger(string.format("unsupported app kind for %s: %s", app.processName, tostring(app.kind)))
    return nil
  end

  function player:pauseIfPlaying()
    if self.mode == "mediaKey" then
      pressPlayPauseKey()
      self.logger("paused with media key")
      return { kind = "mediaKey" }
    end

    local checkedSupportedApp = false

    for _, app in ipairs(self.apps) do
      if isSupportedApp(app) and appIsRunning(app) then
        checkedSupportedApp = true

        local token = self:pauseApp(app)
        if token ~= nil then
          return token
        end
      end
    end

    if self.mediaKeyFallback and not checkedSupportedApp then
      pressPlayPauseKey()
      self.logger("paused with media key fallback")
      return { kind = "mediaKey" }
    end

    if self.mediaKeyFallback and checkedSupportedApp then
      self.logger("supported app present but not playing; skipped media key fallback")
    end

    self.logger("nothing playing; skipped pause")
    return nil
  end

  function player:resume(token)
    if token == nil then
      return false
    end

    if token.kind == "app" then
      if not appIsRunning(token) then
        self.logger(string.format("skipped resume for closed app %s", token.processName))
        return false
      end

      local script = string.format([[
tell application %s
  play
  return %s
end tell
]], appleScriptString(token.scriptName), appleScriptString(didResumeResult))

      local ok, result = hs.osascript.applescript(script)
      self.logger(string.format("resumed %s: ok=%s result=%s", token.processName, tostring(ok), tostring(result)))
      return ok
    end

    if token.kind == "browser" then
      if not appIsRunning(token) then
        self.logger(string.format("skipped resume for closed browser %s", token.processName))
        return false
      end

      local script = browserScript({
        scriptName = token.scriptName,
        kind = token.appKind,
      }, browserResumeJavaScript(), didResumeResult, "not-paused")
      local ok, result = hs.osascript.applescript(script)
      self.logger(string.format("resumed %s media: ok=%s result=%s", token.processName, tostring(ok), tostring(result)))
      return ok and result == didResumeResult
    end

    if token.kind == "browserMediaKeyTabs" then
      if not appIsRunning(token) then
        self.logger(string.format("skipped resume for closed browser %s", token.processName))
        return false
      end

      local toggledTabs = toggleBrowserTabsWithMediaKey({
        scriptName = token.scriptName,
      }, token.tabs or {})

      self.logger(string.format("resumed %d %s tab(s) with media key", #toggledTabs, token.processName))
      return #toggledTabs > 0
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
