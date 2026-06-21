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

local function assertNotContains(value, pattern, message)
  if string.find(value, pattern, 1, true) ~= nil then
    error(string.format("%s: expected %q not to contain %q", message, tostring(value), tostring(pattern)), 2)
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
    frontmostApp = options.frontmostApp,
    axTitles = options.axTitles or {},
    axRoots = options.axRoots or {},
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
      frontmostApplication = function()
        local frontmost = state.frontmostApp
        if frontmost == nil then
          return nil
        end

        return {
          name = function()
            return frontmost.processName
          end,
          bundleID = function()
            return frontmost.bundleID
          end,
        }
      end,
    },
    axuielement = {
      applicationElement = function(app)
        local root = state.axRoots[app:name()]
        if root ~= nil then
          return root
        end

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
        return response[1], response[2], response[3]
      end,
    },
    timer = {
      usleep = function() end,
    },
  }

  if options.axuielementUnavailable then
    hsStub.axuielement = nil
    setmetatable(hsStub, {
      __index = function(_, key)
        if key == "axuielement" then
          error("module 'hs.axuielement' not found")
        end
        return nil
      end,
    })
  end

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

local function testFrontmostSupportedAppIsCheckedFirst()
  local audibleTab = {
    attributeValue = function(_, attribute)
      if attribute == "AXRole" then
        return "AXRadioButton"
      end
      if attribute == "AXDescription" then
        return "Playing Video - playing audio"
      end
      return nil
    end,
  }
  local tabStrip = {
    attributeValue = function(_, attribute)
      if attribute == "AXRole" then
        return "AXGroup"
      end
      if attribute == "AXChildrenInNavigationOrder" then
        return { audibleTab }
      end
      return nil
    end,
  }

  withHsStub({
    frontmostApp = { processName = "Google Chrome", bundleID = "com.google.Chrome" },
    runningApps = {
      Spotify = { bundleID = "com.spotify.client" },
      ["Google Chrome"] = { bundleID = "com.google.Chrome" },
    },
    axRoots = { ["Google Chrome"] = tabStrip },
  }, function()
    local batchJobs = nil
    local Player = loadPlayer()
    local player = Player.new({
      mode = "app",
      appleScriptBatchRunner = function(jobs)
        batchJobs = jobs
        return {
          { ok = true, result = "fn-music-pause:did-pause" },
          { ok = true, result = "paused" },
        }
      end,
      apps = {
        { processName = "Spotify", scriptName = "Spotify", bundleID = "com.spotify.client", kind = "mediaApp" },
        { processName = "Google Chrome", scriptName = "Google Chrome", bundleID = "com.google.Chrome", kind = "chromium" },
      },
    })

    local token = player:pauseIfPlaying()

    assertEqual(#batchJobs, 2, "frontmost browser and running media apps are batched together")
    assertEqual(batchJobs[1].app.processName, "Google Chrome", "frontmost browser is first in the batch")
    assertEqual(batchJobs[2].app.processName, "Spotify", "non-frontmost media app still joins the batch")
    assertEqual(token.kind, "browser", "frontmost browser success returns a browser token")
  end)
end

local function testRemainingAppsUseBatchRunnerAfterFrontmostMiss()
  withHsStub({
    frontmostApp = { processName = "Google Chrome", bundleID = "com.google.Chrome" },
    runningApps = {
      Spotify = { bundleID = "com.spotify.client" },
      Music = { bundleID = "com.apple.Music" },
      ["Google Chrome"] = { bundleID = "com.google.Chrome" },
    },
    axuielementUnavailable = true,
  }, function()
    local batchJobs = nil
    local Player = loadPlayer()
    local player = Player.new({
      mode = "app",
      appleScriptRunner = function()
        return true, "not-playing"
      end,
      appleScriptBatchRunner = function(jobs)
        batchJobs = jobs
        return {
          { ok = true, result = "not-playing" },
          { ok = true, result = "fn-music-pause:did-pause" },
          { ok = true, result = "paused" },
        }
      end,
      apps = {
        { processName = "Spotify", scriptName = "Spotify", bundleID = "com.spotify.client", kind = "mediaApp" },
        { processName = "Google Chrome", scriptName = "Google Chrome", bundleID = "com.google.Chrome", kind = "chromium" },
        { processName = "Music", scriptName = "Music", bundleID = "com.apple.Music", kind = "mediaApp" },
      },
    })

    local token = player:pauseIfPlaying()

    assertEqual(#batchJobs, 3, "running supported apps are submitted to the batch runner together")
    assertEqual(batchJobs[1].app.processName, "Google Chrome", "frontmost app is first in the batch")
    assertEqual(batchJobs[2].app.processName, "Spotify", "second running app is batched")
    assertEqual(batchJobs[3].app.processName, "Music", "third running app is batched")
    assertEqual(token.kind, "app", "single successful batched pause returns its token")
    assertEqual(token.processName, "Spotify", "batched pause token records the paused app")
  end)
end

local function testBatchedMultiplePauseTokensResumeAllSources()
  withHsStub({
    runningApps = {
      Spotify = { bundleID = "com.spotify.client" },
      Music = { bundleID = "com.apple.Music" },
    },
  }, function()
    local resumeCalls = 0
    local Player = loadPlayer()
    local player = Player.new({
      mode = "app",
      appleScriptRunner = function()
        resumeCalls = resumeCalls + 1
        return true, "fn-music-pause:did-resume"
      end,
      appleScriptBatchRunner = function()
        return {
          { ok = true, result = "fn-music-pause:did-pause" },
          { ok = true, result = "fn-music-pause:did-pause" },
        }
      end,
      apps = {
        { processName = "Spotify", scriptName = "Spotify", bundleID = "com.spotify.client", kind = "mediaApp" },
        { processName = "Music", scriptName = "Music", bundleID = "com.apple.Music", kind = "mediaApp" },
      },
    })

    local token = player:pauseIfPlaying()
    local resumed = player:resume(token)

    assertEqual(token.kind, "multiple", "multiple batched pauses return a grouped token")
    assertEqual(#token.tokens, 2, "grouped token records every paused source")
    assertEqual(resumed, true, "grouped token resumes successfully")
    assertEqual(resumeCalls, 2, "resume is called for every paused source")
  end)
end

local function testBatchedPauseResultIgnoresTrailingWhitespace()
  local function audibleTab()
    return {
      attributeValue = function(_, attribute)
        if attribute == "AXRole" then
          return "AXRadioButton"
        end
        if attribute == "AXDescription" then
          return "Playing Video - playing audio"
        end
        return nil
      end,
    }
  end

  local tabStrip = {
    attributeValue = function(_, attribute)
      if attribute == "AXRole" then
        return "AXGroup"
      end
      if attribute == "AXChildrenInNavigationOrder" then
        return { audibleTab() }
      end
      return nil
    end,
  }

  withHsStub({
    runningApps = {
      Spotify = { bundleID = "com.spotify.client" },
      ["Google Chrome"] = { bundleID = "com.google.Chrome" },
    },
    axRoots = { ["Google Chrome"] = tabStrip },
  }, function(state)
    local Player = loadPlayer()
    local player = Player.new({
      mode = "app",
      appleScriptBatchRunner = function()
        return {
          { ok = true, result = "paused " },
          { ok = true, result = "fn-music-pause:did-pause " },
        }
      end,
      apps = {
        { processName = "Spotify", scriptName = "Spotify", bundleID = "com.spotify.client", kind = "mediaApp" },
        { processName = "Google Chrome", scriptName = "Google Chrome", bundleID = "com.google.Chrome", kind = "chromium" },
      },
    })

    local token = player:pauseIfPlaying()

    assertEqual(token.kind, "browser", "trailing whitespace does not hide a successful browser pause")
    assertEqual(#state.events, 0, "successful browser pause with trailing whitespace does not fall back to media key")
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

local function testAppleScriptRunnerTimeoutDoesNotCreatePauseToken()
  withHsStub({
    runningApps = { ["Google Chrome"] = { bundleID = "com.google.Chrome" } },
  }, function(state)
    local calls = {}
    local Player = loadPlayer()
    local player = Player.new({
      mode = "app",
      appleScriptTimeout = 0.25,
      appleScriptRunner = function(script, timeout)
        table.insert(calls, { script = script, timeout = timeout })
        return false, "timeout", { OSAScriptErrorMessageKey = "timeout" }
      end,
      apps = {
        { processName = "Google Chrome", scriptName = "Google Chrome", bundleID = "com.google.Chrome", kind = "chromium" },
      },
    })

    local token = player:pauseIfPlaying()

    assertEqual(token, nil, "timed-out browser script does not create a pause token")
    assertEqual(#calls, 2, "timed-out browser script tries tab discovery and the fallback media scan")
    assertEqual(calls[1].timeout, 0.25, "configured AppleScript timeout is passed to the runner")
    assertEqual(#state.events, 0, "timed-out non-audible browser does not press the media key")
  end)
end

local function testTimedOutAudibleBrowserScriptDoesNotUseMediaKeyFallback()
  local audibleTab = {
    attributeValue = function(_, attribute)
      if attribute == "AXRole" then
        return "AXRadioButton"
      end
      if attribute == "AXDescription" then
        return "Playing Video - playing audio"
      end
      return nil
    end,
  }

  local tabStrip = {
    attributeValue = function(_, attribute)
      if attribute == "AXRole" then
        return "AXGroup"
      end
      if attribute == "AXChildrenInNavigationOrder" then
        return { audibleTab }
      end
      return nil
    end,
  }

  withHsStub({
    runningApps = { ["Google Chrome"] = { bundleID = "com.google.Chrome" } },
    axRoots = { ["Google Chrome"] = tabStrip },
    scriptResponses = {
      { true, "1" },
      { true, "ok" },
      { true, "ok" },
    },
  }, function(state)
    local Player = loadPlayer()
    local player = Player.new({
      mode = "app",
      appleScriptBatchRunner = function()
        return {
          { ok = false, result = "timeout", details = { OSAScriptErrorMessageKey = "timeout", exitCode = 124 } },
        }
      end,
      apps = {
        { processName = "Google Chrome", scriptName = "Google Chrome", bundleID = "com.google.Chrome", kind = "chromium" },
      },
    })

    local token = player:pauseIfPlaying()

    assertEqual(token.kind, "browser", "timed-out audible browser script keeps a safe browser resume token")
    assertEqual(#state.events, 0, "timed-out audible browser script does not press the media key")
  end)
end

local function testBrowserPauseUsesLastBrowserTokenBeforeFullScan()
  local audibleTab = {
    attributeValue = function(_, attribute)
      if attribute == "AXRole" then
        return "AXRadioButton"
      end
      if attribute == "AXDescription" then
        return "Playing Video - playing audio"
      end
      return nil
    end,
  }

  local tabStrip = {
    attributeValue = function(_, attribute)
      if attribute == "AXRole" then
        return "AXGroup"
      end
      if attribute == "AXChildrenInNavigationOrder" then
        return { audibleTab }
      end
      return nil
    end,
  }

  withHsStub({
    runningApps = { ["Google Chrome"] = { bundleID = "com.google.Chrome" } },
    axRoots = { ["Google Chrome"] = tabStrip },
    scriptResponses = {
      { true, "fn-music-pause:did-pause" },
    },
  }, function(state)
    local batchCalls = 0
    local Player = loadPlayer()
    local player = Player.new({
      mode = "app",
      appleScriptBatchRunner = function()
        batchCalls = batchCalls + 1
        if batchCalls == 1 then
          return {
            { ok = true, result = "fn-music-pause:did-pause" },
          }
        end

        return {
          { ok = true, result = "not-playing" },
        }
      end,
      apps = {
        { processName = "Google Chrome", scriptName = "Google Chrome", bundleID = "com.google.Chrome", kind = "chromium" },
      },
    })

    local firstToken = player:pauseIfPlaying()
    local secondToken = player:pauseIfPlaying()

    assertEqual(firstToken.kind, "browser", "first pause records a browser token")
    assertEqual(secondToken.kind, "browser", "second pause can return the cached browser token")
    assertEqual(#state.scripts, 1, "cached pause tries the previous tab before the batch scan")
    assertContains(state.scripts[1], "set tabTargets to {{1, 1}}", "cached pause targets the previous browser tab")
    assertEqual(batchCalls, 2, "full scan still runs after cache hit to catch other sources")
  end)
end

local function testBrowserPauseCacheMissFallsBackToFullScan()
  local audibleTab = {
    attributeValue = function(_, attribute)
      if attribute == "AXRole" then
        return "AXRadioButton"
      end
      if attribute == "AXDescription" then
        return "Playing Video - playing audio"
      end
      return nil
    end,
  }

  local tabStrip = {
    attributeValue = function(_, attribute)
      if attribute == "AXRole" then
        return "AXGroup"
      end
      if attribute == "AXChildrenInNavigationOrder" then
        return { audibleTab }
      end
      return nil
    end,
  }

  withHsStub({
    runningApps = { ["Google Chrome"] = { bundleID = "com.google.Chrome" } },
    axRoots = { ["Google Chrome"] = tabStrip },
    scriptResponses = {
      { true, "not-playing" },
    },
  }, function(state)
    local batchCalls = 0
    local Player = loadPlayer()
    local player = Player.new({
      mode = "app",
      appleScriptBatchRunner = function()
        batchCalls = batchCalls + 1
        return {
          { ok = true, result = "fn-music-pause:did-pause" },
        }
      end,
      apps = {
        { processName = "Google Chrome", scriptName = "Google Chrome", bundleID = "com.google.Chrome", kind = "chromium" },
      },
    })

    local firstToken = player:pauseIfPlaying()
    local secondToken = player:pauseIfPlaying()

    assertEqual(firstToken.kind, "browser", "first pause records a browser token")
    assertEqual(secondToken.kind, "browser", "cache miss falls back to the normal browser scan")
    assertEqual(#state.scripts, 1, "cache miss checks the previous tab once")
    assertEqual(batchCalls, 2, "normal batch scan runs after cache miss")
    assertEqual(#state.events, 0, "cache miss does not use the media key")
  end)
end

local function testDirectTimedOutAudibleBrowserScriptDoesNotUseMediaKeyFallback()
  local audibleTab = {
    attributeValue = function(_, attribute)
      if attribute == "AXRole" then
        return "AXRadioButton"
      end
      if attribute == "AXDescription" then
        return "Playing Video - playing audio"
      end
      return nil
    end,
  }

  local tabStrip = {
    attributeValue = function(_, attribute)
      if attribute == "AXRole" then
        return "AXGroup"
      end
      if attribute == "AXChildrenInNavigationOrder" then
        return { audibleTab }
      end
      return nil
    end,
  }

  withHsStub({
    runningApps = { ["Google Chrome"] = { bundleID = "com.google.Chrome" } },
    axRoots = { ["Google Chrome"] = tabStrip },
    scriptResponses = {
      { false, "timeout", { OSAScriptErrorMessageKey = "timeout", exitCode = 124 } },
      { true, "1" },
      { true, "ok" },
      { true, "ok" },
    },
  }, function(state)
    local Player = loadPlayer()
    local player = Player.new({
      mode = "app",
    })

    local token = player:pauseApp({
      processName = "Google Chrome",
      scriptName = "Google Chrome",
      bundleID = "com.google.Chrome",
      kind = "chromium",
    })

    assertEqual(token.kind, "browser", "direct timed-out audible browser script keeps a safe browser resume token")
    assertEqual(#state.events, 0, "direct timed-out audible browser script does not press the media key")
  end)
end

local function testBrowserJavaScriptFailureUsesRecursiveAxAudioIndicator()
  local audibleBackgroundTab = {
    attributeValue = function(_, attribute)
      if attribute == "AXTitle" then
        return "Video Tab - 正在播放音频"
      end
      return nil
    end,
  }
  local focusedWindow = {
    attributeValue = function(_, attribute)
      if attribute == "AXTitle" then
        return "Current Reading Tab - Google Chrome"
      end
      if attribute == "AXChildren" then
        return { audibleBackgroundTab }
      end
      return nil
    end,
  }
  local root = {
    attributeValue = function(_, attribute)
      if attribute == "AXFocusedWindow" then
        return focusedWindow
      end
      if attribute == "AXWindows" then
        return { focusedWindow }
      end
      return nil
    end,
  }

  withHsStub({
    runningApps = { ["Google Chrome"] = { bundleID = "com.google.Chrome" } },
    axRoots = { ["Google Chrome"] = root },
    scriptResponses = {
      { true, "script-error:JavaScript from Apple Events is disabled" },
      { true, "1" },
      { true, "ok" },
      { true, "ok" },
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

    assertEqual(token.kind, "mediaKey", "background audible tab falls back to media key")
    assertEqual(token.source, "audibleBrowser", "media key token records the audible-browser fallback")
    assertEqual(#state.events, 2, "background audible tab fallback posts one media key press")
  end)
end

local function testBrowserJavaScriptFailureUsesDeepTabStripAudioIndicator()
  local audibleTab = {
    attributeValue = function(_, attribute)
      if attribute == "AXRole" then
        return "AXRadioButton"
      end
      if attribute == "AXDescription" then
        return "Video Tab - 正在播放音频"
      end
      return nil
    end,
  }

  local function wrapInNavigationOrder(child, levels)
    if levels == 0 then
      return child
    end

    local wrappedChild = wrapInNavigationOrder(child, levels - 1)
    return {
      attributeValue = function(_, attribute)
        if attribute == "AXRole" then
          return "AXGroup"
        end
        if attribute == "AXChildrenInNavigationOrder" then
          return { wrappedChild }
        end
        return nil
      end,
    }
  end

  local root = wrapInNavigationOrder(audibleTab, 9)

  withHsStub({
    runningApps = { ["Google Chrome"] = { bundleID = "com.google.Chrome" } },
    axRoots = { ["Google Chrome"] = root },
    scriptResponses = {
      { true, "script-error:JavaScript from Apple Events is disabled" },
      { true, "1" },
      { true, "ok" },
      { true, "ok" },
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

    assertEqual(token.kind, "browserMediaKeyTabs", "deep audible browser tab returns a tab-scoped media-key token")
    assertEqual(token.source, "audibleBrowserTabs", "deep media key token records the audible-browser-tabs fallback")
    assertEqual(#token.tabs, 1, "deep audible browser tab records one tab")
    assertEqual(#state.events, 2, "deep audible tab fallback posts one media key press")
  end)
end

local function testBrowserJavaScriptFailureUsesMediaKeyForEachAudibleTab()
  local function tab(description)
    return {
      attributeValue = function(_, attribute)
        if attribute == "AXRole" then
          return "AXRadioButton"
        end
        if attribute == "AXDescription" then
          return description
        end
        return nil
      end,
    }
  end

  local tabStrip = {
    attributeValue = function(_, attribute)
      if attribute == "AXRole" then
        return "AXGroup"
      end
      if attribute == "AXChildrenInNavigationOrder" then
        return {
          tab("Paused Video"),
          tab("Playing One - 正在播放音频"),
          tab("Playing Two - playing audio"),
        }
      end
      return nil
    end,
  }

  withHsStub({
    runningApps = { ["Google Chrome"] = { bundleID = "com.google.Chrome" } },
    axRoots = { ["Google Chrome"] = tabStrip },
    scriptResponses = {
      { true, "script-error:JavaScript from Apple Events is disabled" },
      { true, "1" },
      { true, "ok" },
      { true, "ok" },
      { true, "ok" },
      { true, "1" },
      { true, "ok" },
      { true, "ok" },
      { true, "ok" },
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
    player:resume(token)

    assertEqual(token.kind, "browserMediaKeyTabs", "audible browser tabs return a tab-scoped media-key token")
    assertEqual(#token.tabs, 2, "only currently audible tabs are recorded")
    assertEqual(token.tabs[1].tabIndex, 2, "first paused tab index is recorded")
    assertEqual(token.tabs[2].tabIndex, 3, "second paused tab index is recorded")
    assertEqual(#state.events, 8, "two tabs are paused and resumed with one media key press each")
  end)
end

local function testChromiumTargetsAudibleTabsBeforeFullScan()
  local function tab(description)
    return {
      attributeValue = function(_, attribute)
        if attribute == "AXRole" then
          return "AXRadioButton"
        end
        if attribute == "AXDescription" then
          return description
        end
        return nil
      end,
    }
  end

  local tabStrip = {
    attributeValue = function(_, attribute)
      if attribute == "AXRole" then
        return "AXGroup"
      end
      if attribute == "AXChildrenInNavigationOrder" then
        return {
          tab("Paused Video"),
          tab("Playing Video - playing audio"),
        }
      end
      return nil
    end,
  }

  withHsStub({
    runningApps = { ["Google Chrome"] = { bundleID = "com.google.Chrome" } },
    axRoots = { ["Google Chrome"] = tabStrip },
    scriptResponses = {
      { true, "fn-music-pause:did-pause" },
      { true, "fn-music-pause:did-resume" },
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
    local resumed = player:resume(token)

    assertEqual(token.kind, "browser", "audible Chromium tab pauses through targeted browser JavaScript")
    assertEqual(#token.tabs, 1, "targeted browser token records only audible tabs")
    assertEqual(token.tabs[1].tabIndex, 2, "targeted browser token records the audible tab index")
    assertEqual(resumed, true, "targeted browser token resumes through JavaScript")
    assertContains(state.scripts[1], "set tabTargets to {{1, 2}}", "pause script targets only audible tabs")
    assertContains(state.scripts[1], "execute browserTab javascript", "pause script executes JavaScript on target tabs")
    assertNotContains(state.scripts[1], "repeat with browserTab in tabs of browserWindow", "pause script avoids full-tab scan")
    assertContains(state.scripts[2], "set tabTargets to {{1, 2}}", "resume script targets only previously paused tabs")
    assertNotContains(state.scripts[2], "repeat with browserTab in tabs of browserWindow", "resume script avoids full-tab scan")
  end)
end

local function testBrowserPauseCancelsPendingResume()
  local function tab(description)
    return {
      attributeValue = function(_, attribute)
        if attribute == "AXRole" then
          return "AXRadioButton"
        end
        if attribute == "AXDescription" then
          return description
        end
        return nil
      end,
    }
  end

  local tabStrip = {
    attributeValue = function(_, attribute)
      if attribute == "AXRole" then
        return "AXGroup"
      end
      if attribute == "AXChildrenInNavigationOrder" then
        return {
          tab("Playing Video - playing audio"),
        }
      end
      return nil
    end,
  }

  withHsStub({
    runningApps = { ["Google Chrome"] = { bundleID = "com.google.Chrome" } },
    axRoots = { ["Google Chrome"] = tabStrip },
    scriptResponses = {
      { true, "fn-music-pause:did-pause" },
      { true, "fn-music-pause:did-resume" },
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
    player:resume(token)

    assertContains(state.scripts[1], "fnMusicPauseResuming", "pause script can cancel a pending resume")
    assertContains(state.scripts[2], "fnMusicPauseResuming", "resume script marks pending playback")
  end)
end

local function testChromiumSkipsMediaScriptWhenTabStripHasNoAudibleTabs()
  local function tab(description)
    return {
      attributeValue = function(_, attribute)
        if attribute == "AXRole" then
          return "AXRadioButton"
        end
        if attribute == "AXDescription" then
          return description
        end
        return nil
      end,
    }
  end

  local tabStrip = {
    attributeValue = function(_, attribute)
      if attribute == "AXRole" then
        return "AXGroup"
      end
      if attribute == "AXChildrenInNavigationOrder" then
        return {
          tab("Paused Video"),
          tab("Reading Tab"),
        }
      end
      return nil
    end,
  }

  withHsStub({
    runningApps = { ["Google Chrome"] = { bundleID = "com.google.Chrome" } },
    axRoots = { ["Google Chrome"] = tabStrip },
  }, function(state)
    local Player = loadPlayer()
    local player = Player.new({
      mode = "app",
      apps = {
        { processName = "Google Chrome", scriptName = "Google Chrome", bundleID = "com.google.Chrome", kind = "chromium" },
      },
    })

    local token = player:pauseIfPlaying()

    assertEqual(token, nil, "Chromium with no audible tabs does not create a pause token")
    assertEqual(#state.scripts, 0, "Chromium with reliable silent tabstrip skips AppleScript media scan")
    assertEqual(#state.events, 0, "Chromium with no audible tabs does not press media key")
  end)
end

local function testChromiumFallsBackToFullScanWhenAxModuleUnavailable()
  withHsStub({
    axuielementUnavailable = true,
    runningApps = { ["Google Chrome"] = { bundleID = "com.google.Chrome" } },
    scriptResponses = {
      { true, "" },
      { true, "fn-music-pause:did-pause" },
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

    assertEqual(token.kind, "browser", "Chromium falls back to full media scan when AX is unavailable")
    assertContains(state.scripts[2], "repeat with browserTab in tabs of browserWindow", "fallback script scans browser tabs")
  end)
end

local function testChromiumFallbackChunksDiscoveredTabs()
  withHsStub({
    axuielementUnavailable = true,
    runningApps = { ["Google Chrome"] = { bundleID = "com.google.Chrome" } },
  }, function()
    local batchJobs = nil
    local Player = loadPlayer()
    local player = Player.new({
      mode = "app",
      browserTabChunkSize = 2,
      appleScriptRunner = function()
        return true, "1:1\n1:2\n1:3\n1:4\n1:5"
      end,
      appleScriptBatchRunner = function(jobs)
        batchJobs = jobs
        return {
          { ok = true, result = "not-playing" },
          { ok = true, result = "fn-music-pause:did-pause" },
          { ok = true, result = "not-playing" },
        }
      end,
      apps = {
        { processName = "Google Chrome", scriptName = "Google Chrome", bundleID = "com.google.Chrome", kind = "chromium" },
      },
    })

    local token = player:pauseIfPlaying()

    assertEqual(#batchJobs, 3, "discovered browser tabs are split into bounded chunks")
    assertEqual(#batchJobs[1].targetTabs, 2, "first chunk contains two tabs")
    assertEqual(#batchJobs[2].targetTabs, 2, "second chunk contains two tabs")
    assertEqual(#batchJobs[3].targetTabs, 1, "last chunk contains the remaining tab")
    assertContains(batchJobs[2].script, "set tabTargets to {{1, 3}, {1, 4}}", "chunk script targets only its tab range")
    assertEqual(token.kind, "browser", "successful chunk returns a browser token")
    assertEqual(#token.tabs, 2, "token records the paused tab chunk")
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

local function testSafariBrowserAppPausesAndResumesAllTabsMedia()
  withHsStub({
    runningApps = { Safari = { bundleID = "com.apple.Safari" } },
    scriptResponses = {
      { true, "1:1\n1:2" },
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
    assertContains(state.scripts[1], "set tabLines to {}", "browser first discovers tab indexes")
    assertContains(state.scripts[2], "set tabTargets to {{1, 1}, {1, 2}}", "browser pause script targets discovered tabs")
    assertContains(state.scripts[2], "querySelectorAll('video,audio')", "browser pause script checks page media")
    assertContains(state.scripts[2], "fnMusicPausePaused", "browser pause script marks media it paused")
    assertContains(state.scripts[3], "fnMusicPausePaused", "browser resume script only resumes media it paused")
    assertContains(state.scripts[3], "fn-music-pause:did-resume", "browser resume script uses the resume sentinel")
  end)
end

local function testChromiumBrowserScriptChecksEveryTab()
  withHsStub({
    runningApps = { ["Google Chrome"] = { bundleID = "com.google.Chrome" } },
    scriptResponses = {
      { true, "1:1\n1:2" },
      { true, "fn-music-pause:did-pause" },
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

    assertEqual(token.kind, "browser", "chromium browser returns a browser resume token")
    assertContains(state.scripts[1], "set tabLines to {}", "chromium first discovers tab indexes")
    assertContains(state.scripts[2], "set tabTargets to {{1, 1}, {1, 2}}", "chromium pause script targets discovered tabs")
    assertContains(state.scripts[2], "execute browserTab javascript", "chromium pause script runs JavaScript against target tabs")
    assertNotContains(state.scripts[2], "active tab", "chromium pause script is not limited to the active tab")
  end)
end

local tests = {
  testClosedMusicAppIsNotLaunched,
  testDefaultModeDoesNotPressMediaKeyForPausedSupportedApp,
  testAppModeReturnsTokenOnlyWhenItActuallyPaused,
  testFrontmostSupportedAppIsCheckedFirst,
  testRemainingAppsUseBatchRunnerAfterFrontmostMiss,
  testBatchedMultiplePauseTokensResumeAllSources,
  testBatchedPauseResultIgnoresTrailingWhitespace,
  testBrowserJavaScriptFailureUsesMediaKeyOnlyWhenAudible,
  testBrowserJavaScriptFailureDoesNotUseMediaKeyWhenNotAudible,
  testAppleScriptRunnerTimeoutDoesNotCreatePauseToken,
  testTimedOutAudibleBrowserScriptDoesNotUseMediaKeyFallback,
  testBrowserPauseUsesLastBrowserTokenBeforeFullScan,
  testBrowserPauseCacheMissFallsBackToFullScan,
  testDirectTimedOutAudibleBrowserScriptDoesNotUseMediaKeyFallback,
  testBrowserJavaScriptFailureUsesRecursiveAxAudioIndicator,
  testBrowserJavaScriptFailureUsesDeepTabStripAudioIndicator,
  testBrowserJavaScriptFailureUsesMediaKeyForEachAudibleTab,
  testChromiumTargetsAudibleTabsBeforeFullScan,
  testBrowserPauseCancelsPendingResume,
  testChromiumSkipsMediaScriptWhenTabStripHasNoAudibleTabs,
  testChromiumFallsBackToFullScanWhenAxModuleUnavailable,
  testChromiumFallbackChunksDiscoveredTabs,
  testMediaKeyModeRemainsExplicitToggleMode,
  testSafariBrowserAppPausesAndResumesAllTabsMedia,
  testChromiumBrowserScriptChecksEveryTab,
}

for _, test in ipairs(tests) do
  test()
end

return "fn_music_pause_player_test: ok"
