local Test = dofile("test/support/testlib.lua")
local Env = dofile("test/support/pz_test_env.lua")

local function addTimedCallback(eventName, callbackCostMs, modPath, lineNumber)
    local fn = Env.annotateCallback(function()
        Env.advanceMs(callbackCostMs)
    end, modPath, lineNumber or 10)
    Events[eventName].Add(fn)
    return fn
end

local function runSeededIntervals(intervalCount, options)
    local settings = options or {}
    local eventNames = settings.eventNames or { "OnPlayerUpdate" }
    for _ = 1, intervalCount do
        for frame = 1, 6 do
            for _, eventName in ipairs(eventNames) do
                Env.fire(eventName)
            end
            if settings.frameIdleMs then
                Env.advanceMs(settings.frameIdleMs)
            end
            if settings.intervalIdleMs and frame == 6 then
                Env.advanceMs(settings.intervalIdleMs)
            end
            Env.fire("OnTick")
        end
    end
end

local function seedProfilerData(options)
    local settings = options or {}
    local ModProfiler = Env.loadModProfiler()
    ModProfiler.setIntervalTicks(6)
    Env.setCpuTime(settings.cpuMs or 10)
    Env.setPerformance(settings.targetFps or 60, settings.uncapped == true)

    local callbacks = settings.callbacks or {
        { event = "OnPlayerUpdate", costMs = 5, path = "media/lua/client/HeavyMod/Worker.lua", line = 11 },
        { event = "OnPlayerUpdate", costMs = 2, path = "media/lua/client/LightMod/Worker.lua", line = 22 },
    }
    for _, spec in ipairs(callbacks) do
        addTimedCallback(spec.event, spec.costMs, spec.path, spec.line)
    end

    runSeededIntervals(settings.intervals or 12, settings)
    return ModProfiler
end

local function loadPanel()
    local ModProfilerUI = Env.loadModProfilerUI()
    local panel = ModProfilerPanel:new(40, 40, 820, 560)
    panel:initialise()
    panel:createChildren()
    panel:refreshRows()
    return ModProfilerUI, panel
end

local function findTextCall(panel, needle)
    for _, call in ipairs(panel._drawCalls or {}) do
        if call.kind == "text" and string.find(call.text, needle, 1, true) then
            return call
        end
    end
    return nil
end

Test.case("panel state round-trips through ini persistence on disk", function()
    Env.reset()
    Env.loadModProfiler()
    Env.loadModProfilerUI()

    local panel = ModProfilerPanel:new(50, 60, 700, 500)
    panel:initialise()
    panel:createChildren()
    panel.pinned["HeavyMod"] = true
    panel.sortColumn = "p95"
    panel.sortDescending = false
    panel.intervalTicks = 30
    panel:setX(111)
    panel:setY(222)
    panel:setWidth(777)
    panel:setHeight(444)
    panel:saveState(true)

    local saved = Env.readTempFile("ModProfiler.ini")
    Test.truthy(saved ~= nil and string.find(saved, "intervalTicks=30", 1, true), "interval ticks not persisted to real ini file")
    Test.truthy(string.find(saved, "sortColumn=p95", 1, true), "sort column not written to ini file")
    Test.truthy(string.find(saved, "visible=true", 1, true), "visibility not written to ini file")

    local restored = ModProfilerPanel:new(0, 0, 0, 0)
    Test.eq(restored:getX(), 111)
    Test.eq(restored:getY(), 222)
    Test.eq(restored:getWidth(), 777)
    Test.eq(restored:getHeight(), 444)
    Test.eq(restored.sortColumn, "p95")
    Test.eq(restored.sortDescending, false)
    Test.eq(restored.intervalTicks, 30)
    Test.truthy(restored.pinned["HeavyMod"], "pinned mod did not restore from ini")
end)

Test.case("onGameStart restores visible overlay and saved poll rate", function()
    Env.reset()
    local ModProfiler = Env.loadModProfiler()
    Env.loadModProfilerUI()

    local panel = ModProfilerPanel:new(40, 40, 820, 560)
    panel:initialise()
    panel:createChildren()
    panel.intervalTicks = 30
    panel.sortColumn = "name"
    panel.sortDescending = false
    panel.pinned["SavedMod"] = true
    panel:saveState(true)

    ModProfilerUI.panel = nil
    ModProfilerUI.visible = false
    Env.fire("OnGameStart")

    Test.truthy(ModProfilerUI.visible, "overlay did not auto-show from saved visible state")
    Test.truthy(ModProfilerUI.panel ~= nil, "overlay panel was not created on game start")
    Test.eq(ModProfiler.getIntervalTicks(), 30)
    Test.eq(ModProfilerUI.panel.sortColumn, "name")
    Test.truthy(ModProfilerUI.panel.pinned["SavedMod"], "saved pinned mod did not restore on show")

    ModProfilerUI.hide()
    Test.eq(ModProfilerUI.visible, false)
end)

Test.case("refreshRows computes real row metrics and default ordering from shared profiler data", function()
    Env.reset()
    seedProfilerData()
    local _ui, panel = loadPanel()

    panel:refreshRows()

    Test.eq(panel.totalRowCount, 2)
    Test.eq(panel.rows[1].mod, "HeavyMod")
    Test.eq(panel.rows[2].mod, "LightMod")
    Test.near(panel.rows[1].p50, 5.0, 0.0001)
    Test.near(panel.rows[1].p95, 5.0, 0.0001)
    Test.near(panel.rows[2].p50, 2.0, 0.0001)
    Test.near(panel.rows[2].p95, 2.0, 0.0001)
    Test.near(panel.rows[1].pctTotal + panel.rows[2].pctTotal, 100.0, 0.0001)
    Test.truthy(panel.rows[1].spikesPerMin > panel.rows[2].spikesPerMin, "heavier mod should have more spikes per minute")
    Test.eq(panel.rows[1].shortTrendDir, "flat")
    Test.eq(panel.rows[2].shortTrendDir, "flat")
end)

Test.case("header sorting, row pinning, and clipboard copy work through real panel events", function()
    Env.reset()
    seedProfilerData()
    local _ui, panel = loadPanel()

    panel:prerender()

    local p95HeaderX = panel._cols[4].x + 2
    local headerY = panel._tableHeaderY + 2
    panel:onMouseDown(p95HeaderX, headerY)
    Test.eq(panel.sortColumn, "p95")
    Test.eq(panel.sortDescending, true)
    panel:onMouseDown(p95HeaderX, headerY)
    Test.eq(panel.sortDescending, false)

    panel:prerender()
    local rowY = panel._tableRowsY + 2
    local rowMod = panel.rows[1].mod
    panel:onMouseDown(panel._cols[1].x + 2, rowY)
    Test.truthy(panel.pinned[rowMod], "row click did not pin the selected mod")

    panel:prerender()
    panel:onRightMouseDown(panel._cols[1].x + 2, rowY)
    Test.eq(Env.getClipboard(), panel.rows[1].mod)
end)

Test.case("header falls back to CPUTime before frame-budget samples exist", function()
    Env.reset()
    Env.loadModProfiler()
    Env.setCpuTime(9)
    Env.setPerformance(60, false)
    local _ui, panel = loadPanel()

    panel:prerender()

    local budgetCall = findTextCall(panel, "9.0 / 16.7 ms frame")
    Test.truthy(budgetCall ~= nil, "header did not render CPUTime fallback budget text")
end)

Test.case("budget graph and self-cost row render from real profiler samples", function()
    Env.reset()
    seedProfilerData({
        cpuMs = 20,
        callbacks = {
            { event = "OnPlayerUpdate", costMs = 4, path = "media/lua/client/BudgetMod/Worker.lua", line = 33 },
        },
        intervals = 12,
    })
    Env.setNowMs(100)
    local _ui, panel = loadPanel()

    panel:prerender()

    Test.truthy(findTextCall(panel, "FRAME BUDGET") ~= nil, "frame budget title missing")
    Test.truthy(findTextCall(panel, "OVER BUDGET: +") ~= nil, "over-budget indicator missing")
    Test.truthy(findTextCall(panel, "PROFILER SELF-COST") ~= nil, "self-cost section missing")

    local selfRow = panel:buildSelfCostRow()
    Test.truthy(selfRow ~= nil, "self-cost row was not built from real profiler samples")
    Test.truthy(selfRow.p50 >= 0, "self-cost row has invalid metrics")
end)

Test.case("budget graph switches title when framerate is uncapped", function()
    Env.reset()
    seedProfilerData({
        cpuMs = 12,
        uncapped = true,
        callbacks = {
            { event = "OnPlayerUpdate", costMs = 3, path = "media/lua/client/UncappedMod/Worker.lua", line = 44 },
        },
        intervals = 12,
    })
    local _ui, panel = loadPanel()

    panel:prerender()

    Test.truthy(findTextCall(panel, "FRAME BUDGET (UNCAPPED)") ~= nil, "uncapped budget title missing")
end)

return Test