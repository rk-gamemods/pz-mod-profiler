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
--
-- SORT ORDER: 00_ prefix ensures alphabetical mod managers place this
-- first so it intercepts registrations from all other mods.
--
-- SELF-COST: profiler's own engine cost (wrapper overhead, dump I/O,
-- spike-log I/O) is attributed to _selfStats, not _modStats, via saved
-- original Events.X.Add references. Overlay cost is NOT tracked — it's
-- a user-initiated tool, not part of always-on profiler overhead.

if rawget(_G, "ModProfiler") and ModProfiler._installed then
    -- Idempotent reload guard: /reloadlua shared re-executes this file
    -- but we must not re-install interception on top of already-wrapped events.
    return
end

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

local INTERVAL_TICKS       = 300      -- mutable; set via ModProfiler.setIntervalTicks()
local PRINT_INTERVAL_TICKS = 300      -- console.txt cadence: fixed 5s at 60Hz
local SUMMARY_TICKS        = 3000
local MIN_INTERVAL_TICKS   = 6
local MAX_INTERVAL_TICKS   = 3000
local SPIKE_THRESHOLD_MS   = 3
local SAMPLE_RING_SIZE     = 600      -- ~50 min of intervals
local FRAME_BUDGET_RING_SIZE = 300    -- 25 min at 5s cadence
local LIVE_RING_CAP        = 600
local MINUTE_RING_SIZE     = 30
local PERIOD_RING_SIZE     = 288      -- 24h at 5-minute buckets
local WARMUP_SWITCH_MIN    = 30
local SPIKE_LOG_CAP        = 10       -- per interval, rest suppressed
local SELF_PATH_MARKER     = "00_ModProfiler"   -- path substring identifying profiler-owned files
local SELF_MOD_NAME        = "00_ModProfiler"

---------------------------------------------------------------------------
-- Internal state
---------------------------------------------------------------------------
local _callbacks       = {}   -- [callbackId] = { event, mod, file, line, iCalls, iMs, iPeak }
local _callbackId      = 0

local _modStats        = {}   -- [modName] = { totalMs, totalCalls, peakMs, peakEvent, peakFile, peakLine, spikeCount, events={} }

-- Per-interval sample rings (for full distribution stats)
local _modIntervalSamples      = {}   -- [modName]       = { data={[1..N]=tot_ms}, n=count, w=nextWriteIdx, size=SAMPLE_RING_SIZE }
local _callbackIntervalSamples = {}   -- [callbackId]    = { avg={...}, peak={...}, calls={...}, n, w, size }

-- Shadow registry: every Add we intercept is recorded here, regardless of enabled state.
-- Used by setEnabled to swap wrappers in/out without losing track of registrations.
local _shadowRegistry  = {}   -- [eventName] = { [callbackId] = { original=fn, wrapper=fn } }

local _tickCount       = 0
local _printTickCount  = 0
local _summaryCount    = 0
local _frameCount      = 0     -- total frames since install (for header display)
local _intervalIndex   = 0     -- monotonically increasing interval counter

local _frameBudgetRing = nil
local _modLiveRings    = {}
local _modMinuteRings  = {}
local _modPeriodRings  = {}
local _modSessionTotals = {}
local _modMinuteAccum  = {}
local _modPeriodAccum  = {}
local _sessionStartMs  = getTimestampMs()
local _lastMinuteRollMs = _sessionStartMs
local _lastPeriodRollMs = _sessionStartMs
local _pendingSelfExtraMs = 0

local _originalAdds    = {}
local _originalRemoves = {}
local _origToWrapper   = {}
local _wrapperToOrig   = {}
local _wrapperToId     = {}    -- reverse lookup so Remove can clear _callbacks[id]
local _interceptedCount = 0

local _enabled         = true

-- Pending spike log buffer (flushed once per interval)
local _pendingSpikeLog = {}
local _suppressedSpikes = 0

-- Self-cost accounting (arrays, not running sums — drives percentile display)
local _selfStats = {
    wrapperPerCallMs    = { samples = {}, lastCalibratedAtMs = 0, calibrationIntervalMs = 60000 },
    intervalDumpMs      = {},
    summaryDumpMs       = {},
    spikeLogMs          = {},
}

---------------------------------------------------------------------------
-- Ring buffer helpers (O(1) writes, bounded memory)
---------------------------------------------------------------------------
local function ringCreate(size)
    return { data = {}, n = 0, w = 1, size = size }
end

local function ringPush(ring, value)
    ring.data[ring.w] = value
    ring.w = ring.w + 1
    if ring.w > ring.size then ring.w = 1 end
    if ring.n < ring.size then ring.n = ring.n + 1 end
end

local function ringToArray(ring)
    -- Returns samples in chronological order (oldest → newest)
    local out = {}
    if ring.n < ring.size then
        for i = 1, ring.n do out[i] = ring.data[i] end
    else
        local idx = 1
        for i = ring.w, ring.size do out[idx] = ring.data[i]; idx = idx + 1 end
        for i = 1, ring.w - 1 do out[idx] = ring.data[i]; idx = idx + 1 end
    end
    return out
end

local function ringResize(ring, newSize)
    if not ring or ring.size == newSize then return ring end
    local arr = ringToArray(ring)
    local start = 1
    if #arr > newSize then
        start = #arr - newSize + 1
    end
    local resized = ringCreate(newSize)
    for i = start, #arr do
        ringPush(resized, arr[i])
    end
    return resized
end

_frameBudgetRing = ringCreate(FRAME_BUDGET_RING_SIZE)

---------------------------------------------------------------------------
-- Mod name extraction from file path
---------------------------------------------------------------------------
local function extractModName(filePath)
    if not filePath or filePath == "unknown" then return "[unknown]" end
    local modName = filePath:match("media/lua/%w+/([^/]+)/")
    if modName then return modName end
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
            events     = {},
        }
    end
    return _modStats[modName]
end

local function getOrCreateModSamples(modName)
    if not _modIntervalSamples[modName] then
        _modIntervalSamples[modName] = ringCreate(SAMPLE_RING_SIZE)
    end
    return _modIntervalSamples[modName]
end

local function liveRingSize()
    local intervalSec = INTERVAL_TICKS / 60
    local size = math.ceil(300 / intervalSec)
    if size > LIVE_RING_CAP then size = LIVE_RING_CAP end
    if size < 10 then size = 10 end
    return size
end

local function getOrCreateLiveRing(modName)
    local needed = liveRingSize()
    local ring = _modLiveRings[modName]
    if not ring then
        ring = ringCreate(needed)
        _modLiveRings[modName] = ring
        return ring
    end
    if ring.size ~= needed then
        ring = ringResize(ring, needed)
        _modLiveRings[modName] = ring
    end
    return ring
end

local function currentWrapperPerCallMs()
    local samples = _selfStats.wrapperPerCallMs.samples
    local n = #samples
    if n == 0 then return 0 end
    local sum = 0
    for i = 1, n do sum = sum + samples[i] end
    return sum / n
end

local function getFrameCpuMs()
    local okCpu, cpuValue = pcall(function()
        if getCPUTime then return getCPUTime() end
        return nil
    end)
    if okCpu and cpuValue and cpuValue >= 0 then return cpuValue end
    return nil
end

local function recordIntervalAggregate(modName, totalMs, spikesThisInterval, intervalTicks)
    local msPerFrame = totalMs / intervalTicks
    ringPush(getOrCreateModSamples(modName), totalMs)
    ringPush(getOrCreateLiveRing(modName), {
        msPerFrame = msPerFrame,
        spikes = spikesThisInterval,
    })

    local sessionTotals = _modSessionTotals[modName]
    if not sessionTotals then
        sessionTotals = { totalIntervalMs = 0, totalSpikes = 0, totalIntervals = 0 }
        _modSessionTotals[modName] = sessionTotals
    end
    sessionTotals.totalIntervalMs = sessionTotals.totalIntervalMs + totalMs
    sessionTotals.totalSpikes = sessionTotals.totalSpikes + spikesThisInterval
    sessionTotals.totalIntervals = sessionTotals.totalIntervals + 1

    local minuteAccum = _modMinuteAccum[modName]
    if not minuteAccum then
        minuteAccum = { sumMs = 0, sumSpikes = 0, count = 0 }
        _modMinuteAccum[modName] = minuteAccum
    end
    minuteAccum.sumMs = minuteAccum.sumMs + msPerFrame
    minuteAccum.sumSpikes = minuteAccum.sumSpikes + spikesThisInterval
    minuteAccum.count = minuteAccum.count + 1

    local periodAccum = _modPeriodAccum[modName]
    if not periodAccum then
        periodAccum = { sumMs = 0, sumSpikes = 0, count = 0 }
        _modPeriodAccum[modName] = periodAccum
    end
    periodAccum.sumMs = periodAccum.sumMs + msPerFrame
    periodAccum.sumSpikes = periodAccum.sumSpikes + spikesThisInterval
    periodAccum.count = periodAccum.count + 1
end

local function rollTierAggregates(nowMs)
    while (nowMs - _lastMinuteRollMs) >= 60000 do
        if ((nowMs - _sessionStartMs) / 60000) < WARMUP_SWITCH_MIN then
            for modName, accum in pairs(_modMinuteAccum) do
                if accum.count > 0 then
                    local ring = _modMinuteRings[modName]
                    if not ring then
                        ring = ringCreate(MINUTE_RING_SIZE)
                        _modMinuteRings[modName] = ring
                    end
                    ringPush(ring, {
                        msPerFrame = accum.sumMs / accum.count,
                        spikes = accum.sumSpikes,
                        count = accum.count,
                    })
                    accum.sumMs = 0
                    accum.sumSpikes = 0
                    accum.count = 0
                end
            end
        end
        _lastMinuteRollMs = _lastMinuteRollMs + 60000
    end

    while (nowMs - _lastPeriodRollMs) >= 300000 do
        for modName, accum in pairs(_modPeriodAccum) do
            if accum.count > 0 then
                local ring = _modPeriodRings[modName]
                if not ring then
                    ring = ringCreate(PERIOD_RING_SIZE)
                    _modPeriodRings[modName] = ring
                end
                ringPush(ring, {
                    msPerFrame = accum.sumMs / accum.count,
                    spikes = accum.sumSpikes,
                    count = accum.count,
                })
                accum.sumMs = 0
                accum.sumSpikes = 0
                accum.count = 0
            end
        end
        _lastPeriodRollMs = _lastPeriodRollMs + 300000
    end
end

---------------------------------------------------------------------------
-- Wrapper builder (shared by install and re-enable paths)
---------------------------------------------------------------------------
local function buildWrapper(eventName, callback, cb, sourceFile, sourceLine)
    local modStat      = getOrCreateModStats(cb.mod)
    if not modStat.events[eventName] then
        modStat.events[eventName] = { totalMs = 0, totalCalls = 0 }
    end
    local modEventStat = modStat.events[eventName]
    local spikeThresh  = SPIKE_THRESHOLD_MS
    local modName      = cb.mod

    return function(...)
        local startMs = getTimestampMs()
        callback(...)
        local rawElapsed = getTimestampMs() - startMs
        local elapsed = rawElapsed - currentWrapperPerCallMs()
        if elapsed < 0 then elapsed = 0 end

        cb.iCalls = cb.iCalls + 1
        cb.iMs    = cb.iMs + elapsed
        if elapsed > cb.iPeak then cb.iPeak = elapsed end
        cb.pCalls = cb.pCalls + 1
        cb.pMs    = cb.pMs + elapsed
        if elapsed > cb.pPeak then cb.pPeak = elapsed end

        modStat.totalMs    = modStat.totalMs + elapsed
        modStat.totalCalls = modStat.totalCalls + 1
        modEventStat.totalMs    = modEventStat.totalMs + elapsed
        modEventStat.totalCalls = modEventStat.totalCalls + 1

        if elapsed > modStat.peakMs then
            modStat.peakMs    = elapsed
            modStat.peakEvent = eventName
            modStat.peakFile  = sourceFile
            modStat.peakLine  = sourceLine
        end

        if elapsed >= spikeThresh then
            modStat.spikeCount = modStat.spikeCount + 1
            if #_pendingSpikeLog < SPIKE_LOG_CAP then
                _pendingSpikeLog[#_pendingSpikeLog + 1] = string.format(
                    "%dms | %s | %s | %s:%d",
                    elapsed, eventName, modName, sourceFile, sourceLine
                )
            else
                _suppressedSpikes = _suppressedSpikes + 1
            end
        end
    end
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
    _shadowRegistry[eventName] = _shadowRegistry[eventName] or {}

    eventTable.Add = function(callback)
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
            iCalls = 0, iMs = 0, iPeak = 0,
            pCalls = 0, pMs = 0, pPeak = 0,
        }
        _callbacks[id] = cb

        local wrapped = buildWrapper(eventName, callback, cb, sourceFile, sourceLine)
        _origToWrapper[callback] = wrapped
        _wrapperToOrig[wrapped]  = callback
        _wrapperToId[wrapped]    = id
        _shadowRegistry[eventName][id] = { original = callback, wrapper = wrapped }

        -- When disabled, register the raw callback (bypasses our wrapper entirely).
        -- When enabled, register the wrapper. Shadow registry holds both refs so
        -- setEnabled can swap later without losing registrations.
        if _enabled then
            origAdd(wrapped)
        else
            origAdd(callback)
        end
    end

    if origRemove then
        eventTable.Remove = function(callback)
            local wrapper = _origToWrapper[callback]
            if wrapper then
                -- Remove whichever we registered based on current _enabled state
                if _enabled then
                    origRemove(wrapper)
                else
                    origRemove(callback)
                end
                local id = _wrapperToId[wrapper]
                if id then
                    _callbacks[id] = nil
                    _callbackIntervalSamples[id] = nil
                    if _shadowRegistry[eventName] then
                        _shadowRegistry[eventName][id] = nil
                    end
                end
                _origToWrapper[callback] = nil
                _wrapperToOrig[wrapper]  = nil
                _wrapperToId[wrapper]    = nil
            else
                origRemove(callback)
            end
        end
    end

    _interceptedCount = _interceptedCount + 1
end

---------------------------------------------------------------------------
-- Enable/disable: swap wrappers in/out using shadow registry
---------------------------------------------------------------------------
local function applyEnabledState(targetEnabled)
    if targetEnabled == _enabled then return end
    for eventName, entries in pairs(_shadowRegistry) do
        local origAdd = _originalAdds[eventName]
        local origRemove = _originalRemoves[eventName]
        if origAdd and origRemove then
            for _id, entry in pairs(entries) do
                if targetEnabled then
                    -- Switching ON: remove raw original, re-add wrapper
                    origRemove(entry.original)
                    origAdd(entry.wrapper)
                else
                    -- Switching OFF: remove wrapper, re-add raw original
                    origRemove(entry.wrapper)
                    origAdd(entry.original)
                end
            end
        end
    end
    _enabled = targetEnabled
    print(string.format("[MODPROFILER] Profiling %s", _enabled and "ENABLED" or "DISABLED"))
end

---------------------------------------------------------------------------
-- Wrapper-overhead calibration (batched, runs periodically)
---------------------------------------------------------------------------
local function calibrateWrapperOverhead()
    -- Simulate the bookkeeping work the wrapper does per-call,
    -- timing a tight loop of 1000 iterations. Divide by 1000 → per-call estimate.
    local iterations = 1000
    local fakeCb     = { iCalls = 0, iMs = 0, iPeak = 0 }
    local fakeMod    = { totalMs = 0, totalCalls = 0, peakMs = 0 }
    local fakeEvent  = { totalMs = 0, totalCalls = 0 }

    local t0 = getTimestampMs()
    for _i = 1, iterations do
        local s = getTimestampMs()
        -- simulated user callback cost = 0 (we measure wrapper cost only)
        local elapsed = getTimestampMs() - s
        fakeCb.iCalls = fakeCb.iCalls + 1
        fakeCb.iMs    = fakeCb.iMs + elapsed
        if elapsed > fakeCb.iPeak then fakeCb.iPeak = elapsed end
        fakeMod.totalMs    = fakeMod.totalMs + elapsed
        fakeMod.totalCalls = fakeMod.totalCalls + 1
        fakeEvent.totalMs    = fakeEvent.totalMs + elapsed
        fakeEvent.totalCalls = fakeEvent.totalCalls + 1
        if elapsed > fakeMod.peakMs then fakeMod.peakMs = elapsed end
    end
    local totalMs = getTimestampMs() - t0
    local perCall = totalMs / iterations

    local samples = _selfStats.wrapperPerCallMs.samples
    samples[#samples + 1] = perCall
    -- Cap samples to last 60 measurements (1 hr at 1/min)
    if #samples > 60 then
        table.remove(samples, 1)
    end
    _selfStats.wrapperPerCallMs.lastCalibratedAtMs = getTimestampMs()
end

---------------------------------------------------------------------------
-- Spike log flush
---------------------------------------------------------------------------
local function flushSpikeLog()
    if #_pendingSpikeLog == 0 and _suppressedSpikes == 0 then return end
    local t0 = getTimestampMs()
    local parts = { "[MODPROFILER] SPIKES this interval:" }
    for i = 1, #_pendingSpikeLog do
        parts[#parts + 1] = "  " .. _pendingSpikeLog[i]
    end
    if _suppressedSpikes > 0 then
        parts[#parts + 1] = string.format("  ... +%d more spikes suppressed", _suppressedSpikes)
    end
    print(table.concat(parts, "\n"))
    local elapsed = getTimestampMs() - t0
    _selfStats.spikeLogMs[#_selfStats.spikeLogMs + 1] = elapsed
    _pendingSpikeLog = {}
    _suppressedSpikes = 0
    return elapsed
end

---------------------------------------------------------------------------
-- Interval report: per-callback detail, resets after each report.
-- Also snapshots per-mod/per-callback distribution samples into ring buffers.
---------------------------------------------------------------------------
local function dumpIntervalReport(shouldPrint)
    local t0 = getTimestampMs()

    -- Snapshot callback IDs first (guard against concurrent modification)
    local ids = {}
    for id in pairs(_callbacks) do ids[#ids + 1] = id end

    -- Per-mod interval totals (aggregated from per-callback)
    local modIntervalTotal = {}
    local entries = {}
    local grandMs = 0
    local tickSpan = shouldPrint and PRINT_INTERVAL_TICKS or INTERVAL_TICKS
    local totalCalls = 0

    for i = 1, #ids do
        local id = ids[i]
        local cb = _callbacks[id]
        local calls = cb and (shouldPrint and cb.pCalls or cb.iCalls) or 0
        local totalMs = cb and (shouldPrint and cb.pMs or cb.iMs) or 0
        local peakMs = cb and (shouldPrint and cb.pPeak or cb.iPeak) or 0
        if cb and calls > 0 then
            grandMs = grandMs + totalMs
            totalCalls = totalCalls + calls
            entries[#entries + 1] = {
                event = cb.event, mod = cb.mod, file = cb.file, line = cb.line,
                avg = totalMs / calls, peak = peakMs,
                calls = calls, total = totalMs,
            }
            modIntervalTotal[cb.mod] = (modIntervalTotal[cb.mod] or 0) + totalMs

            if not shouldPrint then
                -- Push per-callback distribution samples from display snapshots only.
                local cs = _callbackIntervalSamples[id]
                if not cs then
                    cs = { avg = ringCreate(SAMPLE_RING_SIZE), peak = ringCreate(SAMPLE_RING_SIZE), calls = ringCreate(SAMPLE_RING_SIZE) }
                    _callbackIntervalSamples[id] = cs
                end
                ringPush(cs.avg, totalMs / calls)
                ringPush(cs.peak, peakMs)
                ringPush(cs.calls, calls)
            end
        end
    end

    if not shouldPrint then
        local nowMs = getTimestampMs()

        local modMs = grandMs / INTERVAL_TICKS
        local targetFps = 60
        local uncapped = false
        local okPerf, perf = pcall(getPerformance)
        if okPerf and perf then
            local okFps, fps = pcall(function() return perf:getFramerate() end)
            if okFps and fps and fps > 0 then targetFps = fps end
            local okUncapped, uncappedValue = pcall(function() return perf:isFramerateUncapped() end)
            if okUncapped then uncapped = uncappedValue == true end
        end
        local cpuMs = getFrameCpuMs()
        local budgetMs = 1000 / targetFps
        if cpuMs == nil then cpuMs = modMs end

        -- Push per-mod totals for every known mod so inactive mods decay back to zero.
        for modName, modStat in pairs(_modStats) do
            local totalMs = modIntervalTotal[modName] or 0
            local spikesThisInterval = (modStat.spikeCount or 0) - (modStat._lastSnapshotSpikeCount or 0)
            if spikesThisInterval < 0 then spikesThisInterval = 0 end
            modStat._lastSnapshotSpikeCount = modStat.spikeCount or 0
            recordIntervalAggregate(modName, totalMs, spikesThisInterval, INTERVAL_TICKS)
        end

        local engineMs = math.max(0, cpuMs - modMs)
        local headroomMs = math.max(0, budgetMs - cpuMs)
        ringPush(_frameBudgetRing, {
            cpuMs = cpuMs,
            frameMs = cpuMs,
            modMs = modMs,
            engineMs = engineMs,
            headroomMs = headroomMs,
            budgetMs = budgetMs,
            fps = targetFps,
            uncapped = uncapped,
        })

        local elapsed = getTimestampMs() - t0
        _selfStats.intervalDumpMs[#_selfStats.intervalDumpMs + 1] = elapsed

        local selfTotalMs = (currentWrapperPerCallMs() * totalCalls) + _pendingSelfExtraMs + elapsed
        recordIntervalAggregate(SELF_MOD_NAME, selfTotalMs, 0, INTERVAL_TICKS)
        _pendingSelfExtraMs = 0
        rollTierAggregates(nowMs)
        _intervalIndex = _intervalIndex + 1

        local mp = rawget(_G, "ModProfiler")
        if mp and mp._onIntervalCompleteHandlers then
            local handlers = mp._onIntervalCompleteHandlers
            for i = 1, #handlers do
                pcall(handlers[i])
            end
        end

        for i = 1, #ids do
            local cb = _callbacks[ids[i]]
            if cb then
                cb.iCalls = 0
                cb.iMs = 0
                cb.iPeak = 0
            end
        end

        return { totalCalls = totalCalls, dumpMs = elapsed, totalMs = grandMs }
    end

    table.sort(entries, function(a, b) return a.total > b.total end)

    if shouldPrint then
        local lines = {}
        lines[#lines + 1] = string.format("[MODPROFILER] ----- INTERVAL (%d ticks, %dms total) [idx=%d] -----", tickSpan, grandMs, _intervalIndex)
        local showCount = math.min(#entries, 20)
        for i = 1, showCount do
            local e = entries[i]
            local flag = e.peak >= SPIKE_THRESHOLD_MS and "!" or " "
            lines[#lines + 1] = string.format(
                "[MODPROFILER] %s %-18s | %-20s | avg=%.3fms pk=%dms n=%d tot=%dms | %s:%d",
                flag, e.event, e.mod, e.avg, e.peak, e.calls, e.total, e.file, e.line
            )
        end
        if #entries > showCount then
            lines[#lines + 1] = string.format("[MODPROFILER]   ... +%d more callbacks", #entries - showCount)
        end
        print(table.concat(lines, "\n"))
    end

    -- Reset whichever accumulator this pass consumed.
    for i = 1, #ids do
        local cb = _callbacks[ids[i]]
        if cb then
            if shouldPrint then
                cb.pCalls = 0
                cb.pMs = 0
                cb.pPeak = 0
            else
                cb.iCalls = 0
                cb.iMs = 0
                cb.iPeak = 0
            end
        end
    end

    local elapsed = getTimestampMs() - t0
    _selfStats.intervalDumpMs[#_selfStats.intervalDumpMs + 1] = elapsed

    if shouldPrint then
        local spikeLogMs = flushSpikeLog() or 0
        return { totalCalls = totalCalls, dumpMs = elapsed, spikeLogMs = spikeLogMs, totalMs = grandMs }
    end
end

---------------------------------------------------------------------------
-- Session summary: per-mod cumulative totals (never resets)
---------------------------------------------------------------------------
local function dumpSessionSummary()
    local t0 = getTimestampMs()
    local mods = {}
    for modName, ms in pairs(_modStats) do
        if ms.totalCalls > 0 then
            mods[#mods + 1] = {
                mod = modName, totalMs = ms.totalMs, totalCalls = ms.totalCalls,
                avg = ms.totalMs / ms.totalCalls, peakMs = ms.peakMs,
                peakEvent = ms.peakEvent, peakFile = ms.peakFile, peakLine = ms.peakLine,
                spikeCount = ms.spikeCount, events = ms.events,
            }
        end
    end

    table.sort(mods, function(a, b) return a.totalMs > b.totalMs end)

    local grandMs, grandCalls = 0, 0
    for i = 1, #mods do
        grandMs    = grandMs + mods[i].totalMs
        grandCalls = grandCalls + mods[i].totalCalls
    end

    local lines = {}
    lines[#lines + 1] = string.format(
        "[MODPROFILER] ===== SESSION SUMMARY (%d mods, %d calls, %dms total) =====",
        #mods, grandCalls, grandMs
    )

    local showCount = math.min(#mods, 30)
    for i = 1, showCount do
        local m = mods[i]
        local pct = grandMs > 0 and (m.totalMs / grandMs * 100) or 0
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
        lines[#lines + 1] = string.format(
            "[MODPROFILER]  %2d. %-24s %5.1f%% | tot=%6dms avg=%.3fms n=%d%s | %s",
            i, m.mod, pct, m.totalMs, m.avg, m.totalCalls, spikeStr, evStr
        )
    end
    if #mods > showCount then
        lines[#lines + 1] = string.format("[MODPROFILER]   ... +%d more mods", #mods - showCount)
    end

    -- Self-cost block (parsable by pz_log_query.py)
    lines[#lines + 1] = "[MODPROFILER] ----- SELF-COST -----"
    local function statsOf(arr)
        local n = #arr
        if n == 0 then return nil end
        local sorted = {}
        local sum = 0
        for i = 1, n do sorted[i] = arr[i]; sum = sum + arr[i] end
        table.sort(sorted)
        local function pct(p)
            local idx = math.floor(n * p / 100)
            if idx < 1 then idx = 1 end
            if idx > n then idx = n end
            return sorted[idx]
        end
        return { n = n, p50 = pct(50), p95 = pct(95), p99 = pct(99), max = sorted[n], total = sum, mean = sum / n }
    end

    local wp = statsOf(_selfStats.wrapperPerCallMs.samples)
    if wp then
        lines[#lines + 1] = string.format(
            "[MODPROFILER] SELF wrapper_per_call n=%d p50=%.4fms p95=%.4fms p99=%.4fms max=%.4fms mean=%.4fms calls=%d",
            wp.n, wp.p50, wp.p95, wp.p99, wp.max, wp.mean, grandCalls
        )
    end
    local dumps = statsOf(_selfStats.intervalDumpMs)
    if dumps then
        lines[#lines + 1] = string.format(
            "[MODPROFILER] SELF interval_dumps n=%d p50=%dms p95=%dms p99=%dms max=%dms total=%dms",
            dumps.n, dumps.p50, dumps.p95, dumps.p99, dumps.max, dumps.total
        )
    end
    local sums = statsOf(_selfStats.summaryDumpMs)
    if sums then
        lines[#lines + 1] = string.format(
            "[MODPROFILER] SELF summary_dumps n=%d p50=%dms p95=%dms p99=%dms max=%dms total=%dms",
            sums.n, sums.p50, sums.p95, sums.p99, sums.max, sums.total
        )
    end
    local spk = statsOf(_selfStats.spikeLogMs)
    if spk then
        lines[#lines + 1] = string.format(
            "[MODPROFILER] SELF spike_logs n=%d p50=%dms p95=%dms p99=%dms max=%dms total=%dms",
            spk.n, spk.p50, spk.p95, spk.p99, spk.max, spk.total
        )
    end

    lines[#lines + 1] = "[MODPROFILER] ===== END SESSION SUMMARY ====="
    print(table.concat(lines, "\n"))

    local elapsed = getTimestampMs() - t0
    _selfStats.summaryDumpMs[#_selfStats.summaryDumpMs + 1] = elapsed
    return elapsed
end

---------------------------------------------------------------------------
-- Install interception
---------------------------------------------------------------------------
for _i, eventName in ipairs(PROFILED_EVENTS) do
    interceptEvent(eventName)
end

---------------------------------------------------------------------------
-- Engine tick handler — registered via the SAVED ORIGINAL Add so it bypasses
-- its own wrapper. This is what eliminates "00_ModProfiler" appearing in
-- user-mod session deltas.
---------------------------------------------------------------------------
local function engineTick()
    _tickCount = _tickCount + 1
    _printTickCount = _printTickCount + 1
    _summaryCount = _summaryCount + 1
    _frameCount = _frameCount + 1

    -- Periodic wrapper-overhead calibration
    local nowMs = getTimestampMs()
    local wp = _selfStats.wrapperPerCallMs
    if nowMs - wp.lastCalibratedAtMs >= wp.calibrationIntervalMs then
        calibrateWrapperOverhead()
    end

    if _summaryCount >= SUMMARY_TICKS then
        _summaryCount = 0
        _pendingSelfExtraMs = _pendingSelfExtraMs + (dumpSessionSummary() or 0)
    end
    if _printTickCount >= PRINT_INTERVAL_TICKS then
        _printTickCount = 0
        local printResult = dumpIntervalReport(true)
        if printResult then
            _pendingSelfExtraMs = _pendingSelfExtraMs + (printResult.dumpMs or 0) + (printResult.spikeLogMs or 0)
        end
    end
    if _tickCount >= INTERVAL_TICKS then
        _tickCount = 0
        dumpIntervalReport(false)
    end
end

if _originalAdds["OnTick"] then
    _originalAdds["OnTick"](engineTick)
end

-- Initial calibration
calibrateWrapperOverhead()

---------------------------------------------------------------------------
-- Public API: global ModProfiler table
---------------------------------------------------------------------------
ModProfiler = {
    _installed = true,
    _onIntervalCompleteHandlers = {},
}

function ModProfiler.isEnabled() return _enabled end

function ModProfiler.setEnabled(flag)
    applyEnabledState(flag and true or false)
end

function ModProfiler.getModStats() return _modStats end
function ModProfiler.getModIntervalSamples() return _modIntervalSamples end
function ModProfiler.getCallbackIntervalSamples() return _callbackIntervalSamples end
function ModProfiler.getSelfStats() return _selfStats end
function ModProfiler.getCallbacks() return _callbacks end
function ModProfiler.getIntervalTicks() return INTERVAL_TICKS end
function ModProfiler.getTickCount() return _tickCount end
function ModProfiler.getIntervalIndex() return _intervalIndex end
function ModProfiler.getFrameCount() return _frameCount end
function ModProfiler.getSampleRingSize() return SAMPLE_RING_SIZE end
function ModProfiler.getIntervalSeconds() return INTERVAL_TICKS / 60 end

function ModProfiler.setIntervalTicks(ticks)
    ticks = tonumber(ticks) or 300
    if ticks < MIN_INTERVAL_TICKS then ticks = MIN_INTERVAL_TICKS end
    if ticks > MAX_INTERVAL_TICKS then ticks = MAX_INTERVAL_TICKS end
    INTERVAL_TICKS = math.floor(ticks)
    _tickCount = 0
end

function ModProfiler.getFrameBudgetSamples()
    return ModProfiler.ringToArray(_frameBudgetRing)
end

function ModProfiler.getTargetFrameMs()
    local ok, perf = pcall(getPerformance)
    if ok and perf then
        local okFps, fps = pcall(function() return perf:getFramerate() end)
        if okFps and fps and fps > 0 then return 1000 / fps end
    end
    return 1000 / 60
end

function ModProfiler.getModLiveSamples(modName)
    local ring = _modLiveRings[modName]
    if not ring then return {} end
    return ModProfiler.ringToArray(ring)
end

function ModProfiler.getModMinuteSamples(modName)
    local ring = _modMinuteRings[modName]
    if not ring then return {} end
    return ModProfiler.ringToArray(ring)
end

function ModProfiler.getModPeriodSamples(modName)
    local ring = _modPeriodRings[modName]
    if not ring then return {} end
    return ModProfiler.ringToArray(ring)
end

function ModProfiler.getModSessionTotals(modName)
    return _modSessionTotals[modName]
end

function ModProfiler.getSessionElapsedMinutes()
    return (getTimestampMs() - _sessionStartMs) / 60000
end

function ModProfiler.getAllModNames()
    local names = {}
    local seen = {}
    for modName in pairs(_modStats) do
        if not seen[modName] then
            names[#names + 1] = modName
            seen[modName] = true
        end
    end
    for modName in pairs(_modLiveRings) do
        if not seen[modName] then
            names[#names + 1] = modName
            seen[modName] = true
        end
    end
    return names
end

function ModProfiler.getSpikeThresholdMs()
    return SPIKE_THRESHOLD_MS
end

-- Convert a ring into a plain chronological array (oldest → newest)
function ModProfiler.ringToArray(ring) return ringToArray(ring) end

-- Register a handler that bypasses interception (used by overlay, keybinds,
-- and any other profiler-internal code that must not self-measure).
function ModProfiler.registerUnwrapped(eventName, handler)
    local origAdd = _originalAdds[eventName]
    if origAdd then
        origAdd(handler)
        return true
    end
    -- Fallback: event wasn't intercepted, use normal Add (safe — no self-wrap risk)
    if Events[eventName] and Events[eventName].Add then
        Events[eventName].Add(handler)
        return true
    end
    return false
end

-- Register a handler to fire at each interval boundary (event-driven
-- refresh for the overlay — avoids polling).
function ModProfiler.onIntervalComplete(handler)
    local list = ModProfiler._onIntervalCompleteHandlers
    list[#list + 1] = handler
end

function ModProfiler.resetSession()
    _callbackIntervalSamples = {}
    _modIntervalSamples  = {}
    _modLiveRings        = {}
    _modMinuteRings      = {}
    _modPeriodRings      = {}
    _modSessionTotals    = {}
    _modMinuteAccum      = {}
    _modPeriodAccum      = {}
    _frameBudgetRing     = ringCreate(FRAME_BUDGET_RING_SIZE)
    _tickCount           = 0
    _printTickCount      = 0
    _summaryCount        = 0
    _frameCount          = 0
    _intervalIndex       = 0
    _sessionStartMs      = getTimestampMs()
    _lastMinuteRollMs    = _sessionStartMs
    _lastPeriodRollMs    = _sessionStartMs

    for _id, cb in pairs(_callbacks) do
        cb.iCalls = 0
        cb.iMs = 0
        cb.iPeak = 0
        cb.pCalls = 0
        cb.pMs = 0
        cb.pPeak = 0
    end

    for _modName, modStat in pairs(_modStats) do
        modStat.totalMs = 0
        modStat.totalCalls = 0
        modStat.peakMs = 0
        modStat.peakEvent = ""
        modStat.peakFile = ""
        modStat.peakLine = 0
        modStat.spikeCount = 0
        modStat._lastSnapshotSpikeCount = 0
        for _eventName, eventStat in pairs(modStat.events) do
            eventStat.totalMs = 0
            eventStat.totalCalls = 0
        end
    end

    _selfStats.intervalDumpMs = {}
    _selfStats.summaryDumpMs  = {}
    _selfStats.spikeLogMs     = {}
    _selfStats.wrapperPerCallMs.samples = {}
    _selfStats.wrapperPerCallMs.lastCalibratedAtMs = 0
    _pendingSelfExtraMs = 0
    _pendingSpikeLog     = {}
    _suppressedSpikes    = 0
    print("[MODPROFILER] Session reset")
end

function ModProfiler.dumpSnapshot()
    print("[MODPROFILER] SNAPSHOT v=2 BEGIN")
    dumpSessionSummary()
    print("[MODPROFILER] SNAPSHOT v=2 END")
end

ModProfiler._installed = true

print(string.format(
    "[MODPROFILER] Installed: %d/%d events intercepted, interval=%d ticks, summary=%d ticks, sample_ring=%d",
    _interceptedCount, #PROFILED_EVENTS, INTERVAL_TICKS, SUMMARY_TICKS, SAMPLE_RING_SIZE
))
