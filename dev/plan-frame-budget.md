# Plan: Frame Time Budget & Headroom Visualization

## Feature
- **#6** Visualize total profile time vs total frame time as a stacked area graph showing
  mods (total), vanilla/engine, and empty/unutilized time (headroom)

## Problem
The profiler shows per-mod timing but doesn't show the big picture: how much of each frame
is consumed by mods vs vanilla code vs idle headroom. At 60 FPS the budget is 16.67ms.

User's exact request: "if a frame is 16ms it would be good to see empty time... stacked
area graph with mods (total), vanilla, empty unutilized time."

**USER FEEDBACK**: Frame budget graph was LIKED. Multi-Mod Overlay was REJECTED.

---

## Confirmed Working APIs (from test harness probes)

| API | Returns | Used For |
|-----|---------|----------|
| `getCPUTime()` | CPU update time per frame (ms, nanosecond-derived) | Total frame CPU cost |
| `getGPUTime()` | GPU render time per frame (ms, nanosecond-derived) | GPU monitoring |
| `getCPUWait()` | CPU wait for GPU (ms) | Wait analysis |
| `getGPUWait()` | GPU wait for CPU (ms) | Wait analysis |
| `getAverageFPS()` | 5-frame rolling FPS (float) | Current FPS display |
| `getTimestampMs()` | System.currentTimeMillis() (1ms precision) | Timestamp |
| `getPerformance():getFramerate()` | Target FPS lock (int) | Budget calculation |
| `getPerformance():isFramerateUncapped()` | FPS cap off? (boolean) | Disable budget line |
| `getGameTime().fpsMultiplier` | 60/actual_fps (float) | FPS ratio |
| `GameProfiler.getTimeNs()` | **NIL — DOES NOT WORK** | — |

**CRITICAL**: `getCPUTime()` returns the TOTAL CPU frame time including ALL code (mods +
vanilla + engine internals). This is the authoritative "how long the CPU spent this frame"
value. It is NOT limited to profiled code.

---

## Category Calculation (Exact Formulas)

**Per interval (computed in dumpIntervalReport):**

```lua
-- 1. Total CPU time (from Java API — call with pcall for safety)
local ok, cpuMs = pcall(getCPUTime)
if not ok then cpuMs = 0 end

-- 2. Total mod time (sum of all mod interval totals already computed in dump)
-- modTotalMs is already available in dumpIntervalReport scope
-- It's the sum of all per-mod interval totals

-- 3. Engine+vanilla = everything NOT accounted for by mods
--    We cannot separate vanilla Lua from engine C++ — they're lumped together
--    This is CORRECT: the user sees "how much overhead is NOT from mods"
local engineAndVanillaMs = math.max(0, cpuMs - modTotalMs)

-- 4. Frame budget (only meaningful when FPS is capped)
local ok2, perf = pcall(getPerformance)
local targetFPS = (ok2 and perf) and perf:getFramerate() or 60
local uncapped = (ok2 and perf) and perf:isFramerateUncapped() or false
local budgetMs = uncapped and 0 or (1000.0 / targetFPS)
-- 60 FPS → 16.67ms, 30 FPS → 33.33ms, 120 FPS → 8.33ms

-- 5. Headroom
local headroomMs = 0
if not uncapped then
    headroomMs = math.max(0, budgetMs - cpuMs)
end

-- 6. FPS snapshot
local ok3, fps = pcall(getAverageFPS)
if not ok3 then fps = 0 end
```

**Category breakdown for stacked chart:**
```
budgetMs (16.67ms at 60 FPS)
├── modTotalMs        (all mods combined — ORANGE: r=1.0, g=0.5, b=0.2)
├── engineAndVanillaMs (cpuMs - modTotalMs — BLUE: r=0.3, g=0.5, b=0.9)
└── headroomMs        (budgetMs - cpuMs — GREEN: r=0.2, g=0.8, b=0.3)
```

**Edge case — over budget:**
```lua
if cpuMs > budgetMs and not uncapped then
    headroomMs = 0
    -- Over-budget indicator: red blinking text
    local overMs = cpuMs - budgetMs
    -- Label: "OVER BUDGET: +X.Xms"
end
```

**Edge case — uncapped FPS:**
```lua
if uncapped then
    -- No budget line drawn
    -- No headroom category (2-category stack only: mods + engine)
    -- Title shows: "FRAME BUDGET (UNCAPPED)"
    -- Summary shows raw timing only, no headroom percentage
end
```

**Edge case — negative engineAndVanillaMs:**
Happens when profiled mod time exceeds total CPU time (profiler overhead, timing jitter).
Always clamp: `math.max(0, cpuMs - modTotalMs)`

---

## Ring Buffer for Budget Data

Store frame budget samples in a new ring buffer in ModProfiler.lua:

```lua
-- New ring buffer for frame budget data (pushed per interval)
local _frameBudgetRing = ringCreate(120)  -- same size as T0 tier

-- Each entry is a table:
-- { modMs=X, engineMs=Y, cpuMs=Z, fps=F, budgetMs=B, headroomMs=H, uncapped=bool }
```

**In dumpIntervalReport() — add after per-mod ring pushes:**
```lua
local ok, cpuMs = pcall(getCPUTime)
if not ok then cpuMs = 0 end
local ok2, fps = pcall(getAverageFPS)
if not ok2 then fps = 0 end
local ok3, perf = pcall(getPerformance)
local targetFPS = (ok3 and perf) and perf:getFramerate() or 60
local uncapped = (ok3 and perf) and perf:isFramerateUncapped() or false
local budgetMs = uncapped and 0 or (1000.0 / targetFPS)
local engineMs = math.max(0, cpuMs - modTotalMs)
local headroomMs = uncapped and 0 or math.max(0, budgetMs - cpuMs)

ringPush(_frameBudgetRing, {
    modMs = modTotalMs,
    engineMs = engineMs,
    cpuMs = cpuMs,
    fps = fps,
    budgetMs = budgetMs,
    headroomMs = headroomMs,
    uncapped = uncapped,
})
```

**Public API:**
```lua
function ModProfiler.getFrameBudgetSamples()
    return _frameBudgetRing
end

function ModProfiler.getTargetFrameMs()
    local ok, perf = pcall(getPerformance)
    if not ok or not perf then return 16.67 end
    local uncapped = perf:isFramerateUncapped()
    if uncapped then return 0 end
    return 1000.0 / perf:getFramerate()
end
```

**Clear in resetSession():**
```lua
_frameBudgetRing = ringCreate(120)
```

---

## Confirmed Working Primitive: drawStackedArea (test harness lines 260–332)

The test harness `drawStackedArea()` is the quality reference. Copy VERBATIM and adapt
for production data. It draws:
- Dark background (r=0.08, g=0.09, b=0.12, a=0.6)
- Y-axis labels (proportional width: `math.max(30, math.floor(gw * 0.06))`)
- Budget line (dashed horizontal at budget threshold)
- Stacked columns with 3 categories
- Legend at bottom with colored swatches
- Title in top-left

**DO NOT reinvent**. Copy the test harness implementation. Adapt only:
1. Data source: read from `_frameBudgetRing` instead of simulated data
2. Category colors: use the exact ORANGE/BLUE/GREEN defined above
3. Font variables: use production `fHead`/`fBody` instead of test locals
4. Format function: use production `formatMs()` (unified with test `fmtMs()`)
5. Accept `uncapped` flag to control budget line and 2-cat vs 3-cat stack

---

## Exact drawBudgetGraph Implementation

```lua
local function drawBudgetGraph(panel, gx, gy, gw, gh, samples, budgetMs, uncapped, fBody)
    -- Background
    panel:drawRect(gx, gy, gw, gh, 0.6, 0.08, 0.09, 0.12)

    if #samples == 0 then
        local msg = "Waiting for data..."
        panel:drawText(msg, gx + 8, gy + gh / 2 - 6,
            0.5, 0.5, 0.5, 0.7, fBody)
        return
    end

    -- Y-axis dimensions
    local yAxisW = math.max(30, math.floor(gw * 0.06))
    local legendH = 20  -- fixed legend height at bottom
    local plotX = gx + yAxisW
    local plotW = gw - yAxisW
    local plotY = gy
    local plotH = gh - legendH

    -- Find Y max across all samples
    local yMax = 0
    for i = 1, #samples do
        local s = samples[i]
        local total = s.modMs + s.engineMs + s.headroomMs
        if total > yMax then yMax = total end
    end
    -- Ensure Y max >= budget line
    if not uncapped and budgetMs > yMax then yMax = budgetMs end
    yMax = yMax * 1.1  -- 10% padding
    if yMax < 1 then yMax = 1 end  -- division-by-zero guard

    -- Draw 4 horizontal grid lines with Y-axis labels
    for i = 1, 4 do
        local frac = i / 4
        local lineY = plotY + plotH - frac * plotH
        panel:drawRect(plotX, lineY, plotW, 1, 0.15, 0.3, 0.3, 0.3)
        local label = formatMs(frac * yMax)
        local lw = getTextManager():MeasureStringX(fBody, label)
        panel:drawText(label, plotX - lw - 2, lineY - 6,
            0.5, 0.5, 0.5, 0.7, fBody)
    end

    -- Draw budget line (dashed cyan, only when capped)
    if not uncapped and budgetMs > 0 then
        local budgetY = plotY + plotH - (budgetMs / yMax) * plotH
        -- Dashed line: alternating 4px on, 4px off
        for dx = 0, plotW, 8 do
            local segW = math.min(4, plotW - dx)
            panel:drawRect(plotX + dx, budgetY, segW, 1, 0.8, 1.0, 1.0, 0.3)
        end
        -- Label
        local budgetLabel = formatMs(budgetMs) .. " budget"
        panel:drawText(budgetLabel, plotX + 4, budgetY - 14,
            1, 1, 0.3, 0.8, fBody)
    end

    -- Draw stacked columns
    local colW = math.max(1, math.floor(plotW / #samples) - 1)
    for i = 1, #samples do
        local s = samples[i]
        local cx = plotX + (i - 1) * (colW + 1)
        local baseY = plotY + plotH

        -- Headroom (green) — bottom of stack
        local headH_px = (s.headroomMs / yMax) * plotH
        if headH_px > 0.5 then
            panel:drawRect(cx, baseY - headH_px, colW, headH_px,
                0.8, 0.2, 0.8, 0.3)
            baseY = baseY - headH_px
        end
        -- Engine+vanilla (blue) — middle
        local engH_px = (s.engineMs / yMax) * plotH
        if engH_px > 0.5 then
            panel:drawRect(cx, baseY - engH_px, colW, engH_px,
                0.8, 0.3, 0.5, 0.9)
            baseY = baseY - engH_px
        end
        -- Mods (orange) — top
        local modH_px = (s.modMs / yMax) * plotH
        if modH_px > 0.5 then
            panel:drawRect(cx, baseY - modH_px, colW, modH_px,
                0.8, 1.0, 0.5, 0.2)
        end
    end

    -- Legend at bottom
    local legY = gy + gh - legendH + 4
    local legX = plotX + 4
    local legSpacing = math.floor(plotW / 3)

    -- Mod swatch + label
    panel:drawRect(legX, legY, 8, 8, 1.0, 1.0, 0.5, 0.2)
    panel:drawText("Mods", legX + 12, legY - 1,
        0.7, 0.7, 0.7, 1.0, fBody)

    -- Engine swatch + label
    panel:drawRect(legX + legSpacing, legY, 8, 8, 1.0, 0.3, 0.5, 0.9)
    panel:drawText("Engine+Vanilla", legX + legSpacing + 12, legY - 1,
        0.7, 0.7, 0.7, 1.0, fBody)

    -- Headroom swatch + label (only when capped)
    if not uncapped then
        panel:drawRect(legX + legSpacing * 2, legY, 8, 8, 1.0, 0.2, 0.8, 0.3)
        panel:drawText("Headroom", legX + legSpacing * 2 + 12, legY - 1,
            0.7, 0.7, 0.7, 1.0, fBody)
    end
end
```

---

## Implementation Plan

### Phase 1: Frame Budget Data Collection in ModProfiler.lua

Add `_frameBudgetRing` and populate it in `dumpIntervalReport()`.

Specific changes:
1. Add `local _frameBudgetRing = ringCreate(120)` near other ring buffer declarations
2. In `dumpIntervalReport()`, after computing per-mod totals, add the budget sample push
   (exact code shown in "Ring Buffer for Budget Data" section above)
3. Add public getters: `getFrameBudgetSamples()`, `getTargetFrameMs()`
4. Clear ring in `resetSession()`
5. Wrap ALL Java API calls in pcall (getCPUTime, getAverageFPS, getPerformance)

**Verification (Phase 1):**
- [ ] `ModProfiler.getFrameBudgetSamples()` returns a ring buffer
- [ ] After 1 interval, ring has 1 entry with fields: modMs, engineMs, cpuMs, fps, budgetMs, headroomMs, uncapped
- [ ] `modMs + engineMs ≈ cpuMs` (within rounding)
- [ ] `headroomMs ≥ 0` always
- [ ] `budgetMs = 16.67` at 60 FPS cap
- [ ] `budgetMs = 0` when uncapped
- [ ] No crash if getCPUTime() returns nil (pcall guards)
- [ ] `resetSession()` clears the ring
- [ ] Deploy and verify with: `python deploy.py --verify`

### Phase 2: Extract drawBudgetGraph to Production Code

Copy `drawBudgetGraph()` (exact code above) into the production section of ModProfilerUI.lua,
alongside drawPixelLine and drawLineGraph (from Plan 3). If Plan 3 hasn't been implemented
yet, extract drawPixelLine at this stage too — it's needed for the GPU overlay line in
Phase 5.

**Verification (Phase 2):**
- [ ] `drawBudgetGraph` renders with static test data (temporarily inject fake samples)
- [ ] Budget line appears at correct Y position for 16.67ms
- [ ] Legend shows 3 categories (or 2 when uncapped)
- [ ] Stacked columns render correctly ordered (headroom → engine → mods, bottom to top)
- [ ] Y-axis labels show ms values, right-aligned
- [ ] Remove test data injection before Phase 3

### Phase 3: Integrate Budget Graph into prerender()

Add the frame budget section to prerender() layout.

**Placement**: Below mod table (and combined graph if present), above self-cost section.
The budget graph is ALWAYS visible (unlike combined graph which needs pinned mods).

```lua
-- === FRAME BUDGET SECTION ===
local budgetRing = ModProfiler.getFrameBudgetSamples()
local budgetArr = ModProfiler.ringToArray(budgetRing)
-- Take tail DISPLAY_WINDOW entries
local budgetSamples = {}
local bStart = math.max(1, #budgetArr - DISPLAY_WINDOW + 1)
for i = bStart, #budgetArr do
    budgetSamples[#budgetSamples + 1] = budgetArr[i]
end

-- Current frame stats (from most recent sample)
local currentBudget = #budgetArr > 0 and budgetArr[#budgetArr] or nil
local cpuMs = currentBudget and currentBudget.cpuMs or 0
local fps = currentBudget and currentBudget.fps or 0
local budgetMs = currentBudget and currentBudget.budgetMs or 16.67
local headroomMs = currentBudget and currentBudget.headroomMs or 0
local uncapped = currentBudget and currentBudget.uncapped or false

-- Divider
self:drawRect(PAD, y, cw, 1, 0.6, 0.3, 0.3, 0.3)
y = y + 1

-- Section header
local budgetTitle = uncapped and "FRAME BUDGET (UNCAPPED)" or "FRAME BUDGET"
drawTextCol(self, budgetTitle, PAD, y + 2, COL_HEADER, fHead)

-- Right-aligned summary
local summaryText
if uncapped then
    summaryText = string.format("CPU: %s  FPS: %.0f", formatMs(cpuMs), fps)
else
    summaryText = string.format("Budget: %s  CPU: %s  Headroom: %s",
        formatMs(budgetMs), formatMs(cpuMs), formatMs(headroomMs))
end
local sw = getTextManager():MeasureStringX(fBody, summaryText)
drawTextCol(self, summaryText, cw + PAD - sw, y + 2, COL_DIM, fBody)
y = y + headH + 4

-- Over-budget indicator (red blinking)
if cpuMs > budgetMs and not uncapped then
    local overMs = cpuMs - budgetMs
    local overText = string.format("OVER BUDGET: +%s", formatMs(overMs))
    -- Simple blink: 2× per second using timestamp modulo
    local t = (getTimestampMs() % 1000)
    local pulse = (t < 500) and 1.0 or 0.5
    self:drawText(overText, PAD + 4, y,
        1.0, 0.2, 0.2, pulse, fBody)
    y = y + bodyH + 2
end

-- Graph
local BUDGET_GRAPH_H = math.floor(math.max(80, math.min(200,
    (self:getHeight() - self:titleBarHeight()) * 0.30)))
drawBudgetGraph(self, PAD, y, cw, BUDGET_GRAPH_H, budgetSamples, budgetMs, uncapped, fBody)
y = y + BUDGET_GRAPH_H + 4

-- Bottom divider
self:drawRect(PAD, y, cw, 1, 0.6, 0.3, 0.3, 0.3)
y = y + 5
```

**Note on `math.sin`**: Kahlua VM availability is UNKNOWN. Use the simple blink pattern
(timestamp modulo) instead of sine-wave pulsing. Proven safe.

**Verification (Phase 3):**
- [ ] Frame budget section appears between mod table and self-cost
- [ ] Stacked columns show modMs (orange) + engineMs (blue) + headroomMs (green)
- [ ] Budget line (dashed cyan) drawn at correct height for 60 FPS cap
- [ ] Summary text shows: "Budget: 16.7ms  CPU: X.Xms  Headroom: X.Xms"
- [ ] When uncapped: title shows "(UNCAPPED)", no budget line, 2-category stack
- [ ] Over-budget: red blinking "OVER BUDGET: +X.Xms" label (blinks 2×/sec)
- [ ] Graph auto-scales Y-axis to fit all data + budget line
- [ ] At 500px width: graph fits without overlap, Y-axis labels don't bleed
- [ ] At 820px width: proportional and readable
- [ ] At 1200px width: uses extra width effectively
- [ ] Empty data (startup): shows "Waiting for data..." placeholder
- [ ] Window auto-grows to accommodate budget graph section

### Phase 4: Average Headroom Summary with Color Coding

Add running average metrics below the graph (or as part of the summary header):

```lua
-- Compute averages from visible samples
local avgHeadroom = 0
local avgCpu = 0
local minHeadroom = 999999
local maxHeadroom = 0
local count = 0
for i = 1, #budgetSamples do
    local s = budgetSamples[i]
    avgCpu = avgCpu + s.cpuMs
    avgHeadroom = avgHeadroom + s.headroomMs
    if s.headroomMs < minHeadroom then minHeadroom = s.headroomMs end
    if s.headroomMs > maxHeadroom then maxHeadroom = s.headroomMs end
    count = count + 1
end
if count > 0 then
    avgCpu = avgCpu / count
    avgHeadroom = avgHeadroom / count
end

-- Headroom percentage and color
local pctFree = (budgetMs > 0 and not uncapped)
    and (avgHeadroom / budgetMs * 100)
    or 0

local pctColor
if pctFree > 30 then
    pctColor = { r = 0.3, g = 0.9, b = 0.4, a = 1.0 }  -- green
elseif pctFree > 10 then
    pctColor = { r = 1.0, g = 0.9, b = 0.3, a = 1.0 }  -- yellow
else
    pctColor = { r = 1.0, g = 0.3, b = 0.3, a = 1.0 }  -- red
end

-- Draw summary line below graph
if not uncapped and count > 0 then
    local avgText = string.format("Avg headroom: %s (%.0f%% free)  min: %s  max: %s",
        formatMs(avgHeadroom), pctFree, formatMs(minHeadroom), formatMs(maxHeadroom))
    drawTextCol(self, avgText, PAD + 4, y, pctColor, fBody)
    y = y + bodyH + 2
end
```

**Verification (Phase 4):**
- [ ] Average values are mathematically correct (verify with mental math on visible data)
- [ ] Percentage reflects `avgHeadroom / budgetMs * 100`
- [ ] Color: green when >30%, yellow when 10–30%, red when <10%
- [ ] When uncapped: no percentage line shown
- [ ] min/max headroom values appear correct
- [ ] Numbers update at each refresh cycle

### Phase 5 (Optional): GPU Overlay Line

Add a GPU time line overlay on the stacked area chart to show GPU cost alongside CPU:

```lua
-- After drawing stacked columns, overlay GPU line
if #samples >= 2 then
    local prevX, prevY
    for i = 1, #samples do
        local s = samples[i]
        local gpuMs = s.gpuMs or 0  -- need to add gpuMs to budget ring entries
        local cx = plotX + (i - 1) * (colW + 1) + colW / 2
        local cy = plotY + plotH - (gpuMs / yMax) * plotH
        if prevX then
            drawPixelLine(panel, prevX, prevY, cx, cy, 0.9, 0.3, 0.9, 1.0)  -- magenta
        end
        prevX, prevY = cx, cy
    end
end
```

This requires adding `gpuMs` to the budget ring entry:
```lua
-- In dumpIntervalReport:
local ok4, gpuMs = pcall(getGPUTime)
if not ok4 then gpuMs = 0 end

ringPush(_frameBudgetRing, {
    modMs = modTotalMs,
    engineMs = engineMs,
    cpuMs = cpuMs,
    gpuMs = gpuMs,  -- NEW
    fps = fps,
    budgetMs = budgetMs,
    headroomMs = headroomMs,
    uncapped = uncapped,
})
```

Add a magenta legend entry for "GPU" in the legend row.

**This phase is optional.** Implement only if time permits after core budget visualization.

---

## Edge Cases (Must Handle — No Crashes)

| Scenario | Expected Behavior |
|----------|-------------------|
| No budget data yet (startup) | "Waiting for data..." in graph area |
| Uncapped FPS | Title: "(UNCAPPED)", no budget line, 2-cat stack, no headroom % |
| Over budget | headroomMs = 0, red blink text "OVER BUDGET: +X.Xms" |
| engineMs negative (profiler overhead) | Clamped to 0 via `math.max(0, ...)` |
| getCPUTime() returns nil | pcall guard, default to 0 |
| getPerformance() returns nil | Default to 60 FPS capped |
| Very high CPU time (>100ms) | Y-axis auto-scales, budget line near bottom |
| All zeros (profiler disabled) | Flat empty graph, no crash |
| Budget ring empty after resetSession() | "Waiting for data..." placeholder |
| Single sample | One column visible, budget line drawn, summary shows that value |
| FPS changes mid-session (e.g., 60→30) | budgetMs changes per sample, budget line follows latest |

---

## Quality Standards (NON-NEGOTIABLE)

1. **Copy test harness drawStackedArea verbatim** as starting point
2. **Proportional layout** — graph height/width use percentages with math.max minimums
3. **Dynamic font scaling** — follows the 3-bracket system already in production
4. **Right-aligned numbers** — summary text right-aligned in header area
5. **Text truncation** — all labels check MeasureStringX and truncate with ".."
6. **Generous spacing** — 4px between sections, 2px between divider and content
7. **Dark graph background** — r=0.08, g=0.09, b=0.12, a=0.6
8. **No overlap** — verify at 500px minimum width
9. **Consistent ms units** — always "Xms", never seconds
10. **Budget line dashed cyan** — alternating 4px segments, clearly visible
11. **Over-budget clearly indicated** — red blinking text, impossible to miss
12. **Category colors LOCKED** — orange=mods (1.0,0.5,0.2), blue=engine (0.3,0.5,0.9),
    green=headroom (0.2,0.8,0.3). No deviations.
13. **No Kahlua gotchas** — no `math.random()`, no `next()`, use `pairs()`, use
    `MeasureStringY(font, "Aj")` not `MeasureStringY(font)`, pcall around ALL Java API calls
14. **No `math.sin`** — use simple timestamp modulo blink pattern instead

---

## Deployment & Testing

After each phase:
```
cd C:\Users\Admin\Documents\GIT\GameMods\PZMods\00_ModProfiler
python deploy.py --verify
```
User MUST Exit to Desktop (not main menu) to clear Kahlua `require()` cache.

Test matrix:
- Capped at 60 FPS: verify budget line at 16.7ms, green headroom visible
- Capped at 30 FPS: verify budget line at 33.3ms
- Uncapped FPS: verify no budget line, "(UNCAPPED)" label, 2-category stack
- Over-budget scenario: stress-test game with heavy mods, verify red indicator
- Startup: verify "Waiting for data..." before first interval
- Widths: 500px, 600px, 820px, 1200px — no overlap at any width

---

## Files Changed
- `ModProfiler.lua` — add `_frameBudgetRing`, populate in `dumpIntervalReport()`,
  add `getFrameBudgetSamples()`, `getTargetFrameMs()`, clear in `resetSession()`
- `ModProfilerUI.lua` — add `drawBudgetGraph()`, add frame budget section to
  prerender(), add over-budget indicator, add average headroom summary with color coding

## Complexity: Medium-High

## Dependencies
- Requires resizable window (Plan 1+2) — DONE
- Shares drawPixelLine with Line Graphs (Plan 3) — extract together if implementing
  concurrently, or extract independently if implementing sequentially
- Shares formatMs with all other features
- Benefits from faster polling (Plan 4+5) for more responsive budget display

## REMOVED: Nanosecond Timer Investigation
DELETED — GameProfiler is nil. getCPUTime() provides nanosecond-derived timing already.