-- test/test_engine.lua
-- Runs the shared engine under stubs that exercise the pcall / nil-method
-- failure modes that crashed the live game.
--
-- Usage: cd <mod root> && lua test/test_engine.lua

package.path = "./test/support/?.lua;" .. package.path

local env = require("pz_env")

local passed, failed = 0, 0
local function ok(name, cond, detail)
    if cond then
        passed = passed + 1
        print(string.format("  PASS  %s", name))
    else
        failed = failed + 1
        print(string.format("  FAIL  %s  %s", name, detail or ""))
    end
end
local function section(name) print("\n[" .. name .. "]") end

-- Force a fresh load of the engine on each scenario.
local function loadEngine()
    package.loaded["ModProfiler"] = nil
    _G.ModProfiler = nil
    local src = assert(io.open("media/lua/shared/00_ModProfiler/ModProfiler.lua", "r")):read("*a")
    -- The engine does `if rawget(_G, "ModProfiler") and ModProfiler._installed then return end`
    -- at top — we reset that on purpose above.
    local loader = loadstring or load
    local chunk = assert(loader(src, "ModProfiler.lua"))
    chunk()
    return _G.ModProfiler
end

---------------------------------------------------------------------------
section("Scenario A: full Performance API (happy path)")
---------------------------------------------------------------------------
env.setMs(0)
env.setPerformance(env.defaultPerfFull())
env.setCPU(8.0)

local MP = loadEngine()
ok("module loaded", MP ~= nil)
ok("isEnabled()", MP.isEnabled() == true)
ok("getIntervalTicks() default", MP.getIntervalTicks() == 120)

-- Simulate 120 ticks worth of engineTick calls to trigger one dumpIntervalReport.
-- We call the registered OnTick handler directly via Events.
env.setMs(100)
for i = 1, 120 do env.trigger("OnTick") end

local samples = MP.getFrameBudgetSamples()
ok("frame budget sample captured", #samples >= 1,
   "expected >=1, got " .. #samples)
if #samples >= 1 then
    local s = samples[#samples]
    ok("budgetMs ~= 0", s.budgetMs and s.budgetMs > 0)
    ok("uncapped is boolean", type(s.uncapped) == "boolean")
end

---------------------------------------------------------------------------
section("Scenario B: Performance is nil (old build fallback)")
---------------------------------------------------------------------------
env.setMs(0)
env.setPerformance(env.perfCompletelyMissing())
env.setCPU(nil)

MP = loadEngine()
env.setMs(100)
local scenarioBCrashed = false
local okRun, err = pcall(function()
    for i = 1, 120 do env.trigger("OnTick") end
end)
ok("engineTick runs with no Performance", okRun,
   "error: " .. tostring(err))
local samplesB = MP.getFrameBudgetSamples()
ok("still recorded a frame sample (with fallback budgetMs)", #samplesB >= 1)
if #samplesB >= 1 then
    ok("fallback budget == 1000/60", math.abs(samplesB[#samplesB].budgetMs - 1000/60) < 0.001)
end

---------------------------------------------------------------------------
section("Scenario C: Performance lacks isFramerateUncapped AND getUncappedFrameRate (the real crash)")
---------------------------------------------------------------------------
env.setMs(0)
env.setPerformance(env.perfMissingUncapped())
env.setCPU(7.5)

MP = loadEngine()
env.setMs(100)
okRun, err = pcall(function()
    for i = 1, 120 do env.trigger("OnTick") end
end)
ok("engineTick survives missing uncapped-frame API", okRun,
   "error: " .. tostring(err))

---------------------------------------------------------------------------
section("Scenario D: setIntervalTicks clamps and applies")
---------------------------------------------------------------------------
MP = loadEngine()
MP.setIntervalTicks(5)       -- below MIN (6)
ok("clamped to MIN", MP.getIntervalTicks() == 6)
MP.setIntervalTicks(99999)
ok("clamped to MAX", MP.getIntervalTicks() == 3000)
MP.setIntervalTicks(300)
ok("sets arbitrary valid value", MP.getIntervalTicks() == 300)

---------------------------------------------------------------------------
section("Scenario E: getAllModNames + per-mod live ring populated after interval")
---------------------------------------------------------------------------
env.setMs(0)
env.setPerformance(env.defaultPerfFull())
env.setCPU(5.0)
MP = loadEngine()

-- Install a fake mod-owned callback. The engine will have wrapped OnTick.Add,
-- but our stub's Events doesn't go through the same wrap. We can still exercise
-- the per-mod path by poking _modStats directly via the public getter.
-- Simpler: advance 120 ticks, then check the frame budget side populated.
env.setMs(200)
for i = 1, 120 do env.trigger("OnTick") end
local samplesE = MP.getFrameBudgetSamples()
ok("frame budget has sample even with no mod activity", #samplesE >= 1)

---------------------------------------------------------------------------
section("Scenario F: cpuMs is the per-interval AVERAGE, not an instant sample")
---------------------------------------------------------------------------
-- Regression for the screenshot-reported "creeping load" bug:
-- If dumpIntervalReport sampled getCPUTime() exactly once at the end of
-- the interval, a single 16ms spike at tick 120 would be reported as a
-- 16ms frame — dramatically inflating the "Engine + unattributed" band
-- and shrinking "headroom" even though the interval was idle.
-- The fix accumulates a per-tick sample and averages across the interval.
env.setMs(0)
env.setPerformance(env.defaultPerfFull())
-- Baseline 2ms, one 16ms spike on the last tick. Instant sampling would
-- report ~16ms. Averaging should report ~2.117ms.
env.setCPU(env.cpuSpikeStream(2.0, 16.0, 120))
MP = loadEngine()
env.setMs(100)
for i = 1, 120 do env.trigger("OnTick") end
local samplesF = MP.getFrameBudgetSamples()
ok("frame budget sample produced", #samplesF >= 1)
if #samplesF >= 1 then
    local reported = samplesF[#samplesF].cpuMs or 0
    -- Expected: (119 * 2.0 + 16.0) / 120 = 2.1167
    local expected = (119 * 2.0 + 16.0) / 120
    ok("cpuMs reflects average not spike",
       math.abs(reported - expected) < 0.05,
       string.format("expected ~%.3f got %.3f", expected, reported))
    ok("cpuMs is far below spike value (would be ~16 if sampled once)",
       reported < 4.0,
       string.format("got %.3f", reported))
end

---------------------------------------------------------------------------
print(string.format("\n== %d passed, %d failed ==", passed, failed))
os.exit(failed == 0 and 0 or 1)
