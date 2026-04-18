# Plan: Polling Rate Speed & Customization

## Features
- **#4** Speed up the polling and update rate
- **#5** Make the polling rate customizable within the display window

## Problem
The profiler updates every 300 ticks (~5 seconds at 60Hz OnTick). This is too slow for
real-time debugging. Users want faster updates (as fast as 0.1s) and the ability to choose
the rate from the UI without editing code.

---

## Confirmed Facts (from test harness and code review)

### OnTick Rate
OnTick fires at constant 60 Hz regardless of FPS.
- Current INTERVAL_TICKS = 300 → 300/60 = 5.0s per interval
- Current ring: 600 samples × 5s = 3000s = 50 minutes coverage

### Timer Resolution
`getTimestampMs()` = `System.currentTimeMillis()` = 1ms resolution.
At fast polling rates, individual measurements are noisy (±1ms) but sigma-delta
accumulation produces accurate totals over an interval. At 0.1s (6 ticks), 1ms
noise on a 10ms measurement = 10% error per sample, but trends are still useful.

### GameProfiler.getTimeNs() — NOT AVAILABLE
CONFIRMED: `GameProfiler` global is nil in Lua. Sigma-delta with `getTimestampMs()` is
the ONLY option. Do NOT attempt to use it.

### ISComboBox — CONFIRMED WORKING
Test harness used ISComboBox for simulation rate dropdown (lines 334–366). Copy pattern.

### Print I/O Overhead
At 10 dumps/sec, print I/O becomes significant (~50–200ms/sec at high mod counts).
Console output MUST be decoupled from display rate. Print-to-log stays at ≥5s cadence.

---

## Rate Options (Exact Values)

| Label | Ticks | Seconds | Coverage (T0 ring=120) |
|-------|-------|---------|------------------------|
| 10s   | 600   | 10.0    | 20 min                 |
| 5s    | 300   | 5.0     | 10 min                 |
| 2s (default) | 120 | 2.0 | 4 min                  |
| 1s    | 60    | 1.0     | 2 min                  |
| 0.5s  | 30    | 0.5     | 1 min                  |
| 0.1s  | 6     | 0.1     | 12 sec                 |

Default changes from 5s → 2s. This gives a good balance of responsiveness and noise.
The ISComboBox pre-selects "2s" on initialization.

---

## Implementation Plan

### Phase 1: Configurable Interval in ModProfiler.lua

Add a setter function to ModProfiler.lua with validation and smooth transition:

```lua
-- Near the top of ModProfiler.lua, replace the constant:
local _intervalTicks = 120  -- default 2.0s (was 300 = 5.0s)

-- Public getter (existing getIntervalTicks returns the constant — change to return variable)
function ModProfiler.getIntervalTicks()
    return _intervalTicks
end

-- New setter
function ModProfiler.setIntervalTicks(ticks)
    ticks = math.floor(ticks)
    if ticks < 6 then ticks = 6 end        -- minimum 0.1s
    if ticks > 3000 then ticks = 3000 end   -- maximum 50s
    _intervalTicks = ticks
    -- Reset tick counter to start fresh interval at new rate
    _tickCount = 0
end

-- New convenience getter for UI display
function ModProfiler.getIntervalSeconds()
    return _intervalTicks / 60.0
end
```

**Print cadence decoupling:**

Current code in `onTick()` calls `dumpIntervalReport()` which prints to console. Change:

```lua
-- Add near constants
local PRINT_INTERVAL_TICKS = 300  -- always 5s regardless of display rate
local _printTickCount = 0

-- In onTick(), after interval dump:
_printTickCount = _printTickCount + 1
local shouldPrint = (_printTickCount >= PRINT_INTERVAL_TICKS)
if shouldPrint then _printTickCount = 0 end

-- In dumpIntervalReport(), accept shouldPrint parameter:
function dumpIntervalReport(shouldPrint)
    -- ... existing aggregation logic (always runs) ...
    if shouldPrint then
        -- ... existing print/log statements ...
    end
end
```

**Verification (Phase 1):**
- [ ] `ModProfiler.setIntervalTicks(60)` changes interval to 1s
- [ ] `ModProfiler.getIntervalTicks()` returns current value
- [ ] Setting ticks < 6 clamps to 6
- [ ] Setting ticks > 3000 clamps to 3000
- [ ] Console output appears at ~5s intervals regardless of display rate
- [ ] At 0.1s rate, no console spam (print decoupled)
- [ ] Data aggregation and ring buffer pushes occur at the new rate

### Phase 2: Hierarchical Ring Buffer (RRDtool-Style)

Short intervals fill ring buffers fast (0.1s × 120 = 12 seconds of history). To maintain
long-term trends, implement cascading aggregation tiers:

**Tier structure:**
```lua
-- Per-mod hierarchical ring buffer
local function createHierarchicalRing()
    return {
        t0 = ringCreate(120),    -- raw intervals: 120 samples
        t1 = ringCreate(120),    -- 10× aggregated: 120 samples
        t2 = ringCreate(600),    -- 60× aggregated: 600 samples
        t1_acc = { sum = 0, count = 0, min = 999999, max = 0 }, -- T0→T1 accumulator
        t2_acc = { sum = 0, count = 0, min = 999999, max = 0 }, -- T1→T2 accumulator
        t1_threshold = 10,       -- cascade every 10 T0 pushes
        t2_threshold = 6,        -- cascade every 6 T1 pushes
    }
end
```

**Coverage at each rate:**

| Rate  | T0 (120 raw) | T1 (120 × 10) | T2 (600 × 60) |
|-------|-------------|----------------|----------------|
| 0.1s  | 12 sec      | 2 min          | 60 min         |
| 0.5s  | 60 sec      | 10 min         | 5 hours        |
| 1s    | 2 min       | 20 min         | 10 hours       |
| 2s    | 4 min       | 40 min         | 20 hours       |
| 5s    | 10 min      | 100 min        | 50 hours       |

**Cascade logic (in dumpIntervalReport):**
```lua
local function hierarchicalPush(hring, value)
    -- Always push raw value to T0
    ringPush(hring.t0, value)

    -- Accumulate for T1 cascade
    local acc1 = hring.t1_acc
    acc1.sum = acc1.sum + value
    acc1.count = acc1.count + 1
    if value < acc1.min then acc1.min = value end
    if value > acc1.max then acc1.max = value end

    -- Cascade T0→T1 every t1_threshold pushes
    if acc1.count >= hring.t1_threshold then
        local avg = acc1.sum / acc1.count
        ringPush(hring.t1, avg)
        -- Reset T1 accumulator
        acc1.sum = 0
        acc1.count = 0
        acc1.min = 999999
        acc1.max = 0

        -- Accumulate for T2 cascade
        local acc2 = hring.t2_acc
        acc2.sum = acc2.sum + avg
        acc2.count = acc2.count + 1
        if avg < acc2.min then acc2.min = avg end
        if avg > acc2.max then acc2.max = avg end

        -- Cascade T1→T2 every t2_threshold pushes
        if acc2.count >= hring.t2_threshold then
            ringPush(hring.t2, acc2.sum / acc2.count)
            acc2.sum = 0
            acc2.count = 0
            acc2.min = 999999
            acc2.max = 0
        end
    end
end
```

**Replacing existing ring buffers:**

Current code uses `_modIntervalSamples[modName]` as a flat ring. Change to hierarchical:
```lua
-- Replace:
--   _modIntervalSamples[modName] = ringCreate(SAMPLE_RING_SIZE)
-- With:
--   _modIntervalSamples[modName] = createHierarchicalRing()

-- Replace ring pushes:
--   ringPush(_modIntervalSamples[modName], totalMs)
-- With:
--   hierarchicalPush(_modIntervalSamples[modName], totalMs)
```

**Public API changes:**
```lua
-- Existing: returns flat ring → update to return T0 for backward compatibility
function ModProfiler.getModIntervalSamples()
    -- Return a view that maps modName → hring.t0 for backward compatibility
    local view = {}
    for modName, hring in pairs(_modIntervalSamples) do
        view[modName] = hring.t0
    end
    return view
end

-- New: returns full hierarchical ring for tier-aware displays
function ModProfiler.getModHierarchicalSamples()
    return _modIntervalSamples
end

-- New: get specific tier as array
function ModProfiler.getModTierData(modName, tier)
    local hring = _modIntervalSamples[modName]
    if not hring then return {} end
    if tier == 0 then return ringToArray(hring.t0) end
    if tier == 1 then return ringToArray(hring.t1) end
    if tier == 2 then return ringToArray(hring.t2) end
    return {}
end
```

**Memory estimate:** ~33 KB per mod (120+120+600 floats × 8 bytes + overhead), ~1 MB for
30 mods. Negligible.

**What happens to existing data when rate changes:**
- T0 ring keeps its existing samples (they just represent the old interval length)
- T1/T2 accumulators are NOT reset — they continue accumulating
- This means T1/T2 entries near a rate change will mix old and new interval sizes
- This is acceptable — the averaged values are still meaningful
- A full reset is available via `ModProfiler.resetSession()`

**Verification (Phase 2):**
- [ ] T0 ring fills at the current interval rate
- [ ] After 10 T0 pushes, one T1 entry appears
- [ ] After 6 T1 pushes (60 T0), one T2 entry appears
- [ ] `ringToArray(hring.t0)` returns correct recent values
- [ ] `getModIntervalSamples()` still returns flat T0 rings (backward compatible)
- [ ] Memory usage doesn't grow unbounded (ring buffers are fixed-size)
- [ ] Changing rate mid-session doesn't crash or corrupt data
- [ ] No use of `math.random()` or `next()` anywhere in new code
- [ ] Use `pairs()` for all table iteration

### Phase 3: ISComboBox Dropdown in UI

Add an ISComboBox to the profiler window's header area for rate selection.

**In createChildren():**
```lua
-- After ISCollapsableWindow.createChildren(self)
local comboW = 65
local comboH = 20
-- Position: right side of header area, below title bar
local comboX = self:getWidth() - comboW - PAD - 4
local comboY = self:titleBarHeight() + 4

self.rateCombo = ISComboBox:new(comboX, comboY, comboW, comboH, self, self.onRateChange)
self.rateCombo.font = UIFont.DebugConsole  -- smallest available font
self.rateCombo:addOptionWithData("10s", 600)
self.rateCombo:addOptionWithData("5s",  300)
self.rateCombo:addOptionWithData("2s",  120)
self.rateCombo:addOptionWithData("1s",   60)
self.rateCombo:addOptionWithData("0.5s",  30)
self.rateCombo:addOptionWithData("0.1s",   6)
self.rateCombo.selected = 3  -- "2s" (1-indexed, third option)
self:addChild(self.rateCombo)
```

**Rate change callback:**
```lua
function ModProfilerPanel:onRateChange(combo)
    local ticks = combo:getOptionData(combo.selected)
    ModProfiler.setIntervalTicks(ticks)
end
```

**ISComboBox repositioning on resize:**

In prerender(), reposition the combo box when the window is resized:
```lua
if self.rateCombo then
    local comboX = self:getWidth() - 65 - PAD - 4
    self.rateCombo:setX(comboX)
end
```

**Dynamic DISPLAY_WINDOW calculation:**

Sparklines and graphs should show a consistent time range (~40s of data), not a fixed
count of samples. Calculate based on current interval:
```lua
-- In prerender() or refreshRows():
local intervalSec = ModProfiler.getIntervalTicks() / 60.0
local DISPLAY_WINDOW = math.max(5, math.min(60, math.floor(40 / intervalSec)))
-- At 2s rate: 40/2 = 20 (same as current)
-- At 0.1s rate: 40/0.1 = 400, clamped to 60
-- At 10s rate: 40/10 = 4, clamped to 5
```

**Header text update:**
Currently shows "int X frm Y". Add current rate to header:
```lua
local rateLabel = string.format("rate %.1fs", ModProfiler.getIntervalTicks() / 60.0)
```

**Verification (Phase 3):**
- [ ] ISComboBox appears in top-right of header area, below title bar
- [ ] Dropdown opens and shows all 6 rate options
- [ ] Selecting "0.1s" changes interval to 6 ticks (updates within ~0.1s)
- [ ] Selecting "10s" changes interval to 600 ticks
- [ ] "2s" is pre-selected on startup
- [ ] Combo repositions correctly when window is resized
- [ ] Combo doesn't overlap with header text at 500px width
- [ ] Combo doesn't overlap with title bar buttons (close, pin)
- [ ] At 500px width, combo font is DebugConsole (smallest) — still readable
- [ ] Sparkline data range updates to show ~40s regardless of rate
- [ ] DISPLAY_WINDOW correctly calculated: 20 at 2s, 60 at 0.1s, 5 at 10s

### Phase 4: Tier-Aware Display (Combined Graph Enhancement)

When the combined pinned-mod graph (from Plan 3) exists, allow it to show T1 or T2 data
for longer historical views. This is a lightweight addition after Phase 3.

**Add a tier selector to the combined graph header:**
```lua
-- In the combined graph section of prerender():
-- Default: show T0 data
-- If the graph is present, add small clickable labels: [Recent] [Medium] [Long]
-- Or simpler: use tier data automatically based on time range desired
```

For MVP: always use T0 data in combined graph. Tier switching is a polish enhancement
that can be added later as a small follow-up if needed. Do NOT block Phase 3 on this.

---

## Edge Cases (Must Handle — No Crashes)

| Scenario | Expected Behavior |
|----------|-------------------|
| Rate changed to 0.1s with existing 5s data | T0 ring fills with new 0.1s entries; old entries roll off naturally |
| Rate changed back to 5s from 0.1s | T0 ring has mixed data temporarily; trends smooth out in ~60s |
| `resetSession()` called | All rings cleared, accumulators zeroed |
| New mod appears mid-session | Gets fresh hierarchical ring, no history |
| Mod disappears mid-session | Ring data preserved but no new pushes |
| Combo opened at screen edge | ISComboBox handles its own dropdown positioning |
| Very fast rate (0.1s) with 50+ mods | Print I/O decoupled; display rate is fine, only print cadence matters |

---

## Quality Standards (NON-NEGOTIABLE)

1. **ISComboBox positioning** — proportional, respects resize, no overlap with header text
2. **No console spam** — print cadence DECOUPLED from display rate (always ≥5s)
3. **Smooth transitions** — changing rate doesn't clear data or cause visual glitches
4. **Default rate clearly marked** — "2s" pre-selected in combo
5. **Self-cost overhead visible** — at all rates (profiler's own cost is measurable)
6. **Dynamic display window** — auto-adjusts to show ~40s of data at any rate
7. **Backward compatible API** — `getModIntervalSamples()` still returns flat T0 rings
8. **No Kahlua gotchas** — no `math.random()`, no `next()`, use `pairs()`

---

## Deployment & Testing

After each phase:
```
cd C:\Users\Admin\Documents\GIT\GameMods\PZMods\00_ModProfiler
python deploy.py --verify
```
User MUST Exit to Desktop (not main menu) to clear Kahlua `require()` cache.

Test matrix:
- Default rate (2s): verify behavior matches current quality
- Fast rate (0.1s): verify no console spam, sparklines update rapidly
- Slow rate (10s): verify sparklines still show meaningful data
- Rate switching: change from 0.1s → 5s → 1s mid-session, verify no crashes

---

## Files Changed
- `ModProfiler.lua` — hierarchical ring buffer, setIntervalTicks(), decoupled print,
  new API functions (getModHierarchicalSamples, getModTierData, getIntervalSeconds)
- `ModProfilerUI.lua` — ISComboBox dropdown in createChildren, repositioning in prerender,
  dynamic DISPLAY_WINDOW calculation, header text with rate display

## Complexity: Medium-High

## Dependencies
- Requires resizable window (Plan 1+2) — DONE
- Line graphs (Plan 3) will consume tier data through same API
- Frame Budget (Plan 6) benefits from faster sampling for responsive budget display