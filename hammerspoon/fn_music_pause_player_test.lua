local originalPackagePath = package.path
local originalLoadedPlayer = package.loaded.fn_music_pause_player
local originalHs = _G.hs

local function runTests()
  local source = debug.getinfo(1, "S").source
  local scriptPath = source:sub(1, 1) == "@" and source:sub(2) or source
  local scriptDir = scriptPath:match("^(.*)/[^/]*$") or "."

  package.path = scriptDir .. "/?.lua;" .. scriptDir .. "/?/init.lua"
  package.loaded.fn_music_pause_player = nil

  local appleScriptResults = {}
  local appleScriptCalls = 0
  local appleScriptText = nil
  local postedKeys = {}
  local runningApps = {}

  local function makeRunningApp(name, bundleID)
    return {
      name = function()
        return name
      end,
      bundleID = function()
        return bundleID
      end,
    }
  end

  _G.hs = {
    application = {
      get = function()
        return {}
      end,
      runningApplications = function()
        return runningApps
      end,
    },
    osascript = {
      applescript = function(script)
        appleScriptCalls = appleScriptCalls + 1
        appleScriptText = script
        local result = table.remove(appleScriptResults, 1)
        return true, result
      end,
    },
    eventtap = {
      event = {
        newSystemKeyEvent = function(key, down)
          return {
            post = function()
              table.insert(postedKeys, { key = key, down = down })
            end,
          }
        end,
      },
    },
  }

  local Player = require("fn_music_pause_player")

  local function assertEqual(actual, expected, message)
    if actual ~= expected then
      error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)), 2)
    end
  end

  local function assertContains(haystack, needle, message)
    if not string.find(haystack, needle, 1, true) then
      error(string.format("%s: expected %s to contain %s", message, tostring(haystack), tostring(needle)), 2)
    end
  end

  local function makeAppPlayer()
    return Player.new({
      mode = "app",
      apps = {
        { processName = "Spotify", scriptName = "Spotify", bundleID = "com.spotify.client" },
      },
      logger = function() end,
    })
  end

  local function testAppModeDoesNotResumeAlreadyPausedPlayer()
    appleScriptResults = { "paused" }
    appleScriptCalls = 0
    runningApps = { makeRunningApp("Spotify", "com.spotify.client") }

    local token = makeAppPlayer():pauseIfPlaying()

    assertEqual(token, nil, "paused app does not create resume token")
    assertEqual(appleScriptCalls, 1, "running app is checked once")
  end

  local function testAppModeReturnsTokenOnlyWhenItPausedPlayback()
    appleScriptResults = { "paused-by-fn-music-pause" }
    appleScriptCalls = 0
    runningApps = { makeRunningApp("Spotify", "com.spotify.client") }

    local token = makeAppPlayer():pauseIfPlaying()

    assertEqual(token.kind, "app", "playing app creates app resume token")
    assertEqual(token.processName, "Spotify", "resume token records process name")
    assertContains(appleScriptText, 'tell application id "com.spotify.client"', "app mode targets running app bundle id")
  end

  local function testAppModeDoesNotAppleScriptAppsThatAreNotRunning()
    appleScriptResults = { "paused-by-fn-music-pause" }
    appleScriptCalls = 0
    runningApps = {}

    local token = makeAppPlayer():pauseIfPlaying()

    assertEqual(token, nil, "non-running app does not create resume token")
    assertEqual(appleScriptCalls, 0, "non-running app is not touched with AppleScript")
  end

  local tests = {
    testAppModeDoesNotResumeAlreadyPausedPlayer,
    testAppModeReturnsTokenOnlyWhenItPausedPlayback,
    testAppModeDoesNotAppleScriptAppsThatAreNotRunning,
  }

  for _, test in ipairs(tests) do
    test()
  end

  return "fn_music_pause_player_test: ok"
end

local ok, result = pcall(runTests)
package.path = originalPackagePath
package.loaded.fn_music_pause_player = originalLoadedPlayer
_G.hs = originalHs

if not ok then
  error(result, 0)
end

return result
