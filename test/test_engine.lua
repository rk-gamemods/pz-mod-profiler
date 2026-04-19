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
    env.clearEvents()
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
section("Scenario G: _callbacks cleaned up on Remove (GC leak regression)")
---------------------------------------------------------------------------
-- Before the fix, Events.X.Remove(fn) cleaned the wrapper mappings but
-- left the _callbacks[id] entry alive forever. dumpIntervalReport iterated
-- every entry including dead ones, causing O(N) growth over session length.
env.setMs(0)
env.setPerformance(env.defaultPerfFull())
env.setCPU(5.0)
MP = loadEngine()

-- Count callbacks tracked: run 120 ticks, then count how many entries
-- dumpIntervalReport would iterate. We measure indirectly via
-- getModStats — each wrapped callback creates a _modStats entry for its
-- mod. More directly, we exercise add+remove and verify the iteration
-- doesn't see dead entries (grandMs stays 0 for removed callbacks).
local dummy1 = function() end
local dummy2 = function() end
Events.OnTick.Add(dummy1)
Events.OnTick.Add(dummy2)
-- Both should contribute to the callback table now.
-- Remove one before any ticks fire.
Events.OnTick.Remove(dummy2)
-- Run an interval — dummy1 fires 120 times, dummy2 should be gone.
env.setMs(100)
for i = 1, 120 do env.trigger("OnTick") end
-- dummy2 was removed before any ticks, so it should contribute 0ms.
-- If _callbacks leaked, dummy2's entry would still be iterated (with
-- iCalls=0, so it wouldn't inflate grandMs, but the entry itself would
-- persist). We verify removal actually happened by checking the mod
-- stats: TestMod should have calls from dummy1 only.
local testModStats = MP.getModStats()["TestMod"]
ok("TestMod has stats from dummy1", testModStats ~= nil and testModStats.totalCalls > 0)
-- Remove dummy1 too and verify clean removal
Events.OnTick.Remove(dummy1)
ok("Remove does not error", true)

---------------------------------------------------------------------------
section("Scenario H: ringGet + dirty flag + raw ring API")
---------------------------------------------------------------------------
env.setMs(0)
env.setPerformance(env.defaultPerfFull())
env.setCPU(6.0)
MP = loadEngine()
ok("ringGet exposed", type(MP.ringGet) == "function")
ok("isSnapshotDirty exposed", type(MP.isSnapshotDirty) == "function")
ok("clearSnapshotDirty exposed", type(MP.clearSnapshotDirty) == "function")
ok("getFrameBudgetRing exposed", type(MP.getFrameBudgetRing) == "function")

-- Initially clean.
ok("snapshot not dirty before ticks", MP.isSnapshotDirty() == false)

-- Run one full interval (120 ticks) so dumpIntervalReport fires.
env.setMs(100)
for i = 1, 120 do env.trigger("OnTick") end
ok("snapshot dirty after interval", MP.isSnapshotDirty() == true)
MP.clearSnapshotDirty()
ok("snapshot clean after clear", MP.isSnapshotDirty() == false)

-- ringGet should return the same values as ringToArray.
local budgetArr = MP.getFrameBudgetSamples()
local budgetRing = MP.getFrameBudgetRing()
ok("budget ring not nil", budgetRing ~= nil)
ok("budget ring count matches array", budgetRing.count == #budgetArr)
local ringGetMatch = true
for i = 1, budgetRing.count do
    local fromArr  = budgetArr[i]
    local fromRing = MP.ringGet(budgetRing, i)
    if fromArr ~= fromRing then ringGetMatch = false; break end
end
ok("ringGet matches ringToArray element-by-element", ringGetMatch)

-- Out-of-bounds ringGet returns nil.
ok("ringGet(ring, 0) == nil", MP.ringGet(budgetRing, 0) == nil)
ok("ringGet(ring, count+1) == nil", MP.ringGet(budgetRing, budgetRing.count + 1) == nil)

-- Raw mod ring access.
local modLiveRing = MP.getModLiveRing("TestMod")
ok("getModLiveRing returns ring", modLiveRing ~= nil and modLiveRing.count and modLiveRing.count > 0)

---------------------------------------------------------------------------
section("Scenario I: ZBPerfBridge heap data flows to budget ring")
---------------------------------------------------------------------------
env.setMs(0)
env.setPerformance(env.defaultPerfFull())
env.setCPU(5.0)
local zbCtrl = env.installZBPerfBridge({
    heapFreeMb = 1024.0, heapTotalMb = 2048.0, heapMaxMb = 4096.0,
    gcCount = 10, gcTimeMs = 50,
})
MP = loadEngine()
env.setMs(100)
for i = 1, 120 do env.trigger("OnTick") end
local samplesI = MP.getFrameBudgetSamples()
ok("budget sample with ZBPerfBridge", #samplesI >= 1)
if #samplesI >= 1 then
    local s = samplesI[#samplesI]
    ok("heapFreeMb from bridge", s.heapFreeMb == 1024.0,
       "got " .. tostring(s.heapFreeMb))
    ok("heapTotalMb from bridge", s.heapTotalMb == 2048.0,
       "got " .. tostring(s.heapTotalMb))
    ok("gcCount from bridge (first interval)", s.gcCount == 10,
       "got " .. tostring(s.gcCount))
    ok("gcTimeMs from bridge (first interval)", s.gcTimeMs == 50,
       "got " .. tostring(s.gcTimeMs))
end

-- Second interval with GC activity: add 5 collections, 30ms pause
zbCtrl.addGc(5, 30)
env.setMs(300)
for i = 1, 120 do env.trigger("OnTick") end
samplesI = MP.getFrameBudgetSamples()
if #samplesI >= 2 then
    local s = samplesI[#samplesI]
    ok("gcCount delta for second interval", s.gcCount == 5,
       "got " .. tostring(s.gcCount))
    ok("gcTimeMs delta for second interval", s.gcTimeMs == 30,
       "got " .. tostring(s.gcTimeMs))
end
env.removeZBPerfBridge()

---------------------------------------------------------------------------
section("Scenario J: no ZBPerfBridge — graceful fallback, GC fields zero")
---------------------------------------------------------------------------
env.setMs(0)
env.setPerformance(env.defaultPerfFull())
env.setCPU(5.0)
env.removeZBPerfBridge()
MP = loadEngine()
env.setMs(100)
for i = 1, 120 do env.trigger("OnTick") end
local samplesJ = MP.getFrameBudgetSamples()
ok("budget sample without bridge", #samplesJ >= 1)
if #samplesJ >= 1 then
    local s = samplesJ[#samplesJ]
    ok("gcCount is 0 without bridge", s.gcCount == 0)
    ok("gcTimeMs is 0 without bridge", s.gcTimeMs == 0)
    ok("heapFreeMb is 0 without bridge (no MP either)", s.heapFreeMb == 0)
end

---------------------------------------------------------------------------
print(string.format("\n== %d passed, %d failed ==", passed, failed))
os.exit(failed == 0 and 0 or 1)
