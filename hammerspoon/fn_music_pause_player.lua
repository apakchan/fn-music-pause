local M = {}

local didPauseResult = "fn-music-pause:did-pause"
local didResumeResult = "fn-music-pause:did-resume"
local axMaxNodes = 800
local defaultAppleScriptTimeout = 1.0
local defaultAppleScriptConcurrency = 4
local defaultBrowserTabChunkSize = 4
local defaultCacheMaxAgeSeconds = 300

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

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function trimTrailingNewlines(value)
  if type(value) ~= "string" then
    return value
  end

  return (value:gsub("%s+$", ""))
end

local function runAppleScript(script, timeoutSeconds)
  if hs.execute == nil then
    return hs.osascript.applescript(script)
  end

  local scriptPath = os.tmpname() .. ".applescript"
  local file = io.open(scriptPath, "w")
  if file == nil then
    return false, "script-tempfile-error", { OSAScriptErrorMessageKey = "unable to create temporary AppleScript file" }
  end

  file:write(script)
  file:close()

  local timeout = tonumber(timeoutSeconds) or defaultAppleScriptTimeout
  if timeout <= 0 then
    timeout = defaultAppleScriptTimeout
  end

  local runner = [[
script_path=$1
timeout_seconds=$2
out_file=$(mktemp "${TMPDIR:-/tmp}/fn-music-pause-out.XXXXXX") || exit 70
timeout_file=$(mktemp "${TMPDIR:-/tmp}/fn-music-pause-timeout.XXXXXX") || exit 70
rm -f "$timeout_file"

/usr/bin/osascript "$script_path" >"$out_file" 2>&1 &
osa_pid=$!

(
  sleep "$timeout_seconds"
  if kill -0 "$osa_pid" 2>/dev/null; then
    : > "$timeout_file"
    kill "$osa_pid" 2>/dev/null
    sleep 0.05
    kill -9 "$osa_pid" 2>/dev/null
  fi
) &
killer_pid=$!

wait "$osa_pid"
status=$?
kill "$killer_pid" 2>/dev/null
wait "$killer_pid" 2>/dev/null

if [ -s "$timeout_file" ]; then
  echo "fn-music-pause:osascript-timeout"
  rm -f "$out_file" "$timeout_file"
  exit 124
fi

cat "$out_file"
rm -f "$out_file" "$timeout_file"
exit "$status"
]]

  local command = "/bin/sh -c " .. shellQuote(runner) .. " sh " .. shellQuote(scriptPath) .. " " .. shellQuote(tostring(timeout))
  local output, ok, _, rc = hs.execute(command)
  os.remove(scriptPath)

  output = trimTrailingNewlines(output or "")
  if ok then
    return true, output
  end

  local message = output
  if message == "fn-music-pause:osascript-timeout" then
    message = "timeout"
  elseif message == "" then
    message = "osascript failed"
  end

  return false, message, {
    OSAScriptErrorMessageKey = message,
    exitCode = rc,
  }
end

local function parseConcurrentAppleScriptOutput(output, jobCount)
  local results = {}

  for line in string.gmatch(output or "", "[^\n]+") do
    local indexText, statusText, result = string.match(line, "^__FN_JOB__\t(%d+)\t(%d+)\t(.*)$")
    local index = tonumber(indexText)
    if index ~= nil then
      local status = tonumber(statusText)
      result = trimTrailingNewlines(result or "")
      if status == 0 then
        results[index] = { ok = true, result = result }
      else
        local message = result
        if message == "" then
          message = status == 124 and "timeout" or "osascript failed"
        end
        results[index] = {
          ok = false,
          result = message,
          details = {
            OSAScriptErrorMessageKey = message,
            exitCode = status,
          },
        }
      end
    end
  end

  for index = 1, jobCount do
    if results[index] == nil then
      results[index] = {
        ok = false,
        result = "missing result",
        details = {
          OSAScriptErrorMessageKey = "missing result",
        },
      }
    end
  end

  return results
end

local function runAppleScriptsConcurrently(jobs, timeoutSeconds, singleRunner, concurrency)
  if #jobs == 0 then
    return {}
  end

  local maxConcurrent = tonumber(concurrency) or defaultAppleScriptConcurrency
  if maxConcurrent < 1 then
    maxConcurrent = 1
  end

  if hs.execute == nil then
    local results = {}
    for index, job in ipairs(jobs) do
      local ok, result, details = singleRunner(job.script, timeoutSeconds)
      results[index] = { ok = ok, result = result, details = details }
    end
    return results
  end

  local scriptPaths = {}
  for _, job in ipairs(jobs) do
    local scriptPath = os.tmpname() .. ".applescript"
    local file = io.open(scriptPath, "w")
    if file == nil then
      table.insert(scriptPaths, false)
    else
      file:write(job.script)
      file:close()
      table.insert(scriptPaths, scriptPath)
    end
  end

  local timeout = tonumber(timeoutSeconds) or defaultAppleScriptTimeout
  if timeout <= 0 then
    timeout = defaultAppleScriptTimeout
  end

  local runner = [[
timeout_seconds=$1
max_concurrent=$2
shift 2
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/fn-music-pause-batch.XXXXXX") || exit 70

wait_batch() {
  if [ -z "$active_indices" ]; then
    return
  fi

  (
    sleep "$timeout_seconds"
    for index in $active_indices; do
      pid_file="$work_dir/pid_$index"
      if [ -f "$pid_file" ]; then
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
          kill "$pid" 2>/dev/null
          sleep 0.05
          kill -9 "$pid" 2>/dev/null
        fi
      fi
    done
  ) &
  killer_pid=$!

  for index in $active_indices; do
    pid_file="$work_dir/pid_$index"
    if [ -f "$pid_file" ]; then
      pid=$(cat "$pid_file")
      wait "$pid" 2>/dev/null
    fi
  done

  kill "$killer_pid" 2>/dev/null
  wait "$killer_pid" 2>/dev/null
}

index=1
active_count=0
active_indices=""

for script_path in "$@"; do
  if [ "$script_path" = "__missing__" ]; then
    echo "70" > "$work_dir/status_$index"
    echo "unable to create temporary AppleScript file" > "$work_dir/out_$index"
  else
    (
      /usr/bin/osascript "$script_path" > "$work_dir/out_$index" 2>&1
      echo "$?" > "$work_dir/status_$index"
    ) &
    echo "$!" > "$work_dir/pid_$index"
    active_indices="$active_indices $index"
    active_count=$((active_count + 1))
  fi

  if [ "$active_count" -ge "$max_concurrent" ]; then
    wait_batch
    active_count=0
    active_indices=""
  fi

  index=$((index + 1))
done

job_count=$((index - 1))
wait_batch

index=1
while [ "$index" -le "$job_count" ]; do
  status_file="$work_dir/status_$index"
  out_file="$work_dir/out_$index"
  if [ -f "$status_file" ]; then
    status=$(cat "$status_file")
  else
    status=124
  fi
  if [ -f "$out_file" ]; then
    output=$(tr '\r\n\t' '   ' < "$out_file")
  else
    output="timeout"
  fi
  printf "__FN_JOB__\t%s\t%s\t%s\n" "$index" "$status" "$output"
  index=$((index + 1))
done

rm -rf "$work_dir"
exit 0
]]

  local command = "/bin/sh -c " .. shellQuote(runner) .. " sh " .. shellQuote(tostring(timeout)) .. " " .. shellQuote(tostring(maxConcurrent))
  for _, scriptPath in ipairs(scriptPaths) do
    command = command .. " " .. shellQuote(scriptPath or "__missing__")
  end

  local output = hs.execute(command)

  for _, scriptPath in ipairs(scriptPaths) do
    if scriptPath then
      os.remove(scriptPath)
    end
  end

  return parseConcurrentAppleScriptOutput(output, #jobs)
end

local function pressPlayPauseKey()
  hs.eventtap.event.newSystemKeyEvent("PLAY", true):post()
  hs.eventtap.event.newSystemKeyEvent("PLAY", false):post()
end

local function sleepBriefly()
  if hs.timer ~= nil and hs.timer.usleep ~= nil then
    hs.timer.usleep(40000)
  end
end

local function browserPauseJavaScript()
  return [[
(function () {
  var pausedAny = false;
  var media = Array.prototype.slice.call(document.querySelectorAll('video,audio'));

  media.forEach(function (element) {
    var isPendingResume = element.dataset.fnMusicPauseResuming === 'true';
    if (isPendingResume || (!element.paused && !element.ended)) {
      delete element.dataset.fnMusicPauseResuming;
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
      element.dataset.fnMusicPauseResuming = 'true';
      try {
        var playResult = element.play();
        resumedAny = true;
        if (playResult && typeof playResult.then === 'function') {
          playResult.then(function () {
            delete element.dataset.fnMusicPauseResuming;
          }, function () {
            delete element.dataset.fnMusicPauseResuming;
          });
        } else {
          delete element.dataset.fnMusicPauseResuming;
        }
      } catch (error) {
        delete element.dataset.fnMusicPauseResuming;
      }
    }
  });

  return resumedAny ? ']] .. didResumeResult .. [[' : 'not-paused';
})()
]]
end

local function browserScriptErrorResult(result)
  return type(result) == "string" and string.sub(result, 1, 13) == "script-error:"
end

local function mediaAppPauseScript(app)
  return string.format([[
tell application %s
  if player state is playing then
    pause
    return %s
  end if
  return player state as string
end tell
]], appleScriptString(app.scriptName), appleScriptString(didPauseResult))
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

local function browserTabTargetList(tabs)
  local items = {}

  for _, tab in ipairs(tabs) do
    table.insert(items, string.format("{%d, %d}", tab.windowIndex, tab.tabIndex))
  end

  return "{" .. table.concat(items, ", ") .. "}"
end

local function browserScriptForTabs(app, javascript, successResult, emptyResult, tabs)
  if #tabs == 0 then
    return browserScript(app, javascript, successResult, emptyResult)
  end

  if app.kind == "safari" then
    return string.format([[
tell application %s
  if not (exists front window) then
    return "not-running"
  end if

  set tabTargets to %s
  set matchedAny to false
  set lastError to ""

  repeat with tabTarget in tabTargets
    set windowIndex to item 1 of tabTarget
    set tabIndex to item 2 of tabTarget
    try
      if (count of windows) >= windowIndex then
        set browserWindow to window windowIndex
        if (count of tabs of browserWindow) >= tabIndex then
          set browserTab to tab tabIndex of browserWindow
          set tabResult to do JavaScript %s in browserTab
          if tabResult is %s then
            set matchedAny to true
          end if
        end if
      end if
    on error errorMessage
      set lastError to errorMessage
    end try
  end repeat

  if matchedAny then
    return %s
  end if

  if lastError is not "" then
    return "script-error:" & lastError
  end if

  return %s
end tell
]],
      appleScriptString(app.scriptName),
      browserTabTargetList(tabs),
      appleScriptString(javascript),
      appleScriptString(successResult),
      appleScriptString(successResult),
      appleScriptString(emptyResult)
    )
  end

  return string.format([[
tell application %s
  if not (exists front window) then
    return "not-running"
  end if

  set tabTargets to %s
  set matchedAny to false
  set lastError to ""

  repeat with tabTarget in tabTargets
    set windowIndex to item 1 of tabTarget
    set tabIndex to item 2 of tabTarget
    try
      if (count of windows) >= windowIndex then
        set browserWindow to window windowIndex
        if (count of tabs of browserWindow) >= tabIndex then
          set browserTab to tab tabIndex of browserWindow
          set tabResult to execute browserTab javascript %s
          if tabResult is %s then
            set matchedAny to true
          end if
        end if
      end if
    on error errorMessage
      set lastError to errorMessage
    end try
  end repeat

  if matchedAny then
    return %s
  end if

  if lastError is not "" then
    return "script-error:" & lastError
  end if

  return %s
end tell
]],
    appleScriptString(app.scriptName),
    browserTabTargetList(tabs),
    appleScriptString(javascript),
    appleScriptString(successResult),
    appleScriptString(successResult),
    appleScriptString(emptyResult)
  )
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

local function frontmostApplication()
  if hs.application == nil or hs.application.frontmostApplication == nil then
    return nil
  end

  local ok, app = pcall(hs.application.frontmostApplication)
  if ok then
    return app
  end

  return nil
end

local function runningApplicationMatches(app, runningApp)
  if runningApp == nil then
    return false
  end

  local nameOk, name = pcall(function()
    return runningApp:name()
  end)
  local bundleOk, bundleID = pcall(function()
    return runningApp:bundleID()
  end)

  if app.bundleID ~= nil and bundleOk and bundleID == app.bundleID then
    return true
  end

  return nameOk and name == app.processName
end

local function orderedAppsForPause(apps)
  local frontmost = frontmostApplication()
  if frontmost == nil then
    return apps
  end

  local ordered = {}
  local frontmostIndex = nil

  for index, app in ipairs(apps) do
    if frontmostIndex == nil and isSupportedApp(app) and runningApplicationMatches(app, frontmost) then
      frontmostIndex = index
      table.insert(ordered, app)
    end
  end

  if frontmostIndex == nil then
    return apps
  end

  for index, app in ipairs(apps) do
    if index ~= frontmostIndex then
      table.insert(ordered, app)
    end
  end

  return ordered
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

local function browserPauseFailureIsAmbiguous(result, details)
  local resultText = trimTrailingNewlines(result)
  if resultText == "timeout"
    or resultText == "missing result"
    or resultText == "osascript failed"
    or resultText == "fn-music-pause:osascript-timeout" then
    return true
  end

  if type(details) == "table" and tonumber(details.exitCode) == 124 then
    return true
  end

  local errorMessage = osascriptErrorMessage(details)
  if type(errorMessage) ~= "string" then
    return false
  end

  local lowerMessage = string.lower(errorMessage)
  return string.find(lowerMessage, "timeout", 1, true) ~= nil
    or string.find(lowerMessage, "timed out", 1, true) ~= nil
end

local function browserPauseFailureCanUseMediaKeyFallback(ok, result, details)
  if browserPauseFailureIsAmbiguous(result, details) then
    return false
  end

  if ok then
    return true
  end

  local errorMessage = osascriptErrorMessage(details)
  if type(errorMessage) ~= "string" then
    return false
  end

  local lowerMessage = string.lower(errorMessage)
  return string.find(lowerMessage, "javascript from apple events is disabled", 1, true) ~= nil
    or string.find(lowerMessage, "not allowed", 1, true) ~= nil
    or string.find(lowerMessage, "not authorized", 1, true) ~= nil
    or string.find(lowerMessage, "not authorised", 1, true) ~= nil
    or string.find(errorMessage, "不允许访问", 1, true) ~= nil
end

local function cloneTabs(tabs)
  local cloned = {}

  if type(tabs) ~= "table" then
    return cloned
  end

  for _, tab in ipairs(tabs) do
    if type(tab) == "table" and tab.windowIndex ~= nil and tab.tabIndex ~= nil then
      table.insert(cloned, {
        windowIndex = tab.windowIndex,
        tabIndex = tab.tabIndex,
      })
    end
  end

  return cloned
end

local function cacheablePauseToken(token)
  if type(token) ~= "table" then
    return nil
  end

  if token.kind == "browser" then
    local tabs = cloneTabs(token.tabs)
    if #tabs == 0 then
      return nil
    end

    return {
      kind = "browser",
      processName = token.processName,
      scriptName = token.scriptName,
      bundleID = token.bundleID,
      appKind = token.appKind,
      tabs = tabs,
    }
  end

  if token.kind == "multiple" then
    local tokens = {}
    for _, childToken in ipairs(token.tokens or {}) do
      local cacheableChild = cacheablePauseToken(childToken)
      if cacheableChild ~= nil then
        table.insert(tokens, cacheableChild)
      end
    end

    if #tokens == 0 then
      return nil
    end

    if #tokens == 1 then
      return tokens[1]
    end

    return {
      kind = "multiple",
      tokens = tokens,
    }
  end

  return nil
end

local function appendPauseToken(tokens, token)
  if type(token) ~= "table" then
    return
  end

  if token.kind == "multiple" then
    for _, childToken in ipairs(token.tokens or {}) do
      appendPauseToken(tokens, childToken)
    end
    return
  end

  table.insert(tokens, token)
end

local function combinePauseTokens(firstToken, secondToken)
  local tokens = {}
  appendPauseToken(tokens, firstToken)
  appendPauseToken(tokens, secondToken)

  if #tokens == 0 then
    return nil
  end

  if #tokens == 1 then
    return tokens[1]
  end

  return {
    kind = "multiple",
    tokens = tokens,
  }
end

local function addBrowserProcessesFromToken(token, processes)
  if type(token) ~= "table" then
    return
  end

  if token.kind == "browser" and token.processName ~= nil then
    processes[token.processName] = true
    return
  end

  if token.kind == "multiple" then
    for _, childToken in ipairs(token.tokens or {}) do
      addBrowserProcessesFromToken(childToken, processes)
    end
  end
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

local function shouldVisitAxElement(element, visited)
  if element == nil then
    return false
  end

  if (visited._count or 0) >= axMaxNodes then
    return false
  end

  local elementID = tostring(element)
  if visited[elementID] then
    return false
  end

  visited[elementID] = true
  visited._count = (visited._count or 0) + 1
  return true
end

local function axElementLooksAudible(element, depth, visited)
  if depth > 12 or not shouldVisitAxElement(element, visited) then
    return false
  end

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
  local ok, axuielement = pcall(function()
    return hs.axuielement
  end)

  if not ok or axuielement == nil or axuielement.applicationElement == nil then
    return nil
  end

  local runningApp = findRunningApplication(app)
  if runningApp == nil then
    return nil
  end

  local rootOk, root = pcall(axuielement.applicationElement, runningApp)
  if not rootOk or root == nil then
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
  if depth > 12 or not shouldVisitAxElement(element, visited) then
    return false
  end

  if axAttributeValue(element, "AXRole") == "AXWebArea" then
    return false
  end

  local childAttributes = {
    "AXChildren",
    "AXChildrenInNavigationOrder",
    "AXVisibleChildren",
  }

  for _, attribute in ipairs(childAttributes) do
    local childValue = axAttributeValue(element, attribute)
    if type(childValue) == "table" then
      local radioIndex = 0
      local foundTabStrip = false

      for _, child in ipairs(childValue) do
        if type(child) ~= "string" and axAttributeValue(child, "AXRole") == "AXRadioButton" then
          foundTabStrip = true
          radioIndex = radioIndex + 1

          if axElementHasAudibleIndicator(child) then
            addAudibleTab(tabs, seenTabs, windowIndex, radioIndex)
          end
        end
      end

      if foundTabStrip then
        return true
      end
    end
  end

  for _, attribute in ipairs(childAttributes) do
    local childValue = axAttributeValue(element, attribute)
    if type(childValue) == "table" then
      for _, child in ipairs(childValue) do
        if type(child) ~= "string" and axCollectAudibleTabs(child, depth + 1, visited, tabs, seenTabs, windowIndex) then
          return true
        end
      end
    elseif childValue ~= nil and type(childValue) ~= "string" then
      if axCollectAudibleTabs(childValue, depth + 1, visited, tabs, seenTabs, windowIndex) then
        return true
      end
    end
  end

  return false
end

local function browserAudibleTabs(app)
  local root = browserAxRoot(app)
  if root == nil then
    return {}, false
  end

  local tabs = {}
  local seenTabs = {}
  local foundTabStrip = false
  local windows = axAttributeValue(root, "AXWindows")

  if type(windows) == "table" and #windows > 0 then
    for windowIndex, window in ipairs(windows) do
      foundTabStrip = axCollectAudibleTabs(window, 0, {}, tabs, seenTabs, windowIndex) or foundTabStrip
    end
  else
    foundTabStrip = axCollectAudibleTabs(root, 0, {}, tabs, seenTabs, 1)
  end

  return tabs, foundTabStrip
end

local function parseBrowserTabTargets(result)
  local tabs = {}

  if type(result) ~= "string" then
    return tabs
  end

  for windowIndexText, tabIndexText in string.gmatch(result, "(%d+):(%d+)") do
    table.insert(tabs, {
      windowIndex = tonumber(windowIndexText),
      tabIndex = tonumber(tabIndexText),
    })
  end

  return tabs
end

local function browserTabTargets(app, appleScriptRunner, timeoutSeconds)
  local script = string.format([[
tell application %s
  if not (exists front window) then
    return ""
  end if

  set tabLines to {}
  set windowIndex to 1

  repeat with browserWindow in windows
    set tabIndex to 1
    repeat with browserTab in tabs of browserWindow
      set end of tabLines to ((windowIndex as string) & ":" & (tabIndex as string))
      set tabIndex to tabIndex + 1
    end repeat
    set windowIndex to windowIndex + 1
  end repeat

  set oldDelimiters to AppleScript's text item delimiters
  set AppleScript's text item delimiters to linefeed
  set outputText to tabLines as text
  set AppleScript's text item delimiters to oldDelimiters
  return outputText
end tell
]], appleScriptString(app.scriptName))

  local ok, result = appleScriptRunner(script, timeoutSeconds)
  if not ok then
    return {}
  end

  return parseBrowserTabTargets(result)
end

local function chunkTabs(tabs, chunkSize)
  local chunks = {}
  local size = tonumber(chunkSize) or defaultBrowserTabChunkSize

  if size < 1 then
    size = defaultBrowserTabChunkSize
  end

  local current = {}
  for _, tab in ipairs(tabs) do
    table.insert(current, tab)

    if #current >= size then
      table.insert(chunks, current)
      current = {}
    end
  end

  if #current > 0 then
    table.insert(chunks, current)
  end

  return chunks
end

local function browserActiveTabIndex(app, windowIndex, appleScriptRunner, timeoutSeconds)
  local script = string.format([[
tell application %s
  if (count of windows) < %d then
    return "not-running"
  end if

  return active tab index of window %d as string
end tell
]], appleScriptString(app.scriptName), windowIndex, windowIndex)

  local ok, result = appleScriptRunner(script, timeoutSeconds)
  if ok then
    return tonumber(result)
  end

  return nil
end

local function setBrowserActiveTab(app, tab, appleScriptRunner, timeoutSeconds)
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

  local ok, result = appleScriptRunner(script, timeoutSeconds)
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

local function toggleBrowserTabsWithMediaKey(app, tabs, appleScriptRunner, timeoutSeconds)
  local originalTabs = {}
  local toggledTabs = {}

  for _, windowIndex in ipairs(browserWindowIndices(tabs)) do
    originalTabs[windowIndex] = browserActiveTabIndex(app, windowIndex, appleScriptRunner, timeoutSeconds)
  end

  for _, tab in ipairs(tabs) do
    if setBrowserActiveTab(app, tab, appleScriptRunner, timeoutSeconds) then
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
      }, appleScriptRunner, timeoutSeconds)
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
    appleScriptRunner = options.appleScriptRunner or runAppleScript,
    appleScriptBatchRunner = options.appleScriptBatchRunner,
    appleScriptTimeout = tonumber(options.appleScriptTimeout) or defaultAppleScriptTimeout,
    appleScriptConcurrency = tonumber(options.appleScriptConcurrency) or defaultAppleScriptConcurrency,
    browserTabChunkSize = tonumber(options.browserTabChunkSize) or defaultBrowserTabChunkSize,
    cacheMaxAgeSeconds = tonumber(options.cacheMaxAgeSeconds) or defaultCacheMaxAgeSeconds,
    lastPausedToken = nil,
    lastPausedTokenAt = nil,
  }

  if player.appleScriptTimeout <= 0 then
    player.appleScriptTimeout = defaultAppleScriptTimeout
  end
  if player.appleScriptConcurrency < 1 then
    player.appleScriptConcurrency = defaultAppleScriptConcurrency
  end
  if player.browserTabChunkSize < 1 then
    player.browserTabChunkSize = defaultBrowserTabChunkSize
  end
  if player.cacheMaxAgeSeconds < 0 then
    player.cacheMaxAgeSeconds = defaultCacheMaxAgeSeconds
  end

  if player.appleScriptBatchRunner == nil then
    player.appleScriptBatchRunner = function(jobs, timeoutSeconds)
      return runAppleScriptsConcurrently(jobs, timeoutSeconds, player.appleScriptRunner, player.appleScriptConcurrency)
    end
  end

  function player:pauseMediaApp(app)
    local script = mediaAppPauseScript(app)

    local ok, result = self.appleScriptRunner(script, self.appleScriptTimeout)
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

  function player:pauseJobForMediaApp(app)
    return {
      app = app,
      script = mediaAppPauseScript(app),
      token = {
        kind = "app",
        processName = app.processName,
        scriptName = app.scriptName,
        bundleID = app.bundleID,
      },
      logLabel = app.processName,
      logKind = "mediaApp",
    }
  end

  function player:pauseBrowserApp(app)
    local audibleTabs = {}
    local tabScanReliable = false
    if app.kind == "chromium" then
      audibleTabs, tabScanReliable = browserAudibleTabs(app)
    end

    if tabScanReliable and #audibleTabs == 0 then
      self.logger(string.format("checked %s audible tabs: found=0; skipped media script", app.processName))
      return nil
    end

    local script
    if #audibleTabs > 0 then
      script = browserScriptForTabs(app, browserPauseJavaScript(), didPauseResult, "not-playing", audibleTabs)
    else
      script = browserScript(app, browserPauseJavaScript(), didPauseResult, "not-playing")
    end

    local ok, result, details = self.appleScriptRunner(script, self.appleScriptTimeout)
    local resultText = trimTrailingNewlines(result)
    local errorMessage = osascriptErrorMessage(details)

    if errorMessage ~= nil then
      self.logger(string.format(
        "checked %s media tabs=%d: ok=%s result=%s error=%s",
        app.processName,
        #audibleTabs,
        tostring(ok),
        tostring(resultText),
        tostring(errorMessage)
      ))
    elseif browserScriptErrorResult(resultText) then
      self.logger(string.format("checked %s media tabs=%d: ok=%s result=%s", app.processName, #audibleTabs, tostring(ok), tostring(resultText)))
    else
      self.logger(string.format("checked %s media tabs=%d: ok=%s result=%s", app.processName, #audibleTabs, tostring(ok), tostring(resultText)))
    end

    if ok and resultText == didPauseResult then
      return {
        kind = "browser",
        processName = app.processName,
        scriptName = app.scriptName,
        bundleID = app.bundleID,
        appKind = app.kind,
        tabs = #audibleTabs > 0 and audibleTabs or nil,
      }
    end

    local ambiguousFailure = browserPauseFailureIsAmbiguous(resultText, details)
    local canUseMediaKeyFallback = browserPauseFailureCanUseMediaKeyFallback(ok, resultText, details)
    if #audibleTabs > 0 and ambiguousFailure then
      self.logger(string.format("kept %s browser resume token after ambiguous result=%s", app.processName, tostring(resultText)))
      return {
        kind = "browser",
        processName = app.processName,
        scriptName = app.scriptName,
        bundleID = app.bundleID,
        appKind = app.kind,
        tabs = audibleTabs,
      }
    end

    if #audibleTabs > 0 and canUseMediaKeyFallback then
      local toggledTabs = toggleBrowserTabsWithMediaKey(app, audibleTabs, self.appleScriptRunner, self.appleScriptTimeout)
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
    elseif #audibleTabs > 0 and not canUseMediaKeyFallback then
      self.logger(string.format("skipped media key fallback for %s after ambiguous result=%s", app.processName, tostring(resultText)))
    end

    if canUseMediaKeyFallback and browserLooksAudible(app) then
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

  function player:pauseJobForBrowserApp(app)
    local audibleTabs = {}
    local tabScanReliable = false
    if app.kind == "chromium" then
      audibleTabs, tabScanReliable = browserAudibleTabs(app)
    end

    if tabScanReliable and #audibleTabs == 0 then
      return {
        app = app,
        skipped = true,
        reason = "silentAudibleTabs",
      }
    end

    local script
    if #audibleTabs > 0 then
      script = browserScriptForTabs(app, browserPauseJavaScript(), didPauseResult, "not-playing", audibleTabs)
      return {
        app = app,
        script = script,
        audibleTabs = audibleTabs,
        token = {
          kind = "browser",
          processName = app.processName,
          scriptName = app.scriptName,
          bundleID = app.bundleID,
          appKind = app.kind,
          tabs = audibleTabs,
        },
        logLabel = app.processName,
        logKind = "browser",
      }
    end

    local tabTargets = browserTabTargets(app, self.appleScriptRunner, self.appleScriptTimeout)
    if #tabTargets == 0 then
      script = browserScript(app, browserPauseJavaScript(), didPauseResult, "not-playing")
      return {
        app = app,
        script = script,
        token = {
          kind = "browser",
          processName = app.processName,
          scriptName = app.scriptName,
          bundleID = app.bundleID,
          appKind = app.kind,
        },
        logLabel = app.processName,
        logKind = "browser",
      }
    end

    local jobs = {}
    for _, tabChunk in ipairs(chunkTabs(tabTargets, self.browserTabChunkSize)) do
      table.insert(jobs, {
        app = app,
        script = browserScriptForTabs(app, browserPauseJavaScript(), didPauseResult, "not-playing", tabChunk),
        targetTabs = tabChunk,
        token = {
          kind = "browser",
          processName = app.processName,
          scriptName = app.scriptName,
          bundleID = app.bundleID,
          appKind = app.kind,
          tabs = tabChunk,
        },
        logLabel = app.processName,
        logKind = "browser",
      })
    end

    return {
      jobs = jobs,
    }
  end

  function player:pauseJobForApp(app)
    if isMediaApp(app) then
      return self:pauseJobForMediaApp(app)
    end

    if isBrowserApp(app) then
      return self:pauseJobForBrowserApp(app)
    end

    return nil
  end

  function player:logPauseJobResult(job, ok, result, details)
    if job.logKind == "browser" then
      local tabCount = #(job.audibleTabs or job.targetTabs or {})
      local errorMessage = osascriptErrorMessage(details)
      if errorMessage ~= nil then
        self.logger(string.format(
          "checked %s media tabs=%d: ok=%s result=%s error=%s",
          job.app.processName,
          tabCount,
          tostring(ok),
          tostring(result),
          tostring(errorMessage)
        ))
      else
        self.logger(string.format(
          "checked %s media tabs=%d: ok=%s result=%s",
          job.app.processName,
          tabCount,
          tostring(ok),
          tostring(result)
        ))
      end
      return
    end

    self.logger(string.format("checked %s: ok=%s result=%s", job.app.processName, tostring(ok), tostring(result)))
  end

  function player:pauseAppsConcurrently(apps, options)
    options = options or {}
    local mediaKeyFallbackSuppressed = options.mediaKeyFallbackSuppressed or {}
    local jobs = {}
    local checkedSupportedApp = false

    for _, app in ipairs(apps) do
      if isSupportedApp(app) and appIsRunning(app) then
        checkedSupportedApp = true

        local job = self:pauseJobForApp(app)
        if job ~= nil then
          if job.skipped and job.reason == "silentAudibleTabs" then
            self.logger(string.format("checked %s audible tabs: found=0; skipped media script", app.processName))
          elseif job.jobs ~= nil then
            for _, childJob in ipairs(job.jobs) do
              table.insert(jobs, childJob)
            end
          elseif job.script ~= nil then
            table.insert(jobs, job)
          end
        end
      end
    end

    if #jobs == 0 then
      return nil, checkedSupportedApp
    end

    local results = self.appleScriptBatchRunner(jobs, self.appleScriptTimeout)
    local tokens = {}

    for index, job in ipairs(jobs) do
      local result = results[index] or {}
      local resultText = trimTrailingNewlines(result.result)
      local mediaKeyFallbackAllowed = mediaKeyFallbackSuppressed[job.app.processName] ~= true
      self:logPauseJobResult(job, result.ok, resultText, result.details)

      if result.ok and resultText == didPauseResult then
        table.insert(tokens, job.token)
      elseif job.logKind == "browser"
        and browserPauseFailureIsAmbiguous(resultText, result.details)
        and type(job.token) == "table"
        and type(job.token.tabs) == "table"
        and #job.token.tabs > 0 then
        self.logger(string.format("kept %s browser resume token after ambiguous result=%s", job.app.processName, tostring(resultText)))
        table.insert(tokens, job.token)
      elseif job.logKind == "browser"
        and mediaKeyFallbackAllowed
        and #(job.audibleTabs or {}) > 0
        and browserPauseFailureCanUseMediaKeyFallback(result.ok, resultText, result.details) then
        local toggledTabs = toggleBrowserTabsWithMediaKey(job.app, job.audibleTabs, self.appleScriptRunner, self.appleScriptTimeout)
        if #toggledTabs > 0 then
          self.logger(string.format("paused %d audible %s tab(s) with media key fallback", #toggledTabs, job.app.processName))
          table.insert(tokens, {
            kind = "browserMediaKeyTabs",
            processName = job.app.processName,
            scriptName = job.app.scriptName,
            bundleID = job.app.bundleID,
            appKind = job.app.kind,
            source = "audibleBrowserTabs",
            tabs = toggledTabs,
          })
        end
      elseif job.logKind == "browser"
        and mediaKeyFallbackAllowed
        and browserPauseFailureCanUseMediaKeyFallback(result.ok, resultText, result.details)
        and browserLooksAudible(job.app) then
        pressPlayPauseKey()
        self.logger(string.format("paused audible %s with media key fallback", job.app.processName))
        table.insert(tokens, {
          kind = "mediaKey",
          processName = job.app.processName,
          source = "audibleBrowser",
        })
      elseif job.logKind == "browser" and not mediaKeyFallbackAllowed then
        self.logger(string.format("skipped media key fallback for %s after cached pause", job.app.processName))
      elseif job.logKind == "browser"
        and not browserPauseFailureCanUseMediaKeyFallback(result.ok, resultText, result.details) then
        self.logger(string.format("skipped media key fallback for %s after ambiguous result=%s", job.app.processName, tostring(resultText)))
      end
    end

    if #tokens == 0 then
      return nil, checkedSupportedApp
    end

    if #tokens == 1 then
      return tokens[1], checkedSupportedApp
    end

    return {
      kind = "multiple",
      tokens = tokens,
    }, checkedSupportedApp
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

  function player:rememberPausedToken(token)
    self.lastPausedToken = cacheablePauseToken(token)
    if self.lastPausedToken == nil then
      self.lastPausedTokenAt = nil
      return
    end

    self.lastPausedTokenAt = os.time()
  end

  function player:cachedTokenExpired()
    if self.lastPausedToken == nil or self.lastPausedTokenAt == nil then
      return false
    end

    if self.cacheMaxAgeSeconds == 0 then
      return false
    end

    return os.time() - self.lastPausedTokenAt > self.cacheMaxAgeSeconds
  end

  function player:pauseCachedTokenValue(token)
    if type(token) ~= "table" then
      return nil
    end

    if token.kind == "multiple" then
      local pausedToken = nil
      for _, childToken in ipairs(token.tokens or {}) do
        pausedToken = combinePauseTokens(pausedToken, self:pauseCachedTokenValue(childToken))
      end
      return pausedToken
    end

    if token.kind ~= "browser" or type(token.tabs) ~= "table" or #token.tabs == 0 then
      return nil
    end

    if not appIsRunning(token) then
      self.logger(string.format("skipped cached pause for closed browser %s", token.processName))
      return nil
    end

    local script = browserScriptForTabs({
      scriptName = token.scriptName,
      kind = token.appKind,
    }, browserPauseJavaScript(), didPauseResult, "not-playing", token.tabs)

    local ok, result, details = self.appleScriptRunner(script, self.appleScriptTimeout)
    local resultText = trimTrailingNewlines(result)
    local errorMessage = osascriptErrorMessage(details)
    if errorMessage ~= nil then
      self.logger(string.format(
        "checked cached %s media tabs=%d: ok=%s result=%s error=%s",
        token.processName,
        #token.tabs,
        tostring(ok),
        tostring(resultText),
        tostring(errorMessage)
      ))
    else
      self.logger(string.format(
        "checked cached %s media tabs=%d: ok=%s result=%s",
        token.processName,
        #token.tabs,
        tostring(ok),
        tostring(resultText)
      ))
    end

    if ok and resultText == didPauseResult then
      return cacheablePauseToken(token)
    end

    if browserPauseFailureIsAmbiguous(resultText, details) then
      self.logger(string.format("kept cached %s browser resume token after ambiguous result=%s", token.processName, tostring(resultText)))
      return cacheablePauseToken(token)
    end

    return nil
  end

  function player:pauseCachedToken()
    if self.lastPausedToken == nil then
      return nil
    end

    if self:cachedTokenExpired() then
      self.logger("cleared expired browser pause cache")
      self.lastPausedToken = nil
      self.lastPausedTokenAt = nil
      return nil
    end

    local token = self:pauseCachedTokenValue(self.lastPausedToken)
    if token == nil then
      self.logger("cleared stale browser pause cache")
      self.lastPausedToken = nil
      self.lastPausedTokenAt = nil
    end

    return token
  end

  function player:pauseIfPlaying()
    if self.mode == "mediaKey" then
      pressPlayPauseKey()
      self.logger("paused with media key")
      return { kind = "mediaKey" }
    end

    local cachedToken = self:pauseCachedToken()
    local mediaKeyFallbackSuppressed = {}
    addBrowserProcessesFromToken(cachedToken, mediaKeyFallbackSuppressed)
    local token, checkedSupportedApp = self:pauseAppsConcurrently(orderedAppsForPause(self.apps), {
      mediaKeyFallbackSuppressed = mediaKeyFallbackSuppressed,
    })
    token = combinePauseTokens(cachedToken, token)
    if token ~= nil then
      self:rememberPausedToken(token)
      return token
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

    if token.kind == "multiple" then
      local resumedAny = false
      for _, childToken in ipairs(token.tokens or {}) do
        resumedAny = self:resume(childToken) or resumedAny
      end
      return resumedAny
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

      local ok, result = self.appleScriptRunner(script, self.appleScriptTimeout)
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

      if type(token.tabs) == "table" and #token.tabs > 0 then
        script = browserScriptForTabs({
          scriptName = token.scriptName,
          kind = token.appKind,
        }, browserResumeJavaScript(), didResumeResult, "not-paused", token.tabs)
      end

      local ok, result = self.appleScriptRunner(script, self.appleScriptTimeout)
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
      }, token.tabs or {}, self.appleScriptRunner, self.appleScriptTimeout)

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
