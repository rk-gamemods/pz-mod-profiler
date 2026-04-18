local Test = dofile("test/support/testlib.lua")
local Env = dofile("test/support/pz_test_env.lua")

local function runInterval(eventName, callbackCostMs, modPath)
    local ModProfiler = Env.loadModProfiler()
    ModProfiler.setIntervalTicks(6)
    Env.setCpuTime(10)
    Env.setAverageFPS(60)

    local fn = Env.annotateCallback(function()
        Env.advanceMs(callbackCostMs)
    end, modPath, 12)

    Events[eventName].Add(fn)

    local intervalHits = 0
    ModProfiler.onIntervalComplete(function()
        intervalHits = intervalHits + 1
    end)

    for _ = 1, 6 do
        Env.fire(eventName)
        Env.fire("OnTick")
    end

    return ModProfiler, intervalHits
end

local function countOutputFragments(fragment)
    local count = 0
    for _, line in ipairs(Env.outputs) do
        if string.find(line, fragment, 1, true) then
            count = count + 1
        end
    end
    return count
end

Test.case("setIntervalTicks clamps supported bounds", function()
    Env.reset()
    local ModProfiler = Env.loadModProfiler()

    ModProfiler.setIntervalTicks(1)
    Test.eq(ModProfiler.getIntervalTicks(), 6)

    ModProfiler.setIntervalTicks(99999)
    Test.eq(ModProfiler.getIntervalTicks(), 3000)

    ModProfiler.setIntervalTicks(120)
    Test.eq(ModProfiler.getIntervalTicks(), 120)
    Test.near(ModProfiler.getIntervalSeconds(), 2.0, 0.0001)
end)

Test.case("display interval records mod live samples and frame budget", function()
    Env.reset()
    local ModProfiler, intervalHits = runInterval("OnPlayerUpdate", 4, "media/lua/client/MyMod/Test.lua")

    local samples = ModProfiler.getModLiveSamples("MyMod")
    Test.eq(#samples, 1)
    Test.near(samples[1].msPerFrame, 4.0, 0.0001)
    Test.eq(samples[1].spikes, 6)

    local budget = ModProfiler.getFrameBudgetSamples()
    Test.eq(#budget, 1)
    Test.near(budget[1].modMs, 4.0, 0.0001)
    Test.near(budget[1].cpuMs, 10.0, 0.0001)
    Test.near(budget[1].frameMs, 10.0, 0.0001)
    Test.near(budget[1].engineMs, 6.0, 0.0001)
    Test.near(budget[1].budgetMs, 16.6666667, 0.01)
    Test.eq(intervalHits, 1)
end)

Test.case("display samples reset each interval instead of accumulating forever", function()
    Env.reset()
    local ModProfiler = Env.loadModProfiler()
    ModProfiler.setIntervalTicks(6)
    Env.setCpuTime(10)

    local fn = Env.annotateCallback(function()
        Env.advanceMs(4)
    end, "media/lua/client/StableMod/Worker.lua", 9)

    Events.OnPlayerUpdate.Add(fn)

    for _ = 1, 3 do
        for _frame = 1, 6 do
            Env.fire("OnPlayerUpdate")
            Env.fire("OnTick")
        end
    end

    local samples = ModProfiler.getModLiveSamples("StableMod")
    Test.eq(#samples, 3)
    Test.near(samples[1].msPerFrame, 4.0, 0.0001)
    Test.near(samples[2].msPerFrame, 4.0, 0.0001)
    Test.near(samples[3].msPerFrame, 4.0, 0.0001)
end)

Test.case("self-cost is recorded as synthetic profiler mod", function()
    Env.reset()
    local ModProfiler = Env.loadModProfiler()
    ModProfiler.setIntervalTicks(6)
    Env.setCpuTime(8)

    local fn = Env.annotateCallback(function()
        Env.advanceMs(2)
    end, "media/lua/shared/AnotherMod/Worker.lua", 20)

    Events.OnTickEvenPaused.Add(fn)
    for _ = 1, 6 do
        Env.fire("OnTickEvenPaused")
        Env.fire("OnTick")
    end

    local selfSamples = ModProfiler.getModLiveSamples("00_ModProfiler")
    Test.eq(#selfSamples, 1)
    Test.truthy(selfSamples[1].msPerFrame >= 0, "self-cost sample missing msPerFrame")
end)

Test.case("resetSession clears derived rings but wrapped callbacks still work", function()
    Env.reset()
    local ModProfiler = Env.loadModProfiler()
    ModProfiler.setIntervalTicks(6)
    Env.setCpuTime(9)

    local fn = Env.annotateCallback(function()
        Env.advanceMs(3)
    end, "media/lua/client/ResetMod/Worker.lua", 5)

    Events.OnPlayerMove.Add(fn)

    for _ = 1, 6 do
        Env.fire("OnPlayerMove")
        Env.fire("OnTick")
    end

    local firstSamples = ModProfiler.getModLiveSamples("ResetMod")
    Test.eq(#firstSamples, 1)
    Test.near(firstSamples[1].msPerFrame, 3.0, 0.0001)

    ModProfiler.resetSession()
    local clearedSamples = ModProfiler.getModLiveSamples("ResetMod")
    Test.eq(#clearedSamples, 0)

    for _ = 1, 6 do
        Env.fire("OnPlayerMove")
        Env.fire("OnTick")
    end

    local secondSamples = ModProfiler.getModLiveSamples("ResetMod")
    Test.eq(#secondSamples, 1)
    Test.near(secondSamples[1].msPerFrame, 3.0, 0.0001)
end)

Test.case("display cadence is decoupled from console print cadence", function()
    Env.reset()
    local ModProfiler = Env.loadModProfiler()
    ModProfiler.setIntervalTicks(6)
    Env.setCpuTime(5)

    local fn = Env.annotateCallback(function()
        Env.advanceMs(1)
    end, "media/lua/client/PrintCadenceMod/Test.lua", 7)

    Events.OnPlayerUpdate.Add(fn)

    for _ = 1, 60 do
        Env.fire("OnPlayerUpdate")
        Env.fire("OnTick")
    end
    Test.eq(countOutputFragments("----- INTERVAL"), 0, "console interval output appeared before fixed print cadence")

    for _ = 1, 240 do
        Env.fire("OnPlayerUpdate")
        Env.fire("OnTick")
    end
    Test.eq(countOutputFragments("----- INTERVAL"), 1, "expected exactly one printed interval block at 300 ticks")
end)

Test.case("minute, period, and session tiers roll from real interval samples", function()
    Env.reset()
    local ModProfiler = Env.loadModProfiler()
    ModProfiler.setIntervalTicks(6)
    Env.setCpuTime(6)

    local fn = Env.annotateCallback(function()
        Env.advanceMs(3)
    end, "media/lua/client/TieredMod/Worker.lua", 18)

    Events.OnPlayerUpdate.Add(fn)

    for _ = 1, 6 do
        for frame = 1, 6 do
            Env.fire("OnPlayerUpdate")
            if frame == 6 then
                Env.advanceMs(60000)
            end
            Env.fire("OnTick")
        end
    end

    local minuteSamples = ModProfiler.getModMinuteSamples("TieredMod")
    local periodSamples = ModProfiler.getModPeriodSamples("TieredMod")
    local sessionTotals = ModProfiler.getModSessionTotals("TieredMod")

    Test.truthy(#minuteSamples >= 6, "expected one warmup minute sample per simulated minute")
    Test.truthy(#periodSamples >= 1, "expected at least one 5-minute period sample")
    Test.eq(sessionTotals.totalIntervals, 6)
    Test.eq(sessionTotals.totalSpikes, 36)
    Test.near(sessionTotals.totalIntervalMs, 108.0, 0.0001)
    Test.truthy(ModProfiler.getSessionElapsedMinutes() >= 6, "session elapsed minutes did not advance with real timestamps")
end)

return Test
