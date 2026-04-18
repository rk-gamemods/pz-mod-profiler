# 00_ModProfiler — UI Redesign (2026-04-18)

## Why this exists

The current overlay ([ModProfilerUI.lua](../release/00_ModProfiler/42.0/media/lua/client/00_ModProfiler/ModProfilerUI.lua))
has confusing units (ms-per-5s-interval displayed as if it were ms-per-frame), an
unreadable header collision ("ntrend"), no sorting controls, no spike-frequency
metric, an ugly bar sparkline, and a sparse self-cost block. Several items from
the plans in [dev/](.) were skipped entirely: frame budget graph, configurable
poll rate, line sparklines. This design replaces the overlay body with a coherent
column set, a meaningful trend indicator, a frame-budget visualization, and a
self-cost row that shows the profiler's own overhead in the same language as
every user mod.

---

## 1. Units — everything in terms the user already thinks in

The raw data is `ms summed per interval` (interval = `INTERVAL_TICKS / 60` seconds,
default 5s, soon user-configurable). That unit is meaningless on its own. Every
displayed number is converted before rendering:

- **ms/frame** = `interval_ms / (INTERVAL_TICKS)`. Directly comparable to the
  frame budget (`1000 / targetFPS`, ≈16.67ms at 60fps).
- **%Total** = `mod_interval_ms / sum(all_mod_interval_ms) × 100`. Computed over
  the current display window (last N intervals).
- **spikes/min** = spike count summed over the same rolling 5-minute window used
  for the trend computation (see §2), divided by window length in minutes. Same
  data source as the trend — one ring per mod carries `{msPerFrame, spikes}`
  per entry, so the rolling window is shared state, not two separate buffers.
- **trend** = linear-regression slope over the last 5 minutes of `ms/frame`
  samples, expressed as `%/min` drift.

No raw "ms-per-interval" number is shown anywhere in the UI. The raw value is
still used internally for percentile math and for the `console.txt` session log.

---

## 2. Main mod table — column layout

```text
Mod              %Total   ms/f p50   ms/f p95   spk/min   trend 5m/sess
───────────────────────────────────────────────────────────────────────
[vanilla]        45.1%    1.48 ms    1.76 ms     0.0      → →
UTCore           28.3%    0.28 ms    0.42 ms     1.2      ↗ →
HorseMod          7.0%    0.12 ms    0.20 ms     0.3      → →
MemLeakMod        4.2%    0.18 ms    0.25 ms     0.5      → ↗     (creeping over whole session)
SpikerMod         2.8%    0.10 ms    0.45 ms     6.0      ↗ →     (spike burst, not a trend)
RecoveryMod       0.8%    0.04 ms    0.06 ms     0.0      ↘ ↗     (settling now, was rising long-term)
FreshMod          0.3%    0.02 ms    0.03 ms     0.0      → —     (not enough data for session arrow yet)
```

Six columns (trend holds two arrows — short-term left, long-term right).
Every column header is clickable:

- Click a header → sort descending by that column. Click again → ascending.
  Active sort column highlighted with a subtle ▼/▲ glyph next to the label.
- Click a row → pin / unpin (pinned rows always render at top regardless of sort).
- Right-click a row → copy mod name to clipboard.

Default sort on first open: **%Total desc**. Sort preference persists across
sessions via ModProfiler.ini (same file as window geometry).

Color coding is by **p95 of ms/frame** on a green→yellow→red continuous gradient,
bounds `[0.0 ms/f, 1.0 ms/f]`. A mod using 1ms+ per frame on p95 is clearly
in the red. (Previous gradient was `[0, 10]` on the raw per-interval number,
which almost never turned red even for heavy mods — now the scale matches the
unit users actually care about.)

### Trend + spikes — shared rolling window (short-term arrow)

Per mod, one ring buffer carries `{ msPerFrame, spikes }` entries, one entry
pushed per profiler interval. Ring size = enough entries for 5 minutes at the
current poll rate (`ceil(300 / intervalSec)`), capped at 600.

On refresh the UI does a single pass over this ring and computes both metrics:

**Short-term trend** — ordinary least-squares slope of `msPerFrame`:

```text
slope_per_sample = Σ((x_i - x̄)(y_i - ȳ)) / Σ((x_i - x̄)²)
slope_per_minute = slope_per_sample × (60 / intervalSec)
pct_per_minute   = slope_per_minute / mean(y) × 100
```

**Spikes/min** — sum of the `spikes` column over the ring, divided by
`(ring_samples × intervalSec) / 60`.

Display glyph (short-term, left arrow of the pair):

- `pct_per_minute > +2%/min` → `↗` (orange tint)
- `pct_per_minute < -2%/min` → `↘` (blue tint)
- otherwise → `→` (muted)

Flat-threshold 2%/min prevents noise from flipping the arrow constantly. The
arrows are drawn as three pre-rendered `drawText` strings (`↗`, `→`, `↘`) — no
custom glyph code needed, PZ Lua fonts support them.

If the live ring has fewer than 10 samples → short arrow is `—`, and spikes/min
renders as `—` until there's enough data to report.

### Long-term trend — session-wide, with minute-buckets warmup

The right-hand arrow in the trend column reports drift over the **full
session**, using a two-phase bucket scheme to stay meaningful from minute 3
onward:

- **Minute buckets** (warmup): for the first 30 minutes of session, maintain
  `_modMinuteRings` (size 30, one entry per 1-min window, each entry
  `{mean(msPerFrame), sum(spikes), count}`). Long arrow computes OLS slope on
  whatever minute-buckets are available, as long as there are ≥3 of them.
- **5-minute buckets**: always populated (same `_modPeriodRings` described
  below). Once the session has ≥6 complete 5-min buckets (i.e. 30 minutes of
  play), switch the long-term arrow source to period buckets and stop
  updating minute buckets (they've served their purpose).

This yields:

| Session elapsed | Long arrow shows |
| --- | --- |
| 0–3 min | `—` (not enough minute buckets) |
| 3–30 min | OLS slope over 3–30 minute buckets |
| 30 min+ | OLS slope over all 5-min period buckets since session start |

Slope math is identical to the short-term formula, just on the period/minute
tier and expressed as `%/h` internally (not displayed — only the glyph shows,
same thresholds: >+2%/h rising, <−2%/h falling, else steady). The `%/h` unit
matches the longer horizon.

### Tiered aggregation for long sessions

Three tiers of per-mod aggregation:

- **Live tier** (5-min rolling ring): drives short-term arrow, spikes/min,
  percentile columns. Detailed in the prior section.
- **Minute tier** (`_modMinuteRings`, size 30, active only during warmup):
  every 60 seconds, snapshot `{mean(msPerFrame), sum(spikes), count}` into
  this ring. Stops updating once the session reaches 30 min.
- **Period tier** (`_modPeriodRings`, size 288 ≈ 24h of 5-min buckets): every
  5 minutes, snapshot `{mean(msPerFrame), sum(spikes), count}` into this ring.
  Drives the long-term arrow post-warmup. Two floats + one int per entry per
  mod — 100 mods over a full day is ~350 KB.
- **Session tier** (`_modSessionTotals`): one running counter per mod,
  `{totalIntervalMs, totalSpikes, totalIntervals}`. Not displayed in this
  pass, but populated and exposed for future features (session summary
  tooltip, history graph).

Expose via new getters:

- `ModProfiler.getModMinuteSamples(modName)` → minute ring as array
- `ModProfiler.getModPeriodSamples(modName)` → period ring as array
- `ModProfiler.getModSessionTotals(modName)` → session totals
- `ModProfiler.getSessionElapsedMinutes()` → used by UI to pick the right tier

---

## 3. Header — plain English, budget-aware

```text
PROFILER [ON]   9.2 / 16.7 ms frame (55%)   rate 2s ▾   ▸▸■■■■□□□□
                ↑ CPU used / target budget    ↑ poll    ↑ next interval
```

- `[ON]` / `[OFF]` — reflects `ModProfiler.isEnabled()`.
- `CPU / budget` — live values. CPU pulled via `pcall(getCPUTime)`, budget via
  `1000 / getPerformance():getFramerate()`. `(% used)` turns red above 90%,
  yellow above 75%, green otherwise.
- `rate` — `ISComboBox` with options: 10s / 5s / 2s / 1s / 0.5s / 0.1s.
  Default 2s on first install; persisted via `ModProfiler.ini` thereafter.
- Interval progress bar — left-to-right fill on the current partial interval.

At widths <700px the budget string collapses to just `9.2/16.7ms` and the
"ms frame (55%)" wordy suffix is dropped. The combo box and progress bar are
positioned proportionally and re-flow on resize.

---

## 4. Frame budget graph — stacked area below the mod table

New section between the mod table and the self-cost row. Source: a new
`_frameBudgetRing` populated once per interval in `dumpIntervalReport`. Each
entry carries `{modMs, engineMs, headroomMs, cpuMs, fps, budgetMs, uncapped}`
computed using the formulas from [plan-frame-budget.md](plan-frame-budget.md).

Rendering reuses the test-harness `drawStackedArea` primitive (already in the
code under `TEST_MODE`). Three layers stacked bottom-to-top per column:

- **Headroom** (green, `0.2 0.8 0.3`) — unused frame budget
- **Engine + vanilla** (blue, `0.3 0.5 0.9`) — `cpuMs - modTotalMs`
- **Mods** (orange, `1.0 0.5 0.2`) — sum of mod totals

Dashed cyan line at `budgetMs`. When `uncapped`, drop the headroom layer and
omit the line; title becomes `FRAME BUDGET (UNCAPPED)`.

Below the graph, one summary line:

```text
Avg headroom: 7.5 ms (45% free)   min: 0.2 ms   max: 11.3 ms
```

Color: green >30% free, yellow 10-30%, red <10%.

Over-budget indicator: when the latest sample's `cpuMs > budgetMs`, a red
`⚠ OVER BUDGET: +X.Xms` label renders above the graph. Blink pattern: 500ms on
/ 500ms off using `getTimestampMs() % 1000 < 500`.

Graph height: `clamp(80, 30% of available content height, 180)`.

---

## 5. Self-cost row — one-liner aligned with mod table columns

```text
─── PROFILER SELF-COST ─────────────────────────────────────────────────
00_ModProfiler   0.3%    0.03 ms    0.05 ms     0.0      → steady
────────────────────────────────────────────────────────────────────────
```

Literally one row, drawn below the mod table using the exact same column
positions and formatting as a normal mod row, with a divider above and
below to visually separate it. This directly answers the user's request:
"similar metrics to other mod entities, simply separated so it's always
visible as its own separate cost of the profiling itself."

Data source: `_selfStats` already tracks wrapper overhead (calibrated),
interval dumps, session summaries, and spike logs. We aggregate those into
one effective mod called `"00_ModProfiler"`:

- total self-ms-per-interval = `wrapperPerCall × totalCalls_this_interval
  + dumpMs + spikeLogMs (+ summaryMs on summary intervals)`
- convert to ms/frame, compute p50/p95/spikes/trend the same way as user mods

The detailed breakdown (wrapper / dumps / summaries / spike logs) still emits
to `console.txt` — it's gone from the overlay only.

---

## 6. Poll-rate dropdown — configurable interval

Pulled from [plan-polling-rate.md](plan-polling-rate.md), implemented but
simplified (no hierarchical ring buffer — that was scope creep for this pass):

- `ModProfiler.setIntervalTicks(ticks)` — clamped `[6, 3000]`. Resets
  `_tickCount` so the new rate takes effect immediately.
- Print cadence decoupled: `PRINT_INTERVAL_TICKS = 300` always, independent of
  display rate. At 0.1s rate, console.txt still only gets one `[MODPROFILER]`
  block every 5s.
- `DISPLAY_WINDOW` now dynamic: `max(5, min(60, floor(40 / intervalSec)))` so
  percentile + trend windows cover ≈40s regardless of rate.
- `trendRing` sized for 5 minutes at current rate, capped at 600 entries.

When the user changes rate mid-session, existing ring samples aren't purged —
they just represent the old rate until they scroll out. This is consistent with
how the user's question about this was answered in the original plan. A fresh
`ModProfiler.resetSession()` clears everything if the user wants a clean slate.

---

## 7. Persisted state (new fields in ModProfiler.ini)

Extends the existing INI file:

- `intervalTicks` — last-used poll rate
- `sortColumn` — which column the user sorted by (`"pctTotal" | "p50" | "p95" | "spikesPerMin" | "trend" | "name"`)
- `sortDescending` — bool
- Existing: `x, y, w, h, visible, filter, pinned`

---

## 8. Component boundaries (internal, for implementation hygiene)

**ModProfiler.lua** (shared) gains:

- `_frameBudgetRing` + populate in `dumpIntervalReport`
- `_modLiveRings` (`[modName] = ring of {msPerFrame, spikes}`, 5-min rolling) —
  shared state for short-term trend and spikes/min
- `_modMinuteRings` (`[modName] = ring of {msPerFrame, spikesPerMin, count}`,
  30 entries, active only during 0–30 min warmup)
- `_modPeriodRings` (`[modName] = ring of {msPerFrame, spikesPerMin, count}`,
  24h of 5-min buckets, active always)
- `_modSessionTotals` (`[modName] = {totalIntervalMs, totalSpikes, totalIntervals}`)
- `setIntervalTicks(ticks)` / `getIntervalSeconds()` / `getSessionElapsedMinutes()`
- `getFrameBudgetSamples()` / `getTargetFrameMs()`
- `getModLiveSamples` / `getModMinuteSamples` / `getModPeriodSamples` / `getModSessionTotals`

**ModProfilerUI.lua** (client) reorganized into three prerender sections
(header / modTable / framebudget / selfcost), each a small helper function
so the prerender loop is 20 lines instead of 200. Sorting state lives on the
panel; header-click hit-testing added to `onMouseDown`.

Sparkline function removed; trend column uses plain `drawText`.

**ModProfilerKeys.lua** — unchanged.

---

## 9. What's explicitly out of scope for this pass

- Hierarchical ring buffers (RRDtool-style tiered aggregation)
- Pinned-mod comparison line graph
- GPU overlay line on the frame budget graph
- Adaptive spike threshold (% of frame budget)
- pz_log_query.py percentile report enhancements

These stay as `dev/plan-*.md` items for a future pass. The current pass is
scoped to what the user explicitly picked in clarifying questions:
columns + sorting + trend + self-cost row + frame budget graph + poll rate.

---

## 10. Verification plan

1. **Visual**: deploy, open overlay, confirm:
   - No "ntrend" collision
   - %Total column sums to ~100%
   - ms/frame p50 × targetFPS ≈ the previous per-interval display numbers
   - Trend arrows present on mods with ≥10 samples
   - Frame budget stacked area renders and the dashed budget line is at 16.7ms
   - Self-cost row renders in same style as mods, clearly separated
2. **Interactive**: click each header → sort flips. Click row → pin works.
   Right-click row → clipboard has mod name. Change poll rate → interval bar
   cadence updates live.
3. **Sanity**: over 10 min, self-cost p95 should be ≤0.1 ms/f (acceptance
   baseline from PLAN.md phase 6). Over-budget indicator appears when
   intentionally lagging the game (e.g. load many vehicles).
4. **Persistence**: close/reopen game → window position, sort, rate, pinned
   mods all restored.
5. **Release sync**: after each code change, `media/` and
   `release/00_ModProfiler/42.0/media/` stay bit-identical (confirmed by
   `deploy.py --verify`).

---

## Files touched

| File | Change |
| --- | --- |
| `media/lua/shared/00_ModProfiler/ModProfiler.lua` | new rings (budget, trend, spike counters), new getters, `setIntervalTicks`, decoupled print cadence |
| `media/lua/client/00_ModProfiler/ModProfilerUI.lua` | full prerender rewrite, new columns, header with combo box, frame budget section, self-cost one-liner, sort/click interaction, ini persistence of new fields |
| `release/...` (mirrors) | synced by `deploy.py` |

No new files. No changes to `ModProfilerKeys.lua`.
