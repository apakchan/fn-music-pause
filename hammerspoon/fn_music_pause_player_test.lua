local source = debug.getinfo(1, "S").source
local scriptPath = source:sub(1, 1) == "@" and source:sub(2) or source
local scriptDir = scriptPath:match("^(.*)/[^/]*$") or "."

package.path = scriptDir .. "/?.lua;" .. scriptDir .. "/?/init.lua"
package.loaded.fn_music_pause_player = nil

local function assertEqual(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)), 2)
  end
end

local function assertContains(value, pattern, message)
  if string.find(value, pattern, 1, true) == nil then
    error(string.format("%s: expected %q to contain %q", message, tostring(value), tostring(pattern)), 2)
  end
end

local function withHsStub(options, callback)
  options = options or {}

  local previousHs = rawget(_G, "hs")
  local state = {
    events = {},
    scripts = {},
    scriptResponses = options.scriptResponses or {},
    runningApps = options.runningApps or {},
    axTitles = options.axTitles or {},
  }

  local hsStub = {
    application = {
      runningApplications = function()
        local apps = {}

        for processName, appState in pairs(state.runningApps) do
          if appState then
            local bundleID = type(appState) == "table" and appState.bundleID or nil
            table.insert(apps, {
              name = function()
                return processName
              end,
              bundleID = function()
                return bundleID
              end,
            })
          end
        end

        return apps
      end,
    },
    axuielement = {
      applicationElement = function(app)
        local title = state.axTitles[app:name()]
        local window = {
          attributeValue = function(_, attribute)
            if attribute == "AXTitle" then
              return title
            end
            return nil
          end,
        }

        return {
          attributeValue = function(_, attribute)
            if attribute == "AXFocusedWindow" then
              return window
            end
            if attribute == "AXWindows" then
              return { window }
            end
            return nil
          end,
        }
      end,
    },
    eventtap = {
      event = {
        newSystemKeyEvent = function(key, isDown)
          return {
            post = function()
              table.insert(state.events, { key = key, isDown = isDown })
            end,
          }
        end,
      },
    },
    osascript = {
      applescript = function(script)
        table.insert(state.scripts, script)
        local response = state.scriptResponses[#state.scripts] or { true, "stopped" }
        return response[1], response[2]
      end,
    },
  }

  _G.hs = hsStub

  local ok, err = pcall(callback, state)
  _G.hs = previousHs

  if not ok then
    error(err, 0)
  end
end

local function loadPlayer()
  package.loaded.fn_music_pause_player = nil
  return require("fn_music_pause_player")
end

local function testClosedMusicAppIsNotLaunched()
  withHsStub({
    runningApps = {},
  }, function(state)
    local Player = loadPlayer()
    local player = Player.new({
      apps = {
        { processName = "Music", scriptName = "Music", bundleID = "com.apple.Music" },
      },
    })

    local token = player:pauseIfPlaying()

    assertEqual(token, nil, "closed Music app does not create a resume token")
    assertEqual(#state.scripts, 0, "closed Music app is not contacted through AppleScript")
    assertEqual(#state.events, 0, "closed Music app does not fall back to the media key by default")
  end)
end

local function testDefaultModeDoesNotPressMediaKeyForPausedSupportedApp()
  withHsStub({
    runningApps = { Music = { bundleID = "com.apple.Music" } },
    scriptResponses = {
      { true, "paused" },
    },
  }, function(state)
    local Player = loadPlayer()
    local player = Player.new({
      apps = {
        { processName = "Music", scriptName = "Music" },
      },
    })

    local token = player:pauseIfPlaying()

    assertEqual(token, nil, "default mode does not create a resume token for an already paused app")
    assertEqual(#state.events, 0, "default mode does not press the media key for an already paused app")
  end)
end

local function testAppModeReturnsTokenOnlyWhenItActuallyPaused()
  withHsStub({
    runningApps = { Music = { bundleID = "com.apple.Music" } },
    scriptResponses = {
      { true, "fn-music-pause:did-pause" },
    },
  }, function(state)
    local Player = loadPlayer()
    local player = Player.new({
      mode = "app",
      apps = {
        { processName = "Music", scriptName = "Music" },
      },
    })

    local token = player:pauseIfPlaying()

    assertEqual(token.kind, "app", "app mode returns an app resume token after pausing")
    assertEqual(token.processName, "Music", "app token records the paused app")
    assertEqual(#state.events, 0, "app mode pauses through AppleScript instead of the media key")
  end)
end

local function testBrowserJavaScriptFailureUsesMediaKeyOnlyWhenAudible()
  withHsStub({
    runningApps = { ["Google Chrome"] = { bundleID = "com.google.Chrome" } },
    axTitles = {
      ["Google Chrome"] = "Example Video - playing audio - Google Chrome",
    },
    scriptResponses = {
      { false, nil, { NSLocalizedFailureReason = "JavaScript from Apple Events is disabled" } },
    },
  }, function(state)
    local Player = loadPlayer()
    local player = Player.new({
      mode = "app",
      apps = {
        { processName = "Google Chrome", scriptName = "Google Chrome", bundleID = "com.google.Chrome", kind = "chromium" },
      },
    })

    local token = player:pauseIfPlaying()

    assertEqual(token.kind, "mediaKey", "audible browser falls back to media key when JavaScript is unavailable")
    assertEqual(token.source, "audibleBrowser", "media key token records the audible-browser fallback")
    assertEqual(#state.events, 2, "audible browser fallback posts one media key press")
  end)
end

local function testBrowserJavaScriptFailureDoesNotUseMediaKeyWhenNotAudible()
  withHsStub({
    runningApps = { ["Google Chrome"] = { bundleID = "com.google.Chrome" } },
    axTitles = {
      ["Google Chrome"] = "Example Video - Google Chrome",
    },
    scriptResponses = {
      { false, nil, { NSLocalizedFailureReason = "JavaScript from Apple Events is disabled" } },
    },
  }, function(state)
    local Player = loadPlayer()
    local player = Player.new({
      mode = "app",
      apps = {
        { processName = "Google Chrome", scriptName = "Google Chrome", bundleID = "com.google.Chrome", kind = "chromium" },
      },
    })

    local token = player:pauseIfPlaying()

    assertEqual(token, nil, "non-audible browser does not create a resume token")
    assertEqual(#state.events, 0, "non-audible browser does not press the media key")
  end)
end

local function testMediaKeyModeRemainsExplicitToggleMode()
  withHsStub(nil, function(state)
    local Player = loadPlayer()
    local player = Player.new({ mode = "mediaKey" })

    local token = player:pauseIfPlaying()
    player:resume(token)

    assertEqual(token.kind, "mediaKey", "media key mode returns a media key token")
    assertEqual(#state.events, 4, "media key mode posts down/up events for pause and resume")
    assertEqual(state.events[1].key, "PLAY", "media key mode posts PLAY")
    assertEqual(state.events[1].isDown, true, "first media key event is key down")
    assertEqual(state.events[2].isDown, false, "second media key event is key up")
  end)
end

local function testBrowserAppPausesAndResumesCurrentTabMedia()
  withHsStub({
    runningApps = { Safari = { bundleID = "com.apple.Safari" } },
    scriptResponses = {
      { true, "fn-music-pause:did-pause" },
      { true, "fn-music-pause:did-resume" },
    },
  }, function(state)
    local Player = loadPlayer()
    local player = Player.new({
      mode = "app",
      apps = {
        { processName = "Safari", scriptName = "Safari", kind = "safari" },
      },
    })

    local token = player:pauseIfPlaying()
    local resumed = player:resume(token)

    assertEqual(token.kind, "browser", "browser app returns a browser resume token")
    assertEqual(resumed, true, "browser resume reports success")
    assertEqual(#state.events, 0, "browser app does not use the blind media key toggle")
    assertContains(state.scripts[1], "querySelectorAll('video,audio')", "browser pause script checks page media")
    assertContains(state.scripts[1], "fnMusicPausePaused", "browser pause script marks media it paused")
    assertContains(state.scripts[2], "fnMusicPausePaused", "browser resume script only resumes media it paused")
  end)
end

local tests = {
  testClosedMusicAppIsNotLaunched,
  testDefaultModeDoesNotPressMediaKeyForPausedSupportedApp,
  testAppModeReturnsTokenOnlyWhenItActuallyPaused,
  testBrowserJavaScriptFailureUsesMediaKeyOnlyWhenAudible,
  testBrowserJavaScriptFailureDoesNotUseMediaKeyWhenNotAudible,
  testMediaKeyModeRemainsExplicitToggleMode,
  testBrowserAppPausesAndResumesCurrentTabMedia,
}

for _, test in ipairs(tests) do
  test()
end

return "fn_music_pause_player_test: ok"
