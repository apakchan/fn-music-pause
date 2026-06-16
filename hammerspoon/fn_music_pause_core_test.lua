local originalPackagePath = package.path
local originalLoadedCore = package.loaded.fn_music_pause_core

local function runTests()
  local source = debug.getinfo(1, "S").source
  local scriptPath = source:sub(1, 1) == "@" and source:sub(2) or source
  local scriptDir = scriptPath:match("^(.*)/[^/]*$") or "."

  package.path = scriptDir .. "/?.lua;" .. scriptDir .. "/?/init.lua"
  package.loaded.fn_music_pause_core = nil

  local core = require("fn_music_pause_core")

local function assertEqual(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)), 2)
  end
end

local function makePlayer(pauseResults)
  local player = {
    pauseCalls = 0,
    resumeCalls = 0,
    resumedTokens = {},
    pauseResults = pauseResults or {},
  }

  function player:pauseIfPlaying()
    self.pauseCalls = self.pauseCalls + 1
    return self.pauseResults[self.pauseCalls]
  end

  function player:resume(token)
    self.resumeCalls = self.resumeCalls + 1
    table.insert(self.resumedTokens, token)
  end

  return player
end

local function testPressPausesOnlyOnceUntilRelease()
  local player = makePlayer({ "spotify" })
  local controller = core.newController(player)

  core.handleFnFlag(controller, true)
  core.handleFnFlag(controller, true)

  assertEqual(player.pauseCalls, 1, "pressing Fn repeatedly while held pauses only once")
  assertEqual(player.resumeCalls, 0, "holding Fn does not resume")
end

local function testReleaseResumesOnlyWhenPauseSucceeded()
  local player = makePlayer({ "spotify" })
  local controller = core.newController(player)

  core.handleFnFlag(controller, true)
  core.handleFnFlag(controller, false)
  core.handleFnFlag(controller, false)

  assertEqual(player.pauseCalls, 1, "pause called once")
  assertEqual(player.resumeCalls, 1, "release resumes once")
  assertEqual(player.resumedTokens[1], "spotify", "release resumes the paused source")
end

local function testReleaseDoesNotStartPlaybackWhenNothingPaused()
  local player = makePlayer({ nil })
  local controller = core.newController(player)

  core.handleFnFlag(controller, true)
  core.handleFnFlag(controller, false)

  assertEqual(player.pauseCalls, 1, "pause attempted once")
  assertEqual(player.resumeCalls, 0, "release does not resume if pause found nothing playing")
end

local tests = {
  testPressPausesOnlyOnceUntilRelease,
  testReleaseResumesOnlyWhenPauseSucceeded,
  testReleaseDoesNotStartPlaybackWhenNothingPaused,
}

for _, test in ipairs(tests) do
  test()
end

  return "fn_music_pause_core_test: ok"
end

local ok, result = pcall(runTests)
package.path = originalPackagePath
package.loaded.fn_music_pause_core = originalLoadedCore

if not ok then
  error(result, 0)
end

return result
