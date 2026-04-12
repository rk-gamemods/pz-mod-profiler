-- ModProfiler.lua
-- Universal mod callback profiler for Project Zomboid Build 42.
--
-- HOW IT WORKS: Intercepts Events.X.Add() for high-impact events and wraps
-- each incoming callback with a timing closure. Aggregates per-MOD totals
-- across the entire game session, exposing which mods are the real cost.
--
-- TIMING PRECISION: PZ Lua only has getTimestampMs() (1ms resolution).
-- Sub-millisecond callbacks individually read as 0ms or 1ms. But over
-- hundreds/thousands of calls the totals converge to the true fractional
-- cost via statistical accumulation (same principle as sigma-delta ADCs).
-- A callback averaging 0.3ms will show avg=0.300ms after enough samples.
--
-- SORT ORDER: 00_ prefix ensures alphabetical mod managers place this
-- first so it intercepts registrations from all other mods.

---------------------------------------------------------------------------
-- Configuration
---------------------------------------------------------------------------
local PROFILED_EVENTS = {
    -- Per-frame (highest impact)
    "OnTick",
    "OnTickEvenPaused",
    "OnPlayerUpdate",
    "OnRenderUpdate",
    "OnRenderTick",
    "OnPreUIDraw",
    "OnPostUIDraw",
    -- Periodic / burst
    "EveryOneMinute",
    "EveryTenMinutes",
    "EveryHours",
    "LoadGridsquare",
    "ReuseGridsquare",
    -- Collision / movement
    "OnCharacterCollide",
    "OnPlayerMove",
    -- Game lifecycle (startup lag)
    "OnGameStart",
    "OnGameBoot",
    "OnCreatePlayer",
    "OnInitWorld",
    "OnPreMapLoad",
    "OnPostMapLoad",
    -- Climate / weather
    "OnClimateTick",
    -- Container / inventory
    "OnRefreshInventoryWindowContainers",
    "OnFillInventoryObjectContextMenu",
    "OnFillWorldObjectContextMenu",
}

local INTERVAL_TICKS     = 300   -- ticks between interval reports
local SUMMARY_TICKS      = 3000  -- ticks between session summaries (~5 min at 10 tick/s)
local SPIKE_THRESHOLD_MS = 3     -- immediate log for callbacks above this

---------------------------------------------------------------------------
-- Internal state
---------------------------------------------------------------------------
-- Per-callback tracking (resets each interval for the interval report)
local _callbacks       = {}   -- [callbackId] = { event, mod, file, line, iCalls, iMs, iPeak }
local _callbackId      = 0

-- Per-mod SESSION totals (never reset)
local _modStats        = {}   -- [modName] = { totalMs, totalCalls, peakMs, peakEvent, peakFile, peakLine, spikeCount, events={} }

local _tickCount       = 0
local _summaryCount    = 0
local _originalAdds    = {}
local _originalRemoves = {}
local _origToWrapper   = {}
local _wrapperToOrig   = {}
local _interceptedCount = 0

---------------------------------------------------------------------------
-- Mod name extraction from file path
---------------------------------------------------------------------------
local function extractModName(filePath)
    if not filePath or filePath == "unknown" then return "[unknown]" end
    -- Paths look like: media/lua/shared/ModName/... or media/lua/client/ModName/...
    local modName = filePath:match("media/lua/%w+/([^/]+)/")
    if modName then return modName end
    -- No subfolder (vanilla PZ files directly in shared/client/server)
    if filePath:match("media/lua/%w+/[^/]+%.lua$") then return "[vanilla]" end
    return filePath
end

local function getOrCreateModStats(modName)
    if not _modStats[modName] then
        _modStats[modName] = {
            totalMs    = 0,
            totalCalls = 0,
            peakMs     = 0,
            peakEvent  = "",
            peakFile   = "",
            peakLine   = 0,
            spikeCount = 0,
            events     = {},   -- [eventName] = { totalMs, totalCalls }
        }
    end
    return _modStats[modName]
end

---------------------------------------------------------------------------
-- Interceptor installation
---------------------------------------------------------------------------
local function interceptEvent(eventName)
    local eventTable = Events[eventName]
    if not eventTable then return end

    local origAdd = eventTable.Add
    local origRemove = eventTable.Remove
    if not origAdd then return end

    _originalAdds[eventName] = origAdd
    _originalRemoves[eventName] = origRemove

    eventTable.Add = function(callback)
        -- Capture source attribution BEFORE wrapping
        local sourceFile = "unknown"
        local sourceLine = 0
        pcall(function()
            sourceFile = getFilenameOfClosure(callback) or "unknown"
            sourceLine = getFirstLineOfClosure(callback) or 0
        end)

        local modName = extractModName(sourceFile)

        _callbackId = _callbackId + 1
        local id = _callbackId
        local cb = {
            event = eventName,
            mod   = modName,
            file  = sourceFile,
            line  = sourceLine,
            -- Interval counters (reset each report)
            iCalls = 0,
            iMs    = 0,
            iPeak  = 0,
        }
        _callbacks[id] = cb

        -- Ensure mod session stats exist
        local ms = getOrCreateModStats(modName)
        if not ms.events[eventName] then
            ms.events[eventName] = { totalMs = 0, totalCalls = 0 }
        end

        -- Upvalue refs for hot path
        local modStat      = ms
        local modEventStat = ms.events[eventName]
        local spikeThresh  = SPIKE_THRESHOLD_MS

        local wrapped = function(...)
            local startMs = getTimestampMs()
            callback(...)
            local elapsed = getTimestampMs() - startMs

            -- Per-callback interval stats
            cb.iCalls = cb.iCalls + 1
            cb.iMs    = cb.iMs + elapsed
            if elapsed > cb.iPeak then
                cb.iPeak = elapsed
            end

            -- Per-mod SESSION stats (never reset)
            modStat.totalMs    = modStat.totalMs + elapsed
            modStat.totalCalls = modStat.totalCalls + 1
            modEventStat.totalMs    = modEventStat.totalMs + elapsed
            modEventStat.totalCalls = modEventStat.totalCalls + 1

            if elapsed > modStat.peakMs then
                modStat.peakMs   = elapsed
                modStat.peakEvent = eventName
                modStat.peakFile  = sourceFile
                modStat.peakLine  = sourceLine
            end

            if elapsed >= spikeThresh then
                modStat.spikeCount = modStat.spikeCount + 1
                print(string.format(
                    "[MODPROFILER] SPIKE %dms | %s | %s | %s:%d",
                    elapsed, eventName, modName, sourceFile, sourceLine
                ))
            end
        end

        _origToWrapper[callback] = wrapped
        _wrapperToOrig[wrapped]  = callback
        origAdd(wrapped)
    end

    if origRemove then
        eventTable.Remove = function(callback)
            local wrapper = _origToWrapper[callback]
            if wrapper then
                origRemove(wrapper)
                _origToWrapper[callback] = nil
                _wrapperToOrig[wrapper]  = nil
            else
                origRemove(callback)
            end
        end
    end

    _interceptedCount = _interceptedCount + 1
end

for _, eventName in ipairs(PROFILED_EVENTS) do
    interceptEvent(eventName)
end

---------------------------------------------------------------------------
-- Interval report: per-callback detail, resets after each report
---------------------------------------------------------------------------
local function dumpIntervalReport()
    local entries = {}
    local grandMs = 0

    for id, cb in pairs(_callbacks) do
        if cb.iCalls > 0 then
            grandMs = grandMs + cb.iMs
            entries[#entries + 1] = {
                event = cb.event,
                mod   = cb.mod,
                file  = cb.file,
                line  = cb.line,
                avg   = cb.iMs / cb.iCalls,
                peak  = cb.iPeak,
                calls = cb.iCalls,
                total = cb.iMs,
            }
        end
    end

    table.sort(entries, function(a, b) return a.total > b.total end)

    print(string.format("[MODPROFILER] ----- INTERVAL (%d ticks, %dms total) -----", INTERVAL_TICKS, grandMs))

    local showCount = math.min(#entries, 20)
    for i = 1, showCount do
        local e = entries[i]
        local flag = e.peak >= SPIKE_THRESHOLD_MS and "!" or " "
        print(string.format(
            "[MODPROFILER] %s %-18s | %-20s | avg=%.3fms pk=%dms n=%d tot=%dms | %s:%d",
            flag, e.event, e.mod, e.avg, e.peak, e.calls, e.total, e.file, e.line
        ))
    end
    if #entries > showCount then
        print(string.format("[MODPROFILER]   ... +%d more callbacks", #entries - showCount))
    end

    -- Reset interval counters
    for id, cb in pairs(_callbacks) do
        cb.iCalls = 0
        cb.iMs    = 0
        cb.iPeak  = 0
    end
end

---------------------------------------------------------------------------
-- Session summary: per-mod cumulative totals (never resets)
---------------------------------------------------------------------------
local function dumpSessionSummary()
    local mods = {}
    for modName, ms in pairs(_modStats) do
        if ms.totalCalls > 0 then
            mods[#mods + 1] = {
                mod        = modName,
                totalMs    = ms.totalMs,
                totalCalls = ms.totalCalls,
                avg        = ms.totalMs / ms.totalCalls,
                peakMs     = ms.peakMs,
                peakEvent  = ms.peakEvent,
                peakFile   = ms.peakFile,
                peakLine   = ms.peakLine,
                spikeCount = ms.spikeCount,
                events     = ms.events,
            }
        end
    end

    table.sort(mods, function(a, b) return a.totalMs > b.totalMs end)

    local grandMs    = 0
    local grandCalls = 0
    for _, m in ipairs(mods) do
        grandMs    = grandMs + m.totalMs
        grandCalls = grandCalls + m.totalCalls
    end

    print(string.format(
        "[MODPROFILER] ===== SESSION SUMMARY (%d mods, %d calls, %dms total) =====",
        #mods, grandCalls, grandMs
    ))

    local showCount = math.min(#mods, 30)
    for i = 1, showCount do
        local m = mods[i]
        local pct = grandMs > 0 and (m.totalMs / grandMs * 100) or 0

        -- Build per-event breakdown string (top 3 events by time)
        local evList = {}
        for eName, eStat in pairs(m.events) do
            if eStat.totalCalls > 0 then
                evList[#evList + 1] = { name = eName, ms = eStat.totalMs, calls = eStat.totalCalls }
            end
        end
        table.sort(evList, function(a, b) return a.ms > b.ms end)
        local evParts = {}
        for j = 1, math.min(#evList, 3) do
            evParts[#evParts + 1] = string.format("%s=%dms", evList[j].name, evList[j].ms)
        end
        local evStr = table.concat(evParts, " ")

        local spikeStr = m.spikeCount > 0
            and string.format(" spikes=%d worst=%dms@%s", m.spikeCount, m.peakMs, m.peakEvent)
            or ""

        print(string.format(
            "[MODPROFILER]  %2d. %-24s %5.1f%% | tot=%6dms avg=%.3fms n=%d%s | %s",
            i, m.mod, pct, m.totalMs, m.avg, m.totalCalls, spikeStr, evStr
        ))
    end
    if #mods > showCount then
        print(string.format("[MODPROFILER]   ... +%d more mods", #mods - showCount))
    end

    print("[MODPROFILER] ===== END SESSION SUMMARY =====")
end

---------------------------------------------------------------------------
-- Tick handler
---------------------------------------------------------------------------
Events.OnTick.Add(function()
    _tickCount    = _tickCount + 1
    _summaryCount = _summaryCount + 1

    if _tickCount >= INTERVAL_TICKS then
        _tickCount = 0
        dumpIntervalReport()
    end

    if _summaryCount >= SUMMARY_TICKS then
        _summaryCount = 0
        dumpSessionSummary()
    end
end)

print(string.format(
    "[MODPROFILER] Installed: %d/%d events intercepted, interval=%d ticks, summary=%d ticks",
    _interceptedCount, #PROFILED_EVENTS, INTERVAL_TICKS, SUMMARY_TICKS
))
