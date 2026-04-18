# Plan: Line Graphs & Combined Frame Time Line Graph

## Feature
- **#3** Implement line graphs and a combined frame time line graph

## Problem
The current sparklines are small bar-chart style visualizations in each row. The user wants:
1. Proper line graphs (cleaner visual for time-series trends)
2. A combined graph showing pinned mods' trends overlaid on one chart

**CRITICAL USER FEEDBACK**: The user explicitly rejected the "Multi-Mod Overlay" concept as
"stupid" and "means nothing to me" when shown as an automatic all-mods overlay. The combined
graph MUST only show **pinned mods** (click-to-select) and serve as a detailed analysis tool,
NOT a default overview. If no mods are pinned, the graph section does NOT appear at all.

---

## Confirmed Working Primitives (from test harness, ModProfilerUI.lua lines 176–258)

### drawPixelLine (lines 176–190)
Bresenham line drawing using 1×1 drawRect calls. Performance: handles hundreds of points at
60 FPS without visible impact. Copy EXACTLY — do not optimize or refactor.

### drawLineGraph (lines 200–258)
Multi-series line graph with Y-axis, grid lines, and legend. Reference quality standard:
- Dark background rect (r=0.08, g=0.09, b=0.12, a=0.6)
- Y-axis labels: proportional width `math.max(30, math.floor(gw * 0.06))`
- Legend: proportional width `math.max(50, math.floor(gw * 0.13))`
- Plot area: fills remaining width between Y-axis and legend
- 4 horizontal grid lines with fmtMs() labels
- Auto-scaled Y range with 10% padding above max
- Title text in top-left of plot area (fHead font)
- Legend entries: colored swatch (6×5px) + truncated label with MeasureStringX check
- Line thickness: 1px (single drawPixelLine between adjacent points)

### fmtMs (lines 192–198)
Format milliseconds for display. Unify with production `formatMs()` — always ms, commas for
thousands, 1 decimal place. `fmtMs(16.678)` → `"16.7ms"`. `fmtMs(1234.5)` → `"1,234.5ms"`.

---

## Color Palette (Hardcoded — 8 Colors for Pinned Mods)

Each pinned mod gets an assigned color by its order in the pinned set. Colors are chosen for
maximum contrast on dark backgrounds and for distinguishability by colorblind users:

```lua
local LINE_COLORS = {
    { 0.35, 0.70, 1.00 },  -- [1] sky blue
    { 1.00, 0.50, 0.20 },  -- [2] orange
    { 0.30, 0.90, 0.40 },  -- [3] green
    { 1.00, 0.35, 0.55 },  -- [4] pink/rose
    { 0.70, 0.50, 1.00 },  -- [5] purple
    { 1.00, 0.85, 0.20 },  -- [6] yellow
    { 0.40, 0.90, 0.90 },  -- [7] cyan
    { 1.00, 0.65, 0.65 },  -- [8] salmon
}
```

If more than 8 mods are pinned, wrap: `colorIdx = ((i - 1) % 8) + 1`. This is unlikely in
practice — users pin 2–4 mods for comparison.

---

## Data Source

`ModProfiler.getModIntervalSamples()` returns `_modIntervalSamples[modName]`, each a ring
buffer `{ data={}, n=count, w=nextWriteIdx, size=SAMPLE_RING_SIZE }`.

Convert to array: `ModProfiler.ringToArray(ring)` returns `{ [1]=oldest, ..., [n]=newest }`.

For sparklines: take tail `DISPLAY_WINDOW` entries (currently 20).
For combined graph: take all available samples for longer trend view (up to 120).

---

## Implementation Plan

### Phase 1: Extract Drawing Utilities to Production Code

Move shared drawing functions from the test harness (lines 176–258) into the production code
section. Place them ABOVE the ModProfilerPanel class definition (around line 560), alongside
existing utility functions (percentile, computeStats, etc.).

Functions to extract — copy EXACTLY from test harness, zero modifications:

```lua
-- 1. drawPixelLine(panel, x1, y1, x2, y2, r, g, b, a)
--    Copy lines 176-190 verbatim

-- 2. drawLineGraph(panel, gx, gy, gw, gh, series, title, font)
--    Copy lines 200-258 verbatim
--    series format: { { label="ModName", data={1.2, 3.4, ...}, r=0.35, g=0.70, b=1.00 }, ... }

-- 3. Unify fmtMs with formatMs
--    Replace production formatMs with test harness fmtMs (lines 192-198)
--    It handles comma formatting and always returns "Xms"
```

**DO NOT** simplify, refactor, or "improve" the test harness code. It is proven. Copy verbatim.

**Verification (Phase 1):**
- [ ] drawPixelLine draws visible lines (test: draw a diagonal across the header area temporarily)
- [ ] drawLineGraph renders with test data (temporarily render a static graph in prerender)
- [ ] formatMs output matches: `formatMs(16.7)` → `"16.7ms"`, `formatMs(0.3)` → `"0.3ms"`
- [ ] Deploy and visually confirm — then remove test draws before Phase 2

### Phase 2: Replace Bar Sparklines with Line Sparklines

Current production `drawSparkline()` (around line 835) draws vertical bars. Replace with a
mini line graph using `drawPixelLine`:

```lua
local function drawSparkline(panel, sx, sy, sw, sh, data, r, g, b)
    if not data or #data < 2 then return end

    -- Dark background
    panel:drawRect(sx, sy, sw, sh, 0.6, 0.08, 0.09, 0.12)

    -- Find range
    local yMin, yMax = data[1], data[1]
    for i = 2, #data do
        if data[i] < yMin then yMin = data[i] end
        if data[i] > yMax then yMax = data[i] end
    end
    local yRange = yMax - yMin
    if yRange < 0.001 then yRange = 1.0 end  -- flat line guard

    -- Draw connected line segments
    local step = sw / (#data - 1)
    local prevX = sx
    local prevY = sy + sh - ((data[1] - yMin) / yRange) * sh
    for i = 2, #data do
        local px = sx + (i - 1) * step
        local py = sy + sh - ((data[i] - yMin) / yRange) * sh
        drawPixelLine(panel, prevX, prevY, px, py, r, g, b, 1.0)
        prevX, prevY = px, py
    end
end
```

Color inherits from the mod row's p95-based color (use the same `p95Color()` function).

**Edge cases:**
- `data` is nil → return immediately, draw nothing
- `#data == 0` → return immediately
- `#data == 1` → draw a single horizontal line at vertical center
- All values identical (yRange < 0.001) → draw flat line at center
- Negative values → should not occur (ms timing), but clamp to 0 as safety

**Sparkline dimensions** (unchanged from current layout):
- Width: `sparkW` from proportional layout (remainder after columns, ~32% of `cw`)
- Height: `RH - 2` (row height minus 2px top/bottom padding)
- If sparkW < 20, hide sparkline entirely (set sparkW = 0)

**Verification (Phase 2):**
- [ ] Every mod row shows a line sparkline (not bars)
- [ ] Sparkline color matches the p95 color coding
- [ ] Flat data shows a horizontal line (not empty area)
- [ ] Single data point shows a short horizontal mark
- [ ] Sparkline fits within its column — no bleed into adjacent columns
- [ ] At 500px width, sparklines may be hidden — verify graceful disappearance
- [ ] At 820px default width, sparklines are clearly visible with smooth lines

### Phase 3: Combined Pinned-Mod Comparison Graph

Add a dedicated graph section that appears ONLY when 1+ mods are pinned (click a mod row to
pin). The graph goes between the mod table and the self-cost section in the prerender layout.

**Visibility rule:**
```lua
local pinnedCount = 0
local pinnedList = {}
for modName, pinned in pairs(self.pinned) do
    if pinned then
        pinnedCount = pinnedCount + 1
        pinnedList[#pinnedList + 1] = modName
    end
end
-- Sort pinned list alphabetically for consistent color assignment
table.sort(pinnedList)
```

If `pinnedCount == 0`, skip this entire section (no divider, no graph, no vertical space used).

**Layout formula:**
```lua
local GRAPH_H = math.floor(math.max(80, math.min(180, (self:getHeight() - tbH) * 0.25)))
local graphX = PAD
local graphY = y + 4  -- 4px spacing after mod table
local graphW = cw
-- Draw section divider
panel:drawRect(graphX, y, graphW, 1, 0.6, 0.3, 0.3, 0.3)
y = y + 1

-- Section title
drawTextCol(self, "PINNED MOD COMPARISON", PAD, y + 2, COL_HEADER, fHead)
y = y + headH + 2
```

**Building the series array:**
```lua
local series = {}
for i, modName in ipairs(pinnedList) do
    local ring = ModProfiler.getModIntervalSamples()[modName]
    if ring then
        local arr = ModProfiler.ringToArray(ring)
        -- Take tail DISPLAY_WINDOW entries for consistent view
        local visible = {}
        local start = math.max(1, #arr - DISPLAY_WINDOW + 1)
        for j = start, #arr do
            visible[#visible + 1] = arr[j]
        end
        local ci = ((i - 1) % #LINE_COLORS) + 1
        local c = LINE_COLORS[ci]
        series[#series + 1] = { label = modName, data = visible, r = c[1], g = c[2], b = c[3] }
    end
end
```

Then draw:
```lua
if #series > 0 then
    drawLineGraph(self, graphX, y, graphW, GRAPH_H, series, "", fBody)
    y = y + GRAPH_H + 4
    -- Bottom divider
    self:drawRect(graphX, y, graphW, 1, 0.6, 0.3, 0.3, 0.3)
    y = y + 5
end
```

**Legend overflow handling:** If more than 4 mods are pinned, the legend entries in
drawLineGraph may overflow vertically. The drawLineGraph implementation already uses
truncated labels and fixed swatch sizes. If the legend overflows, it will clip at the
graph bottom — this is acceptable for 5–8 mods. For practical use, users pin 2–4 mods.

**What happens when a mod is unpinned:**
- The graph re-renders on next prerender() cycle (every frame)
- If last pinned mod is unpinned (pinnedCount → 0), the graph section disappears entirely
- Window height auto-shrinks (existing auto-grow logic only grows, not shrinks — this is
  acceptable; the space remains until the user manually resizes or closes/reopens)

**Verification (Phase 3):**
- [ ] No mods pinned → no graph section visible, no blank space
- [ ] Click a mod → graph appears with that mod's line
- [ ] Click 2nd mod → graph shows both lines with distinct colors
- [ ] Unpin all → graph disappears
- [ ] Graph Y-axis auto-scales to fit all pinned mods' data
- [ ] Graph has dark background, grid lines, Y-axis labels in ms
- [ ] Legend shows mod names with correct color swatches
- [ ] At 500px width: graph renders without overlap, Y-axis labels don't bleed
- [ ] At 820px width: graph is proportional and readable
- [ ] At 1200px width: graph uses extra width well, no wasted space
- [ ] With 0 or 1 data points: no crash, graph shows flat line or nothing

### Phase 4: Auto-Grow Height for Graph Section

The window auto-grow logic (existing) increases height when content exceeds it. The combined
graph adds `GRAPH_H + headH + dividers` (~100–200px) when pinned mods exist. Verify:
- Window grows to accommodate graph
- Window doesn't exceed screen height (existing screen-clamp logic)
- If screen is too short for graph, graph height reduces (via the `math.min(180, ...)` clamp)

---

## Edge Cases (Must Handle — No Crashes)

| Scenario | Expected Behavior |
|----------|-------------------|
| 0 data points for a mod | Skip that series (don't add to series array) |
| 1 data point for a mod | Draw a single dot (horizontal line of 1px at that Y value) |
| All values identical | Flat horizontal line at center of graph |
| Very large values (>1000ms) | Y-axis labels show "1,234.5ms" — formatMs handles this |
| Negative values | Clamp to 0 before plotting (should never occur, safety guard) |
| nil ring buffer for a mod | Skip that mod in series building (pcall not needed — just nil check) |
| Pinned mod gets removed mid-session | pairs(self.pinned) check skips it; no crash |
| Window width < 500px | Graph proportions still work — Y-axis and legend hit minimums |

---

## Quality Standards (NON-NEGOTIABLE)

1. **Copy test harness drawing code verbatim** — do not simplify, refactor, or "improve"
2. **Proportional layout** — ALL dimensions use percentages with math.max minimums
3. **Dynamic font scaling** — follows the 3-bracket system already in production
4. **Right-aligned numbers** — Y-axis labels right-aligned within their column
5. **Text truncation** — ALL text checks MeasureStringX and truncates with ".."
6. **Generous spacing** — 4px minimum between sections, 2px between divider and content
7. **Dark graph background** — r=0.08, g=0.09, b=0.12, a=0.6
8. **No overlap** — verify at 500px minimum width
9. **Consistent ms units** — always "Xms", never seconds
10. **Sorted display** — mods always sorted by performance impact (heaviest first) in table;
    pinned list sorted alphabetically for consistent color assignment
11. **No Kahlua gotchas** — no `math.random()`, no `next()`, use `pairs()`, use
    `MeasureStringY(font, "Aj")` not `MeasureStringY(font)`

---

## Deployment & Testing

After each phase:
```
cd C:\Users\Admin\Documents\GIT\GameMods\PZMods\00_ModProfiler
python deploy.py --verify
```
User MUST Exit to Desktop (not main menu) to clear Kahlua `require()` cache.

Test at widths: 500px, 600px, 820px (default), 1200px.

---

## Files Changed
- `ModProfilerUI.lua` — add drawPixelLine, drawLineGraph, LINE_COLORS to production section;
  replace drawSparkline; add combined graph section to prerender()

## Complexity: Medium

## Dependencies
- Requires resizable window (Plan 1+2) — DONE
- Frame Budget (Plan 6) will reuse drawPixelLine and drawStackedArea (separate extraction)