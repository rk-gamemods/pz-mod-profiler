# 00_ModProfiler Live Issues Research Report

Date: 2026-04-18
Scope: investigation only
Constraint: no code changes were made for this report

## Executive Summary

Two different issues were reported:

1. The overlay shows two dropdowns, with one blocking the close icon.
2. The frame-budget graph appears to "leak" upward over time even when the visible per-mod rows stay near 0.00 ms/f.

The first issue is a confirmed UI lifecycle bug in the current code.

The second issue is not currently supported as a profiler accumulation bug. The current implementation and the Project Zomboid Java source indicate a different explanation: the graph is intentionally showing total game-thread CPU time, while the rows show only wrapped Lua callback time for a limited event set. That means a high or growing blue engine band with tiny orange mod rows is possible without any contradiction.

## Sources Reviewed

Local mod code:

- media/lua/client/00_ModProfiler/ModProfilerUI.lua
- media/lua/shared/00_ModProfiler/ModProfiler.lua

Stored Project Zomboid source:

- Lua/client/ISUI/ISUIElement.lua
- Lua/client/ISUI/ISCollapsableWindow.lua
- Lua/client/ISUI/ISComboBox.lua
- Java/source/zombie/GameWindow.java
- Java/source/zombie/Lua/LuaManager.java
- Java/source/zombie/FPSTracking.java

External references reviewed:

- https://projectzomboid.com/modding/zombie/Lua/LuaManager.GlobalObject.html
- https://projectzomboid.com/modding/zombie/GameWindow.html
- https://projectzomboid.com/modding/zombie/core/PerformanceSettings.html
- https://pzwiki.net/wiki/Mod_optimization
- https://www.lua.org/pil/23.1.html
- https://www.lua.org/pil/23.2.html

Repository context used:

- /memories/repo/pz_modprofiler_frame_budget_math_root_cause_20260418.md
- /memories/repo/pz_utmods_profiler_baseline_original_20260412.md

## Confirmed Finding 1: Duplicate Dropdown Root Cause

This is a real bug.

### Evidence

In media/lua/client/00_ModProfiler/ModProfilerUI.lua, `ModProfilerUI.show()` manually calls `panel:createChildren()` before the panel is added to the UI manager.

Relevant code path:

- `ModProfilerUI.show()` constructs the panel
- `panel:initialise()` is called
- `panel:createChildren()` is called manually
- later `panel:addToUIManager()` is called

In Lua/client/ISUI/ISUIElement.lua, `ISUIElement:instantiate()` also calls `self:createChildren()` automatically when the Java UI object is created.

That means the panel child tree is being created twice.

### Why that matters

`ModProfilerPanel:createChildren()` in media/lua/client/00_ModProfiler/ModProfilerUI.lua creates the rate combo box and adds it as a child.

It also calls `ISCollapsableWindow.createChildren(self)`, and the base Project Zomboid window class creates the title bar buttons and resize widgets there.

So the current sequence is effectively:

1. create title-bar children + rate combo once
2. instantiate panel
3. create title-bar children + rate combo again

That matches the observed symptom closely:

- duplicate dropdown rendering
- title bar overlap
- one control intercepting mouse input near the close icon

### Confidence

High.

This is directly supported by the current mod code and the stored PZ UI base class behavior.

## Confirmed Finding 2: The Graph Is Measuring A Bigger Thing Than The Rows

This is also real.

### Evidence From PZ Java Source

In Java/source/zombie/Lua/LuaManager.java, `getCPUTime()` returns:

`GameWindow.getUpdateTime() / 1000000L`

In Java/source/zombie/GameWindow.java, `getUpdateTime()` returns `updateTime`.

In the same file, `updateTime` is assigned in `frameStep()` as:

`updateTime = System.nanoTime() - startTime`

That assignment happens in a `finally` block around the whole frame update section.

The measured block includes:

- `logic()`
- `IsoWorld.instance.FinishAnimation()`
- `IsoObjectAnimations.getInstance().update()`
- `renderInternal()`
- `onRender()` when enabled
- `Core.getInstance().DoFrameReady()`
- `LightingThread.instance.update()`
- `LuaEventManager.RunQueuedEvents()`
- debug handling branches

So `getCPUTime()` is not "sum of wrapped mod callbacks". It is the wall-clock duration of the whole game-thread update block.

### Evidence From Current Mod Code

In media/lua/shared/00_ModProfiler/ModProfiler.lua:

- `buildWrapper()` measures only wrapped callback execution time
- `dumpIntervalReport(false)` computes `modMs = grandMs / INTERVAL_TICKS`
- then computes `engineMs = max(0, cpuMs - modMs)`
- then stores `cpuMs`, `modMs`, `engineMs`, and `headroomMs` into the frame-budget ring

In media/lua/client/00_ModProfiler/ModProfilerUI.lua, `drawBudget()` renders:

- green = headroom
- blue = engine
- orange = mods

So the current UI is explicitly designed to show residual non-row cost as the blue band.

### Practical Meaning

If the rows show tiny values but the graph is still crowded, that does not automatically mean the profiler is wrong.

It means one of these is happening:

1. non-profiled game-thread work is expensive
2. Java-side engine work is expensive
3. wrapped Lua callbacks are not covering the hot path that is actually growing

### Confidence

High.

This is directly backed by current mod code and decompiled PZ Java source.

## Finding 3: No Current Evidence Of A Ring-Buffer Accumulation Leak

I do not currently find evidence that the profiler itself is falsely accumulating graph history forever.

### Evidence

In media/lua/shared/00_ModProfiler/ModProfiler.lua:

- `ringCreate()` creates bounded fixed-size rings
- `ringPush()` wraps write position and caps count at size
- `_frameBudgetRing` is created with a fixed size
- `recordIntervalAggregate()` pushes per-interval values, not session-growing cumulative display values
- `dumpIntervalReport(false)` resets the interval accumulators after consuming them

This matters because a previous genuine bug in interval resets was already fixed earlier. In the current code path, I do not see a second obvious bug where frame-budget samples keep numerically compounding by mistake.

### What this does not prove

It does not prove there is no real runtime growth.

It only means the specific theory "the graph is growing because the profiler is accidentally accumulating old interval samples into new ones" is not currently supported by the code I reviewed.

### Confidence

Medium-high.

The negative claim is based on source inspection, not on new live instrumentation from the running game.

## Finding 4: Event Coverage Boundary Is Large Enough To Matter

This is likely the most important explanation for the user-visible mismatch.

### Evidence

The profiler only wraps the events listed in `PROFILED_EVENTS` in media/lua/shared/00_ModProfiler/ModProfiler.lua.

That list includes many important hooks, but it is still only a whitelist of selected Lua event registrations.

Anything outside that boundary will not appear as a user row even if it contributes to total game-thread frame cost.

Examples of work that can escape row attribution:

- Java engine work inside frameStep
- rendering preparation
- lighting updates
- animation finishing
- queued Lua events outside the wrapped registration path
- mod logic using non-profiled events
- engine-side work triggered by Lua but not spending its time inside the wrapped callback body

### External Guidance Relevance

The PZ wiki optimization guide reinforces that:

- Java/Lua crossings are expensive
- per-tick work is expensive
- not all hot work is visible from naive Lua-side inspection

That does not prove a specific leak, but it does support the idea that visible callback rows can under-explain whole-frame CPU usage.

### Confidence

High on the coverage-boundary fact.

Medium on it being the complete explanation for the live drift.

## Finding 5: Graph Contrast And Density Complaints Are Valid UI Issues

These are not research mysteries. They are presentation problems in the current UI.

### Evidence

In media/lua/client/00_ModProfiler/ModProfilerUI.lua, `drawBudget()` uses three semi-transparent stacked fills:

- headroom: green
- engine: blue
- mods: orange

On a dark background, especially with a visually dominant blue residual band, the separation is harder to read than it should be.

The same file also allocates a relatively tall graph plus footer block, which contributes to the feeling that the panel is too airy for the amount of information shown.

### Confidence

High.

This is directly visible in the current implementation.

## What Is Confirmed Versus Not Confirmed

### Confirmed

- The duplicate dropdown is caused by child creation happening twice.
- `getCPUTime()` measures total frameStep wall-clock time, not just mod callback time.
- The graph is intentionally showing residual blue engine time separate from orange mod time.
- The current code does not show an obvious second accumulation bug in the frame-budget ring.

### Not Confirmed

- A true long-session engine leak inside Project Zomboid or a specific mod.
- A claim that the profiler math is currently inventing usage out of nowhere.
- A claim that the drift is purely cosmetic.

## Most Likely Current Interpretation

The best-supported reading of the live screenshots is:

- the duplicate dropdown is a real UI bug
- the growing graph is most likely showing real growth in total game-thread frame cost outside the wrapped mod rows
- the profiler is not currently proving where that blue residual comes from

In other words, the overlay is currently much better at answering:

"How expensive are wrapped callbacks from the profiled event set?"

than it is at answering:

"What exact subsystem is responsible for every millisecond inside frameStep as the session ages?"

## Recommended Next Steps If Code Changes Are Allowed Later

1. Fix the confirmed duplicate-child lifecycle bug first.

Reason: until the panel is creating children exactly once, UI observations around overlap, hitboxes, and header layout are not trustworthy.

2. Add temporary interval diagnostics for the residual.

Specifically log, per display interval:

- `cpuMs`
- `modMs`
- `engineMs`
- profiler self row total
- current tick/frame index

Reason: this would verify whether the blue residual is truly growing, and at what rate, without relying only on the graph.

3. Audit event coverage against the actual hot mods in the user load order.

Reason: if a hot mod runs mostly through non-profiled hooks, the graph/rows mismatch will persist even when the profiler itself is behaving correctly.

4. Improve graph readability after correctness work is settled.

Reason: the current color/alpha choices make interpretation harder than necessary, especially when engine time dominates.

## Bottom Line

The duplicate dropdown issue is solved at the research level: it is a confirmed bug in the current panel lifecycle.

The performance issue is narrower than "the profiler is broken" and broader than "nothing is wrong". What is currently proven is that the graph measures total frameStep CPU time while the rows measure only wrapped callback time. That means the screenshot can be real and still look inconsistent if the missing cost is in the blue residual path.

The next useful step is not blind math rewrites. It is residual-focused instrumentation and event-coverage validation.