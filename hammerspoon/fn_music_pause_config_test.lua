local originalPackagePath = package.path
local originalLoadedModule = package.loaded.fn_music_pause
local originalLoadedCore = package.loaded.fn_music_pause_core
local originalLoadedPlayer = package.loaded.fn_music_pause_player
local originalHs = _G.hs
local originalConfig = rawget(_G, "fnMusicPauseConfig")

local function runTests()
  local source = debug.getinfo(1, "S").source
  local scriptPath = source:sub(1, 1) == "@" and source:sub(2) or source
  local scriptDir = scriptPath:match("^(.*)/[^/]*$") or "."

  package.path = scriptDir .. "/?.lua;" .. scriptDir .. "/?/init.lua"
  package.loaded.fn_music_pause = nil

  local configuredApps = {
    { processName = "Spotify", scriptName = "Spotify" },
  }
  local capturedOptions = nil

  package.loaded.fn_music_pause_core = {
    newController = function(player)
      return { player = player }
    end,
  }
  package.loaded.fn_music_pause_player = {
    new = function(options)
      capturedOptions = options
      return {}
    end,
  }

  _G.fnMusicPauseConfig = {
    apps = configuredApps,
    autoStart = false,
  }
  _G.hs = {
    configdir = "/tmp",
  }

  require("fn_music_pause")

  if capturedOptions.apps ~= configuredApps then
    error("fnMusicPauseConfig.apps was not passed to Player.new", 2)
  end

  return "fn_music_pause_config_test: ok"
end

local ok, result = pcall(runTests)
package.path = originalPackagePath
package.loaded.fn_music_pause = originalLoadedModule
package.loaded.fn_music_pause_core = originalLoadedCore
package.loaded.fn_music_pause_player = originalLoadedPlayer
_G.hs = originalHs
_G.fnMusicPauseConfig = originalConfig

if not ok then
  error(result, 0)
end

return result
