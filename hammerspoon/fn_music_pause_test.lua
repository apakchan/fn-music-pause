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
    assertEqual(scheduledTimers[1].delay, 0.15, "Fn down uses the default hold delay")

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

local function testRightOptionTriggerPausesAfterHoldDelay()
  local previousConfig = rawget(_G, "fnMusicPauseConfig")
  local previousHs = rawget(_G, "hs")
  local previousModule = package.loaded.fn_music_pause
  local previousCore = package.loaded.fn_music_pause_core
  local previousPlayer = package.loaded.fn_music_pause_player
  local tapCallback = nil
  local scheduledTimers = {}
  local handledFlags = {}

  _G.fnMusicPauseConfig = { alert = false, holdDelay = 0.2, log = false, triggerKey = "rightOption" }
  _G.hs = {
    configdir = "/tmp",
    accessibilityState = function()
      return true
    end,
    alert = { show = function() end },
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
    local returned = tapCallback({
      getFlags = function()
        return { alt = true }
      end,
      getKeyCode = function()
        return 61
      end,
    })

    assertEqual(returned, false, "right Option event is not swallowed")
    assertEqual(#handledFlags, 0, "right Option work is deferred until hold delay")
    assertEqual(#scheduledTimers, 1, "right Option schedules pause work")
    assertEqual(scheduledTimers[1].delay, 0.2, "right Option uses configured hold delay")

    scheduledTimers[1].callback()

    assertEqual(#handledFlags, 1, "right Option scheduled work runs")
    assertEqual(handledFlags[1], true, "right Option down sends pause logic")

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

local function testLeftOptionDoesNotTriggerRightOptionMode()
  local previousConfig = rawget(_G, "fnMusicPauseConfig")
  local previousHs = rawget(_G, "hs")
  local previousModule = package.loaded.fn_music_pause
  local previousCore = package.loaded.fn_music_pause_core
  local previousPlayer = package.loaded.fn_music_pause_player
  local tapCallback = nil
  local scheduledTimers = {}
  local handledFlags = {}

  _G.fnMusicPauseConfig = { alert = false, holdDelay = 0.2, log = false, triggerKey = "rightOption" }
  _G.hs = {
    configdir = "/tmp",
    accessibilityState = function()
      return true
    end,
    alert = { show = function() end },
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
    local returned = tapCallback({
      getFlags = function()
        return { alt = true }
      end,
      getKeyCode = function()
        return 58
      end,
    })

    assertEqual(returned, false, "left Option event is not swallowed")
    assertEqual(#scheduledTimers, 0, "left Option does not schedule right Option pause work")
    assertEqual(#handledFlags, 0, "left Option does not call pause logic")

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

local function testSavedTriggerKeyOverridesConfigDefault()
  local previousConfig = rawget(_G, "fnMusicPauseConfig")
  local previousHs = rawget(_G, "hs")
  local previousModule = package.loaded.fn_music_pause
  local previousCore = package.loaded.fn_music_pause_core
  local previousPlayer = package.loaded.fn_music_pause_player
  local tapCallback = nil
  local scheduledTimers = {}
  local handledFlags = {}

  _G.fnMusicPauseConfig = { alert = false, holdDelay = 0.2, log = false, triggerKey = "fn" }
  _G.hs = {
    configdir = "/tmp",
    accessibilityState = function()
      return true
    end,
    alert = { show = function() end },
    settings = {
      get = function(key)
        if key == "fnMusicPause.triggerKey" then
          return "rightOption"
        end
        return nil
      end,
    },
    menubar = {
      new = function()
        return {
          setTitle = function(self)
            return self
          end,
          setMenu = function(self)
            return self
          end,
        }
      end,
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
        return { alt = true }
      end,
      getKeyCode = function()
        return 61
      end,
    })

    assertEqual(#scheduledTimers, 1, "saved right Option trigger overrides config Fn trigger")

    scheduledTimers[1].callback()

    assertEqual(#handledFlags, 1, "saved trigger key pause logic runs")
    assertEqual(handledFlags[1], true, "saved trigger key sends down state")

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

local function testMenuSelectionPersistsTriggerKeyAndRestartsListener()
  local previousConfig = rawget(_G, "fnMusicPauseConfig")
  local previousHs = rawget(_G, "hs")
  local previousModule = package.loaded.fn_music_pause
  local previousCore = package.loaded.fn_music_pause_core
  local previousPlayer = package.loaded.fn_music_pause_player
  local settingsValues = {}
  local menuObjects = {}
  local taps = {}

  local function findMenuItem(menu, title)
    for _, item in ipairs(menu or {}) do
      if item.title == title then
        return item
      end
    end
    return nil
  end

  _G.fnMusicPauseConfig = { alert = false, holdDelay = 0.2, log = false, triggerKey = "fn" }
  _G.hs = {
    configdir = "/tmp",
    accessibilityState = function()
      return true
    end,
    alert = { show = function() end },
    settings = {
      get = function(key)
        return settingsValues[key]
      end,
      set = function(key, value)
        settingsValues[key] = value
      end,
    },
    menubar = {
      new = function()
        local menuObject = {
          title = nil,
          menu = nil,
          setTitle = function(self, title)
            self.title = title
            return self
          end,
          setMenu = function(self, menu)
            self.menu = menu
            return self
          end,
        }
        table.insert(menuObjects, menuObject)
        return menuObject
      end,
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
      new = function()
        local tap = {
          started = false,
          stopped = false,
          start = function(self)
            self.started = true
          end,
          stop = function(self)
            self.stopped = true
          end,
          isEnabled = function(self)
            return self.started and not self.stopped
          end,
        }
        table.insert(taps, tap)
        return tap
      end,
    },
    timer = {
      doAfter = function(delay, callback)
        return {
          delay = delay,
          callback = callback,
          stop = function() end,
        }
      end,
    },
  }

  package.loaded.fn_music_pause = nil
  package.loaded.fn_music_pause_core = {
    newController = function(player)
      return { player = player }
    end,
    handleFnFlag = function() end,
  }
  package.loaded.fn_music_pause_player = {
    new = function()
      return {}
    end,
  }

  local ok, err = pcall(function()
    local module = require("fn_music_pause")

    assertEqual(#menuObjects, 1, "menu bar item is created")
    assertEqual(menuObjects[1].title, "Fn Pause", "menu bar title is set")
    assertEqual(#taps, 1, "initial listener is created")
    assertEqual(taps[1].started, true, "initial listener starts")

    local fnItem = findMenuItem(menuObjects[1].menu, "Fn")
    local rightOptionItem = findMenuItem(menuObjects[1].menu, "Right Option")

    assertEqual(fnItem.checked, true, "Fn starts checked from config")
    assertEqual(rightOptionItem.checked, false, "Right Option starts unchecked")

    rightOptionItem.fn()

    assertEqual(settingsValues["fnMusicPause.triggerKey"], "rightOption", "menu selection persists trigger key")
    assertEqual(taps[1].stopped, true, "old listener stops after menu selection")
    assertEqual(#taps, 2, "listener is recreated after menu selection")
    assertEqual(taps[2].started, true, "new listener starts after menu selection")

    rightOptionItem = findMenuItem(menuObjects[1].menu, "Right Option")
    assertEqual(rightOptionItem.checked, true, "selected trigger key is checked after menu refresh")

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
  testRightOptionTriggerPausesAfterHoldDelay,
  testLeftOptionDoesNotTriggerRightOptionMode,
  testSavedTriggerKeyOverridesConfigDefault,
  testMenuSelectionPersistsTriggerKeyAndRestartsListener,
}

for _, test in ipairs(tests) do
  test()
end

return "fn_music_pause_test: ok"
