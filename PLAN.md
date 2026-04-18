# 00_ModProfiler — Overlay, Toggle, and Full Statistical Profiling

## TL;DR

Extend the existing profiler with three deliverables:

- **A.** In-game overlay (HUD panel) with live per-mod stats, driven by percentile distributions only (no bare means).
- **B.** Toggleable profiling + toggleable overlay, independently keybound.
- **C.** Full statistical timing profile (p25 / p50 / p95 / p99 + min / max / count) everywhere a metric is surfaced — overlay and `pz_log_query.py` report. No metric is shown as a bare mean anywhere.

The profiler engine (event interception, timing closures, mod attribution) stays structurally intact. The cumulative `_modStats` table keeps its role. What changes: we add a per-interval sample array so the full distribution is available, we separate the profiler's own core cost from user-mod attribution, and we expose a clean API for the overlay.

---

## Core principles (apply to every phase; do not contradict later)

1. **Percentiles are mandatory.** Every numeric column displayed to the user includes p25 / p50 / p95 / p99 + min / max / count. Mean may be shown alongside but never alone. This applies to: overlay rows, overlay sidebar, interval report, session summary, `pz_log_query.py` output.
2. **Disabled = zero cost.** When profiling is off, the wrapper fast-path is eliminated, not merely short-circuited. Toggling swaps registrations — it does not add a per-call boolean check.
3. **Profiler core self-cost is tracked separately.** The profiler's engine cost (wrapper overhead, interval dumps, session summaries, spike-log I/O) is attributed to `_selfStats`, not to `_modStats["00_ModProfiler"]`. Overlay cost is explicitly **not** tracked — overlay is user-driven and not part of "profiler always-on cost."
4. **Color coding uses p95, not mean.** A handler that spikes rarely but hard must surface red. Mean-based coloring hides this.
5. **Overlay handlers register via the saved original `Events.X.Add` references**, bypassing interception. Same for the engine's own tick handler. This fixes the current self-attribution that shows `00_ModProfiler +1,915ms +300 spikes` in session deltas.

---

## Phase 1 — Core engine: API, toggle, sample arrays

**File:** `media/lua/shared/00_ModProfiler/ModProfiler.lua`

### 1.1 Global table + public API

Introduce global `ModProfiler` with:

- `ModProfiler.isEnabled()` → bool
- `ModProfiler.setEnabled(bool)` → swaps wrapper registrations (see 1.2); prints status
- `ModProfiler.getModStats()` → `_modStats` reference (cumulative totals — kept for backwards compat)
- `ModProfiler.getModIntervalSamples()` → `_modIntervalSamples` reference (new — per-interval distributions)
- `ModProfiler.getCallbackIntervalSamples()` → `_callbackIntervalSamples` reference
- `ModProfiler.getSelfStats()` → `_selfStats` reference (new — profiler's own core cost)
- `ModProfiler.getIntervalTicks()` / `getTickCount()` — current interval progress
- `ModProfiler.resetSession()` — zeroes everything (for "start fresh")
- `ModProfiler.dumpSnapshot()` — prints a `[MODPROFILER] SNAPSHOT` block to `console.txt` (parsable by `pz_log_query.py`)
- `ModProfiler.registerUnwrapped(eventName, handler)` — registers a handler via the saved `_originalAdds[eventName]`, bypassing interception. Public API for overlay and engine-internal use. Client-side files (UI, keybinds) MUST use this instead of `Events.X.Add` to avoid self-measurement.

### 1.2 Toggle via wrapper swap + shadow registry

**Shadow registry:** `_shadowRegistry[eventName] = { [callbackId] = { original, wrapper } }` — populated on every intercepted `Add` call regardless of enabled state. This is the only durable record we have of registered callbacks (PZ's `Events.X` table is opaque).

When `setEnabled(false)`:

- For each intercepted event, walk `_shadowRegistry[event]` and call `_originalRemoves[event](entry.wrapper)` followed by `_originalAdds[event](entry.original)`. Keeps real callbacks firing, removes timing closures from the call path entirely.

When `setEnabled(true)`:

- Reverse: for each shadow entry, remove raw original and re-add wrapper.

**Registrations made while disabled:** the intercepted `Add` still runs (our replacement is in place), still builds the wrapper and shadow entry, but registers the *raw callback* with PZ (not the wrapper). This keeps the shadow registry complete and allows a later re-enable to correctly swap in wrappers for callbacks that appeared during the disabled window.

**Result:** disabled = zero wrapper cost in PZ's call path (the raw user callback fires directly, no indirection). Shadow registry cost is a single table write per `Add` call — not per event fire — so negligible.

### 1.3 Sample arrays for full distributions

Add two ring-buffered sample stores:

```
_modIntervalSamples       = {}  -- [modName][] = tot_ms for that interval
_callbackIntervalSamples  = {}  -- [callbackId] = { avg=[], peak=[], calls=[] }
```

Bounded to **600 intervals per mod / per callback** (~50 minutes of gameplay at 300-tick intervals). Overflow pops oldest via circular write index (no `table.remove` — O(1) writes).

At each interval boundary (inside `dumpIntervalReport`, which already iterates all active callbacks): for each mod, push the summed interval `tot_ms` into `_modIntervalSamples[mod]`; for each callback, push its `avg`, `peak`, `calls` into `_callbackIntervalSamples[id]`. Done in the same pass — no separate iteration.

### 1.4 Concurrent-modification + reload safety

- `dumpIntervalReport` and `dumpSessionSummary` snapshot keys first (`local ids = {}; for id in pairs(_callbacks) do ids[#ids+1] = id end`), then iterate the snapshot. Prevents issues when callbacks register/unregister mid-dump.
- `Remove` wrapper also clears `_callbacks[id]` (reverse lookup `_wrapperToId` added alongside `_wrapperToOrig`). Fixes unbounded `_callbacks` growth.
- Installation is idempotent: module-level `_installed` flag guards against `/reloadlua` double-wrapping.

### 1.5 Batched spike logging

Current code `print()`s inline on every spike ≥3ms. On a bad frame this itself causes hitches. Replace with per-interval buffered flush: collect spikes into `_pendingSpikeLog[]` during the interval, flush at the interval boundary as **one** `print()` call with a concatenated body. If `#_pendingSpikeLog > 10`, flush as `"... +N more spikes suppressed (worst: Xms @ source)"`.

### 1.6 Batched interval dump I/O

The current `dumpIntervalReport` loop does 20+ separate `print()` calls. Concatenate into one string + single `print()`. Applies to `dumpSessionSummary` too. Measured cost (see 1.7): drops `intervalDumpMs` roughly 10×.

### 1.7 Phase 1b — Profiler self-cost accounting (core only)

`_selfStats` (arrays, not running sums — needed for percentile display):

```
_selfStats = {
    wrapperOverheadPerCall = { samples={}, calibratedAt=0 },  -- batch calibration, see below
    intervalDumpMs         = {},  -- one entry per dump
    summaryDumpMs          = {},
    spikeLogMs             = {},
}
```

**Wrapper overhead — batch calibration, not per-call measurement.** At startup and every 60s thereafter: time a tight loop of 1000 iterations doing exactly what the wrapper does (two `getTimestampMs()` calls, four table writes, two comparisons). Divide by 1000 → per-call overhead estimate. Multiply by `totalCalls` at report time for attributed self-cost. Cost of calibration itself: ~1ms, once per minute.

**Dump / summary / spike-log timing** — wrap each function body with `local s = getTimestampMs(); ...; _selfStats.intervalDumpMs[#+1] = getTimestampMs() - s`. Direct measurement, no calibration needed.

**Explicitly excluded from `_selfStats`:** overlay refresh, overlay render, keybind handler cost. These are user-initiated, not always-on.

**Attribution fix:** engine's own `Events.OnTick.Add` (line 335 of current code) switches to use the saved original reference captured in `_originalAdds["OnTick"]` *before* interception is installed. Requires re-ordering initialization: capture originals → install interception → register engine tick handler via saved original. This is the fix for `00_ModProfiler +1,915ms +300 spikes` appearing in session deltas.

---

## Phase 2 — Overlay panel

**New file:** `media/lua/client/00_ModProfiler/ModProfilerUI.lua`

### 2.1 Panel structure

`ModProfilerPanel = ISPanel:derive("ModProfilerPanel")`. Draggable, resizable, semi-transparent black background. Width/height persisted to `Zomboid/Lua/ModProfiler.ini` alongside visibility, filter state, and pinned mods.

### 2.2 Refresh cadence

- Session/cumulative rows refresh at **250ms** via `OnPostUIDraw` (not `OnTick` — `OnPostUIDraw` is frame-rate-driven, matches user perception of snappiness, and the handler registers via saved `_originalAdds["OnPostUIDraw"]` so it doesn't self-measure).
- Percentile/sparkline columns refresh only at interval boundaries (event-driven via a `ModProfiler.onIntervalComplete` callback the engine fires after `dumpIntervalReport`). No polling — no wasted work.
- Refresh gated by `panel:getIsVisible() and getCore():isIdle() == false`. If the PZ window loses focus or the panel is hidden, refresh ticks short-circuit.

### 2.3 Row format (percentile-only; no bare means)

```
ModName          p50    p95    p99    max     n    [sparkline]
────────────────────────────────────────────────────────────────
[vanilla]       98ms  145ms  210ms  1739ms  319   ▂▃▂▄▃▅▂▃▂▄
UTCore          15ms   22ms   28ms    35ms  319   ▂▂▂▃▂▂▂▂▂▃
HorseMod         5ms    8ms   12ms    19ms  319   ▁▂▁▂▂▂▁▂▁▂
```

- Sparkline: 10-cell bar chart of the last 10 intervals (cheap — 10 × `drawRect` per row). Replaces the trend arrow idea from earlier drafts; percentile shift across the sparkline carries the trend story visually.
- Color coding: **by p95**, not mean. Continuous HSL gradient green → red, with p95 mapped to `[0ms, 10ms]`. Gradient not three-tier — more information per pixel.
- Font: `UIFont.DebugConsole` (monospace) for all numeric columns. Headers: `UIFont.Small`.

### 2.4 Header

```
PROFILER [ON]  interval ▓▓▓▓▓▓▓░░░  frame 90,421
```

- `[ON/OFF]` reflects `ModProfiler.isEnabled()`.
- Progress bar: `drawRect` filling left-to-right over the interval (`getTickCount() / INTERVAL_TICKS`). Gives free cadence feedback.
- Frame counter: current `_summaryCount + _tickCount` sum since session start.

### 2.5 Footer — total overhead stacked bar + self-cost sidebar

- **Stacked bar** (100% width): each top-N mod's share colored by row color. Instantly answers "who's eating my frame budget?"
- **Self-cost sidebar** (right edge, distinct styling so it reads as engine diagnostics, not user-mod data):
  ```
  PROFILER SELF-COST
    wrapper     p50=0.08  p95=0.12  × 12,453 calls = 996ms
    dumps       p50=42    p95=58    × 5            = 210ms
    summaries   p50=8     p95=14    × 1            =   8ms
    spike logs  p50=1.2   p95=2.1   × 23           =  28ms
    ─────────────────────────────────────────────────────────
    TOTAL                                           1,242ms
  ```

### 2.6 Interaction

- **Click row** → pin to top (stays visible even if it drops below the display cutoff).
- **Right-click row** → copy mod name to clipboard.
- **Filter input** at top — substring match against mod name.
- **Top-N selector** — default 15, user-adjustable via mousewheel over a `TopN: 15` label.
- **"Dump snapshot" button** → calls `ModProfiler.dumpSnapshot()` to emit a parsable block to `console.txt`.

### 2.7 Persistence

Panel X/Y/W/H, visibility, filter text, pinned mods, top-N — all serialized to `Zomboid/Lua/ModProfiler.ini` via PZ's config file API on `OnMainMenuEnter` / `OnGameStart`.

---

## Phase 3 — Keybinds

**New file:** `media/lua/client/00_ModProfiler/ModProfilerKeys.lua`

Two separate bindings registered via PZ's key binding system (configurable through **Options → Key Bindings**):

- `[ModProfiler] Toggle Overlay` — default: **F8** (F8 is reserved by vanilla for admin UI; avoid conflict)
- `[ModProfiler] Toggle Profiling` — default: **F12**

Handler uses `OnCustomUIKeyPressed` with direct key ID comparison — no chord logic, no manual modifier-state checks. PZ's binding UI doesn't natively handle chords, so each action gets its own slot.

---

## Phase 4 — Live aggregation for overlay

Rolled into Phase 1.3 by design. The sample arrays ARE the rolling window. The overlay's percentile columns read directly from `_modIntervalSamples` with a display window (default last 20 intervals, configurable). No separate rolling-buffer structure needed — removes the duplicate state the earlier draft proposed.

---

## Phase 5 — `pz_log_query.py` percentile report

**File:** `UTMods/tools/pz_log_query.py`

### 5.1 Augment existing output — no columns removed, percentiles added

Existing `show_profiler()` columns (`Δms`, `Δspikes`, `ms/1000f`, `spikes/1000f`) stay. New percentile columns added alongside. No "mean-only" columns remain anywhere in the output.

### 5.2 New sections (in output order)

1. **Existing session delta** — unchanged, still first.
2. **PROFILER SELF-COST** — new, second. Breaks out wrapper / dumps / summaries / spike-log cost as percentile rows. Lets the user see "what did running the profiler cost me" as a headline before diving into user-mod stats.
3. **PER-MOD INTERVAL PERCENTILES** — for each mod with ≥5 intervals:
   ```
   Mod             Intervals   P25    P50    P95    P99    Max    Mean
   ────────────── ──────────  ─────  ─────  ─────  ─────  ──────  ─────
   [vanilla]             319   78ms   98ms  145ms  210ms  1739ms  112ms
   UTCore                319   11ms   15ms   22ms   28ms    35ms   16ms
   ```
4. **PER-CALLBACK PERCENTILES** — `(mod, source:line)` with ≥5 intervals, both `avg_ms` and `pk_ms` distributions. Two side-by-side percentile blocks per row so the user sees "typical cost" and "peak behavior" in one view.

### 5.3 Computation

- Single `sorted()` pass per sample array, then index lookup for `p25 = arr[n//4]`, `p50 = arr[n//2]`, `p95 = arr[n*95//100]`, `p99 = arr[n*99//100]`. Beats `statistics.quantiles(n=100)` for sample sizes in the 300–600 range we'll see.
- Sub-millisecond handling: if ≥80% of samples are 0ms or 1ms (timing-floor-bound), display `<1ms` for p25/p50 and compute real percentiles only for p95/p99. Footnote the output section explaining the 1ms timing floor.

### 5.4 Schema versioning

Each `[MODPROFILER]` dump line gets a `v=2` tag (current unversioned = v1). `pz_log_query.py` reads both. Forward compatibility as the format evolves.

---

## Phase 6 — Verification

1. **Baseline measurement (Phase 0, before any changes):** record current profiler self-cost. Today's value from user's session: 1,915ms over 90,000 frames = 21.3ms/1000f with 3.3 spikes/1000f. This is the acceptance baseline.
2. **Disabled-overhead test:** `ModProfiler.setEnabled(false)` → profile a 1-minute session with a separate external profiler (or compare `getTimestampMs()` totals across OnTick). Disabled overhead must be **<0.2ms/1000f** (effectively zero). If measurable, the wrapper-swap in 1.2 is broken.
3. **Enabled-overhead test:** `ModProfiler.setEnabled(true)`, no overlay. Self-cost (from `_selfStats`) should be **≤15ms/1000f** after the batched-I/O improvements — better than the 21.3ms baseline. If worse, revisit 1.5/1.6.
4. **Percentile report sanity:** run `python tools/pz_log_query.py profiler` against a real `console.txt`. Every row has all six columns (P25/P50/P95/P99/Max/Mean). No column is mean-only.
5. **Overlay functional test:** press F8 → panel appears. Press F12 → header flips ON/OFF, MODPROFILER lines stop appearing in `console.txt`. Click a row → it pins. Type in filter → list narrows. Relaunch PZ → panel restores to last position.
6. **Self-attribution test:** after 10 minutes of play, `00_ModProfiler` does **not** appear in the top-N mod list. Its cost appears in the sidebar `PROFILER SELF-COST` block instead.
7. **Reload safety:** `/reloadlua shared` mid-session → profiler does not double-wrap (verified by callback count staying stable, not doubling).
8. **Deploy verification:** after release sync + robocopy, hash-compare `media/**` vs `release/00_ModProfiler/42.0/media/**` vs `C:\Users\Admin\Zomboid\mods\00_ModProfiler\42.0\media/**`.

---

## Files touched

| File | Change |
|---|---|
| `00_ModProfiler/media/lua/shared/00_ModProfiler/ModProfiler.lua` | Phase 1 + 1b — global API, wrapper-swap toggle, sample arrays, self-cost tracking, batched I/O, idempotent install |
| `00_ModProfiler/media/lua/client/00_ModProfiler/ModProfilerUI.lua` | **NEW** — overlay panel |
| `00_ModProfiler/media/lua/client/00_ModProfiler/ModProfilerKeys.lua` | **NEW** — keybinds |
| `UTMods/tools/pz_log_query.py` | Phase 5 — percentile sections + self-cost section + schema versioning |

Reference (read-only, template for overlay pattern): `ProximityInventoryLocal/media/lua/client/ProxInventory/ProxProfilerUI.lua`.

---

## Decisions (locked — do not re-debate in later phases)

- **No bare means anywhere.** Every displayed metric carries p25/p50/p95/p99/min/max/count.
- **Toggle swaps registrations, doesn't gate a boolean.** Disabled = zero wrapper cost.
- **Overlay cost is not tracked in `_selfStats`.** User-initiated, not always-on. Core engine cost (wrapper, dumps, summaries, spike logs) is tracked.
- **Color coding by p95**, gradient not tiered.
- **Rolling window = sample arrays** (Phase 1.3). No separate ring-buffer structure.
- **Engine's own tick handler uses saved `_originalAdds`**, bypassing interception. Fixes current self-attribution artifact (`00_ModProfiler +1,915ms +300 spikes`).
- **Keybinds: F8 overlay, F12 profiling.** No chords.
- **Sample arrays bounded to 600 intervals** (~50 min). Circular write, O(1).

---

## Out of scope (explicit non-goals)

- Cross-session persistent storage of sample data (current scope: in-memory per session; export via `dumpSnapshot` + log parsing covers cross-session analysis).
- Networked / multiplayer aggregation.
- Profiling of non-Events paths (ISTimedAction overrides, ISUIElement render cost, etc.) — future work if needed.
- UI for changing `INTERVAL_TICKS` / `SUMMARY_TICKS` / `SPIKE_THRESHOLD_MS` at runtime — stays as Lua constants.
