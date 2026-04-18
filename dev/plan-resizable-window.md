# Plan: Resizable & Resolution-Aware Window

## Features
- **#1** Make the profiler window resizable (drag edges/corners)
- **#2** Constrain window to game resolution (can't exceed screen)

## Status: IMPLEMENTED — Polish Required

Core implementation is complete. ISCollapsableWindow parent class, resize/drag, proportional
layout, font scaling, right-aligned numbers, name truncation, sorting, auto-grow height.

---

## Remaining Polish Tasks (Mandatory — Not Optional)

### Task A: Column Minimum Pixel Widths

At narrow widths (<600px), stat columns at 10.5% each shrink to ~50px which causes number
overlap. Fix this with floor-with-minimum pattern:

```lua
local statW = math.max(52, math.floor(cw * 0.105))
local nW    = math.max(28, math.floor(cw * 0.06))
local nameW = math.max(70, math.floor(cw * 0.20))
-- sparkline absorbs remaining: sparkW = cw - nameW - statW*4 - nW
-- If sparkW < 20, hide sparkline entirely (set sparkW = 0, skip drawing)
```

Priority order when space is constrained (reduce in this order):
1. Sparkline width (can be hidden entirely below 20px)
2. Name column (minimum 70px, always truncate with "..")
3. Stat columns (minimum 52px, never reduce below this)

### Task B: Row Height Breathing Room

Change row height calculation from `+3` to `+4`:
```lua
local RH = tm:MeasureStringY(fBody, "Aj") + 4
```
This adds 1px additional vertical breathing room per row. At 15 mods visible, this uses
only 15px extra — well within the window's height budget.

### Task C: Header Wrap at Narrow Widths

When width < 600px, the header line "PROFILER [ON] int 5 frm 120" overflows. Split into
two lines at narrow widths:

```lua
if w < 600 then
    -- Line 1: PROFILER [ON]
    drawTextCol(self, "PROFILER", PAD, y, COL_HEADER, fHead)
    drawTextCol(self, enabledStr, PAD + profW + 6, subY, enabledCol, fBody)
    y = y + headH
    -- Line 2: interval + frame count (muted, smaller)
    drawTextCol(self, string.format("int %d  frm %d",
        ModProfiler.getIntervalIndex(), ModProfiler.getFrameCount()),
        PAD, y, COL_MUTED, fBody)
    y = y + RH
else
    -- Single line (current behavior)
end
```

### Task D: Width Clamping on Initial Open

When the window first opens, ensure it doesn't exceed screen bounds:
```lua
local sw = getCore():getScreenWidth()
local sh = getCore():getScreenHeight()
local initW = math.min(DEFAULT_W, math.floor(sw * 0.70))
local initH = math.min(DEFAULT_H, math.floor(sh * 0.60))
local initX = math.max(0, math.floor((sw - initW) / 2))
local initY = math.max(0, math.floor((sh - initH) / 4))
```

---

## Verification Checklist

Test at these widths after each change (drag-resize the window):

| Width | Expected Behavior |
|-------|-------------------|
| 500px (minimum) | All columns visible, no text overlap, sparkline may be hidden, DebugConsole font |
| 600px | Sparkline visible (narrow), Small font body, header still readable |
| 700px | Comfortable layout, all columns clearly separated |
| 820px (default) | Reference layout — generous spacing, Small body / Medium header |
| 1200px | Extra sparkline width, columns well-spaced, no wasted right margin |

Test at these screen resolutions:
- 1920×1080: Window should open centered, max initial width 1344px (70%)
- 2560×1440: Window should open centered, max initial width 1792px (70%)
- 1280×720: Window should open at ~820px wide or 896px (70%), whichever is smaller

Verify these behaviors:
- [ ] Drag right edge to resize width — layout reflows smoothly, no flickering
- [ ] Drag bottom edge to resize height — content area grows, no overlap
- [ ] Drag corner — both dimensions resize together
- [ ] Resize below minimum (500×300) — window snaps to minimum, doesn't shrink further
- [ ] Resize wider than screen edge — width-clamp resizeFunction prevents overflow
- [ ] Title bar drag — window moves, doesn't resize
- [ ] Collapse button — window collapses to title bar only, restores correctly
- [ ] Pin button — window stays on screen across game state changes
- [ ] Auto-grow with many mods — height grows to fit 15+ rows, never exceeds screen

---

## Key Technical Constraints (Proven by Testing)

- `self.__index = self` (NOT `self.__index = o`) — wrong pattern → "loop in gettable" crash
- Must call BOTH `ISCollapsableWindow.prerender(self)` AND `ISCollapsableWindow.render(self)`
- `ISResizeWidget` is invisible — mouse-capture only; `ISCollapsableWindow.render()` draws grip
- Title bar height: `self:titleBarHeight()` = `math.max(16, FONT_HGT_SMALL + 1)`
- `MeasureStringY(UIFont, "Aj")` — MUST pass string arg, bare `MeasureStringY(UIFont)` crashes
- `MeasureStringX(UIFont, str)` — works correctly for width measurement
- NTFS junctions don't work for PZ mod loading — always use `deploy.py`
- `pcall` catches errors but Kahlua still shows error dialog; guard nil globals BEFORE calling

## Deployment

```
cd C:\Users\Admin\Documents\GIT\GameMods\PZMods\00_ModProfiler
python deploy.py --verify
```
User MUST Exit to Desktop (not main menu) to clear Kahlua `require()` cache before testing.

## Files
- `ModProfilerUI.lua` — production code section (lines ~560–1060)
