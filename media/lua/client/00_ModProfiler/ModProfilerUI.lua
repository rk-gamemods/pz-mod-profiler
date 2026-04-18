-- ModProfilerUI.lua
-- Live overlay panel for 00_ModProfiler. Reads passively from the shared
-- ModProfiler API; never writes to profiler internals.
--
-- DESIGN:
--   * Percentile-only display (p25/p50/p95/p99/max/count). No bare means.
--   * Color coding by p95, continuous HSL gradient green → red.
--   * Sparkline per row driven by the per-mod ring buffer.
--   * Refresh cadence: session rows every 250ms via OnPostUIDraw,
--     percentile/sparkline columns event-driven on interval boundary.
--   * All handlers register via ModProfiler.registerUnwrapped — the overlay
--     does NOT self-measure into _modStats or _selfStats.
--
-- TEST MODE:
--   Set TEST_MODE = true below to replace the normal overlay with a visual
--   test harness that auto-opens on game load. Uses simulated data for
--   line graphs, stacked area charts, and probes all Java APIs.
--   Set back to false (or delete the test block) when done.

---------------------------------------------------------------------------
-- *** TESTING FLAG — flip to true to enable, false for normal operation ***
---------------------------------------------------------------------------
local TEST_MODE = false

if not ModProfiler then
    print("[MODPROFILER-UI] ModProfiler shared module not loaded; overlay unavailable.")
    return
end

---------------------------------------------------------------------------
-- TEST HARNESS (active only when TEST_MODE = true)
-- Auto-opens a visual test panel with simulated data, API probes,
-- line graphs, stacked area charts, and resize testing.
-- Normal profiler UI is skipped entirely in test mode.
---------------------------------------------------------------------------
if TEST_MODE then

require "ISUI/ISCollapsableWindow"
require "ISUI/ISComboBox"

-- Self-contained ring buffer (no dependency on ModProfiler rings)
local function ringNew(sz)
    return { buf = {}, head = 0, count = 0, size = sz }
end
local function ringPush(ring, val)
    ring.head = (ring.head % ring.size) + 1
    ring.buf[ring.head] = val
    if ring.count < ring.size then ring.count = ring.count + 1 end
end
local function ringToArray(ring)
    local out = {}
    if ring.count == 0 then return out end
    local start = ring.head - ring.count + 1
    if start < 1 then start = start + ring.size end
    for i = 0, ring.count - 1 do
        local idx = ((start - 1 + i) % ring.size) + 1
        out[#out + 1] = ring.buf[idx]
    end
    return out
end

-- Simulated data
local RING_SZ       = 120
local SIM_TICK      = 0
local TARGET_FMS    = 16.667  -- 60fps
local simMods       = {}
local budgetRings   = {}

local function initSimMods()
    simMods = {
        { name = "SineWave",   ring = ringNew(RING_SZ),
          color = {r=0.4, g=0.8, b=1.0},
          gen = function(t) return 2.0 + 1.5 * math.sin(t * 0.1) end },
        { name = "RandomWalk", ring = ringNew(RING_SZ),
          color = {r=1.0, g=0.6, b=0.3}, _walk = 1.5,
          gen = function(t, m)
              m._walk = m._walk + (ZombRandFloat(0.0, 1.0) - 0.48) * 0.3
              if m._walk < 0.2 then m._walk = 0.2 end
              if m._walk > 5.0 then m._walk = 5.0 end
              return m._walk
          end },
        { name = "StepFunc",   ring = ringNew(RING_SZ),
          color = {r=0.3, g=1.0, b=0.5},
          gen = function(t)
              local vals = {1.0, 3.5, 0.5}
              return vals[math.floor(t / 20) % 3 + 1] + (ZombRandFloat(0.0, 1.0) - 0.5) * 0.2
          end },
        { name = "Spiker",     ring = ringNew(RING_SZ),
          color = {r=1.0, g=0.3, b=0.4},
          gen = function(t)
              if ZombRandFloat(0.0, 1.0) < 0.05 then return 8.0 + ZombRandFloat(0.0, 4.0) end
              return 0.8 + ZombRandFloat(0.0, 0.4)
          end },
        { name = "RampUp",     ring = ringNew(RING_SZ),
          color = {r=0.8, g=0.8, b=0.3},
          gen = function(t)
              return 0.5 + (t % 60) * 0.06 + (ZombRandFloat(0.0, 1.0) - 0.5) * 0.3
          end },
    }
end

local function initBudgetRings()
    budgetRings = {
        vanilla  = ringNew(RING_SZ),
        mods     = ringNew(RING_SZ),
        engine   = ringNew(RING_SZ),
        headroom = ringNew(RING_SZ),
    }
end

local function advanceSim()
    SIM_TICK = SIM_TICK + 1
    for _, mod in ipairs(simMods) do
        ringPush(mod.ring, mod.gen(SIM_TICK, mod))
    end
    local vanillaMs = 4.0 + math.sin(SIM_TICK * 0.05) * 1.5
                        + (ZombRandFloat(0.0, 1.0) - 0.5) * 0.5
    local modsMs = 0
    for _, mod in ipairs(simMods) do
        modsMs = modsMs + mod.ring.buf[mod.ring.head]
    end
    local engineMs = 1.2 + (ZombRandFloat(0.0, 1.0) - 0.5) * 0.4
    local headroom = TARGET_FMS - vanillaMs - modsMs - engineMs
    if headroom < 0 then headroom = 0 end
    ringPush(budgetRings.vanilla,  vanillaMs)
    ringPush(budgetRings.mods,     modsMs)
    ringPush(budgetRings.engine,   engineMs)
    ringPush(budgetRings.headroom, headroom)
end

-- API probe
local _probeResults = {}
local function probeAPI(label, fn)
    local ok, val = pcall(fn)
    local r = { label = label, ok = ok }
    if ok then r.value = tostring(val); r.vtype = type(val)
    else       r.error = tostring(val) end
    _probeResults[#_probeResults + 1] = r
    print(string.format("[TEST] %-36s %s  %s", label,
          ok and "OK" or "FAIL",
          ok and (r.vtype .. " = " .. r.value) or r.error))
end
local function runProbes()
    _probeResults = {}
    print("===== ModProfiler Test Harness: API Probes =====")
    probeAPI("getCPUTime()",            function() return getCPUTime() end)
    probeAPI("getGPUTime()",            function() return getGPUTime() end)
    probeAPI("getCPUWait()",            function() return getCPUWait() end)
    probeAPI("getGPUWait()",            function() return getGPUWait() end)
    probeAPI("getAverageFPS()",         function() return getAverageFPS() end)
    probeAPI("getTimestampMs()",        function() return getTimestampMs() end)
    probeAPI("getPerformance()",        function() return getPerformance() end)
    probeAPI("perf:getFramerate()",     function() return getPerformance():getFramerate() end)
    probeAPI("perf:isUncapped()",       function() return getPerformance():isFramerateUncapped() end)
    probeAPI("getGameTime()",           function() return getGameTime() end)
    probeAPI("gt:getRealSecs()",        function() return getGameTime():getRealworldSecondsSinceLastUpdate() end)
    probeAPI("gt.fpsMultiplier",        function() return getGameTime().fpsMultiplier end)
    probeAPI("getCore()",               function() return getCore() end)
    probeAPI("screenWidth",             function() return getCore():getScreenWidth() end)
    probeAPI("screenHeight",            function() return getCore():getScreenHeight() end)
    probeAPI("GameProfiler",            function() return GameProfiler end)
    probeAPI("GameProfiler.getTimeNs",  function()
        if GameProfiler == nil then return "N/A (GameProfiler is nil)" end
        return GameProfiler.getTimeNs()
    end)
    probeAPI("cpu+gpu sum",             function() return getCPUTime() + getGPUTime() end)
    probeAPI("frame budget calc",       function()
        local tgt = 1000.0 / getPerformance():getFramerate()
        local used = getCPUTime() + getGPUTime()
        return string.format("tgt=%.1fms used=%.1fms free=%.1fms", tgt, used, tgt - used)
    end)
    print(string.format("===== Probe Complete: %d tests =====", #_probeResults))
end

-- Drawing primitives
local function drawPixelLine(panel, x1, y1, x2, y2, r, g, b, a)
    local dx = math.abs(x2 - x1)
    local dy = math.abs(y2 - y1)
    local sx = x1 < x2 and 1 or -1
    local sy = y1 < y2 and 1 or -1
    local err = dx - dy
    local cx, cy = x1, y1
    for _ = 0, dx + dy + 1 do
        panel:drawRect(cx, cy, 1, 1, a, r, g, b)
        if cx == x2 and cy == y2 then break end
        local e2 = 2 * err
        if e2 > -dy then err = err - dy; cx = cx + sx end
        if e2 <  dx then err = err + dx; cy = cy + sy end
    end
end

local function fmtMs(ms)
    if ms >= 1000 then return string.format("%.1fs", ms / 1000) end
    if ms >= 10   then return string.format("%dms", math.floor(ms + 0.5)) end
    if ms >= 1    then return string.format("%.1fms", ms) end
    if ms > 0     then return string.format("%.2fms", ms) end
    return "0ms"
end

local function drawLineGraph(panel, gx, gy, gw, gh, series, title, font)
    font = font or UIFont.Small
    panel:drawRect(gx, gy, gw, gh, 0.6, 0.08, 0.09, 0.12)
    local yAxisW  = math.max(30, math.floor(gw * 0.06))
    local legendW = math.max(50, math.floor(gw * 0.13))
    local plotX   = gx + yAxisW
    local plotW   = gw - yAxisW - legendW
    local fH = getTextManager():MeasureStringY(font, "Aj")

    local yMin, yMax = 1e9, -1e9
    for _, s in ipairs(series) do
        for _, v in ipairs(s.data) do
            if v < yMin then yMin = v end
            if v > yMax then yMax = v end
        end
    end
    if yMin >= yMax then yMax = yMin + 1 end
    local pad = (yMax - yMin) * 0.1
    yMin = yMin - pad; yMax = yMax + pad
    local yRange = yMax - yMin
    for i = 0, 3 do
        local fy = gy + gh - (i / 3) * gh
        panel:drawRect(plotX, math.floor(fy), plotW, 1, 0.2, 0.3, 0.3, 0.4)
        panel:drawText(fmtMs(yMin + (i / 3) * yRange),
                       gx + 2, math.floor(fy) - fH,
                       0.5, 0.5, 0.6, 0.8, font)
    end
    for _, s in ipairs(series) do
        local n = #s.data
        if n >= 2 then
            for i = 2, n do
                drawPixelLine(panel,
                    math.floor(plotX + ((i - 2) / (n - 1)) * plotW),
                    math.floor(gy + gh - ((s.data[i - 1] - yMin) / yRange) * gh),
                    math.floor(plotX + ((i - 1) / (n - 1)) * plotW),
                    math.floor(gy + gh - ((s.data[i] - yMin) / yRange) * gh),
                    s.color.r, s.color.g, s.color.b, 0.9)
            end
        end
    end
    if title then
        panel:drawText(title, plotX + 4, gy + 2, 0.9, 0.9, 1.0, 1.0, font)
    end
    local legendX = plotX + plotW + 4
    local maxLblW = legendW - 16
    local legendRH = fH + 1
    for idx, s in ipairs(series) do
        local row = gy + fH + (idx - 1) * legendRH
        panel:drawRect(legendX, row + 3, 6, 5, 0.9, s.color.r, s.color.g, s.color.b)
        local lbl = s.label
        if getTextManager():MeasureStringX(font, lbl) > maxLblW then
            while #lbl > 2 and getTextManager():MeasureStringX(font, lbl .. "..") > maxLblW do
                lbl = lbl:sub(1, #lbl - 1)
            end
            lbl = lbl .. ".."
        end
        panel:drawText(lbl, legendX + 10, row, 0.7, 0.7, 0.8, 0.9, font)
    end
end

local function drawStackedArea(panel, gx, gy, gw, gh, layers, budgetMs, title, font)
    font = font or UIFont.Small
    panel:drawRect(gx, gy, gw, gh, 0.6, 0.08, 0.09, 0.12)
    local yAxisW  = math.max(30, math.floor(gw * 0.06))
    local legendW = math.max(50, math.floor(gw * 0.13))
    local plotX   = gx + yAxisW
    local plotW   = gw - yAxisW - legendW
    local fH = getTextManager():MeasureStringY(font, "Aj")

    local nPts = 0
    if #layers > 0 then nPts = #layers[1].data end
    if nPts == 0 then return end
    local maxSum = 0
    for i = 1, nPts do
        local sum = 0
        for _, layer in ipairs(layers) do sum = sum + (layer.data[i] or 0) end
        if sum > maxSum then maxSum = sum end
    end
    if budgetMs and budgetMs > maxSum then maxSum = budgetMs end
    maxSum = maxSum * 1.1
    if maxSum <= 0 then maxSum = 20 end
    local colW = math.max(1, math.floor(plotW / nPts))
    for i = 1, nPts do
        local cx = plotX + (i - 1) * colW
        local yOff = 0
        for _, layer in ipairs(layers) do
            local val  = layer.data[i] or 0
            local barH = math.max(0, math.floor((val / maxSum) * gh))
            if barH > 0 then
                panel:drawRect(cx, gy + gh - yOff - barH, colW, barH,
                               layer.color.a or 0.7,
                               layer.color.r, layer.color.g, layer.color.b)
            end
            yOff = yOff + barH
        end
    end
    if budgetMs then
        local by = math.floor(gy + gh - (budgetMs / maxSum) * gh)
        for bx = plotX, plotX + plotW - 1, 4 do
            panel:drawRect(bx, by, 2, 1, 1.0, 1.0, 1.0, 0.3)
        end
        local budgetTxt = string.format("%.1fms", budgetMs)
        panel:drawText(budgetTxt,
                       plotX + plotW - getTextManager():MeasureStringX(font, budgetTxt) - 4,
                       by + 2, 1.0, 1.0, 0.3, 0.9, font)
    end
    for i = 1, 3 do
        local fy = gy + gh - (i / 4) * gh
        panel:drawRect(plotX, math.floor(fy), plotW, 1, 0.15, 0.3, 0.3, 0.4)
        panel:drawText(fmtMs((i / 4) * maxSum),
                       gx + 2, math.floor(fy) - fH,
                       0.5, 0.5, 0.6, 0.8, font)
    end
    if title then
        panel:drawText(title, plotX + 4, gy + 2, 0.9, 0.9, 1.0, 1.0, font)
    end
    local legendX = plotX + plotW + 4
    local maxLblW = legendW - 16
    local legendRH = fH + 1
    for idx, layer in ipairs(layers) do
        local row = gy + fH + (idx - 1) * legendRH
        panel:drawRect(legendX, row + 3, 6, 5, layer.color.a or 0.7,
                       layer.color.r, layer.color.g, layer.color.b)
        local lbl = layer.label
        if getTextManager():MeasureStringX(font, lbl) > maxLblW then
            while #lbl > 2 and getTextManager():MeasureStringX(font, lbl .. "..") > maxLblW do
                lbl = lbl:sub(1, #lbl - 1)
            end
            lbl = lbl .. ".."
        end
        panel:drawText(lbl, legendX + 10, row, 0.7, 0.7, 0.8, 0.9, font)
    end
end

-- Test harness panel (ISCollapsableWindow for resize testing)
TestHarnessPanel = ISCollapsableWindow:derive("TestHarnessPanel")

function TestHarnessPanel:new(x, y, w, h)
    local o = ISCollapsableWindow:new(x, y, w, h)
    setmetatable(o, self)
    self.__index     = self
    o.title          = "ModProfiler Test Harness"
    o.resizable      = true
    o.minimumWidth   = 420
    o.minimumHeight  = 340
    o.backgroundColor = { r = 0.05, g = 0.06, b = 0.08, a = 0.92 }
    o.borderColor     = { r = 0.25, g = 0.28, b = 0.32, a = 1.0 }
    o.simRate  = 0.2
    o.lastSimMs = 0
    o.probesRan = false
    return o
end

function TestHarnessPanel:createChildren()
    ISCollapsableWindow.createChildren(self)
    local cW = 80
    self.rateCombo = ISComboBox:new(self:getWidth() - cW - 12, 28, cW, 20,
                                    self, self.onRateChanged)
    self.rateCombo:initialise()
    self.rateCombo:addOption("0.1s")
    self.rateCombo:addOption("0.2s")
    self.rateCombo:addOption("0.5s")
    self.rateCombo:addOption("1.0s")
    self.rateCombo:addOption("2.0s")
    self.rateCombo.selected = 2
    self:addChild(self.rateCombo)
end

function TestHarnessPanel:onRateChanged(combo)
    local rates = { 0.1, 0.2, 0.5, 1.0, 2.0 }
    self.simRate = rates[combo.selected] or 0.2
end

function TestHarnessPanel:prerender()
    ISCollapsableWindow.prerender(self)
    if self.rateCombo then
        self.rateCombo:setX(self:getWidth() - 80 - 12)
    end
    if not self.probesRan then runProbes(); self.probesRan = true end

    local nowMs = getTimestampMs()
    if nowMs - self.lastSimMs >= self.simRate * 1000 then
        advanceSim()
        self.lastSimMs = nowMs
    end

    local pw = self:getWidth()
    local M  = 8
    local cy = 26
    local cw = pw - M * 2
    local half = math.floor(cw / 2)

    -- Dynamic font selection based on window width
    local fBody, fHead
    if pw < 600 then
        fBody = UIFont.DebugConsole
        fHead = UIFont.Small
    elseif pw < 800 then
        fBody = UIFont.Small
        fHead = UIFont.Small
    else
        fBody = UIFont.Small
        fHead = UIFont.Medium
    end
    local RH = getTextManager():MeasureStringY(fBody, "Aj") + 2
    local headH = getTextManager():MeasureStringY(fHead, "Aj") + 2

    -- rate label
    self:drawText("Sim rate:", M, cy + 2, 0.7, 0.7, 0.8, 0.9, fBody)
    cy = cy + RH + 6

    -- Section A: Live API values
    self:drawText("LIVE API VALUES", M, cy, 0.95, 0.95, 1.0, 1.0, fHead)
    cy = cy + headH + 2
    self:drawRect(M, cy, cw, 1, 0.6, 0.3, 0.32, 0.36); cy = cy + 3

    local VAL_OFF = math.floor(half * 0.38)
    local function lv(label, fn, col)
        local ok, val = pcall(fn)
        self:drawText(label .. ":", M + col, cy, 0.6, 0.65, 0.7, 0.9, fBody)
        if ok then
            local txt
            if type(val) == "number" then
                if val > 1e10 then txt = string.format("%.0f", val)
                else               txt = string.format("%.3f", val) end
            else txt = tostring(val) end
            local maxValW = half - VAL_OFF - 4
            if getTextManager():MeasureStringX(fBody, txt) > maxValW then
                while #txt > 2 and getTextManager():MeasureStringX(fBody, txt .. "..") > maxValW do
                    txt = txt:sub(1, #txt - 1)
                end
                txt = txt .. ".."
            end
            self:drawText(txt, M + col + VAL_OFF, cy, 0.4, 0.9, 0.5, 0.9, fBody)
        else
            self:drawText("ERROR", M + col + VAL_OFF, cy, 1.0, 0.3, 0.3, 0.9, fBody)
        end
    end
    lv("getCPUTime()",     function() return getCPUTime() end,              0)
    lv("getGPUTime()",     function() return getGPUTime() end,              half)
    cy = cy + RH
    lv("getCPUWait()",     function() return getCPUWait() end,              0)
    lv("getGPUWait()",     function() return getGPUWait() end,              half)
    cy = cy + RH
    lv("getAverageFPS()",  function() return getAverageFPS() end,           0)
    lv("getTimestampMs()", function() return getTimestampMs() end,          half)
    cy = cy + RH
    lv("targetFPS",        function() return getPerformance():getFramerate() end, 0)
    lv("fpsMultiplier",    function() return getGameTime().fpsMultiplier end,     half)
    cy = cy + RH + 8

    -- Section B: Probe results (2-column)
    self:drawText("API PROBE RESULTS (one-shot on open)", M, cy,
                  0.95, 0.95, 1.0, 1.0, fHead)
    cy = cy + headH + 2
    self:drawRect(M, cy, cw, 1, 0.6, 0.3, 0.32, 0.36); cy = cy + 3
    for i, pr in ipairs(_probeResults) do
        local col = ((i - 1) % 2) * half
        if pr.ok then
            self:drawText("OK",   M + col, cy, 0.4, 0.9, 0.5, 0.9, fBody)
        else
            self:drawText("FAIL", M + col, cy, 1.0, 0.3, 0.3, 0.9, fBody)
        end
        self:drawText(pr.label, M + col + 32, cy, 0.6, 0.65, 0.7, 0.9, fBody)
        if pr.ok then
            local d = pr.value
            local probeValOff = math.floor(half * 0.50)
            local maxProbeW = half - probeValOff - 4
            if getTextManager():MeasureStringX(fBody, d) > maxProbeW then
                while #d > 2 and getTextManager():MeasureStringX(fBody, d .. "..") > maxProbeW do
                    d = d:sub(1, #d - 1)
                end
                d = d .. ".."
            end
            self:drawText(d, M + col + probeValOff, cy, 0.5, 0.6, 0.5, 0.8, fBody)
        end
        if i % 2 == 0 then cy = cy + RH end
    end
    if #_probeResults % 2 ~= 0 then cy = cy + RH end
    cy = cy + 8

    -- Section C: Multi-mod line graph
    local availH = self:getHeight() - cy - 50
    local graphH = math.floor(math.max(60, math.min(160, availH / 2)))
    local lineSeries = {}
    for _, mod in ipairs(simMods) do
        lineSeries[#lineSeries + 1] = {
            data = ringToArray(mod.ring), color = mod.color, label = mod.name }
    end
    drawLineGraph(self, M, cy, cw, graphH, lineSeries, "Multi-Mod Overlay (simulated)", fBody)
    cy = cy + graphH + 8

    -- Section D: Frame budget stacked area
    local stackH = graphH
    local budgetLayers = {
        { data = ringToArray(budgetRings.engine),
          color = {r=0.6, g=0.6, b=0.6, a=0.7}, label = "Engine" },
        { data = ringToArray(budgetRings.vanilla),
          color = {r=0.3, g=0.5, b=0.9, a=0.7}, label = "Vanilla" },
        { data = ringToArray(budgetRings.mods),
          color = {r=1.0, g=0.5, b=0.2, a=0.7}, label = "Mods" },
        { data = ringToArray(budgetRings.headroom),
          color = {r=0.2, g=0.8, b=0.3, a=0.4}, label = "Headroom" },
    }
    drawStackedArea(self, M, cy, cw, stackH, budgetLayers, TARGET_FMS,
                    "Frame Budget (simulated, 60fps)", fBody)
    cy = cy + stackH + 4

    -- headroom summary
    local hrData = ringToArray(budgetRings.headroom)
    if #hrData > 0 then
        local sum, mn, mx = 0, 1e9, -1e9
        for _, v in ipairs(hrData) do
            sum = sum + v
            if v < mn then mn = v end
            if v > mx then mx = v end
        end
        local avg = sum / #hrData
        self:drawText(
            string.format("Headroom: avg %.1fms (%.0f%% free)  min %.1fms  max %.1fms",
                          avg, (avg / TARGET_FMS) * 100, mn, mx),
            M, cy, 0.6, 0.75, 0.6, 0.9, fBody)
        cy = cy + RH
    end
    cy = cy + 6

    -- footer
    self:drawRect(M, cy, cw, 1, 0.6, 0.3, 0.32, 0.36); cy = cy + 3
    self:drawText(">> Set TEST_MODE = false in ModProfilerUI.lua when done <<",
                  M, cy, 1.0, 0.6, 0.2, 0.9, fBody)
    cy = cy + RH
    self:drawText(
        string.format("tick: %d | ring: %d | rate: %.1fs | window: %dx%d",
                      SIM_TICK, RING_SZ, self.simRate,
                      math.floor(pw), math.floor(self:getHeight())),
        M, cy, 0.5, 0.5, 0.55, 0.8, fBody)
end

-- Auto-open on game load
local _testPanel = nil
local function openTestHarness()
    if _testPanel then return end
    initSimMods()
    initBudgetRings()
    for _ = 1, RING_SZ do advanceSim() end  -- pre-fill
    local sw = getCore():getScreenWidth()
    local sh = getCore():getScreenHeight()
    local w  = math.min(800, math.floor(sw * 0.55))
    local h  = math.min(580, math.floor(sh * 0.65))
    _testPanel = TestHarnessPanel:new(
        math.floor((sw - w) / 2), math.floor((sh - h) / 2), w, h)
    _testPanel:initialise()
    _testPanel:addToUIManager()
end
Events.OnGameStart.Add(openTestHarness)

print("[MODPROFILER-UI] *** TEST MODE ACTIVE *** Normal overlay disabled.")
return  -- skip all normal UI code below
end -- if TEST_MODE

require "ISUI/ISCollapsableWindow"
require "ISUI/ISComboBox"

local DEFAULT_W     = 820
local DEFAULT_H     = 560
local MIN_W         = 560
local MIN_H         = 420
local TOP_N_DEFAULT = 20
local REFRESH_MS    = 250
local SELF_MOD_NAME = "00_ModProfiler"

local RATE_OPTIONS = {
    { label = "10s", ticks = 600 },
    { label = "5s", ticks = 300 },
    { label = "2s", ticks = 120 },
    { label = "1s", ticks = 60 },
    { label = "0.5s", ticks = 30 },
    { label = "0.1s", ticks = 6 },
}

local COL_BG         = { a = 0.92, r = 0.05, g = 0.06, b = 0.08 }
local COL_BORDER     = { a = 1.00, r = 0.40, g = 0.45, b = 0.55 }
local COL_HEADER     = { a = 1.00, r = 0.95, g = 0.95, b = 1.00 }
local COL_SUBHEADER  = { a = 1.00, r = 0.70, g = 0.75, b = 0.85 }
local COL_MUTED      = { a = 1.00, r = 0.55, g = 0.55, b = 0.60 }
local COL_STEADY     = { a = 1.00, r = 0.75, g = 0.75, b = 0.80 }
local COL_RISING     = { a = 1.00, r = 0.95, g = 0.65, b = 0.35 }
local COL_FALLING    = { a = 1.00, r = 0.45, g = 0.70, b = 0.95 }
local COL_DIVIDER    = { a = 0.40, r = 0.40, g = 0.45, b = 0.55 }
local COL_PINNED_BG  = { a = 0.15, r = 0.40, g = 0.20, b = 0.10 }
local COL_BAR_TRACK  = { a = 0.35, r = 0.10, g = 0.12, b = 0.14 }
local COL_BAR_FILL   = { a = 0.80, r = 0.40, g = 0.50, b = 0.70 }

local GREEN_MS       = 0.0
local RED_MS         = 1.0
local INI_FILENAME   = "ModProfiler.ini"

---------------------------------------------------------------------------
-- ModProfilerINI — key=value persistence in Zomboid Lua dir
---------------------------------------------------------------------------
local function iniParse(lines)
    local out = {}
    for _, line in ipairs(lines) do
        local key, value = line:match("^%s*([%w_%.]+)%s*=%s*(.-)%s*$")
        if key then out[key] = value end
    end
    return out
end

local function iniSerialize(tbl)
    local keys = {}
    for key in pairs(tbl) do keys[#keys + 1] = key end
    table.sort(keys)
    local out = {}
    for _, key in ipairs(keys) do
        out[#out + 1] = key .. "=" .. tostring(tbl[key])
    end
    return out
end

local ModProfilerINI = {}

function ModProfilerINI.load()
    local reader = getFileReader(INI_FILENAME, false)
    if not reader then return {} end
    local lines = {}
    while true do
        local line = reader:readLine()
        if not line then break end
        lines[#lines + 1] = line
    end
    reader:close()
    return iniParse(lines)
end

function ModProfilerINI.save(tbl)
    local writer = getFileWriter(INI_FILENAME, true, false)
    if not writer then return end
    local lines = iniSerialize(tbl)
    for _, line in ipairs(lines) do
        writer:write(line .. "\n")
    end
    writer:close()
end

function ModProfilerINI.num(tbl, key, default)
    local value = tonumber(tbl[key])
    if value == nil then return default end
    return value
end

function ModProfilerINI.bool(tbl, key, default)
    local value = tbl[key]
    if value == "true" then return true end
    if value == "false" then return false end
    return default
end

function ModProfilerINI.str(tbl, key, default)
    return tbl[key] or default
end

function ModProfilerINI.list(tbl, key)
    local value = tbl[key]
    if not value or value == "" then return {} end
    local out = {}
    for item in value:gmatch("([^,]+)") do
        out[#out + 1] = item
    end
    return out
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function percentile(sortedArr, pct)
    local n = #sortedArr
    if n == 0 then return 0 end
    if n == 1 then return sortedArr[1] end
    local idx = math.floor(n * pct / 100)
    if idx < 1 then idx = 1 end
    if idx > n then idx = n end
    return sortedArr[idx]
end

local function computeStats(samples)
    local n = #samples
    if n == 0 then return { p50 = 0, p95 = 0, mean = 0, n = 0 } end
    local sorted = {}
    local sum = 0
    for i = 1, n do
        sorted[i] = samples[i]
        sum = sum + samples[i]
    end
    table.sort(sorted)
    return {
        p50 = percentile(sorted, 50),
        p95 = percentile(sorted, 95),
        mean = sum / n,
        n = n,
    }
end

local function tailArray(arr, count)
    local n = #arr
    if n <= count then return arr end
    local out = {}
    local start = n - count + 1
    for i = start, n do out[#out + 1] = arr[i] end
    return out
end

local function displayWindowCount(intervalSec)
    local count = math.floor(40 / intervalSec)
    if count < 5 then count = 5 end
    if count > 60 then count = 60 end
    return count
end

local function p95Color(p95ms)
    local t
    if p95ms <= GREEN_MS then t = 0
    elseif p95ms >= RED_MS then t = 1
    else t = (p95ms - GREEN_MS) / (RED_MS - GREEN_MS) end

    local r, g, b
    if t < 0.5 then
        local u = t * 2
        r = 0.35 + (0.95 - 0.35) * u
        g = 0.90 + (0.85 - 0.90) * u
        b = 0.40 + (0.35 - 0.40) * u
    else
        local u = (t - 0.5) * 2
        r = 0.95
        g = 0.85 + (0.35 - 0.85) * u
        b = 0.35 + (0.30 - 0.35) * u
    end
    return { a = 1.0, r = r, g = g, b = b }
end

local function olsSlope(ys)
    local n = #ys
    if n < 2 then return nil, 0 end
    local sumX, sumY = 0, 0
    for i = 1, n do
        sumX = sumX + i
        sumY = sumY + ys[i]
    end
    local meanX = sumX / n
    local meanY = sumY / n
    local num, den = 0, 0
    for i = 1, n do
        local dx = i - meanX
        local dy = ys[i] - meanY
        num = num + dx * dy
        den = den + dx * dx
    end
    if den == 0 then return 0, meanY end
    return num / den, meanY
end

local function trendGlyph(value, risingThreshold, fallingThreshold, minSamples, sampleCount)
    if sampleCount < minSamples or value == nil then return "na", COL_MUTED end
    if value > risingThreshold then return "up", COL_RISING end
    if value < fallingThreshold then return "down", COL_FALLING end
    return "flat", COL_STEADY
end

local function shortTrend(samples, intervalSec)
    local n = #samples
    if n < 10 then return "na", COL_MUTED, nil end
    local ys = {}
    for i = 1, n do ys[i] = samples[i].msPerFrame or 0 end
    local slopePerSample, mean = olsSlope(ys)
    if not slopePerSample or mean <= 0 then return "flat", COL_STEADY, 0 end
    local slopePerMin = slopePerSample * (60 / intervalSec)
    local pctPerMin = slopePerMin / mean * 100
    local glyph, color = trendGlyph(pctPerMin, 2, -2, 10, n)
    return glyph, color, pctPerMin
end

local function longTrend(minuteSamples, periodSamples, sessionMinutes)
    local source, sampleMinutes
    if sessionMinutes < 30 then
        source = minuteSamples
        sampleMinutes = 1
    else
        source = periodSamples
        sampleMinutes = 5
    end
    local n = #source
    if n < 3 then return "na", COL_MUTED, nil end
    local ys = {}
    for i = 1, n do ys[i] = source[i].msPerFrame or 0 end
    local slopePerSample, mean = olsSlope(ys)
    if not slopePerSample or mean <= 0 then return "flat", COL_STEADY, 0 end
    local slopePerHour = slopePerSample * (60 / sampleMinutes)
    local pctPerHour = slopePerHour / mean * 100
    local glyph, color = trendGlyph(pctPerHour, 2, -2, 3, n)
    return glyph, color, pctPerHour
end

local function spikesPerMin(samples, intervalSec)
    local n = #samples
    if n < 10 then return nil end
    local sum = 0
    for i = 1, n do sum = sum + (samples[i].spikes or 0) end
    local windowMinutes = (n * intervalSec) / 60
    if windowMinutes <= 0 then return 0 end
    return sum / windowMinutes
end

local function drawTextCol(panel, text, x, y, color, font)
    panel:drawText(text, x, y, color.r, color.g, color.b, color.a, font)
end

local function drawRectCol(panel, x, y, w, h, color)
    panel:drawRect(x, y, w, h, color.a, color.r, color.g, color.b)
end

local function drawPixelLine(panel, x1, y1, x2, y2, color)
    local dx = math.abs(x2 - x1)
    local dy = math.abs(y2 - y1)
    local sx = x1 < x2 and 1 or -1
    local sy = y1 < y2 and 1 or -1
    local err = dx - dy
    local cx = x1
    local cy = y1

    for _ = 0, dx + dy + 1 do
        panel:drawRect(cx, cy, 1, 1, color.a, color.r, color.g, color.b)
        if cx == x2 and cy == y2 then break end
        local e2 = err * 2
        if e2 > -dy then err = err - dy; cx = cx + sx end
        if e2 < dx then err = err + dx; cy = cy + sy end
    end
end

local function ellipsize(font, text, maxWidth)
    if getTextManager():MeasureStringX(font, text) <= maxWidth then return text end
    local out = text
    while #out > 2 and getTextManager():MeasureStringX(font, out .. "..") > maxWidth do
        out = out:sub(1, #out - 1)
    end
    return out .. ".."
end

local function formatMsValue(ms)
    return string.format("%.2f ms", ms or 0)
end

local function formatPctValue(value)
    return string.format("%.1f%%", value or 0)
end

local function formatSpikeValue(value)
    if value == nil then return "" end
    return string.format("%.1f", value)
end

local function pickFonts(width)
    if width < 620 then
        return UIFont.Small, UIFont.DebugConsole
    elseif width < 900 then
        return UIFont.Small, UIFont.Small
    end
    return UIFont.Medium, UIFont.Small
end

local function getHeaderSnapshot()
    local samples = ModProfiler.getFrameBudgetSamples and ModProfiler.getFrameBudgetSamples() or {}
    if #samples > 0 then
        local sample = samples[#samples]
        local usedMs = sample.cpuMs or 0
        local modMs = sample.modMs or 0
        if modMs > usedMs then usedMs = modMs end
        return {
            usedMs = usedMs,
            budgetMs = sample.budgetMs or (1000 / 60),
            uncapped = sample.uncapped == true,
        }
    end

    local perf = nil
    pcall(function() perf = getPerformance and getPerformance() or nil end)
    local budgetMs = 1000 / 60
    local uncapped = false
    if perf then
        local okFps, fps = pcall(function() return perf:getFramerate() end)
        if okFps and fps and fps > 0 then budgetMs = 1000 / fps end
        local okUncapped, uncappedValue = pcall(function() return perf:isFramerateUncapped() end)
        if okUncapped then uncapped = uncappedValue == true end
    end

    local usedMs = 0
    local okCpu, cpuValue = pcall(function() return getCPUTime and getCPUTime() or 0 end)
    if okCpu and cpuValue then usedMs = cpuValue end
    return {
        usedMs = usedMs,
        budgetMs = budgetMs,
        uncapped = uncapped,
    }
end

local function drawTrendIndicator(panel, x, y, direction, color, size)
    local midY = y + math.floor(size / 2)
    local rightX = x + size
    if direction == "up" then
        drawPixelLine(panel, x, y + size - 1, rightX - 2, y + 1, color)
        drawPixelLine(panel, rightX - 2, y + 1, rightX - 2, y + 4, color)
        drawPixelLine(panel, rightX - 2, y + 1, rightX - 5, y + 1, color)
    elseif direction == "down" then
        drawPixelLine(panel, x, y + 1, rightX - 2, y + size - 1, color)
        drawPixelLine(panel, rightX - 2, y + size - 1, rightX - 2, y + size - 4, color)
        drawPixelLine(panel, rightX - 2, y + size - 1, rightX - 5, y + size - 1, color)
    elseif direction == "flat" then
        drawPixelLine(panel, x, midY, rightX - 2, midY, color)
        drawPixelLine(panel, rightX - 2, midY, rightX - 5, midY - 2, color)
        drawPixelLine(panel, rightX - 2, midY, rightX - 5, midY + 2, color)
    else
        drawPixelLine(panel, x + 1, midY, rightX - 3, midY, color)
    end
end

local function drawSortIndicator(panel, x, y, descending, color, size)
    local half = math.floor(size / 2)
    if descending then
        drawPixelLine(panel, x, y, x + half, y + size, color)
        drawPixelLine(panel, x + size, y, x + half, y + size, color)
    else
        drawPixelLine(panel, x, y + size, x + half, y, color)
        drawPixelLine(panel, x + size, y + size, x + half, y, color)
    end
end

local function drawPinMarker(panel, x, y, color)
    panel:drawRect(x + 1, y + 1, 5, 2, color.a, color.r, color.g, color.b)
    panel:drawRect(x + 2, y + 3, 3, 4, color.a, color.r, color.g, color.b)
end

local function buildColumns(panel, pad)
    local contentW = panel:getWidth() - (pad * 2)
    local cols = {}
    local nameW  = math.floor(contentW * 0.37)
    local pctW   = math.floor(contentW * 0.10)
    local p50W   = math.floor(contentW * 0.14)
    local p95W   = math.floor(contentW * 0.14)
    local spikeW = math.floor(contentW * 0.11)
    local trendW = contentW - nameW - pctW - p50W - p95W - spikeW
    local x = pad
    cols[1] = { key = "name", label = "Mod", x = x, w = nameW, align = "left" }
    x = x + nameW
    cols[2] = { key = "pctTotal", label = "%Total", x = x, w = pctW, align = "right" }
    x = x + pctW
    cols[3] = { key = "p50", label = "ms/f p50", x = x, w = p50W, align = "right" }
    x = x + p50W
    cols[4] = { key = "p95", label = "ms/f p95", x = x, w = p95W, align = "right" }
    x = x + p95W
    cols[5] = { key = "spikesPerMin", label = "spk/min", x = x, w = spikeW, align = "right" }
    x = x + spikeW
    local trendLabel = panel:getWidth() < 760 and "trend" or "trend 5m/sess"
    cols[6] = { key = "trend", label = trendLabel, x = x, w = trendW, align = "center" }
    return cols
end

local function drawRight(panel, font, text, col, y, color)
    local tw = getTextManager():MeasureStringX(font, text)
    drawTextCol(panel, text, col.x + col.w - tw - 2, y, color, font)
end

local function drawCentered(panel, font, text, col, y, color)
    local tw = getTextManager():MeasureStringX(font, text)
    drawTextCol(panel, text, col.x + math.floor((col.w - tw) / 2), y, color, font)
end

local function drawStackedArea(panel, x, y, w, h, layers, budgetMs)
    local samples = 0
    if #layers > 0 then samples = #layers[1].values end
    drawRectCol(panel, x, y, w, h, COL_BAR_TRACK)
    if samples <= 0 then return end
    local maxSum = budgetMs or 0
    for i = 1, samples do
        local sum = 0
        for _, layer in ipairs(layers) do sum = sum + (layer.values[i] or 0) end
        if sum > maxSum then maxSum = sum end
    end
    if maxSum <= 0 then maxSum = 1 end
    local colW = w / samples
    for i = 1, samples do
        local cx = x + math.floor((i - 1) * colW)
        local nx = x + math.floor(i * colW)
        local bw = math.max(1, nx - cx)
        local offset = 0
        for _, layer in ipairs(layers) do
            local value = layer.values[i] or 0
            local barH = math.max(0, math.floor((value / maxSum) * h))
            if barH > 0 then
                panel:drawRect(cx, y + h - offset - barH, bw, barH, layer.a, layer.r, layer.g, layer.b)
            end
            offset = offset + barH
        end
    end
    if budgetMs then
        local budgetY = math.floor(y + h - (budgetMs / maxSum) * h)
        for bx = x, x + w - 1, 6 do
            panel:drawRect(bx, budgetY, 3, 1, 1.0, 0.0, 0.9, 1.0)
        end
    end
end

local function drawHeader(panel, y, headerFont, bodyFont, pad)
    local enabled = ModProfiler.isEnabled() and "[ON]" or "[OFF]"
    local statusColor = ModProfiler.isEnabled() and { a = 1.0, r = 0.45, g = 0.90, b = 0.50 } or { a = 1.0, r = 0.80, g = 0.45, b = 0.45 }

    local snapshot = getHeaderSnapshot()
    local usedMs = snapshot.usedMs or 0
    local budgetMs = snapshot.budgetMs or (1000 / 60)
    local uncapped = snapshot.uncapped == true
    local pctUsed = budgetMs > 0 and (usedMs / budgetMs * 100) or 0
    local usageColor
    if pctUsed >= 90 then
        usageColor = { a = 1.0, r = 0.90, g = 0.40, b = 0.40 }
    elseif pctUsed >= 75 then
        usageColor = { a = 1.0, r = 0.95, g = 0.85, b = 0.35 }
    else
        usageColor = { a = 1.0, r = 0.60, g = 0.85, b = 0.60 }
    end

    drawTextCol(panel, "PROFILER", pad, y, COL_HEADER, headerFont)
    local headerW = getTextManager():MeasureStringX(headerFont, "PROFILER")
    drawTextCol(panel, enabled, pad + headerW + 8, y, statusColor, headerFont)

    local comboW = panel:getWidth() < 700 and 78 or 90
    local comboX = panel:getWidth() - comboW - 12
    local rateLabel = "rate"
    local rateLabelW = getTextManager():MeasureStringX(bodyFont, rateLabel)
    local rateX = comboX - rateLabelW - 6

    local budgetText
    if panel:getWidth() < 700 then
        budgetText = string.format("%.1f/%.1fms", usedMs, budgetMs)
    else
        local suffix = uncapped and " uncapped" or ""
        budgetText = string.format("%.1f / %.1f ms frame (%d%%)%s", usedMs, budgetMs, math.floor(pctUsed + 0.5), suffix)
    end
    local budgetX = pad + headerW + 72
    local budgetMaxW = rateX - budgetX - 8
    if budgetMaxW < 40 then budgetMaxW = 40 end
    drawTextCol(panel, ellipsize(bodyFont, budgetText, budgetMaxW), budgetX, y + 1, usageColor, bodyFont)

    if panel.rateCombo then
        panel.rateCombo:setX(comboX)
        panel.rateCombo:setY(y - 2)
        panel.rateCombo:setWidth(comboW)
        panel.rateCombo:setVisible(true)
    end
    drawTextCol(panel, rateLabel, rateX, y + 1, COL_SUBHEADER, bodyFont)

    local barY = y + getTextManager():MeasureStringY(bodyFont, "Aj") + 7
    local barX = pad
    local barW = comboX - barX - 8
    local totalTicks = ModProfiler.getIntervalTicks() or 300
    local currentTicks = ModProfiler.getTickCount() or 0
    local frac = 0
    if totalTicks > 0 then frac = currentTicks / totalTicks end
    if frac < 0 then frac = 0 end
    if frac > 1 then frac = 1 end
    drawRectCol(panel, barX, barY, barW, 4, COL_BAR_TRACK)
    drawRectCol(panel, barX, barY, math.floor(barW * frac), 4, COL_BAR_FILL)
    return barY + 10
end

local function drawColHeader(panel, y, font, cols)
    for _, col in ipairs(cols) do
        local label = col.label
        local active = panel.sortColumn == col.key
        local labelW = getTextManager():MeasureStringX(font, label)
        local iconSize = 6
        if col.align == "right" then
            local labelX = col.x + col.w - labelW - 2 - (active and (iconSize + 4) or 0)
            drawTextCol(panel, label, labelX, y, COL_SUBHEADER, font)
            if active then
                drawSortIndicator(panel, labelX + labelW + 4, y + 3, panel.sortDescending, COL_SUBHEADER, iconSize)
            end
        elseif col.align == "center" then
            local totalW = labelW + (active and (iconSize + 4) or 0)
            local labelX = col.x + math.floor((col.w - totalW) / 2)
            drawTextCol(panel, label, labelX, y, COL_SUBHEADER, font)
            if active then
                drawSortIndicator(panel, labelX + labelW + 4, y + 3, panel.sortDescending, COL_SUBHEADER, iconSize)
            end
        else
            drawTextCol(panel, label, col.x, y, COL_SUBHEADER, font)
            if active then
                drawSortIndicator(panel, col.x + labelW + 4, y + 3, panel.sortDescending, COL_SUBHEADER, iconSize)
            end
        end
    end
    drawRectCol(panel, cols[1].x, y + getTextManager():MeasureStringY(font, "Aj") + 1, panel:getWidth() - (cols[1].x * 2), 1, COL_DIVIDER)
    return y + getTextManager():MeasureStringY(font, "Aj") + 5
end

local function drawModRow(panel, row, y, font, cols)
    if row.pinned then
        drawRectCol(panel, cols[1].x - 2, y - 1, panel:getWidth() - (cols[1].x * 2) + 4, getTextManager():MeasureStringY(font, "Aj") + 3, COL_PINNED_BG)
    end
    local textColor = p95Color(row.p95 or 0)
    local nameX = cols[1].x
    if row.pinned then
        drawPinMarker(panel, cols[1].x, y + 2, textColor)
        nameX = nameX + 10
    end
    drawTextCol(panel, ellipsize(font, row.mod, cols[1].w - (nameX - cols[1].x) - 4), nameX, y, textColor, font)
    drawRight(panel, font, formatPctValue(row.pctTotal), cols[2], y, textColor)
    drawRight(panel, font, formatMsValue(row.p50), cols[3], y, textColor)
    drawRight(panel, font, formatMsValue(row.p95), cols[4], y, textColor)
    drawRight(panel, font, formatSpikeValue(row.spikesPerMin), cols[5], y, textColor)

    local glyphSize = math.max(7, getTextManager():MeasureStringY(font, "Aj") - 4)
    local pairW = glyphSize * 2 + 8
    local startX = cols[6].x + math.floor((cols[6].w - pairW) / 2)
    local glyphY = y + 1
    drawTrendIndicator(panel, startX, glyphY, row.shortTrendDir or "na", row.shortC or COL_MUTED, glyphSize)
    drawTrendIndicator(panel, startX + glyphSize + 8, glyphY, row.longTrendDir or "na", row.longC or COL_MUTED, glyphSize)
end

local function drawBudget(panel, x, y, w, h, font)
    local samples = ModProfiler.getFrameBudgetSamples and ModProfiler.getFrameBudgetSamples() or {}
    if #samples < 2 then
        drawTextCol(panel, "FRAME BUDGET: collecting data...", x, y, COL_SUBHEADER, font)
        return y + getTextManager():MeasureStringY(font, "Aj") + 6
    end

    local last = samples[#samples]
    local uncapped = last.uncapped == true
    local title = uncapped and "FRAME BUDGET (UNCAPPED)" or "FRAME BUDGET"
    drawTextCol(panel, title, x, y, COL_SUBHEADER, font)

    local overBy = (last.cpuMs or 0) - (last.budgetMs or 0)
    if overBy > 0 and not uncapped and (getTimestampMs() % 1000) < 500 then
        drawTextCol(panel, string.format("OVER BUDGET: +%.1fms", overBy), x + 180, y, { a = 1.0, r = 0.95, g = 0.35, b = 0.35 }, font)
    end

    local graphY = y + getTextManager():MeasureStringY(font, "Aj") + 4
    local graphH = h - 24
    local modsValues, engineValues, headroomValues = {}, {}, {}
    for i = 1, #samples do
        modsValues[i] = samples[i].modMs or 0
        engineValues[i] = samples[i].engineMs or 0
        headroomValues[i] = uncapped and 0 or (samples[i].headroomMs or 0)
    end

    local layers = {
        { values = headroomValues, a = 0.60, r = 0.20, g = 0.80, b = 0.30 },
        { values = engineValues, a = 0.70, r = 0.30, g = 0.50, b = 0.90 },
        { values = modsValues, a = 0.80, r = 1.00, g = 0.50, b = 0.20 },
    }
    if uncapped then table.remove(layers, 1) end
    drawStackedArea(panel, x, graphY, w, graphH, layers, uncapped and nil or last.budgetMs)

    local sumHeadroom, minHeadroom, maxHeadroom = 0, math.huge, -math.huge
    local sumBudget = 0
    for i = 1, #samples do
        local headroom = samples[i].headroomMs or 0
        local budget = samples[i].budgetMs or 16.67
        sumHeadroom = sumHeadroom + headroom
        sumBudget = sumBudget + budget
        if headroom < minHeadroom then minHeadroom = headroom end
        if headroom > maxHeadroom then maxHeadroom = headroom end
    end
    local avgHeadroom = sumHeadroom / #samples
    local avgBudget = sumBudget / #samples
    local freePct = avgBudget > 0 and (avgHeadroom / avgBudget * 100) or 0
    local footerColor
    if freePct > 30 then
        footerColor = { a = 1.0, r = 0.55, g = 0.85, b = 0.55 }
    elseif freePct >= 10 then
        footerColor = { a = 1.0, r = 0.95, g = 0.85, b = 0.35 }
    else
        footerColor = { a = 1.0, r = 0.90, g = 0.40, b = 0.40 }
    end
    local footer = string.format("Avg headroom: %.1f ms (%d%% free)   min: %.1f ms   max: %.1f ms", avgHeadroom, math.floor(freePct + 0.5), minHeadroom, maxHeadroom)
    drawTextCol(panel, footer, x, graphY + graphH + 3, footerColor, font)
    return graphY + graphH + getTextManager():MeasureStringY(font, "Aj") + 8
end

---------------------------------------------------------------------------
-- ModProfilerPanel
---------------------------------------------------------------------------
ModProfilerPanel = ISCollapsableWindow:derive("ModProfilerPanel")

function ModProfilerPanel:new(x, y, w, h)
    local ini = ModProfilerINI.load()
    local defaultX, defaultY = 40, 40
    local defaultW, defaultH = DEFAULT_W, DEFAULT_H

    x = ModProfilerINI.num(ini, "x", x or defaultX)
    y = ModProfilerINI.num(ini, "y", y or defaultY)
    w = ModProfilerINI.num(ini, "w", w or defaultW)
    h = ModProfilerINI.num(ini, "h", h or defaultH)

    local o = ISCollapsableWindow:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.title = "Mod Profiler"
    o.resizable = true
    o.minimumWidth = MIN_W
    o.minimumHeight = MIN_H
    o.backgroundColor = COL_BG
    o.borderColor = COL_BORDER
    o.rows = {}
    o.pinned = {}
    for _, modName in ipairs(ModProfilerINI.list(ini, "pinned")) do o.pinned[modName] = true end
    o.topN = TOP_N_DEFAULT
    o.sortColumn = ModProfilerINI.str(ini, "sortColumn", "pctTotal")
    o.sortDescending = ModProfilerINI.bool(ini, "sortDescending", true)
    o.intervalTicks = ModProfilerINI.num(ini, "intervalTicks", 120)
    o.lastRefreshAtMs = 0
    o.windowTotalMs = 0
    o._ini = ini
    o._cols = {}
    o._tableHeaderY = 0
    o._tableRowsY = 0
    o._tableBottomY = 0
    o._rowHeight = 16
    o.maxVisibleRows = TOP_N_DEFAULT
    return o
end

function ModProfilerPanel:initialise()
    ISCollapsableWindow.initialise(self)
end

function ModProfilerPanel:createChildren()
    ISCollapsableWindow.createChildren(self)
    self:setTitle("Mod Profiler")

    self.rateCombo = ISComboBox:new(0, 0, 90, 20, self, ModProfilerPanel.onRateChanged)
    self.rateCombo:initialise()
    for _, opt in ipairs(RATE_OPTIONS) do
        self.rateCombo:addOption(opt.label)
    end
    local selected = 3
    for idx, opt in ipairs(RATE_OPTIONS) do
        if opt.ticks == self.intervalTicks then selected = idx break end
    end
    self.rateCombo.selected = selected
    self:addChild(self.rateCombo)

    if self.resizeWidget then
        self.resizeWidget.resizeFunction = function(target, newW, newH)
            local core = getCore()
            local maxW = core:getScreenWidth() - target:getX()
            local maxH = core:getScreenHeight() - target:getY()
            if newW > maxW then newW = maxW end
            if newH > maxH then newH = maxH end
            if newW < MIN_W then newW = MIN_W end
            if newH < MIN_H then newH = MIN_H end
            target:setWidth(newW)
            target:setHeight(newH)
        end
    end
end

function ModProfilerPanel:onRateChanged(combo)
    local option = RATE_OPTIONS[combo.selected]
    if not option then return end
    self.intervalTicks = option.ticks
    if ModProfiler.setIntervalTicks then
        ModProfiler.setIntervalTicks(option.ticks)
    end
end

function ModProfilerPanel:saveState(isVisible)
    local pinnedList = {}
    for modName, isPinned in pairs(self.pinned) do
        if isPinned then pinnedList[#pinnedList + 1] = modName end
    end
    table.sort(pinnedList)
    local ini = self._ini or {}
    ini.x = math.floor(self:getX())
    ini.y = math.floor(self:getY())
    ini.w = math.floor(self:getWidth())
    ini.h = math.floor(self:getHeight())
    ini.visible = isVisible and "true" or "false"
    ini.pinned = table.concat(pinnedList, ",")
    ini.sortColumn = self.sortColumn or "pctTotal"
    ini.sortDescending = self.sortDescending and "true" or "false"
    ini.intervalTicks = tostring(self.intervalTicks or 120)
    ModProfilerINI.save(ini)
    self._ini = ini
end

function ModProfilerPanel:close()
    self:saveState(false)
    ISCollapsableWindow.close(self)
    ModProfilerUI.visible = false
end

function ModProfilerPanel:refreshRows(maxVisibleRows)
    local intervalSec = ModProfiler.getIntervalSeconds and ModProfiler.getIntervalSeconds() or 5
    local sessionMinutes = ModProfiler.getSessionElapsedMinutes and ModProfiler.getSessionElapsedMinutes() or 0
    local names = ModProfiler.getAllModNames and ModProfiler.getAllModNames() or {}
    local rows = {}
    local liveByMod = {}
    local displayByMod = {}
    local totalWindowMs = 0
    local windowCount = displayWindowCount(intervalSec)
    maxVisibleRows = maxVisibleRows or self.maxVisibleRows or TOP_N_DEFAULT

    for _, modName in ipairs(names) do
        if modName ~= SELF_MOD_NAME then
            local liveSamples = ModProfiler.getModLiveSamples(modName) or {}
            if #liveSamples > 0 then
                local displaySamples = tailArray(liveSamples, windowCount)
                local windowMs = 0
                for i = 1, #displaySamples do
                    windowMs = windowMs + (displaySamples[i].msPerFrame or 0)
                end
                local sessionTotals = ModProfiler.getModSessionTotals and ModProfiler.getModSessionTotals(modName) or nil
                if windowMs > 0 or (sessionTotals and sessionTotals.totalIntervalMs and sessionTotals.totalIntervalMs > 0) then
                    liveByMod[modName] = liveSamples
                    displayByMod[modName] = displaySamples
                    totalWindowMs = totalWindowMs + windowMs
                end
            end
        end
    end

    for _, modName in ipairs(names) do
        local liveSamples = liveByMod[modName]
        local displaySamples = displayByMod[modName]
        if liveSamples and displaySamples then
            local values = {}
            local windowMs = 0
            for i = 1, #displaySamples do
                local value = displaySamples[i].msPerFrame or 0
                values[#values + 1] = value
                windowMs = windowMs + value
            end
            local stats = computeStats(values)
            local pctTotal = totalWindowMs > 0 and (windowMs / totalWindowMs * 100) or 0
            local shortG, shortC, shortValue = shortTrend(liveSamples, intervalSec)
            local longG, longC, longValue = longTrend(
                ModProfiler.getModMinuteSamples and ModProfiler.getModMinuteSamples(modName) or {},
                ModProfiler.getModPeriodSamples and ModProfiler.getModPeriodSamples(modName) or {},
                sessionMinutes
            )
            rows[#rows + 1] = {
                mod = modName,
                pctTotal = pctTotal,
                p50 = stats.p50,
                p95 = stats.p95,
                spikesPerMin = spikesPerMin(liveSamples, intervalSec),
                shortTrendDir = shortG,
                shortC = shortC,
                shortTrendValue = shortValue or 0,
                longTrendDir = longG,
                longC = longC,
                longTrendValue = longValue or 0,
                pinned = self.pinned[modName] == true,
                windowTotalMs = windowMs,
            }
        end
    end

    table.sort(rows, function(a, b)
        if a.pinned ~= b.pinned then return a.pinned end
        local av, bv
        if self.sortColumn == "name" then
            av, bv = a.mod, b.mod
        elseif self.sortColumn == "trend" then
            av = a.shortTrendValue or 0
            bv = b.shortTrendValue or 0
        else
            av = a[self.sortColumn] or -1
            bv = b[self.sortColumn] or -1
        end
        if av == bv then return a.mod < b.mod end
        if self.sortDescending then return av > bv end
        return av < bv
    end)

    local displayed = {}
    for _, row in ipairs(rows) do
        if #displayed >= maxVisibleRows then break end
        if row.pinned then
            displayed[#displayed + 1] = row
        else
            displayed[#displayed + 1] = row
        end
    end

    self.rows = displayed
    self.totalRowCount = #rows
    self.hiddenRowCount = #rows - #displayed
    self.windowTotalMs = totalWindowMs
end

function ModProfilerPanel:buildSelfCostRow()
    local intervalSec = ModProfiler.getIntervalSeconds and ModProfiler.getIntervalSeconds() or 5
    local sessionMinutes = ModProfiler.getSessionElapsedMinutes and ModProfiler.getSessionElapsedMinutes() or 0
    local liveSamples = ModProfiler.getModLiveSamples and ModProfiler.getModLiveSamples(SELF_MOD_NAME) or {}
    if #liveSamples == 0 then return nil end
    local perInterval = tailArray(liveSamples, displayWindowCount(intervalSec))
    local values = {}
    local windowMs = 0
    for i = 1, #perInterval do
        local value = perInterval[i].msPerFrame or 0
        values[#values + 1] = value
        windowMs = windowMs + value
    end
    local stats = computeStats(values)
    local totalWithSelf = self.windowTotalMs + windowMs
    local pctTotal = totalWithSelf > 0 and (windowMs / totalWithSelf * 100) or 0
    local shortG, shortC = shortTrend(perInterval, intervalSec)
    local longG, longC = longTrend(
        ModProfiler.getModMinuteSamples and ModProfiler.getModMinuteSamples(SELF_MOD_NAME) or {},
        ModProfiler.getModPeriodSamples and ModProfiler.getModPeriodSamples(SELF_MOD_NAME) or {},
        sessionMinutes
    )

    return {
        mod = SELF_MOD_NAME,
        pctTotal = pctTotal,
        p50 = stats.p50,
        p95 = stats.p95,
        spikesPerMin = 0,
        shortTrendDir = shortG,
        shortC = shortC,
        longTrendDir = longG,
        longC = longC,
        pinned = false,
    }
end

function ModProfilerPanel:prerender()
    ISCollapsableWindow.prerender(self)

    local headerFont, bodyFont = pickFonts(self:getWidth())
    local pad = math.max(8, math.floor(self:getWidth() * 0.015))
    local y = self:titleBarHeight() + 8
    local lineH = getTextManager():MeasureStringY(bodyFont, "Aj") + 3

    y = drawHeader(self, y, headerFont, bodyFont, pad)

    local cols = buildColumns(self, pad)
    self._cols = cols
    self._tableHeaderY = y + 2
    local tableHeaderTop = y + 2
    local tableHeaderBottom = drawColHeader(self, tableHeaderTop, bodyFont, cols)

    local contentBottomPad = 10
    local graphH = math.max(80, math.min(180, math.floor((self:getHeight() - tableHeaderBottom - (lineH * 5)) * 0.30)))
    local graphBlockH = graphH + lineH + 14
    local selfBlockH = lineH * 2 + 16
    local footerH = lineH + 8
    local rowsAvailableH = self:getHeight() - tableHeaderBottom - graphBlockH - selfBlockH - footerH - contentBottomPad
    local maxVisibleRows = math.floor(rowsAvailableH / lineH)
    if maxVisibleRows < 6 then maxVisibleRows = 6 end
    self.maxVisibleRows = maxVisibleRows
    self:refreshRows(maxVisibleRows)

    y = tableHeaderBottom
    self._tableRowsY = y
    self._rowHeight = lineH

    for _, row in ipairs(self.rows or {}) do
        drawModRow(self, row, y, bodyFont, cols)
        y = y + lineH
    end
    self._tableBottomY = y

    if self.hiddenRowCount and self.hiddenRowCount > 0 then
        drawTextCol(self, string.format("... +%d more rows", self.hiddenRowCount), pad, y + 1, COL_MUTED, bodyFont)
        y = y + lineH
    end

    y = y + 6
    y = drawBudget(self, pad, y, self:getWidth() - (pad * 2), graphH, bodyFont)

    local selfRow = self:buildSelfCostRow()
    if selfRow then
        drawRectCol(self, pad, y + 2, self:getWidth() - (pad * 2), 1, COL_DIVIDER)
        y = y + 7
        drawTextCol(self, "PROFILER SELF-COST", pad, y, COL_SUBHEADER, bodyFont)
        y = y + lineH
        drawModRow(self, selfRow, y, bodyFont, cols)
        y = y + lineH
        drawRectCol(self, pad, y + 1, self:getWidth() - (pad * 2), 1, COL_DIVIDER)
        y = y + 6
    else
        y = y + 4
    end

    drawRectCol(self, pad, y, self:getWidth() - (pad * 2), 1, COL_DIVIDER)
    y = y + 4
    drawTextCol(self, "Header sort | Row pin | Right-click copy | F8 overlay | F12 profiling", pad, y, COL_MUTED, bodyFont)
end

function ModProfilerPanel:render()
    ISCollapsableWindow.render(self)
end

function ModProfilerPanel:onMouseDown(x, y)
    if self._cols and y >= self._tableHeaderY and y <= (self._tableHeaderY + self._rowHeight) then
        for _, col in ipairs(self._cols) do
            if x >= col.x and x <= (col.x + col.w) then
                if self.sortColumn == col.key then
                    self.sortDescending = not self.sortDescending
                else
                    self.sortColumn = col.key
                    self.sortDescending = col.key ~= "name"
                end
                self:refreshRows()
                return
            end
        end
    end

    if self.rows and y > self._tableRowsY and y <= self._tableBottomY then
        local idx = math.floor((y - self._tableRowsY) / self._rowHeight) + 1
        local row = self.rows[idx]
        if row then
            if self.pinned[row.mod] then self.pinned[row.mod] = nil else self.pinned[row.mod] = true end
            self:refreshRows()
            return
        end
    end

    ISCollapsableWindow.onMouseDown(self, x, y)
end

function ModProfilerPanel:onRightMouseDown(x, y)
    if self.rows and y > self._tableRowsY and y <= self._tableBottomY then
        local idx = math.floor((y - self._tableRowsY) / self._rowHeight) + 1
        local row = self.rows[idx]
        if row and Clipboard and Clipboard.setClipboard then
            pcall(function() Clipboard.setClipboard(row.mod) end)
            return
        end
    end
    ISCollapsableWindow.onRightMouseDown(self, x, y)
end

---------------------------------------------------------------------------
-- Module API
---------------------------------------------------------------------------
ModProfilerUI = {
    panel = nil,
    visible = false,
}

local function onPostUIDraw()
    if not ModProfilerUI.visible or not ModProfilerUI.panel then return end
    local nowMs = getTimestampMs()
    if nowMs - (ModProfilerUI.panel.lastRefreshAtMs or 0) >= REFRESH_MS then
        ModProfilerUI.panel:refreshRows()
        ModProfilerUI.panel.lastRefreshAtMs = nowMs
    end
end

local function onIntervalComplete()
    if ModProfilerUI.panel and ModProfilerUI.visible then
        ModProfilerUI.panel:refreshRows()
    end
end

local function onGameStart()
    local ini = ModProfilerINI.load()
    if ModProfilerINI.bool(ini, "visible", false) then
        ModProfilerUI.show()
    end
end

function ModProfilerUI.show()
    if ModProfilerUI.visible then return end
    if not ModProfilerUI.panel then
        local core = getCore()
        local sw = core:getScreenWidth()
        local sh = core:getScreenHeight()
        local w = math.min(DEFAULT_W, math.floor(sw * 0.75))
        local h = math.min(DEFAULT_H, math.floor(sh * 0.72))
        if w < MIN_W then w = MIN_W end
        if h < MIN_H then h = MIN_H end
        local panel = ModProfilerPanel:new(math.floor((sw - w) / 2), math.floor((sh - h) / 2), w, h)
        panel:initialise()
        panel:createChildren()
        ModProfilerUI.panel = panel
    end
    if ModProfilerUI.panel.intervalTicks and ModProfiler.setIntervalTicks then
        ModProfiler.setIntervalTicks(ModProfilerUI.panel.intervalTicks)
    end
    ModProfilerUI.panel:addToUIManager()
    ModProfilerUI.panel:setVisible(true)
    ModProfilerUI.panel:refreshRows()
    ModProfilerUI.panel:saveState(true)
    ModProfilerUI.visible = true
end

function ModProfilerUI.hide()
    if not ModProfilerUI.visible then return end
    if ModProfilerUI.panel then
        ModProfilerUI.panel:saveState(false)
        ModProfilerUI.panel:removeFromUIManager()
        ModProfilerUI.panel:setVisible(false)
    end
    ModProfilerUI.visible = false
end

function ModProfilerUI.toggle()
    if ModProfilerUI.visible then ModProfilerUI.hide() else ModProfilerUI.show() end
end

ModProfiler.registerUnwrapped("OnPostUIDraw", onPostUIDraw)
ModProfiler.registerUnwrapped("OnGameStart", onGameStart)
ModProfiler.onIntervalComplete(onIntervalComplete)

print("[MODPROFILER-UI] Overlay loaded. Press F8 to toggle.")
