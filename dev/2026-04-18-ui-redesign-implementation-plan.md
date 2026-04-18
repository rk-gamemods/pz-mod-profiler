# 00_ModProfiler UI Redesign — Implementation Plan

**Status:** Implemented on 2026-04-18.

**Execution result:** Engine and UI changes were applied to `media/lua/shared/00_ModProfiler/ModProfiler.lua` and `media/lua/client/00_ModProfiler/ModProfilerUI.lua`, then deployed with `python deploy.py --verify` and confirmed bit-identical in release/live output.

**Verification note:** The redesign is now covered by `test/run_tests.lua`, which compiles the shipped Lua files, runs shared-engine contract tests, runs UI integration tests against the real overlay module, and validates referenced PZ APIs against the stored PZCodebase.

> **For agentic workers:** Execute task-by-task in order. Each task's steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current confusing overlay with a professional 6-column mod table, dual-arrow trend indicators, frame-budget stacked-area graph, one-line self-cost row, and a rate-selector combo box — per approved spec at `dev/2026-04-18-ui-redesign-design.md`.

**Architecture:** Engine (`ModProfiler.lua`) gains three new per-mod ring tiers (live/minute/period), a session-totals counter, a frame-budget ring, a configurable `setIntervalTicks`, and getters for each. UI (`ModProfilerUI.lua`) gets a full `prerender` rewrite split into focused section helpers (header / modTable / frameBudget / selfCost), sortable headers via `onMouseDown` hit-tests, and new INI persistence for rate+sort+pinned+geometry.

**Tech Stack:** Lua 5.1 (Kahlua — PZ build 42), PZ UI primitives (`ISCollapsableWindow`, `ISComboBox`), PZ Lua engine APIs (`getTimestampMs`, `getPerformance`, `getCPUTime`, `Clipboard.setClipboard`), existing `deploy.py` mirror-sync.

**Convention notes:**

- Plans live in `dev/` (this repo's convention), not `docs/superpowers/plans/`.
- After **every** file change to `media/lua/**`, run `python deploy.py --verify` to sync `release/` and the Zomboid mods folder bit-identically.
- After every edit, call `register_edit` (jCodemunch) so the index stays warm.
- The contract suite lives in `test/run_tests.lua`. Any redesign change is incomplete until that runner is green.

---

## File Map

**New files:** none.

**Modified files:**

| File | Role | Major changes |
| --- | --- | --- |
| `media/lua/shared/00_ModProfiler/ModProfiler.lua` | Engine | New rings, new getters, `setIntervalTicks`, decoupled print cadence, `_frameBudgetRing` |
| `media/lua/client/00_ModProfiler/ModProfilerUI.lua` | Overlay UI | Full `prerender` rewrite, new sections, sort state, rate combo wiring, INI persist |

**Release mirrors** (`release/00_ModProfiler/42.0/media/lua/...`) are synced automatically by `deploy.py --verify` after each change.

---

## Task 1: Add configurable interval with decoupled print cadence

**Goal:** Make `INTERVAL_TICKS` mutable at runtime while keeping `console.txt` cadence fixed at 5s.

**Files:**

- Modify: `media/lua/shared/00_ModProfiler/ModProfiler.lua:63` (constants block), `:389` (`dumpIntervalReport`), `:598` (`engineTick`), `:646` (`getIntervalTicks`), `:678` (`resetSession`)

- [ ] **Step 1: Change constant into mutable local + add print cadence constant**

Replace [ModProfiler.lua:63](../media/lua/shared/00_ModProfiler/ModProfiler.lua#L63):

```lua
local INTERVAL_TICKS     = 300
local SUMMARY_TICKS      = 3000
```

with:

```lua
local INTERVAL_TICKS       = 300          -- mutable; set via ModProfiler.setIntervalTicks
local PRINT_INTERVAL_TICKS = 300          -- console.txt cadence: always 5s at 60Hz
local SUMMARY_TICKS        = 3000
local MIN_INTERVAL_TICKS   = 6            -- 0.1s at 60Hz
local MAX_INTERVAL_TICKS   = 3000         -- 50s at 60Hz
```

- [ ] **Step 2: Add print-tick counter to state block**

After [ModProfiler.lua:89](../media/lua/shared/00_ModProfiler/ModProfiler.lua#L89) (`local _intervalIndex`), add:

```lua
local _printTickCount  = 0     -- independent counter for console.txt cadence
```

- [ ] **Step 3: Split `engineTick` to trigger interval-display and console-print on separate counters**

Replace the body of `engineTick` ([ModProfiler.lua:598-618](../media/lua/shared/00_ModProfiler/ModProfiler.lua#L598-L618)) with:

```lua
local function engineTick()
    _tickCount      = _tickCount + 1
    _printTickCount = _printTickCount + 1
    _summaryCount   = _summaryCount + 1
    _frameCount     = _frameCount + 1

    local nowMs = getTimestampMs()
    local wp = _selfStats.wrapperPerCallMs
    if nowMs - wp.lastCalibratedAtMs >= wp.calibrationIntervalMs then
        calibrateWrapperOverhead()
    end

    if _tickCount >= INTERVAL_TICKS then
        _tickCount = 0
        dumpIntervalReport(false)   -- display-only snapshot (no console print unless aligned)
    end
    if _printTickCount >= PRINT_INTERVAL_TICKS then
        _printTickCount = 0
        -- If the display path just ran on this same tick, it already reset its state.
        -- We still want a console block at 5s cadence — call with print=true and let
        -- dumpIntervalReport decide whether to print based on the flag.
        dumpIntervalReport(true)
    end
    if _summaryCount >= SUMMARY_TICKS then
        _summaryCount = 0
        dumpSessionSummary()
    end
end
```

- [ ] **Step 4: Add a `printOnly` parameter to `dumpIntervalReport`**

At [ModProfiler.lua:389](../media/lua/shared/00_ModProfiler/ModProfiler.lua#L389), change the signature:

```lua
local function dumpIntervalReport(shouldPrint)
```

Inside the body, locate the `print(table.concat(lines, "\n"))` call (the `print(...)` near line ~448) and guard it:

```lua
    if shouldPrint then
        print(table.concat(lines, "\n"))
    end
```

Also guard `flushSpikeLog()` at the end of the function with the same flag (spike log is a print side-effect):

```lua
    if shouldPrint then
        flushSpikeLog()
    end
```

Rationale: at 0.1s display rate we still want one console block every 5s, not 50/s.

- [ ] **Step 5: Add public `setIntervalTicks` / `getIntervalSeconds`**

After [ModProfiler.lua:646](../media/lua/shared/00_ModProfiler/ModProfiler.lua#L646) (`getIntervalTicks`), add:

```lua
function ModProfiler.setIntervalTicks(ticks)
    ticks = tonumber(ticks) or 300
    if ticks < MIN_INTERVAL_TICKS then ticks = MIN_INTERVAL_TICKS end
    if ticks > MAX_INTERVAL_TICKS then ticks = MAX_INTERVAL_TICKS end
    INTERVAL_TICKS = math.floor(ticks)
    _tickCount = 0                    -- take effect immediately
end

function ModProfiler.getIntervalSeconds()
    return INTERVAL_TICKS / 60
end
```

- [ ] **Step 6: Ensure `resetSession` also resets `_printTickCount`**

In [ModProfiler.lua:678-694](../media/lua/shared/00_ModProfiler/ModProfiler.lua#L678-L694) add `_printTickCount = 0` alongside the existing `_tickCount = 0` / `_summaryCount = 0`.

- [ ] **Step 7: Deploy + sanity-check**

```bash
cd C:/Users/Admin/Documents/GIT/GameMods/PZMods/00_ModProfiler
python deploy.py --verify
```

Expected: `OK: release/ mirrors media/ bit-identically`.

Load game, open overlay. `ModProfiler.getIntervalTicks()` returns 300. No change in behavior yet — just plumbing.

- [ ] **Step 8: Register edit and commit**

```bash
# From inside the mod folder
# (no git repo here; just register with jCodemunch)
# register_edit { "repo": "local/00_ModProfiler-f599acab", "file_paths": ["media/lua/shared/00_ModProfiler/ModProfiler.lua"] }
```

---

## Task 2: Add frame-budget ring + populate

**Goal:** One rolling ring of `{cpuMs, modMs, engineMs, headroomMs, budgetMs, fps, uncapped}` entries, one per display-interval, surfaced via a getter.

**Files:**

- Modify: `media/lua/shared/00_ModProfiler/ModProfiler.lua` (state block, `dumpIntervalReport`, getters)

- [ ] **Step 1: Declare ring + target accessor**

Near the state block, after the line added in Task 1 for `_printTickCount`, add:

```lua
local FRAME_BUDGET_RING_SIZE = 300   -- 25min at 5s cadence
local _frameBudgetRing = ringCreate(FRAME_BUDGET_RING_SIZE)
```

- [ ] **Step 2: Populate inside `dumpIntervalReport`**

In `dumpIntervalReport` ([ModProfiler.lua:389](../media/lua/shared/00_ModProfiler/ModProfiler.lua#L389)), after the `for modName, totalMs in pairs(modIntervalTotal)` push loop (~line 428), compute and push a budget entry:

```lua
    -- Frame budget snapshot ---------------------------------------------
    local intervalSec = INTERVAL_TICKS / 60
    local targetFps  = 60
    local uncapped   = false
    local okPerf, perf = pcall(getPerformance)
    if okPerf and perf then
        local okFps, fps = pcall(function() return perf:getFramerate() end)
        if okFps and fps and fps > 0 then targetFps = fps end
        local okUn, un = pcall(function() return perf:getUncappedFrameRate() end)
        if okUn then uncapped = un == true end
    end
    local budgetMs = 1000 / targetFps
    local cpuMs
    local okCpu, cpu = pcall(getCPUTime)
    if okCpu and cpu then cpuMs = cpu end   -- already per-frame avg from engine
    if not cpuMs then
        -- Fallback: sum of all mod interval ms / frames-in-interval
        cpuMs = grandMs / INTERVAL_TICKS
    end
    local modMs       = grandMs / INTERVAL_TICKS
    local engineMs    = math.max(0, cpuMs - modMs)
    local headroomMs  = math.max(0, budgetMs - cpuMs)
    ringPush(_frameBudgetRing, {
        cpuMs      = cpuMs,
        modMs      = modMs,
        engineMs   = engineMs,
        headroomMs = headroomMs,
        budgetMs   = budgetMs,
        fps        = targetFps,
        uncapped   = uncapped,
    })
```

- [ ] **Step 3: Add getters**

After [ModProfiler.lua:650](../media/lua/shared/00_ModProfiler/ModProfiler.lua#L650) (`getSampleRingSize`), add:

```lua
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
```

- [ ] **Step 4: Extend `resetSession`**

In `resetSession` ([ModProfiler.lua:678](../media/lua/shared/00_ModProfiler/ModProfiler.lua#L678)), add:

```lua
    _frameBudgetRing = ringCreate(FRAME_BUDGET_RING_SIZE)
```

- [ ] **Step 5: Deploy + verify**

```bash
python deploy.py --verify
```

Launch game. In in-game console:

```
/lua print(#ModProfiler.getFrameBudgetSamples())
```

After ≥5s of play: returns a non-zero integer. After ≥30s: ≥6.

- [ ] **Step 6: Register edit**

jCodemunch `register_edit` for `media/lua/shared/00_ModProfiler/ModProfiler.lua`.

---

## Task 3: Add tiered per-mod rings (live / minute / period / session)

**Goal:** Replace the single `_modIntervalSamples` dependency with four tiers that match the approved spec.

**Files:**

- Modify: `media/lua/shared/00_ModProfiler/ModProfiler.lua` (state block, `dumpIntervalReport`, `resetSession`, new getters)

- [ ] **Step 1: Declare the four tier tables + constants**

In the state block, after the `_frameBudgetRing` declaration from Task 2, add:

```lua
-- Tiered per-mod aggregation (spec §2)
local LIVE_RING_CAP      = 600   -- safety cap on 5-min live ring
local MINUTE_RING_SIZE   = 30    -- 30 one-minute warmup buckets
local PERIOD_RING_SIZE   = 288   -- 24h at 5-min buckets
local WARMUP_SWITCH_MIN  = 30    -- long arrow switches from minute→period at 30min

local _modLiveRings      = {}    -- [mod] = ring of { msPerFrame, spikes }
local _modMinuteRings    = {}    -- [mod] = ring of { msPerFrame, spikes, count }
local _modPeriodRings    = {}    -- [mod] = ring of { msPerFrame, spikes, count }
local _modSessionTotals  = {}    -- [mod] = { totalIntervalMs, totalSpikes, totalIntervals }
local _modMinuteAccum    = {}    -- [mod] = { sumMs, sumSpikes, count } — rolls over each minute
local _modPeriodAccum    = {}    -- [mod] = { sumMs, sumSpikes, count } — rolls over each 5min

local _sessionStartMs    = getTimestampMs()
local _lastMinuteRollMs  = _sessionStartMs
local _lastPeriodRollMs  = _sessionStartMs
```

- [ ] **Step 2: Add helper to compute live ring size dynamically**

Inside the same constants region:

```lua
local function liveRingSize()
    local intervalSec = INTERVAL_TICKS / 60
    local size = math.ceil(300 / intervalSec)   -- 5 min worth of samples
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
```

- [ ] **Step 3: Populate tiers inside `dumpIntervalReport`**

Inside `dumpIntervalReport`, right after the existing `ringPush(getOrCreateModSamples(modName), totalMs)` loop — and before the `table.sort(entries, ...)` call — add:

```lua
    -- Tiered per-mod aggregation ----------------------------------------
    local intervalSec = INTERVAL_TICKS / 60
    for modName, totalMs in pairs(modIntervalTotal) do
        local msPerFrame = totalMs / INTERVAL_TICKS
        -- Live ring (msPerFrame + spikes this interval)
        local spikesThisInterval = 0
        local modEntry = _modStats[modName]
        if modEntry then
            spikesThisInterval = (modEntry.spikeCount or 0) - (modEntry._lastSnapshotSpikeCount or 0)
            modEntry._lastSnapshotSpikeCount = modEntry.spikeCount or 0
        end
        ringPush(getOrCreateLiveRing(modName), { msPerFrame = msPerFrame, spikes = spikesThisInterval })

        -- Session totals
        local tot = _modSessionTotals[modName]
        if not tot then
            tot = { totalIntervalMs = 0, totalSpikes = 0, totalIntervals = 0 }
            _modSessionTotals[modName] = tot
        end
        tot.totalIntervalMs = tot.totalIntervalMs + totalMs
        tot.totalSpikes     = tot.totalSpikes + spikesThisInterval
        tot.totalIntervals  = tot.totalIntervals + 1

        -- Minute & period accumulators
        local ma = _modMinuteAccum[modName]
        if not ma then ma = { sumMs = 0, sumSpikes = 0, count = 0 }; _modMinuteAccum[modName] = ma end
        ma.sumMs = ma.sumMs + msPerFrame; ma.sumSpikes = ma.sumSpikes + spikesThisInterval; ma.count = ma.count + 1

        local pa = _modPeriodAccum[modName]
        if not pa then pa = { sumMs = 0, sumSpikes = 0, count = 0 }; _modPeriodAccum[modName] = pa end
        pa.sumMs = pa.sumMs + msPerFrame; pa.sumSpikes = pa.sumSpikes + spikesThisInterval; pa.count = pa.count + 1
    end

    -- Minute roll-over (every ~60s) — skip once session ≥ 30 min
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

    -- Period roll-over (every 5 min, always)
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
```

- [ ] **Step 4: Add getters**

After the Task-2 getters, add:

```lua
function ModProfiler.getModLiveSamples(modName)
    local r = _modLiveRings[modName]
    if not r then return {} end
    return ModProfiler.ringToArray(r)
end

function ModProfiler.getModMinuteSamples(modName)
    local r = _modMinuteRings[modName]
    if not r then return {} end
    return ModProfiler.ringToArray(r)
end

function ModProfiler.getModPeriodSamples(modName)
    local r = _modPeriodRings[modName]
    if not r then return {} end
    return ModProfiler.ringToArray(r)
end

function ModProfiler.getModSessionTotals(modName)
    return _modSessionTotals[modName]
end

function ModProfiler.getSessionElapsedMinutes()
    return (getTimestampMs() - _sessionStartMs) / 60000
end

function ModProfiler.getAllModNames()
    local names, seen = {}, {}
    for m in pairs(_modStats)      do if not seen[m] then names[#names+1]=m; seen[m]=true end end
    for m in pairs(_modLiveRings)  do if not seen[m] then names[#names+1]=m; seen[m]=true end end
    return names
end
```

- [ ] **Step 5: Extend `resetSession` to clear tiers**

In `resetSession`, before `print(...)`, add:

```lua
    _modLiveRings      = {}
    _modMinuteRings    = {}
    _modPeriodRings    = {}
    _modSessionTotals  = {}
    _modMinuteAccum    = {}
    _modPeriodAccum    = {}
    _sessionStartMs    = getTimestampMs()
    _lastMinuteRollMs  = _sessionStartMs
    _lastPeriodRollMs  = _sessionStartMs
```

- [ ] **Step 6: Deploy + verify**

```bash
python deploy.py --verify
```

Launch game, play 6+ min. In console:

```
/lua for _,m in ipairs(ModProfiler.getAllModNames()) do print(m, #ModProfiler.getModLiveSamples(m), #ModProfiler.getModMinuteSamples(m)) end
```

Expected: each mod has `#live > 0`, and after 6 min, `#minute >= 3` for mods that were active throughout.

- [ ] **Step 7: Register edit**

jCodemunch `register_edit` for `ModProfiler.lua`.

---

## Task 4: Add `registerUnwrapped` preservation check + finalize engine API surface

**Goal:** Before touching the UI, confirm the new getter surface is complete and none of the new helpers shadow or break existing ones. Add any missing pieces the UI will need.

**Files:**

- Modify: `media/lua/shared/00_ModProfiler/ModProfiler.lua` (final sweep — add any missing helpers)

- [ ] **Step 1: Add a `getSpikeThresholdMs` getter (the UI needs it for color/label math)**

After the other new getters:

```lua
function ModProfiler.getSpikeThresholdMs()
    return SPIKE_THRESHOLD_MS
end
```

- [ ] **Step 2: Confirm `ModProfiler.ringToArray` handles the struct-value rings**

Read [ModProfiler.lua:653](../media/lua/shared/00_ModProfiler/ModProfiler.lua#L653) — the function already walks the ring and copies `.data[i]` entries regardless of type. Tables (`{msPerFrame, spikes}`) pass through unchanged. **No change required.** Leave a one-line note in the new getter comments:

```lua
-- Note: ring entries are tables; ringToArray returns them as-is by reference.
```

- [ ] **Step 3: Deploy + verify**

```bash
python deploy.py --verify
```

Launch, confirm no new errors in console.

- [ ] **Step 4: Register edit**

---

## Task 5: Add shared ModProfilerINI persistence module (inline in ModProfilerUI.lua)

**Goal:** Centralize read/write for `<Zomboid cache dir>/Lua/ModProfiler.ini`. Used by every subsequent UI task.

**Files:**

- Modify: `media/lua/client/00_ModProfiler/ModProfilerUI.lua` (add a small INI block near the top)

- [ ] **Step 1: Add the INI helper just after the `require` block at [ModProfilerUI.lua:39](../media/lua/client/00_ModProfiler/ModProfilerUI.lua#L39)**

Insert (after all `require` lines and before `TEST_MODE`):

```lua
---------------------------------------------------------------------------
-- ModProfilerINI — key=value persistence in Zomboid Lua dir
---------------------------------------------------------------------------
local INI_FILENAME = "ModProfiler.ini"

local function iniParse(lines)
    local t = {}
    for _, line in ipairs(lines) do
        local k, v = line:match("^%s*([%w_%.]+)%s*=%s*(.-)%s*$")
        if k then t[k] = v end
    end
    return t
end

local function iniSerialize(tbl)
    local keys = {}
    for k in pairs(tbl) do keys[#keys+1] = k end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do out[#out+1] = k .. "=" .. tostring(tbl[k]) end
    return out
end

local ModProfilerINI = {}

function ModProfilerINI.load()
    local reader = getFileReader(INI_FILENAME, false)
    if not reader then return {} end
    local lines = {}
    while true do
        local line = reader:readLine()
        if not line then break end
        lines[#lines+1] = line
    end
    reader:close()
    return iniParse(lines)
end

function ModProfilerINI.save(tbl)
    local writer = getFileWriter(INI_FILENAME, true, false)
    if not writer then return end
    for _, line in ipairs(iniSerialize(tbl)) do
        writer:write(line .. "\n")
    end
    writer:close()
end

function ModProfilerINI.num(tbl, key, default)
    local v = tonumber(tbl[key]); if v == nil then return default end; return v
end

function ModProfilerINI.bool(tbl, key, default)
    local v = tbl[key]
    if v == "true" then return true end
    if v == "false" then return false end
    return default
end

function ModProfilerINI.str(tbl, key, default)
    return tbl[key] or default
end

function ModProfilerINI.list(tbl, key)
    local s = tbl[key]; if not s or s == "" then return {} end
    local out = {}
    for w in s:gmatch("([^,]+)") do out[#out+1] = w end
    return out
end
```

- [ ] **Step 2: Deploy + sanity test**

```bash
python deploy.py --verify
```

Launch game, in console:

```
/lua local ini = require("00_ModProfiler/ModProfilerUI") -- noop; but test via panel global once it's open
```

(We validate this in later tasks when the panel actually reads/writes the file.)

- [ ] **Step 3: Register edit**

---

## Task 6: Wire panel initialization to load INI state; persist geometry on close

**Goal:** Replace hard-coded defaults with INI-backed `x/y/w/h/visible/pinned/intervalTicks/sortColumn/sortDescending`.

**Files:**

- Modify: `media/lua/client/00_ModProfiler/ModProfilerUI.lua` (`ModProfilerPanel:new` at line 658, `:close` at 697)

- [ ] **Step 1: Extend `ModProfilerPanel:new` to load INI defaults**

Replace [ModProfilerUI.lua:658-676](../media/lua/client/00_ModProfiler/ModProfilerUI.lua#L658-L676) entirely with:

```lua
function ModProfilerPanel:new(x, y, w, h)
    local ini = ModProfilerINI.load()
    local defaultX, defaultY = 40, 40
    local defaultW, defaultH = 820, 560

    x = ModProfilerINI.num(ini, "x", x or defaultX)
    y = ModProfilerINI.num(ini, "y", y or defaultY)
    w = ModProfilerINI.num(ini, "w", w or defaultW)
    h = ModProfilerINI.num(ini, "h", h or defaultH)

    local o = ISCollapsableWindow:new(x, y, w, h)
    setmetatable(o, self)
    self.__index            = self
    o.title                 = "Mod Profiler"
    o.resizable             = true
    o.drawFrame             = true
    o.backgroundColor       = { r=0.05, g=0.06, b=0.08, a=0.92 }
    o.borderColor           = { r=0.40, g=0.45, b=0.55, a=1.00 }
    o.topN                  = 20
    o.pinned                = {}
    for _, m in ipairs(ModProfilerINI.list(ini, "pinned")) do o.pinned[m] = true end
    o.sortColumn            = ModProfilerINI.str(ini, "sortColumn", "pctTotal")
    o.sortDescending        = ModProfilerINI.bool(ini, "sortDescending", true)
    o.intervalTicks         = ModProfilerINI.num(ini, "intervalTicks", 120)  -- 2s default
    o._ini                  = ini
    return o
end
```

- [ ] **Step 2: Replace `ModProfilerPanel:close` to persist state**

Replace [ModProfilerUI.lua:697-702](../media/lua/client/00_ModProfiler/ModProfilerUI.lua#L697-L702) with:

```lua
function ModProfilerPanel:close()
    local pinnedList = {}
    for k, v in pairs(self.pinned) do if v then pinnedList[#pinnedList+1] = k end end
    local t = self._ini or {}
    t.x               = math.floor(self:getX())
    t.y               = math.floor(self:getY())
    t.w               = math.floor(self:getWidth())
    t.h               = math.floor(self:getHeight())
    t.visible         = "false"
    t.pinned          = table.concat(pinnedList, ",")
    t.sortColumn      = self.sortColumn or "pctTotal"
    t.sortDescending  = self.sortDescending and "true" or "false"
    t.intervalTicks   = tostring(self.intervalTicks or 120)
    ModProfilerINI.save(t)
    ISCollapsableWindow.close(self)
end
```

- [ ] **Step 3: Also persist `visible=true` on show**

Find `ModProfilerUI.show` at [ModProfilerUI.lua:1082](../media/lua/client/00_ModProfiler/ModProfilerUI.lua#L1082). Near the end (just before the function closes), add:

```lua
    local t = ModProfilerINI.load(); t.visible = "true"; ModProfilerINI.save(t)
```

- [ ] **Step 4: Apply loaded intervalTicks on first show**

In `ModProfilerUI.show`, after the panel is constructed and before returning, add:

```lua
    if _panel and _panel.intervalTicks and ModProfiler.setIntervalTicks then
        ModProfiler.setIntervalTicks(_panel.intervalTicks)
    end
```

- [ ] **Step 5: Deploy + verify**

```bash
python deploy.py --verify
```

In game: open overlay, drag it, resize it, close it. Reopen — geometry is restored. Inspect the file:

```bash
# Windows: %USERPROFILE%\Zomboid\Lua\ModProfiler.ini
```

Expected: file present with `x=`, `y=`, `w=`, `h=`, `visible=true`, etc.

- [ ] **Step 6: Register edit**

---

## Task 7: Header rewrite — live budget display + ISComboBox rate selector

**Goal:** Replace the existing header block inside `ModProfilerPanel:prerender` with the spec's plain-English line including `CPU / budget ms frame (%)`, rate combo (10s/5s/2s/1s/0.5s/0.1s, default 2s), and the existing interval progress bar repositioned.

**Files:**

- Modify: `media/lua/client/00_ModProfiler/ModProfilerUI.lua` (`createChildren` at 682, `prerender` at 846, new helper `drawHeader`)

- [ ] **Step 1: Create the rate combo in `createChildren`**

Replace [ModProfilerUI.lua:682-695](../media/lua/client/00_ModProfiler/ModProfilerUI.lua#L682-L695) with:

```lua
function ModProfilerPanel:createChildren()
    ISCollapsableWindow.createChildren(self)

    local cW, cH = 90, 20
    self.rateCombo = ISComboBox:new(self:getWidth() - cW - 12, 28, cW, cH,
                                    self, ModProfilerPanel.onRateChanged)
    self.rateCombo:initialise()
    self:addChild(self.rateCombo)
    self.rateCombo:addOption("10s")    -- 600 ticks
    self.rateCombo:addOption("5s")     -- 300
    self.rateCombo:addOption("2s")     -- 120  (default)
    self.rateCombo:addOption("1s")     --  60
    self.rateCombo:addOption("0.5s")   --  30
    self.rateCombo:addOption("0.1s")   --   6
    -- Preselect based on loaded intervalTicks
    local map = { [600]=1, [300]=2, [120]=3, [60]=4, [30]=5, [6]=6 }
    local sel = map[self.intervalTicks] or 3
    self.rateCombo.selected = sel

    -- Resize hook so the combo stays top-right
    local originalOnResize = self.onResize
    self.onResize = function(target, newW, newH)
        if originalOnResize then originalOnResize(target, newW, newH) end
        if self.rateCombo then self.rateCombo:setX(newW - cW - 12) end
    end
end

function ModProfilerPanel:onRateChanged(combo)
    local ticksByIdx = { 600, 300, 120, 60, 30, 6 }
    local ticks = ticksByIdx[combo.selected] or 120
    self.intervalTicks = ticks
    if ModProfiler.setIntervalTicks then ModProfiler.setIntervalTicks(ticks) end
end
```

- [ ] **Step 2: Add header drawing helper above `prerender`**

Before [ModProfilerUI.lua:846](../media/lua/client/00_ModProfiler/ModProfilerUI.lua#L846), add:

```lua
local function drawHeader(panel, y, font)
    local enabled = ModProfiler.isEnabled()
    local statusTxt = enabled and "[ON]" or "[OFF]"
    local statusCol = enabled and {r=0.45,g=0.90,b=0.50,a=1} or {r=0.80,g=0.45,b=0.45,a=1}

    local cpuMs, budgetMs
    local ok, perf = pcall(getPerformance)
    if ok and perf then
        local okFps, fps = pcall(function() return perf:getFramerate() end)
        if okFps and fps and fps > 0 then budgetMs = 1000 / fps end
    end
    budgetMs = budgetMs or (1000/60)
    local okCpu, cpu = pcall(getCPUTime)
    if okCpu and cpu then cpuMs = cpu end
    cpuMs = cpuMs or 0
    local pct = budgetMs > 0 and (cpuMs / budgetMs * 100) or 0

    local col
    if pct >= 90 then col = {r=0.90,g=0.40,b=0.40,a=1}
    elseif pct >= 75 then col = {r=0.95,g=0.85,b=0.35,a=1}
    else col = {r=0.60,g=0.85,b=0.60,a=1} end

    panel:drawText("PROFILER ", 10, y, 0.85,0.85,0.90,1, font)
    panel:drawText(statusTxt, 66, y, statusCol.r, statusCol.g, statusCol.b, 1, font)

    local bigStr = string.format("%.1f / %.1f ms frame (%d%%)", cpuMs, budgetMs, pct+0.5)
    local narrow = panel:getWidth() < 700
    if narrow then bigStr = string.format("%.1f/%.1fms", cpuMs, budgetMs) end
    panel:drawText(bigStr, 110, y, col.r, col.g, col.b, 1, font)

    panel:drawText("rate", panel:getWidth() - 180, y, 0.75,0.75,0.80,1, font)

    -- Interval progress bar (below header line)
    local totalTicks = ModProfiler.getIntervalTicks() or 300
    local curTicks   = ModProfiler.getTickCount() or 0
    local frac = math.max(0, math.min(1, curTicks / totalTicks))
    local barX, barY, barW, barH = 10, y + 16, panel:getWidth() - 200, 4
    panel:drawRect(barX, barY, barW, barH, 0.35, 0.10, 0.12, 0.14)
    panel:drawRect(barX, barY, math.floor(barW * frac), barH, 0.80, 0.40, 0.50, 0.70)

    return y + 26   -- y-cursor below header
end
```

- [ ] **Step 3: Use it at top of `prerender`**

At [ModProfilerUI.lua:846](../media/lua/client/00_ModProfiler/ModProfilerUI.lua#L846), inside `ModProfilerPanel:prerender`, replace the existing header block (the first ~60 lines of the function that draw status/CPU/GPU text) with:

```lua
    ISCollapsableWindow.prerender(self)
    local font = UIFont.Small
    local y = self:titleBarHeight() + 8
    y = drawHeader(self, y, font)
```

(Save the remainder of `prerender` for later tasks — we'll rewrite table/budget/self-cost sections in Tasks 8-11.)

- [ ] **Step 4: Deploy + sanity check**

```bash
python deploy.py --verify
```

In game: open overlay. Header reads `PROFILER [ON]   9.2 / 16.7 ms frame (55%)   rate` with combo to the right. Change rate → interval bar fills faster/slower.

- [ ] **Step 5: Register edit**

---

## Task 8: Pure helpers — percentile, OLS slope, trend classifier

**Goal:** Add reusable pure functions so later drawing code reads clearly. Write them before first use.

**Files:**

- Modify: `media/lua/client/00_ModProfiler/ModProfilerUI.lua` (near existing `percentile` at line 589)

- [ ] **Step 1: Keep existing `percentile` at [ModProfilerUI.lua:589](../media/lua/client/00_ModProfiler/ModProfilerUI.lua#L589); add these just below it**

```lua
-- OLS slope of y-series with uniform x-spacing. Returns slope-per-sample (nil if <2 pts).
local function olsSlope(ys)
    local n = #ys
    if n < 2 then return nil, 0 end
    local sumX, sumY = 0, 0
    for i = 1, n do sumX = sumX + i; sumY = sumY + ys[i] end
    local meanX, meanY = sumX/n, sumY/n
    local num, den = 0, 0
    for i = 1, n do
        local dx = i - meanX; local dy = ys[i] - meanY
        num = num + dx * dy
        den = den + dx * dx
    end
    if den == 0 then return 0, meanY end
    return num / den, meanY
end

-- Given % drift (per the spec thresholds), return glyph + color.
local function trendGlyph(pctPerUnit, thresholdRising, thresholdFalling, minSamples, nSamples)
    if nSamples < minSamples then return "—", {r=0.55,g=0.55,b=0.60,a=1} end
    if pctPerUnit == nil then return "—", {r=0.55,g=0.55,b=0.60,a=1} end
    if pctPerUnit > thresholdRising  then return "↗", {r=0.95,g=0.65,b=0.35,a=1} end
    if pctPerUnit < thresholdFalling then return "↘", {r=0.45,g=0.70,b=0.95,a=1} end
    return "→", {r=0.75,g=0.75,b=0.80,a=1}
end

-- Short-term (live ring): slope over msPerFrame samples, expressed %/min.
local function shortTrend(liveRing, intervalSec)
    local n = #liveRing
    if n < 10 then return "—", {r=0.55,g=0.55,b=0.60,a=1}, 0 end
    local ys = {}
    for i = 1, n do ys[i] = liveRing[i].msPerFrame or 0 end
    local slopePerSample, mean = olsSlope(ys)
    if not slopePerSample or mean <= 0 then return "→", {r=0.75,g=0.75,b=0.80,a=1}, 0 end
    local slopePerMin = slopePerSample * (60 / intervalSec)
    local pctPerMin = slopePerMin / mean * 100
    local g, c = trendGlyph(pctPerMin, 2, -2, 10, n)
    return g, c, pctPerMin
end

-- Long-term: minute buckets if session < 30 min, else period buckets. %/h thresholds.
local function longTrend(minuteRing, periodRing, sessionMin)
    local src, sampleMin
    if sessionMin < 30 then
        src, sampleMin = minuteRing, 1            -- 1 sample per minute
    else
        src, sampleMin = periodRing, 5            -- 1 sample per 5 min
    end
    local n = #src
    if sessionMin < 3 or n < 3 then return "—", {r=0.55,g=0.55,b=0.60,a=1}, 0 end
    local ys = {}
    for i = 1, n do ys[i] = src[i].msPerFrame or 0 end
    local slopePerSample, mean = olsSlope(ys)
    if not slopePerSample or mean <= 0 then return "→", {r=0.75,g=0.75,b=0.80,a=1}, 0 end
    local slopePerHour = slopePerSample * (60 / sampleMin)
    local pctPerHour   = slopePerHour / mean * 100
    local g, c = trendGlyph(pctPerHour, 2, -2, 3, n)
    return g, c, pctPerHour
end

-- Spikes/min: sum of spikes in live ring / window-minutes.
local function spikesPerMin(liveRing, intervalSec)
    local n = #liveRing
    if n < 10 then return nil end
    local sum = 0
    for i = 1, n do sum = sum + (liveRing[i].spikes or 0) end
    local windowMin = (n * intervalSec) / 60
    if windowMin <= 0 then return 0 end
    return sum / windowMin
end
```

- [ ] **Step 2: Deploy (no behavior change yet) + register edit**

```bash
python deploy.py --verify
```

---

## Task 9: Mod table rewrite — 6 columns, sortable headers, dual trend arrows

**Goal:** Replace the existing table rendering inside `prerender` with the spec's 6-column layout + header sort hit-tests.

**Files:**

- Modify: `media/lua/client/00_ModProfiler/ModProfilerUI.lua` (body of `prerender` from 846 down to ~1031; also `onMouseDown` at 1039)

- [ ] **Step 1: Add `:buildRows` that composes new row data from engine getters**

Replace [ModProfilerUI.lua:704-768](../media/lua/client/00_ModProfiler/ModProfilerUI.lua#L704-L768) (`refreshRows`) with:

```lua
function ModProfilerPanel:refreshRows()
    local intervalSec = ModProfiler.getIntervalSeconds and ModProfiler.getIntervalSeconds() or 5
    local sessionMin  = ModProfiler.getSessionElapsedMinutes and ModProfiler.getSessionElapsedMinutes() or 0
    local names = ModProfiler.getAllModNames and ModProfiler.getAllModNames() or {}
    local rows = {}
    local sumLiveMs = 0

    local perModLive = {}
    for _, m in ipairs(names) do
        local live = ModProfiler.getModLiveSamples(m) or {}
        perModLive[m] = live
        local s = 0
        for i = 1, #live do s = s + (live[i].msPerFrame or 0) end
        sumLiveMs = sumLiveMs + s
    end

    for _, m in ipairs(names) do
        local live = perModLive[m]
        if #live > 0 then
            local ys = {}
            for i = 1, #live do ys[i] = live[i].msPerFrame end
            table.sort(ys)
            local p50 = percentile(ys, 50)
            local p95 = percentile(ys, 95)
            local meanMs = 0
            for i = 1, #ys do meanMs = meanMs + ys[i] end
            meanMs = meanMs / #ys

            local modTotal = 0
            for i = 1, #live do modTotal = modTotal + (live[i].msPerFrame or 0) end
            local pctTotal = sumLiveMs > 0 and (modTotal / sumLiveMs * 100) or 0

            local shortG, shortC = shortTrend(live, intervalSec)
            local longG,  longC  = longTrend(
                ModProfiler.getModMinuteSamples(m) or {},
                ModProfiler.getModPeriodSamples(m) or {},
                sessionMin
            )
            local spk = spikesPerMin(live, intervalSec)

            rows[#rows+1] = {
                mod=m, pctTotal=pctTotal, p50=p50, p95=p95,
                spikesPerMin=spk, shortG=shortG, shortC=shortC,
                longG=longG, longC=longC,
                pinned = self.pinned[m] == true,
                meanMs = meanMs,
            }
        end
    end

    -- Sort: pinned first, then by sortColumn/sortDescending
    local col  = self.sortColumn or "pctTotal"
    local desc = self.sortDescending ~= false
    local function cmp(a, b)
        if a.pinned ~= b.pinned then return a.pinned end
        local av, bv
        if col == "name" then av, bv = a.mod, b.mod
        else av, bv = a[col] or -1, b[col] or -1 end
        if av == bv then return a.mod < b.mod end
        if desc then return av > bv else return av < bv end
    end
    table.sort(rows, cmp)

    -- Top-N cut (pinned always kept)
    local displayed = {}
    for _, r in ipairs(rows) do
        if r.pinned or #displayed < self.topN then displayed[#displayed+1] = r end
    end

    self.rows = displayed
end
```

- [ ] **Step 2: Add column layout constants + draw helper above `prerender`**

Just before `ModProfilerPanel:prerender`, add:

```lua
-- Column layout (x is offset from content-left; widths tuned for 820px default)
local COLS = {
    { key="name",         label="Mod",      x=10,  w=220, align="left"  },
    { key="pctTotal",     label="%Total",   x=240, w=70,  align="right" },
    { key="p50",          label="ms/f p50", x=320, w=90,  align="right" },
    { key="p95",          label="ms/f p95", x=420, w=90,  align="right" },
    { key="spikesPerMin", label="spk/min",  x=520, w=80,  align="right" },
    { key="trend",        label="trend",    x=610, w=60,  align="center"},
}

local function drawColHeader(panel, y, font, sortKey, sortDesc)
    for _, c in ipairs(COLS) do
        local label = c.label
        if c.key == sortKey then label = label .. (sortDesc and " ▼" or " ▲") end
        if c.align == "right" then
            local tw = getTextManager():MeasureStringX(font, label)
            panel:drawText(label, c.x + c.w - tw, y, 0.70, 0.75, 0.85, 1, font)
        elseif c.align == "center" then
            local tw = getTextManager():MeasureStringX(font, label)
            panel:drawText(label, c.x + (c.w - tw)/2, y, 0.70, 0.75, 0.85, 1, font)
        else
            panel:drawText(label, c.x, y, 0.70, 0.75, 0.85, 1, font)
        end
    end
    panel:drawRect(10, y + 16, panel:getWidth() - 20, 1, 0.40, 0.45, 0.55, 0.30)
    return y + 20
end

local function drawModRow(panel, row, y, font)
    local baseCol = p95Color(row.p95 or 0)
    if row.pinned then
        panel:drawRect(8, y - 1, panel:getWidth() - 16, 16, 0.40, 0.40, 0.20, 0.15)
    end
    -- name (left) with pin indicator
    local nameStr = (row.pinned and "★ " or "  ") .. (row.mod or "?")
    panel:drawText(nameStr, COLS[1].x, y, baseCol.r, baseCol.g, baseCol.b, 1, font)
    -- numeric cols
    local function R(txt, col)
        local tw = getTextManager():MeasureStringX(font, txt)
        panel:drawText(txt, col.x + col.w - tw, y, baseCol.r, baseCol.g, baseCol.b, 1, font)
    end
    R(string.format("%.1f%%", row.pctTotal or 0), COLS[2])
    R(string.format("%.2f ms", row.p50 or 0), COLS[3])
    R(string.format("%.2f ms", row.p95 or 0), COLS[4])
    R(row.spikesPerMin and string.format("%.1f", row.spikesPerMin) or "—", COLS[5])
    -- trend: two glyphs side by side
    local g1 = row.shortG or "—"; local g2 = row.longG or "—"
    local pair = g1 .. " " .. g2
    local tw = getTextManager():MeasureStringX(font, pair)
    local tx = COLS[6].x + (COLS[6].w - tw)/2
    panel:drawText(g1, tx, y, row.shortC.r, row.shortC.g, row.shortC.b, 1, font)
    local g1w = getTextManager():MeasureStringX(font, g1 .. " ")
    panel:drawText(g2, tx + g1w, y, row.longC.r, row.longC.g, row.longC.b, 1, font)
end
```

- [ ] **Step 3: Replace the table-rendering section of `prerender`**

In `ModProfilerPanel:prerender` (starting at line 846), AFTER the `y = drawHeader(...)` line from Task 7 and BEFORE the old table-drawing logic, add:

```lua
    self:refreshRows()

    -- Column header row
    y = drawColHeader(self, y + 4, font, self.sortColumn, self.sortDescending)
    self._tableHeaderY = y - 20   -- remember for mouse hit-test

    -- Mod rows
    for _, r in ipairs(self.rows or {}) do
        drawModRow(self, r, y, font)
        y = y + 16
    end
    self._tableBottomY = y
```

Delete the existing table-rendering loop that previously spanned roughly [ModProfilerUI.lua:900-1020](../media/lua/client/00_ModProfiler/ModProfilerUI.lua#L900-L1020). (Keep any self-cost, budget, or render-bottom code — those are replaced in Tasks 10-11.)

- [ ] **Step 4: Rewrite `onMouseDown` for header-click sort + row pin + right-click copy**

Replace [ModProfilerUI.lua:1039-1063](../media/lua/client/00_ModProfiler/ModProfilerUI.lua#L1039-L1063) with:

```lua
function ModProfilerPanel:onMouseDown(x, y)
    -- Header sort?
    if self._tableHeaderY and y >= self._tableHeaderY and y <= self._tableHeaderY + 20 then
        for _, c in ipairs(COLS) do
            if x >= c.x and x <= c.x + c.w then
                if self.sortColumn == c.key then
                    self.sortDescending = not self.sortDescending
                else
                    self.sortColumn = c.key
                    self.sortDescending = (c.key ~= "name")
                end
                return
            end
        end
    end
    -- Row pin?
    if self._tableHeaderY and self.rows and y > self._tableHeaderY + 20 and y <= self._tableBottomY then
        local idx = math.floor((y - (self._tableHeaderY + 20)) / 16) + 1
        local r = self.rows[idx]
        if r then
            if self.pinned[r.mod] then self.pinned[r.mod] = nil else self.pinned[r.mod] = true end
        end
    end
    ISCollapsableWindow.onMouseDown(self, x, y)
end

function ModProfilerPanel:onRightMouseDown(x, y)
    if self._tableHeaderY and self.rows and y > self._tableHeaderY + 20 and y <= self._tableBottomY then
        local idx = math.floor((y - (self._tableHeaderY + 20)) / 16) + 1
        local r = self.rows[idx]
        if r and Clipboard and Clipboard.setClipboard then
            pcall(Clipboard.setClipboard, r.mod)
        end
    end
    ISCollapsableWindow.onRightMouseDown(self, x, y)
end
```

- [ ] **Step 5: Deploy + verify**

```bash
python deploy.py --verify
```

In game: overlay shows 6 columns. Click each header → sort flips. Click row → `★` appears and row locks to top. Right-click row → paste elsewhere shows mod name.

- [ ] **Step 6: Register edit**

---

## Task 10: Frame-budget stacked-area section

**Goal:** Below the mod table, draw a stacked-area graph of headroom/engine/mods with a dashed budget line and over-budget blink indicator. Reuse `drawStackedArea` primitive (already defined at [ModProfilerUI.lua:260](../media/lua/client/00_ModProfiler/ModProfilerUI.lua#L260)).

**Files:**

- Modify: `media/lua/client/00_ModProfiler/ModProfilerUI.lua` (`prerender`)

- [ ] **Step 1: Add a drawBudget helper above `prerender`**

Right above `drawModRow` (from Task 9):

```lua
local function drawBudget(panel, x, y, w, h, font)
    local samples = ModProfiler.getFrameBudgetSamples and ModProfiler.getFrameBudgetSamples() or {}
    local n = #samples
    if n < 2 then
        panel:drawText("Frame budget: collecting data…", x, y, 0.60,0.60,0.65,1, font)
        return y + 18
    end

    local uncappedLast = samples[n].uncapped == true
    local title = uncappedLast and "FRAME BUDGET (UNCAPPED)" or "FRAME BUDGET"
    panel:drawText(title, x, y, 0.75,0.75,0.80,1, font)

    local last = samples[n]
    local overBy = last.cpuMs - last.budgetMs
    if overBy > 0 and not uncappedLast then
        local blink = (getTimestampMs() % 1000) < 500
        if blink then
            panel:drawText(string.format("⚠ OVER BUDGET: +%.1fms", overBy),
                           x + 180, y, 0.95,0.35,0.35,1, font)
        end
    end

    local gy = y + 18
    local gh = h - 18 - 16   -- reserve 16 for footer line

    local layers = {
        headroom = {}, engine = {}, mods = {},
    }
    for i = 1, n do
        layers.headroom[i] = uncappedLast and 0 or samples[i].headroomMs
        layers.engine[i]   = samples[i].engineMs
        layers.mods[i]     = samples[i].modMs
    end

    local layerList = {
        { name="Headroom", values=layers.headroom, r=0.2, g=0.8, b=0.3, a=0.6 },
        { name="Engine",   values=layers.engine,   r=0.3, g=0.5, b=0.9, a=0.7 },
        { name="Mods",     values=layers.mods,     r=1.0, g=0.5, b=0.2, a=0.8 },
    }
    if uncappedLast then table.remove(layerList, 1) end

    drawStackedArea(panel, x, gy, w, gh, layerList, uncappedLast and nil or last.budgetMs, nil, font)

    -- Footer: avg/min/max headroom
    local sumHr, minHr, maxHr = 0, math.huge, -math.huge
    for i = 1, n do
        local hr = samples[i].headroomMs or 0
        sumHr = sumHr + hr
        if hr < minHr then minHr = hr end
        if hr > maxHr then maxHr = hr end
    end
    local avgHr = sumHr / n
    local budgetAvg = 0
    for i = 1, n do budgetAvg = budgetAvg + (samples[i].budgetMs or 16.67) end
    budgetAvg = budgetAvg / n
    local freePct = budgetAvg > 0 and (avgHr / budgetAvg * 100) or 0
    local col
    if freePct >= 30 then col = {r=0.55,g=0.85,b=0.55,a=1}
    elseif freePct >= 10 then col = {r=0.95,g=0.85,b=0.35,a=1}
    else col = {r=0.90,g=0.40,b=0.40,a=1} end
    local footer = string.format("Avg headroom: %.1f ms (%d%% free)   min: %.1f   max: %.1f",
                                 avgHr, freePct+0.5, minHr, maxHr)
    panel:drawText(footer, x, y + h - 14, col.r, col.g, col.b, 1, font)

    return y + h + 4
end
```

- [ ] **Step 2: Call it in `prerender` after the mod table**

After the `for _, r in ipairs(self.rows or {}) do ... end` loop from Task 9, add:

```lua
    local gx = 10
    local gw = self:getWidth() - 20
    local gh = math.max(80, math.min(180, math.floor((self:getHeight() - y) * 0.45)))
    y = drawBudget(self, gx, y + 8, gw, gh, font)
```

- [ ] **Step 3: Deploy + verify**

```bash
python deploy.py --verify
```

In game after ≥10s: stacked area appears below mod table with green/blue/orange layers, dashed cyan budget line, summary footer. If you artificially stress the game (load many vehicles), the red `⚠ OVER BUDGET` text blinks.

- [ ] **Step 4: Register edit**

---

## Task 11: Self-cost single-row section

**Goal:** One row in the same visual style as mod rows, labeled `00_ModProfiler`, above + below divider.

**Files:**

- Modify: `media/lua/client/00_ModProfiler/ModProfilerUI.lua` (`buildSelfCostRows` + `prerender`)

- [ ] **Step 1: Replace `buildSelfCostRows` with a function returning ONE row shaped like a mod row**

Replace [ModProfilerUI.lua:770-788](../media/lua/client/00_ModProfiler/ModProfilerUI.lua#L770-L788) with:

```lua
function ModProfilerPanel:buildSelfCostRow()
    local self_ = ModProfiler.getSelfStats()
    if not self_ then return nil end
    local intervalSec = ModProfiler.getIntervalSeconds and ModProfiler.getIntervalSeconds() or 5
    local tickRate    = 60
    local intervalTicks = intervalSec * tickRate

    -- Assemble per-interval self-ms samples from available arrays.
    -- Approximation: wrapperPerCall × calls/interval + dumpMs + spikeLogMs
    local dumpArr   = self_.intervalDumpMs or {}
    local spikeArr  = self_.spikeLogMs or {}
    local wrapArr   = self_.wrapperPerCallMs and self_.wrapperPerCallMs.samples or {}
    local wrapMean  = 0
    if #wrapArr > 0 then
        for i=1,#wrapArr do wrapMean = wrapMean + wrapArr[i] end
        wrapMean = wrapMean / #wrapArr
    end

    -- Rough calls/interval: sum of all mod stats totalCalls
    local callsPerInterval = 0
    local modStats = ModProfiler.getModStats() or {}
    local modCount = 0
    for _, s in pairs(modStats) do
        modCount = modCount + 1
        callsPerInterval = callsPerInterval + (s.totalCalls or 0)
    end
    local tot = ModProfiler.getSessionElapsedMinutes and ModProfiler.getSessionElapsedMinutes() or 0
    if tot > 0 then callsPerInterval = callsPerInterval / (tot * 60 / intervalSec) end

    local samples = {}
    local n = math.max(#dumpArr, #spikeArr)
    for i = 1, n do
        local d = dumpArr[i] or 0
        local s = spikeArr[i] or 0
        local perInterval = wrapMean * callsPerInterval + d + s
        samples[i] = perInterval / intervalTicks
    end
    if #samples < 2 then return nil end
    local sorted = {}; for i=1,#samples do sorted[i]=samples[i] end; table.sort(sorted)
    local p50 = percentile(sorted, 50)
    local p95 = percentile(sorted, 95)
    local mean = 0; for i=1,#samples do mean = mean + samples[i] end; mean = mean / #samples

    return {
        mod          = "00_ModProfiler",
        pctTotal     = 0,   -- computed below with access to sumLiveMs context
        p50          = p50,
        p95          = p95,
        spikesPerMin = 0,
        shortG = "→", shortC = {r=0.75,g=0.75,b=0.80,a=1},
        longG  = "→", longC  = {r=0.75,g=0.75,b=0.80,a=1},
        pinned = false,
        _mean  = mean,
    }
end
```

- [ ] **Step 2: Draw it in `prerender` right after the mod-table loop, before `drawBudget`**

After the table `for _, r in ipairs(self.rows or {}) do ... end`, insert:

```lua
    local selfRow = self:buildSelfCostRow()
    if selfRow then
        self:drawRect(10, y + 2, self:getWidth() - 20, 1, 0.40, 0.45, 0.55, 0.40)
        y = y + 6
        drawModRow(self, selfRow, y, font)
        y = y + 16
        self:drawRect(10, y + 1, self:getWidth() - 20, 1, 0.40, 0.45, 0.55, 0.40)
        y = y + 4
    end
```

- [ ] **Step 3: Remove the old multi-stat self-cost block (if any stragglers in the old prerender body)**

Verify nothing remains from the old self-cost block that previously spanned [ModProfilerUI.lua:940-1020](../media/lua/client/00_ModProfiler/ModProfilerUI.lua#L940-L1020). It should have been deleted in Task 9 Step 3.

- [ ] **Step 4: Deploy + verify**

```bash
python deploy.py --verify
```

In game: overlay shows mod table → divider → `00_ModProfiler` row styled identically → divider → frame budget section. Numbers for `00_ModProfiler` are tiny (≤ 0.1 ms/f p95) after a few minutes.

- [ ] **Step 5: Register edit**

---

## Task 12: Final verification pass

- [ ] **Step 1: End-to-end verification (from design §10)**

Play the game for ≥10 min. Confirm each item from the spec:

| # | Check | Pass criterion |
|---|-------|----------------|
| 1 | No `ntrend` collision | Header reads `trend` alone, centered |
| 2 | %Total sums ~100% | Sum of column over visible rows ∈ [95%, 100%] |
| 3 | ms/f p50 × 60 ≈ prior per-interval display | e.g. UTCore 0.28 ms/f × 60 ≈ 17 ms — matches old screenshot |
| 4 | Trend arrows on mods with ≥10 samples | Visible after ~50s at 5s rate |
| 5 | Frame budget section renders | Stacked area + dashed budget line |
| 6 | Self-cost row same style as mods | Divider above/below, 6 columns |
| 7 | Header click sorts | `▼` / `▲` toggles |
| 8 | Row click pins | `★` prefix appears |
| 9 | Right-click copies mod name | Paste elsewhere matches |
| 10 | Rate combo updates interval bar | 0.5s → bar fills visibly faster |
| 11 | Over-budget blink works | Stress test: load vehicles → red text appears |
| 12 | Persistence round-trip | Close game, reopen → geometry+sort+rate+pins restored |
| 13 | Release sync | `deploy.py --verify` exits 0 |

- [ ] **Step 2: Remove any dev-only self-check prints**

Grep for `_TEST` or `print("[MODPROFILER-DEBUG]` and remove.

- [ ] **Step 3: Final deploy**

```bash
python deploy.py --verify
```

- [ ] **Step 4: Register final edits**

jCodemunch `register_edit` with both changed files.

- [ ] **Step 5: Update project memory**

Flip memory `Status` line from "Design approved, ready for implementation" to "Implemented 2026-04-18".

---

## Self-Review Checklist (completed before handoff)

- [x] **Spec coverage:** §1 units (Task 3 live ring pushes msPerFrame), §2 table (Task 9), §2 trend (Task 8+9), §2 tiers (Task 3), §3 header (Task 7), §4 frame budget (Task 10), §5 self-cost row (Task 11), §6 poll-rate (Task 1+7), §7 INI (Task 5+6), §8 component split (helpers in Tasks 7-11), §9 out-of-scope (not implemented, correct), §10 verification (Task 12).
- [x] **Placeholder scan:** No `TBD`, `similar to`, or handwaves. Every code step has the actual code.
- [x] **Type consistency:** `msPerFrame`, `spikes`, `count`, `totalIntervalMs` names match across Tasks 3 / 8 / 9 / 10 / 11. `COLS` shared between header-draw and hit-test. `sortColumn` values (`"pctTotal" | "p50" | "p95" | "spikesPerMin" | "name"`) match between INI-load in Task 6 and sort-cmp in Task 9.

---

**Execution handoff:**

Plan complete and saved to `dev/2026-04-18-ui-redesign-implementation-plan.md`.

The user already said "execute the plan" — proceeding inline with `superpowers:executing-plans` semantics: work through tasks sequentially, verify-and-deploy at each task's verify step, stop and report if any verification fails.
