local source = debug.getinfo(1, "S").source
local scriptPath = source:sub(1, 1) == "@" and source:sub(2) or source
local scriptDir = scriptPath:match("^(.*)/[^/]*$") or "."

package.path = scriptDir .. "/?.lua;" .. scriptDir .. "/?/init.lua"

local function assertEqual(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)), 2)
  end
end

local function testDefaultConfigUsesStateAwareAppMode()
  local previousConfig = rawget(_G, "fnMusicPauseConfig")
  local previousHs = rawget(_G, "hs")
  local previousModule = package.loaded.fn_music_pause
  local previousCore = package.loaded.fn_music_pause_core
  local previousPlayer = package.loaded.fn_music_pause_player
  local capturedOptions = nil

  _G.fnMusicPauseConfig = {
    autoStart = false,
    log = false,
  }

  _G.hs = {
    configdir = "/tmp",
  }

  package.loaded.fn_music_pause = nil
  package.loaded.fn_music_pause_core = {
    newController = function(player)
      return { player = player }
    end,
    handleFnFlag = function() end,
  }
  package.loaded.fn_music_pause_player = {
    new = function(options)
      capturedOptions = options
      return {}
    end,
  }

  local ok, err = pcall(function()
    require("fn_music_pause")
    assertEqual(capturedOptions.mode, "app", "default module config uses state-aware app mode")
  end)

  package.loaded.fn_music_pause = previousModule
  package.loaded.fn_music_pause_core = previousCore
  package.loaded.fn_music_pause_player = previousPlayer
  _G.fnMusicPauseConfig = previousConfig
  _G.hs = previousHs

  if not ok then
    error(err, 0)
  end
end

local function testFnEventReturnsBeforePauseWorkRuns()
  local previousConfig = rawget(_G, "fnMusicPauseConfig")
  local previousHs = rawget(_G, "hs")
  local previousModule = package.loaded.fn_music_pause
  local previousCore = package.loaded.fn_music_pause_core
  local previousPlayer = package.loaded.fn_music_pause_player
  local tapCallback = nil
  local scheduledTimers = {}
  local handledFlags = {}

  _G.fnMusicPauseConfig = {
    alert = false,
    log = false,
  }

  _G.hs = {
    configdir = "/tmp",
    accessibilityState = function()
      return true
    end,
    alert = {
      show = function() end,
    },
    eventtap = {
      isSecureInputEnabled = function()
        return false
      end,
      event = {
        types = {
          flagsChanged = 12,
        },
      },
      new = function(_, callback)
        tapCallback = callback
        return {
          start = function() end,
          stop = function() end,
          isEnabled = function()
            return true
          end,
        }
      end,
    },
    timer = {
      doAfter = function(_, callback)
        local timer = {
          stop = function() end,
        }
        table.insert(scheduledTimers, {
          delay = _,
          callback = callback,
          timer = timer,
        })
        return timer
      end,
    },
  }

  package.loaded.fn_music_pause = nil
  package.loaded.fn_music_pause_core = {
    newController = function(player)
      return { player = player }
    end,
    handleFnFlag = function(_, isDown)
      table.insert(handledFlags, isDown)
    end,
  }
  package.loaded.fn_music_pause_player = {
    new = function()
      return {}
    end,
  }

  local ok, err = pcall(function()
    local module = require("fn_music_pause")
    local returned = tapCallback({
      getFlags = function()
        return { fn = true }
      end,
    })

    assertEqual(returned, false, "Fn event is not swallowed")
    assertEqual(#handledFlags, 0, "Fn work is deferred until after the event returns")
    assertEqual(#scheduledTimers, 1, "Fn work is scheduled asynchronously")
    assertEqual(scheduledTimers[1].delay, 0.2, "Fn down uses the default hold delay")

    scheduledTimers[1].callback()

    assertEqual(#handledFlags, 1, "scheduled Fn work runs")
    assertEqual(handledFlags[1], true, "scheduled Fn work keeps the flag state")

    module.stop()
  end)

  package.loaded.fn_music_pause = previousModule
  package.loaded.fn_music_pause_core = previousCore
  package.loaded.fn_music_pause_player = previousPlayer
  _G.fnMusicPauseConfig = previousConfig
  _G.hs = previousHs

  if not ok then
    error(err, 0)
  end
end

local function testShortFnPressDoesNotPause()
  local previousConfig = rawget(_G, "fnMusicPauseConfig")
  local previousHs = rawget(_G, "hs")
  local previousModule = package.loaded.fn_music_pause
  local previousCore = package.loaded.fn_music_pause_core
  local previousPlayer = package.loaded.fn_music_pause_player
  local tapCallback = nil
  local scheduledTimers = {}
  local handledFlags = {}

  _G.fnMusicPauseConfig = {
    alert = false,
    holdDelay = 0.2,
    log = false,
  }

  _G.hs = {
    configdir = "/tmp",
    accessibilityState = function()
      return true
    end,
    alert = {
      show = function() end,
    },
    eventtap = {
      isSecureInputEnabled = function()
        return false
      end,
      event = {
        types = {
          flagsChanged = 12,
        },
      },
      new = function(_, callback)
        tapCallback = callback
        return {
          start = function() end,
          stop = function() end,
          isEnabled = function()
            return true
          end,
        }
      end,
    },
    timer = {
      doAfter = function(delay, callback)
        local timer = {
          delay = delay,
          callback = callback,
          stopped = false,
          stop = function(self)
            self.stopped = true
          end,
        }
        table.insert(scheduledTimers, timer)
        return timer
      end,
    },
  }

  package.loaded.fn_music_pause = nil
  package.loaded.fn_music_pause_core = {
    newController = function(player)
      return { player = player }
    end,
    handleFnFlag = function(_, isDown)
      table.insert(handledFlags, isDown)
    end,
  }
  package.loaded.fn_music_pause_player = {
    new = function()
      return {}
    end,
  }

  local ok, err = pcall(function()
    local module = require("fn_music_pause")
    tapCallback({
      getFlags = function()
        return { fn = true }
      end,
    })
    tapCallback({
      getFlags = function()
        return { fn = false }
      end,
    })

    assertEqual(#scheduledTimers, 1, "short Fn press schedules only the hold timer")
    assertEqual(scheduledTimers[1].delay, 0.2, "short Fn press uses configured hold delay")
    assertEqual(scheduledTimers[1].stopped, true, "short Fn press cancels the hold timer")
    assertEqual(#handledFlags, 0, "short Fn press never reaches pause logic")

    module.stop()
  end)

  package.loaded.fn_music_pause = previousModule
  package.loaded.fn_music_pause_core = previousCore
  package.loaded.fn_music_pause_player = previousPlayer
  _G.fnMusicPauseConfig = previousConfig
  _G.hs = previousHs

  if not ok then
    error(err, 0)
  end
end

local function testLongFnPressPausesAfterHoldDelayAndResumesOnRelease()
  local previousConfig = rawget(_G, "fnMusicPauseConfig")
  local previousHs = rawget(_G, "hs")
  local previousModule = package.loaded.fn_music_pause
  local previousCore = package.loaded.fn_music_pause_core
  local previousPlayer = package.loaded.fn_music_pause_player
  local tapCallback = nil
  local scheduledTimers = {}
  local handledFlags = {}

  _G.fnMusicPauseConfig = {
    alert = false,
    holdDelay = 0.2,
    log = false,
  }

  _G.hs = {
    configdir = "/tmp",
    accessibilityState = function()
      return true
    end,
    alert = {
      show = function() end,
    },
    eventtap = {
      isSecureInputEnabled = function()
        return false
      end,
      event = {
        types = {
          flagsChanged = 12,
        },
      },
      new = function(_, callback)
        tapCallback = callback
        return {
          start = function() end,
          stop = function() end,
          isEnabled = function()
            return true
          end,
        }
      end,
    },
    timer = {
      doAfter = function(delay, callback)
        local timer = {
          delay = delay,
          callback = callback,
          stopped = false,
          stop = function(self)
            self.stopped = true
          end,
        }
        table.insert(scheduledTimers, timer)
        return timer
      end,
    },
  }

  package.loaded.fn_music_pause = nil
  package.loaded.fn_music_pause_core = {
    newController = function(player)
      return { player = player }
    end,
    handleFnFlag = function(_, isDown)
      table.insert(handledFlags, isDown)
    end,
  }
  package.loaded.fn_music_pause_player = {
    new = function()
      return {}
    end,
  }

  local ok, err = pcall(function()
    local module = require("fn_music_pause")
    tapCallback({
      getFlags = function()
        return { fn = true }
      end,
    })

    assertEqual(#handledFlags, 0, "long Fn press does not pause before the hold delay")
    scheduledTimers[1].callback()

    assertEqual(#handledFlags, 1, "long Fn press pauses after the hold delay")
    assertEqual(handledFlags[1], true, "long Fn press sends Fn down to pause logic")

    tapCallback({
      getFlags = function()
        return { fn = false }
      end,
    })

    assertEqual(#handledFlags, 1, "Fn release work is also deferred")
    assertEqual(scheduledTimers[2].delay, 0, "Fn release schedules immediate async resume")

    scheduledTimers[2].callback()

    assertEqual(#handledFlags, 2, "Fn release resumes after async callback")
    assertEqual(handledFlags[2], false, "Fn release sends Fn up to pause logic")

    module.stop()
  end)

  package.loaded.fn_music_pause = previousModule
  package.loaded.fn_music_pause_core = previousCore
  package.loaded.fn_music_pause_player = previousPlayer
  _G.fnMusicPauseConfig = previousConfig
  _G.hs = previousHs

  if not ok then
    error(err, 0)
  end
end

local tests = {
  testDefaultConfigUsesStateAwareAppMode,
  testFnEventReturnsBeforePauseWorkRuns,
  testShortFnPressDoesNotPause,
  testLongFnPressPausesAfterHoldDelayAndResumesOnRelease,
}

for _, test in ipairs(tests) do
  test()
end

return "fn_music_pause_test: ok"
