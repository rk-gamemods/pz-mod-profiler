-- ModProfiler.lua
-- Universal mod callback profiler for Project Zomboid Build 42.

if rawget(_G, "ModProfiler") and ModProfiler._installed then
    return
end

---------------------------------------------------------------------------
-- Configuration
---------------------------------------------------------------------------
local PROFILED_EVENTS = {
    "OnTick", "OnTickEvenPaused", "OnPlayerUpdate", "OnRenderUpdate",
    "OnRenderTick", "OnPreUIDraw", "OnPostUIDraw",
    "EveryOneMinute", "EveryTenMinutes", "EveryHours",
    "LoadGridsquare", "ReuseGridsquare",
    "OnCharacterCollide", "OnPlayerMove",
    "OnGameStart", "OnGameBoot", "OnCreatePlayer",
    "OnInitWorld", "OnPreMapLoad", "OnPostMapLoad",
    "OnClimateTick",
    "OnRefreshInventoryWindowContainers",
    "OnFillInventoryObjectContextMenu",
    "OnFillWorldObjectContextMenu",
}

local INTERVAL_TICKS       = 120        -- mutable; set via ModProfiler.setIntervalTicks
local PRINT_INTERVAL_TICKS = 300        -- console.txt cadence: always 5s at 60Hz
local SUMMARY_TICKS        = 3000
local MIN_INTERVAL_TICKS   = 6          -- 0.1s at 60Hz
local MAX_INTERVAL_TICKS   = 3000       -- 50s at 60Hz
local SPIKE_THRESHOLD_MS   = 3

local LIVE_RING_CAP        = 600
local MINUTE_RING_SIZE     = 30
local PERIOD_RING_SIZE     = 288
local WARMUP_SWITCH_MIN    = 30
local FRAME_BUDGET_RING_SIZE = 300

---------------------------------------------------------------------------
-- Ring buffer primitive
---------------------------------------------------------------------------
local function ringCreate(size)
    return { data = {}, size = size, head = 0, count = 0 }
end

local function ringPush(ring, value)
    ring.head = (ring.head % ring.size) + 1
    ring.data[ring.head] = value
    if ring.count < ring.size then ring.count = ring.count + 1 end
end

local function ringToArray(ring)
    local out = {}
    if ring.count == 0 then return out end
    if ring.count < ring.size then
        for i = 1, ring.count do out[i] = ring.data[i] end
    else
        local idx = 0
        for i = ring.head + 1, ring.size do
            idx = idx + 1; out[idx] = ring.data[i]
        end
        for i = 1, ring.head do
            idx = idx + 1; out[idx] = ring.data[i]
        end
    end
    return out
end

-- O(1) indexed access into a ring without copying to a new array.
-- i = 1 is the oldest entry, i = ring.count is the newest.
local function ringGet(ring, i)
    if i < 1 or i > ring.count then return nil end
    if ring.count < ring.size then return ring.data[i] end
    return ring.data[((ring.head + i - 1) % ring.size) + 1]
end

---------------------------------------------------------------------------
-- Internal state
---------------------------------------------------------------------------
local _callbacks        = {}
local _callbackId       = 0
local _modStats         = {}

local _tickCount        = 0
local _printTickCount   = 0
local _summaryCount     = 0
local _frameCount       = 0

local _originalAdds     = {}
local _originalRemoves  = {}
local _origToWrapper    = {}
local _wrapperToOrig    = {}
local _wrapperToId      = {}   -- wrapper → callback-id; for cleanup on Remove
local _interceptedCount = 0

-- Tiered per-mod aggregation
local _modLiveRings     = {}
local _modMinuteRings   = {}
local _modPeriodRings   = {}
local _modSessionTotals = {}
local _modMinuteAccum   = {}
local _modPeriodAccum   = {}

local _sessionStartMs   = getTimestampMs()
local _lastMinuteRollMs = _sessionStartMs
local _lastPeriodRollMs = _sessionStartMs

-- Frame budget ring
local _frameBudgetRing  = ringCreate(FRAME_BUDGET_RING_SIZE)

-- Per-tick CPU sampling (averaged at each interval report)
local _cpuMsSum    = 0
local _cpuMsCount  = 0
local _cpuMsPeak   = 0

-- Per-tick CPU/GPU wait sampling (render-sync overhead)
local _cpuWaitSum   = 0
local _cpuWaitCount = 0
local _gpuWaitSum   = 0
local _gpuWaitCount = 0

-- Per-interval heap tracking for GC pressure detection
local _heapFreeAtIntervalStart = 0
local _heapTotalAtIntervalStart = 0

-- Dirty flag: set after each interval report so the UI refreshes exactly
-- at interval boundaries — not on a separate timer.
local _snapshotDirty = false

-- Self-stats: profiler wrapper overhead
local _selfStats = {
    wrapperCalibratedMs = 0,            -- current calibrated wrapper cost per call
    wrapperSamples      = {},           -- recent wrapper-cost calibration samples
    dumpMsRing          = ringCreate(120),  -- ms spent in dumpIntervalReport
    spikeLogMs          = 0,            -- not currently tracked beyond zero
    lastCalibratedAtMs  = 0,
    calibrationIntervalMs = 60000,      -- re-calibrate every minute
}

---------------------------------------------------------------------------
-- Helpers
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
            _lastSnapshotSpikeCount = 0,
        }
    end
    return _modStats[modName]
end

local function liveRingSize()
    local intervalSec = INTERVAL_TICKS / 60
    local size = math.ceil(300 / intervalSec)
    if size > LIVE_RING_CAP then size = LIVE_RING_CAP end
    if size < 10 then size = 10 end
    return size
end

local function getOrCreateLiveRing(mod)
    local r = _modLiveRings[mod]
    if not r or r.size ~= liveRingSize() then
        r = ringCreate(liveRingSize())
        _modLiveRings[mod] = r
    end
    return r
end

---------------------------------------------------------------------------
-- Safe probes for optional PZ APIs.
--
-- Kahlua rule of thumb: pcall does NOT rescue you from calling a nil
-- method on a Java object — the JVM throws RuntimeException("Tried to
-- call nil") and Kahlua's pcall fails to wrap it. So we have to:
--   1. Check the Lua global exists before calling it.
--   2. Check the method exists on the returned Java proxy before calling.
-- The `type(x) == "function"` check is safe; calling-then-catching is not.
---------------------------------------------------------------------------
-- Cached once we've seen a Performance object that works — avoids
-- repeated nil-method probing every interval.
local _perfMethodProbed = false
local _hasGetFramerate        = false
local _hasIsFramerateUncapped = false
local _hasGetUncappedFramerate = false

local function probeFps()
    local targetFps = 60
    local uncapped  = false
    if type(getPerformance) ~= "function" then return targetFps, uncapped end
    local ok, perf = pcall(getPerformance)
    if not ok or perf == nil then return targetFps, uncapped end

    if not _perfMethodProbed then
        -- On Java proxies, indexing a missing method returns nil in Kahlua.
        _hasGetFramerate         = type(perf.getFramerate) == "function"
        _hasIsFramerateUncapped  = type(perf.isFramerateUncapped) == "function"
        _hasGetUncappedFramerate = type(perf.getUncappedFrameRate) == "function"
        _perfMethodProbed = true
    end

    if _hasGetFramerate then
        local okFps, fps = pcall(perf.getFramerate, perf)
        if okFps and fps and fps > 0 then targetFps = fps end
    end
    if _hasIsFramerateUncapped then
        local okUn, un = pcall(perf.isFramerateUncapped, perf)
        if okUn then uncapped = un == true end
    elseif _hasGetUncappedFramerate then
        local okUn, un = pcall(perf.getUncappedFrameRate, perf)
        if okUn then uncapped = un == true end
    end
    return targetFps, uncapped
end

local function probeCpuMs()
    if type(getCPUTime) ~= "function" then return nil end
    local ok, cpu = pcall(getCPUTime)
    if ok and type(cpu) == "number" and cpu >= 0 then return cpu end
    return nil
end

local function probeCpuWaitMs()
    if type(getCPUWait) ~= "function" then return nil end
    local ok, v = pcall(getCPUWait)
    if ok and type(v) == "number" and v >= 0 then return v end
    return nil
end

local function probeGpuWaitMs()
    if type(getGPUWait) ~= "function" then return nil end
    local ok, v = pcall(getGPUWait)
    if ok and type(v) == "number" and v >= 0 then return v end
    return nil
end

local function probeHeapMb()
    -- Prefer ZBPerfBridge (works in single-player via JMX)
    if type(ZBPerfBridge) == "table" and type(ZBPerfBridge.getHeapFreeMb) == "function" then
        local okF, free  = pcall(ZBPerfBridge.getHeapFreeMb)
        local okT, total = pcall(ZBPerfBridge.getHeapTotalMb)
        if okF and okT and type(free) == "number" and type(total) == "number"
           and free > 0 and total > 0 then
            return free, total
        end
    end
    -- Fallback: PZ getPerformanceLocal (multiplayer only)
    if type(getPerformanceLocal) ~= "function" then return nil, nil end
    local ok, t = pcall(getPerformanceLocal)
    if not ok or type(t) ~= "table" then return nil, nil end
    local free  = t["memory-free"]
    local total = t["memory-total"]
    if type(free) == "number" and free > 0 and type(total) == "number" and total > 0 then
        return free, total
    end
    return nil, nil
end

--- Snapshot GC counters. Call once per interval.
-- Returns (deltaCount, deltaTimeMs) or (nil, nil) if bridge unavailable.
local function probeGcDelta()
    if type(ZBPerfBridge) ~= "table" or type(ZBPerfBridge.snapshotGc) ~= "function" then
        return nil, nil
    end
    local ok = pcall(ZBPerfBridge.snapshotGc)
    if not ok then return nil, nil end
    local okC, count = pcall(ZBPerfBridge.getGcDeltaCount)
    local okT, timeMs = pcall(ZBPerfBridge.getGcDeltaTimeMs)
    if okC and okT then return count, timeMs end
    return nil, nil
end

local function calibrateWrapperOverhead()
    -- Cheap calibration: run a trivial closure N times, measure elapsed, compute per-call ms.
    local N = 200
    local f = function() end
    local start = getTimestampMs()
    for i = 1, N do f() end
    local elapsed = getTimestampMs() - start
    local perCall = elapsed / N
    local s = _selfStats.wrapperSamples
    s[#s + 1] = perCall
    if #s > 30 then table.remove(s, 1) end
    local sum = 0
    for i = 1, #s do sum = sum + s[i] end
    _selfStats.wrapperCalibratedMs = sum / #s
    _selfStats.lastCalibratedAtMs = getTimestampMs()
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

    _originalAdds[eventName]    = origAdd
    _originalRemoves[eventName] = origRemove

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
            event = eventName, mod = modName, file = sourceFile, line = sourceLine,
            iCalls = 0, iMs = 0, iPeak = 0,
        }
        _callbacks[id] = cb

        local ms = getOrCreateModStats(modName)
        if not ms.events[eventName] then
            ms.events[eventName] = { totalMs = 0, totalCalls = 0 }
        end

        local modStat      = ms
        local modEventStat = ms.events[eventName]
        local spikeThresh  = SPIKE_THRESHOLD_MS

        local wrapped = function(...)
            local startMs = getTimestampMs()
            callback(...)
            local elapsed = getTimestampMs() - startMs

            cb.iCalls = cb.iCalls + 1
            cb.iMs    = cb.iMs + elapsed
            if elapsed > cb.iPeak then cb.iPeak = elapsed end

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
                print(string.format(
                    "[MODPROFILER] SPIKE %dms | %s | %s | %s:%d",
                    elapsed, eventName, modName, sourceFile, sourceLine
                ))
            end
        end

        _origToWrapper[callback] = wrapped
        _wrapperToOrig[wrapped]  = callback
        _wrapperToId[wrapped]    = id
        origAdd(wrapped)
    end

    if origRemove then
        eventTable.Remove = function(callback)
            local wrapper = _origToWrapper[callback]
            if wrapper then
                origRemove(wrapper)
                local cbId = _wrapperToId[wrapper]
                if cbId then _callbacks[cbId] = nil; _wrapperToId[wrapper] = nil end
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
-- Interval report
---------------------------------------------------------------------------
local function dumpIntervalReport(shouldPrint)
    local dumpStart = getTimestampMs()
    local entries = {}
    local grandMs = 0
    local modIntervalTotal = {}

    for id, cb in pairs(_callbacks) do
        if cb.iCalls > 0 then
            grandMs = grandMs + cb.iMs
            modIntervalTotal[cb.mod] = (modIntervalTotal[cb.mod] or 0) + cb.iMs
            entries[#entries + 1] = {
                event = cb.event, mod = cb.mod, file = cb.file, line = cb.line,
                avg   = cb.iMs / cb.iCalls, peak = cb.iPeak,
                calls = cb.iCalls, total = cb.iMs,
            }
        end
    end

    -- Tiered per-mod aggregation
    local intervalSec = INTERVAL_TICKS / 60
    for modName, totalMs in pairs(modIntervalTotal) do
        local msPerFrame = totalMs / INTERVAL_TICKS
        local spikesThisInterval = 0
        local modEntry = _modStats[modName]
        if modEntry then
            spikesThisInterval = (modEntry.spikeCount or 0) - (modEntry._lastSnapshotSpikeCount or 0)
            modEntry._lastSnapshotSpikeCount = modEntry.spikeCount or 0
        end
        ringPush(getOrCreateLiveRing(modName), { msPerFrame = msPerFrame, spikes = spikesThisInterval })

        local tot = _modSessionTotals[modName]
        if not tot then
            tot = { totalIntervalMs = 0, totalSpikes = 0, totalIntervals = 0 }
            _modSessionTotals[modName] = tot
        end
        tot.totalIntervalMs = tot.totalIntervalMs + totalMs
        tot.totalSpikes     = tot.totalSpikes + spikesThisInterval
        tot.totalIntervals  = tot.totalIntervals + 1

        local ma = _modMinuteAccum[modName]
        if not ma then ma = { sumMs = 0, sumSpikes = 0, count = 0 }; _modMinuteAccum[modName] = ma end
        ma.sumMs = ma.sumMs + msPerFrame; ma.sumSpikes = ma.sumSpikes + spikesThisInterval; ma.count = ma.count + 1

        local pa = _modPeriodAccum[modName]
        if not pa then pa = { sumMs = 0, sumSpikes = 0, count = 0 }; _modPeriodAccum[modName] = pa end
        pa.sumMs = pa.sumMs + msPerFrame; pa.sumSpikes = pa.sumSpikes + spikesThisInterval; pa.count = pa.count + 1
    end

    -- Minute & period roll-overs
    local nowMs = getTimestampMs()
    local elapsedMin = (nowMs - _sessionStartMs) / 60000
    if elapsedMin < WARMUP_SWITCH_MIN and (nowMs - _lastMinuteRollMs) >= 60000 then
        for mod, acc in pairs(_modMinuteAccum) do
            if acc.count > 0 then
                local ring = _modMinuteRings[mod]
                if not ring then ring = ringCreate(MINUTE_RING_SIZE); _modMinuteRings[mod] = ring end
                ringPush(ring, { msPerFrame = acc.sumMs / acc.count, spikes = acc.sumSpikes, count = acc.count })
                acc.sumMs, acc.sumSpikes, acc.count = 0, 0, 0
            end
        end
        _lastMinuteRollMs = nowMs
    end

    if (nowMs - _lastPeriodRollMs) >= 300000 then
        for mod, acc in pairs(_modPeriodAccum) do
            if acc.count > 0 then
                local ring = _modPeriodRings[mod]
                if not ring then ring = ringCreate(PERIOD_RING_SIZE); _modPeriodRings[mod] = ring end
                ringPush(ring, { msPerFrame = acc.sumMs / acc.count, spikes = acc.sumSpikes, count = acc.count })
                acc.sumMs, acc.sumSpikes, acc.count = 0, 0, 0
            end
        end
        _lastPeriodRollMs = nowMs
    end

    -- Frame budget snapshot.
    -- NOTE: Kahlua's pcall does NOT catch "Tried to call nil" Java-side for
    -- missing methods on Java objects. Probe existence before calling.
    local targetFps, uncapped = probeFps()
    local budgetMs = 1000 / targetFps
    -- Use the AVERAGE of per-tick CPU samples taken during the interval,
    -- not a single instant sample. Averaging matches modMs semantics
    -- (also averaged) and prevents instant-cpu spikes from biasing the
    -- headroom/engine bands and producing the "creeping load" artifact.
    local cpuMs
    if _cpuMsCount > 0 then
        cpuMs = _cpuMsSum / _cpuMsCount
    end
    if not cpuMs then cpuMs = grandMs / INTERVAL_TICKS end
    -- Reset per-tick CPU accumulator for the next interval window.
    _cpuMsSum, _cpuMsCount, _cpuMsPeak = 0, 0, 0

    -- Average CPU/GPU wait for this interval.
    local cpuWaitMs = _cpuWaitCount > 0 and (_cpuWaitSum / _cpuWaitCount) or 0
    local gpuWaitMs = _gpuWaitCount > 0 and (_gpuWaitSum / _gpuWaitCount) or 0
    _cpuWaitSum, _cpuWaitCount = 0, 0
    _gpuWaitSum, _gpuWaitCount = 0, 0

    -- Heap snapshot: capture free/total now and compute delta since last interval.
    local heapFreeMb, heapTotalMb = probeHeapMb()
    local heapAllocMb = 0  -- positive = net allocation since last interval
    if heapFreeMb and _heapFreeAtIntervalStart > 0 then
        heapAllocMb = _heapFreeAtIntervalStart - heapFreeMb  -- free went down = alloc
    end
    _heapFreeAtIntervalStart  = heapFreeMb or 0
    _heapTotalAtIntervalStart = heapTotalMb or 0

    -- GC snapshot: delta collections and pause time since last interval.
    local gcDeltaCount, gcDeltaTimeMs = probeGcDelta()

    local modMs      = grandMs / INTERVAL_TICKS
    local engineMs   = math.max(0, cpuMs - modMs)
    local headroomMs = math.max(0, budgetMs - cpuMs)
    ringPush(_frameBudgetRing, {
        cpuMs = cpuMs, modMs = modMs, engineMs = engineMs,
        headroomMs = headroomMs, budgetMs = budgetMs,
        fps = targetFps, uncapped = uncapped,
        cpuWaitMs = cpuWaitMs, gpuWaitMs = gpuWaitMs,
        heapFreeMb = heapFreeMb or 0, heapTotalMb = heapTotalMb or 0,
        heapAllocMb = heapAllocMb,
        gcCount = gcDeltaCount or 0, gcTimeMs = gcDeltaTimeMs or 0,
    })
    _snapshotDirty = true

    -- Console output (print cadence only)
    if shouldPrint then
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
    end

    -- Reset interval counters
    for id, cb in pairs(_callbacks) do
        cb.iCalls = 0; cb.iMs = 0; cb.iPeak = 0
    end

    ringPush(_selfStats.dumpMsRing, getTimestampMs() - dumpStart)
end

---------------------------------------------------------------------------
-- Session summary
---------------------------------------------------------------------------
local function dumpSessionSummary()
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
    for _, m in ipairs(mods) do grandMs = grandMs + m.totalMs; grandCalls = grandCalls + m.totalCalls end
    print(string.format(
        "[MODPROFILER] ===== SESSION SUMMARY (%d mods, %d calls, %dms total) =====",
        #mods, grandCalls, grandMs))
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
            and string.format(" spikes=%d worst=%dms@%s", m.spikeCount, m.peakMs, m.peakEvent) or ""
        print(string.format(
            "[MODPROFILER]  %2d. %-24s %5.1f%% | tot=%6dms avg=%.3fms n=%d%s | %s",
            i, m.mod, pct, m.totalMs, m.avg, m.totalCalls, spikeStr, evStr))
    end
    if #mods > showCount then
        print(string.format("[MODPROFILER]   ... +%d more mods", #mods - showCount))
    end
    print("[MODPROFILER] ===== END SESSION SUMMARY =====")
end

---------------------------------------------------------------------------
-- Engine tick
---------------------------------------------------------------------------
local function engineTick()
    _tickCount      = _tickCount + 1
    _printTickCount = _printTickCount + 1
    _summaryCount   = _summaryCount + 1
    _frameCount     = _frameCount + 1

    -- Sample frame CPU per-tick so the interval report can AVERAGE it,
    -- matching the per-tick averaging we do for modMs. Single sampling
    -- (once per interval) mixes instant-CPU with average-mod, giving a
    -- math error that grows with session length and spike frequency.
    local cpu = probeCpuMs()
    if cpu then
        _cpuMsSum   = _cpuMsSum + cpu
        _cpuMsCount = _cpuMsCount + 1
        if cpu > _cpuMsPeak then _cpuMsPeak = cpu end
    end

    -- Sample CPU/GPU render-sync wait per tick.
    local cw = probeCpuWaitMs()
    if cw then _cpuWaitSum = _cpuWaitSum + cw; _cpuWaitCount = _cpuWaitCount + 1 end
    local gw = probeGpuWaitMs()
    if gw then _gpuWaitSum = _gpuWaitSum + gw; _gpuWaitCount = _gpuWaitCount + 1 end

    local nowMs = getTimestampMs()
    if nowMs - _selfStats.lastCalibratedAtMs >= _selfStats.calibrationIntervalMs then
        calibrateWrapperOverhead()
    end

    if _tickCount >= INTERVAL_TICKS then
        _tickCount = 0
        dumpIntervalReport(false)
    end
    if _printTickCount >= PRINT_INTERVAL_TICKS then
        _printTickCount = 0
        dumpIntervalReport(true)
    end
    if _summaryCount >= SUMMARY_TICKS then
        _summaryCount = 0
        dumpSessionSummary()
    end
end

Events.OnTick.Add(engineTick)

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
ModProfiler = ModProfiler or {}
ModProfiler._installed = true

function ModProfiler.isEnabled() return true end

function ModProfiler.setIntervalTicks(ticks)
    ticks = tonumber(ticks) or 120
    if ticks < MIN_INTERVAL_TICKS then ticks = MIN_INTERVAL_TICKS end
    if ticks > MAX_INTERVAL_TICKS then ticks = MAX_INTERVAL_TICKS end
    INTERVAL_TICKS = math.floor(ticks)
    _tickCount = 0
end

function ModProfiler.getIntervalTicks()    return INTERVAL_TICKS end
function ModProfiler.getIntervalSeconds()  return INTERVAL_TICKS / 60 end
function ModProfiler.getTickCount()        return _tickCount end
function ModProfiler.getSpikeThresholdMs() return SPIKE_THRESHOLD_MS end

function ModProfiler.getModStats() return _modStats end

function ModProfiler.getFrameBudgetSamples() return ringToArray(_frameBudgetRing) end
function ModProfiler.getTargetFrameMs()
    local fps = probeFps()
    if fps and fps > 0 then return 1000 / fps end
    return 1000 / 60
end

function ModProfiler.getModLiveSamples(modName)
    local r = _modLiveRings[modName]; if not r then return {} end
    return ringToArray(r)
end
function ModProfiler.getModMinuteSamples(modName)
    local r = _modMinuteRings[modName]; if not r then return {} end
    return ringToArray(r)
end
function ModProfiler.getModPeriodSamples(modName)
    local r = _modPeriodRings[modName]; if not r then return {} end
    return ringToArray(r)
end
function ModProfiler.getModSessionTotals(modName) return _modSessionTotals[modName] end
function ModProfiler.getSessionElapsedMinutes() return (getTimestampMs() - _sessionStartMs) / 60000 end

function ModProfiler.getAllModNames()
    local names, seen = {}, {}
    for m in pairs(_modStats)     do if not seen[m] then names[#names+1] = m; seen[m] = true end end
    for m in pairs(_modLiveRings) do if not seen[m] then names[#names+1] = m; seen[m] = true end end
    return names
end

function ModProfiler.getSelfStats()
    local dumpArr = ringToArray(_selfStats.dumpMsRing)
    return {
        wrapperPerCallMs    = _selfStats.wrapperCalibratedMs,
        intervalDumpMs      = dumpArr,
        lastCalibratedAtMs  = _selfStats.lastCalibratedAtMs,
    }
end

function ModProfiler.resetSession()
    _tickCount, _printTickCount, _summaryCount = 0, 0, 0
    _modLiveRings, _modMinuteRings, _modPeriodRings = {}, {}, {}
    _modSessionTotals, _modMinuteAccum, _modPeriodAccum = {}, {}, {}
    _frameBudgetRing = ringCreate(FRAME_BUDGET_RING_SIZE)
    _cpuMsSum, _cpuMsCount, _cpuMsPeak = 0, 0, 0
    _snapshotDirty = true
    _sessionStartMs = getTimestampMs()
    _lastMinuteRollMs, _lastPeriodRollMs = _sessionStartMs, _sessionStartMs
    for _, cb in pairs(_callbacks) do cb.iCalls, cb.iMs, cb.iPeak = 0, 0, 0 end
    print("[MODPROFILER] session reset")
end

-- Expose ring helpers so UI can reuse them without redefining.
ModProfiler.ringToArray = ringToArray
ModProfiler.ringGet     = ringGet

-- Dirty flag: the UI checks this to refresh only at interval boundaries.
function ModProfiler.isSnapshotDirty()    return _snapshotDirty end
function ModProfiler.clearSnapshotDirty() _snapshotDirty = false end

-- Zero-copy ring access: returns raw ring objects for ringGet iteration.
-- Avoids the per-call table allocation that ringToArray requires.
function ModProfiler.getModLiveRing(modName)   return _modLiveRings[modName] end
function ModProfiler.getModMinuteRing(modName)  return _modMinuteRings[modName] end
function ModProfiler.getModPeriodRing(modName)  return _modPeriodRings[modName] end
function ModProfiler.getFrameBudgetRing()       return _frameBudgetRing end
function ModProfiler.getSelfDumpRing()          return _selfStats.dumpMsRing end
function ModProfiler.getSelfWrapperMs()         return _selfStats.wrapperCalibratedMs end

print(string.format(
    "[MODPROFILER] Installed: %d/%d events intercepted, interval=%d ticks, print=%d ticks, summary=%d ticks",
    _interceptedCount, #PROFILED_EVENTS, INTERVAL_TICKS, PRINT_INTERVAL_TICKS, SUMMARY_TICKS))
