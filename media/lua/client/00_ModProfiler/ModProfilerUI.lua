-- ModProfilerUI.lua
-- Overlay for 00_ModProfiler. Full redesign per dev/2026-04-18-ui-redesign-implementation-plan.md
-- with user-directed overrides:
--   * single muted off-white for all row text (no p95-based tint)
--   * UIFont.Small throughout
--   * desaturated graph — single accent hue at varying alpha
--   * ISCollapsableWindow handles createChildren — never call it manually
--   * engine band labeled "Engine + unattributed"

require "ISUI/ISCollapsableWindow"
require "ISUI/ISComboBox"

---------------------------------------------------------------------------
-- ModProfilerINI — key=value persistence in Zomboid Lua dir
---------------------------------------------------------------------------
local INI_FILENAME = "ModProfiler.ini"

local function iniParse(lines)
    local t = {}
    for _, line in ipairs(lines) do
        local k, v = line:match("^%s*([%w_%.]+)%s*=%s*(.-)%s*$")
        if k then t[k] = v end
    end
    return t
end

local function iniSerialize(tbl)
    local keys = {}
    for k in pairs(tbl) do keys[#keys+1] = k end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do out[#out+1] = k .. "=" .. tostring(tbl[k]) end
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
        lines[#lines+1] = line
    end
    reader:close()
    return iniParse(lines)
end

function ModProfilerINI.save(tbl)
    local writer = getFileWriter(INI_FILENAME, true, false)
    if not writer then return end
    for _, line in ipairs(iniSerialize(tbl)) do
        writer:write(line .. "\n")
    end
    writer:close()
end

function ModProfilerINI.num(tbl, key, default)
    local v = tonumber(tbl[key]); if v == nil then return default end; return v
end
function ModProfilerINI.bool(tbl, key, default)
    local v = tbl[key]
    if v == "true" then return true end
    if v == "false" then return false end
    return default
end
function ModProfilerINI.str(tbl, key, default) return tbl[key] or default end
function ModProfilerINI.list(tbl, key)
    local s = tbl[key]; if not s or s == "" then return {} end
    local out = {}; for w in s:gmatch("([^,]+)") do out[#out+1] = w end
    return out
end

---------------------------------------------------------------------------
-- Pure helpers
---------------------------------------------------------------------------
local function percentile(sortedArr, pct)
    local n = #sortedArr
    if n == 0 then return 0 end
    if n == 1 then return sortedArr[1] end
    local rank = (pct / 100) * (n - 1) + 1
    local lo = math.floor(rank); local hi = math.ceil(rank)
    if lo == hi then return sortedArr[lo] end
    local frac = rank - lo
    return sortedArr[lo] * (1 - frac) + sortedArr[hi] * frac
end

local function olsSlope(ys)
    local n = #ys
    if n < 2 then return nil, 0 end
    local sumX, sumY = 0, 0
    for i = 1, n do sumX = sumX + i; sumY = sumY + ys[i] end
    local meanX, meanY = sumX/n, sumY/n
    local num, den = 0, 0
    for i = 1, n do
        local dx = i - meanX; local dy = ys[i] - meanY
        num = num + dx * dy
        den = den + dx * dx
    end
    if den == 0 then return 0, meanY end
    return num / den, meanY
end

-- Neutral / muted trend colors — no strong hue shifts.
local TREND_NEUTRAL = { r=0.60, g=0.60, b=0.62, a=1 }
local TREND_RISING  = { r=0.82, g=0.70, b=0.55, a=1 }
local TREND_FALLING = { r=0.55, g=0.70, b=0.82, a=1 }

local function trendGlyph(pctPerUnit, thresholdRising, thresholdFalling, minSamples, nSamples)
    if nSamples < minSamples then return "-", TREND_NEUTRAL end
    if pctPerUnit == nil then return "-", TREND_NEUTRAL end
    if pctPerUnit > thresholdRising  then return "^", TREND_RISING end
    if pctPerUnit < thresholdFalling then return "v", TREND_FALLING end
    return ">", TREND_NEUTRAL
end

-- ys: pre-filled plain-number array of msPerFrame values (time-ordered).
-- Caller fills a reusable scratch buffer; zero allocation in this function.
local function shortTrend(ys, intervalSec)
    local n = #ys
    if n < 10 then return "-", TREND_NEUTRAL, 0 end
    local slopePerSample, mean = olsSlope(ys)
    if not slopePerSample or mean <= 0 then return ">", TREND_NEUTRAL, 0 end
    local slopePerMin = slopePerSample * (60 / intervalSec)
    local pctPerMin = slopePerMin / mean * 100
    local g, c = trendGlyph(pctPerMin, 2, -2, 10, n)
    return g, c, pctPerMin
end

-- ys: pre-filled plain-number array from the appropriate tier ring.
-- sampleMin: 1 for minute ring, 5 for period ring.
local function longTrend(ys, sampleMin, sessionMin)
    local n = #ys
    if sessionMin < 3 or n < 3 then return "-", TREND_NEUTRAL, 0 end
    local slopePerSample, mean = olsSlope(ys)
    if not slopePerSample or mean <= 0 then return ">", TREND_NEUTRAL, 0 end
    local slopePerHour = slopePerSample * (60 / sampleMin)
    local pctPerHour = slopePerHour / mean * 100
    local g, c = trendGlyph(pctPerHour, 2, -2, 3, n)
    return g, c, pctPerHour
end

-- Iterates ring in-place via ringGet — no array copy needed.
local function spikesPerMinFromRing(ring, intervalSec)
    local n = ring and ring.count or 0
    if n < 10 then return nil end
    local rg = ModProfiler.ringGet
    local sum = 0
    for i = 1, n do sum = sum + ((rg(ring, i)).spikes or 0) end
    local windowMin = (n * intervalSec) / 60
    if windowMin <= 0 then return 0 end
    return sum / windowMin
end

---------------------------------------------------------------------------
-- Shared palette (muted)
---------------------------------------------------------------------------
local TEXT_MUTED  = { r=0.82, g=0.82, b=0.80, a=1 }   -- single row-text color
local TEXT_HEADER = { r=0.70, g=0.72, b=0.78, a=1 }
local TEXT_DIM    = { r=0.58, g=0.58, b=0.62, a=1 }

-- Single accent hue for interactive bits: slate cyan.
local ACCENT = { r=0.45, g=0.60, b=0.70 }

-- Frame-budget graph: three muted tones with real lightness separation.
-- Dark = unused headroom, mid = engine/unattributed, light = mod work.
-- Separated by lightness (not hue) keeps the muted aesthetic and survives
-- both dark and bright game backgrounds.
local BG_HEADROOM = { r=0.18, g=0.21, b=0.24, a=0.95 }  -- near-black slate
local BG_ENGINE   = { r=0.42, g=0.47, b=0.52, a=0.95 }  -- mid steel
local BG_MODS     = { r=0.78, g=0.80, b=0.82, a=0.98 }  -- off-white
local BUDGET_LINE = { r=0.95, g=0.78, b=0.45, a=0.90 }  -- warm amber — stands out

-- The mod name the profiler attributes to its own Lua files. Kept in sync
-- with extractModName() in ModProfiler.lua.
local SELF_MOD_NAME = "00_ModProfiler"

---------------------------------------------------------------------------
-- Column layout
---------------------------------------------------------------------------
local COLS = {
    { key="name",         label="Mod",      x=10,  w=220, align="left"  },
    { key="pctTotal",     label="%Total",   x=240, w=70,  align="right" },
    { key="p50",          label="ms/f p50", x=320, w=90,  align="right" },
    { key="p95",          label="ms/f p95", x=420, w=90,  align="right" },
    { key="spikesPerMin", label="spk/min",  x=520, w=80,  align="right" },
    { key="trend",        label="trend",    x=610, w=60,  align="center"},
}

local function drawColHeader(panel, y, font, sortKey, sortDesc)
    for _, c in ipairs(COLS) do
        local label = c.label
        if c.key == sortKey then label = label .. (sortDesc and " v" or " ^") end
        if c.align == "right" then
            local tw = getTextManager():MeasureStringX(font, label)
            panel:drawText(label, c.x + c.w - tw, y, TEXT_HEADER.r, TEXT_HEADER.g, TEXT_HEADER.b, 1, font)
        elseif c.align == "center" then
            local tw = getTextManager():MeasureStringX(font, label)
            panel:drawText(label, c.x + (c.w - tw)/2, y, TEXT_HEADER.r, TEXT_HEADER.g, TEXT_HEADER.b, 1, font)
        else
            panel:drawText(label, c.x, y, TEXT_HEADER.r, TEXT_HEADER.g, TEXT_HEADER.b, 1, font)
        end
    end
    panel:drawRect(10, y + 14, panel:getWidth() - 20, 1, 0.35, 0.40, 0.50, 0.30)
    return y + 18
end

local function drawModRow(panel, row, y, font)
    if row.pinned then
        panel:drawRect(8, y - 1, panel:getWidth() - 16, 15, 0.35, 0.35, 0.20, 0.12)
    end
    local col = TEXT_MUTED
    panel:drawText(row._fmtName, COLS[1].x, y, col.r, col.g, col.b, 1, font)
    local function R(txt, c)
        local tw = getTextManager():MeasureStringX(font, txt)
        panel:drawText(txt, c.x + c.w - tw, y, col.r, col.g, col.b, 1, font)
    end
    R(row._fmtPct,   COLS[2])
    R(row._fmtP50,   COLS[3])
    R(row._fmtP95,   COLS[4])
    R(row._fmtSpk,   COLS[5])
    local g1 = row.shortG or "-"; local g2 = row.longG or "-"
    local pair = g1 .. " " .. g2
    local tw = getTextManager():MeasureStringX(font, pair)
    local tx = COLS[6].x + (COLS[6].w - tw)/2
    panel:drawText(g1, tx, y, row.shortC.r, row.shortC.g, row.shortC.b, 1, font)
    local g1w = getTextManager():MeasureStringX(font, g1 .. " ")
    panel:drawText(g2, tx + g1w, y, row.longC.r, row.longC.g, row.longC.b, 1, font)
end

---------------------------------------------------------------------------
-- Header (status + CPU/budget + interval bar). Rate combo is a real child
-- widget positioned independently — see createChildren / onResize.
---------------------------------------------------------------------------
local function drawHeader(panel, y, font)
    local enabled = ModProfiler.isEnabled and ModProfiler.isEnabled()
    local statusTxt = enabled and "[ON]" or "[OFF]"

    panel:drawText("PROFILER", 10, y, 0.82, 0.82, 0.85, 1, font)
    local afterLabelX = 10 + getTextManager():MeasureStringX(font, "PROFILER ")
    panel:drawText(statusTxt, afterLabelX, y, TEXT_MUTED.r, TEXT_MUTED.g, TEXT_MUTED.b, 1, font)

    local bigStr = panel:getWidth() < 700 and panel._fmtHeaderBigShort or panel._fmtHeaderBig
    local bigX = afterLabelX + getTextManager():MeasureStringX(font, statusTxt .. "  ")
    panel:drawText(bigStr, bigX, y, TEXT_MUTED.r, TEXT_MUTED.g, TEXT_MUTED.b, 1, font)

    -- "rate" label sits left of the rate combo (which is a child widget).
    local rateLabelX = panel:getWidth() - 140
    panel:drawText("rate", rateLabelX, y, TEXT_DIM.r, TEXT_DIM.g, TEXT_DIM.b, 1, font)

    -- Interval progress bar drawn on its own line beneath the header text.
    local totalTicks = (ModProfiler.getIntervalTicks and ModProfiler.getIntervalTicks()) or 120
    local curTicks   = (ModProfiler.getTickCount and ModProfiler.getTickCount()) or 0
    local frac = math.max(0, math.min(1, curTicks / totalTicks))
    local barY = y + 18
    local barX, barW, barH = 10, panel:getWidth() - 20, 3
    panel:drawRect(barX, barY, barW, barH, 0.22, 0.24, 0.28, 0.60)
    panel:drawRect(barX, barY, math.floor(barW * frac), barH, ACCENT.r, ACCENT.g, ACCENT.b, 0.80)

    return barY + barH + 4   -- y-cursor below the bar with a little breathing room
end

---------------------------------------------------------------------------
-- Frame-budget stacked area (single-hue, "Engine + unattributed")
---------------------------------------------------------------------------
local function drawStackedArea(panel, x, y, w, h, layers, budgetMs, font)
    -- Find Y-axis max across stacked totals
    local n = 0
    for _, L in ipairs(layers) do if #L.values > n then n = #L.values end end
    if n < 2 then return end
    local maxY = 0
    for i = 1, n do
        local sum = 0
        for _, L in ipairs(layers) do sum = sum + (L.values[i] or 0) end
        if sum > maxY then maxY = sum end
    end
    if budgetMs and budgetMs > maxY then maxY = budgetMs end
    if maxY <= 0 then maxY = 1 end

    -- Background
    panel:drawRect(x, y, w, h, 0.10, 0.11, 0.13, 0.80)

    -- Stacked bars, left-to-right, one column per sample.
    -- Use integer math on pixel boundaries so adjacent columns ABUT
    -- instead of overlapping by 1px (which visually merges the bars
    -- and kills the stacked-area look).
    local colFloatW = w / n
    for i = 1, n do
        local cx      = x + math.floor((i - 1) * colFloatW)
        local cxNext  = x + math.floor(i * colFloatW)
        local pixelW  = cxNext - cx
        if pixelW < 1 then pixelW = 1 end
        local stackY = y + h
        for _, L in ipairs(layers) do
            local v = L.values[i] or 0
            local barH = (v / maxY) * h
            panel:drawRect(cx, stackY - barH, pixelW, barH, L.r, L.g, L.b, L.a)
            stackY = stackY - barH
        end
    end

    -- Budget line (dashed) — warm amber so it reads as a distinct marker
    -- against any of the grey/steel band tones.
    if budgetMs then
        local ly = y + h - (budgetMs / maxY) * h
        local segW = 6; local gapW = 4; local step = segW + gapW
        local xi = x
        while xi < x + w do
            local segEnd = math.min(xi + segW, x + w)
            panel:drawRect(xi, ly, segEnd - xi, 1, BUDGET_LINE.r, BUDGET_LINE.g, BUDGET_LINE.b, BUDGET_LINE.a)
            xi = xi + step
        end
    end
end

local function drawBudget(panel, x, y, w, h, font)
    local n = panel._budgetN
    if n < 2 then
        panel:drawText("Frame budget: collecting data...", x, y, TEXT_DIM.r, TEXT_DIM.g, TEXT_DIM.b, 1, font)
        return y + 16
    end

    local last = panel._budgetLast
    local uncapped = panel._budgetUncapped
    local title = uncapped and "FRAME BUDGET (UNCAPPED)" or "FRAME BUDGET"
    panel:drawText(title, x, y, TEXT_HEADER.r, TEXT_HEADER.g, TEXT_HEADER.b, 1, font)

    local overBy = last.cpuMs - last.budgetMs
    if overBy > 0 and not uncapped then
        local blink = (getTimestampMs() % 1000) < 500
        if blink then
            panel:drawText(string.format("! OVER BUDGET: +%.1fms", overBy),
                           x + 180, y, 0.85, 0.55, 0.50, 1, font)
        end
    end

    local titlePad = 26
    local gy = y + titlePad
    local footerPad = 18
    local gh = h - titlePad - footerPad

    -- Use pre-filled layer arrays from refreshBudgetLayers (zero alloc here).
    local layerList = uncapped and panel._layerListUncapped or panel._layerListCapped

    drawStackedArea(panel, x, gy, w, gh, layerList, uncapped and nil or last.budgetMs, font)

    -- Legend row
    local legendY = gy + gh + 2
    local lx = x
    for _, L in ipairs(layerList) do
        panel:drawRect(lx, legendY + 3, 8, 6, L.r, L.g, L.b, L.a)
        panel:drawText(L.name, lx + 12, legendY, TEXT_DIM.r, TEXT_DIM.g, TEXT_DIM.b, 1, font)
        lx = lx + 14 + getTextManager():MeasureStringX(font, L.name) + 12
    end
    if not uncapped then
        panel:drawRect(lx, legendY + 5, 8, 1, BUDGET_LINE.r, BUDGET_LINE.g, BUDGET_LINE.b, BUDGET_LINE.a)
        panel:drawText("budget", lx + 12, legendY, TEXT_DIM.r, TEXT_DIM.g, TEXT_DIM.b, 1, font)
    end

    -- Footer uses pre-cached string from refresh cycle.
    panel:drawText(panel._fmtBudgetFooter, x, y + h + 4, TEXT_DIM.r, TEXT_DIM.g, TEXT_DIM.b, 1, font)

    local note = "Mods band = profiled Lua callbacks only; native/asset cost rolls into Engine band."
    panel:drawText(note, x, y + h + 18, TEXT_DIM.r, TEXT_DIM.g, TEXT_DIM.b, 0.75, font)

    return y + h + 34
end

---------------------------------------------------------------------------
-- Panel class
---------------------------------------------------------------------------
ModProfilerPanel = ISCollapsableWindow:derive("ModProfilerPanel")

function ModProfilerPanel:new(x, y, w, h)
    local ini = ModProfilerINI.load()
    local defaultX, defaultY = 40, 40
    local defaultW, defaultH = 820, 560

    x = ModProfilerINI.num(ini, "x", x or defaultX)
    y = ModProfilerINI.num(ini, "y", y or defaultY)
    w = ModProfilerINI.num(ini, "w", w or defaultW)
    h = ModProfilerINI.num(ini, "h", h or defaultH)

    local o = ISCollapsableWindow:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.title           = "Mod Profiler"
    o.resizable       = true
    o.drawFrame       = true
    o.backgroundColor = { r=0.05, g=0.06, b=0.08, a=0.92 }
    o.borderColor     = { r=0.30, g=0.34, b=0.40, a=1.00 }
    o.topN            = 20
    o.pinned          = {}
    for _, m in ipairs(ModProfilerINI.list(ini, "pinned")) do o.pinned[m] = true end
    o.sortColumn      = ModProfilerINI.str(ini, "sortColumn", "pctTotal")
    o.sortDescending  = ModProfilerINI.bool(ini, "sortDescending", true)
    o.intervalTicks   = ModProfilerINI.num(ini, "intervalTicks", 120)
    o._ini            = ini
    o._comboW         = 90
    -- Pre-allocated buffers for zero-alloc refresh path.
    -- All data rebuilt at interval boundaries via engine dirty flag.
    o._cachedSelfRow       = nil
    o._cachedHeaderCpuMs   = 0
    o._cachedHeaderBudgetMs= 1000/60
    o._cachedHeaderPct     = 0
    o._scratch             = {}   -- reusable number array for percentile/OLS
    o._layerHeadroom       = {}   -- pre-allocated graph band value arrays
    o._layerEngine         = {}
    o._layerMods           = {}
    o._budgetN             = 0    -- valid entry count in layer arrays
    o._budgetLast          = nil  -- newest budget ring entry (reference)
    o._budgetUncapped      = false
    o._footerAvgHr         = 0
    o._footerMinHr         = 0
    o._footerMaxHr         = 0
    o._footerFreePct       = 0
    o._fmtHeaderBig        = ""    -- cached formatted strings (rebuilt per refresh)
    o._fmtHeaderBigShort   = ""
    o._fmtBudgetFooter     = ""
    o._fmtGapLine          = ""    -- unattributed gap summary
    o._gapShortG           = "-"   -- trend glyphs for the gap
    o._gapShortC           = TREND_NEUTRAL
    o._gapLongG            = "-"
    o._gapLongC            = TREND_NEUTRAL
    o._fmtGapLine2         = ""    -- second gap line: render sync + heap
    -- Static layer descriptors — point to the pre-allocated value arrays.
    -- drawBudget picks the right list each frame with zero allocation.
    o._layerListCapped = {
        { name="Headroom",              values=o._layerHeadroom, r=BG_HEADROOM.r, g=BG_HEADROOM.g, b=BG_HEADROOM.b, a=BG_HEADROOM.a },
        { name="Engine + unattributed", values=o._layerEngine,   r=BG_ENGINE.r,   g=BG_ENGINE.g,   b=BG_ENGINE.b,   a=BG_ENGINE.a },
        { name="Mods",                  values=o._layerMods,     r=BG_MODS.r,     g=BG_MODS.g,     b=BG_MODS.b,     a=BG_MODS.a },
    }
    o._layerListUncapped = {
        o._layerListCapped[2],   -- Engine
        o._layerListCapped[3],   -- Mods
    }
    return o
end

function ModProfilerPanel:createChildren()
    ISCollapsableWindow.createChildren(self)

    -- Align with drawHeader()'s header-text baseline:
    --   y = titleBarHeight() + 14 (text row). We drop 2px so the combo
    --   sits vertically centered next to the "rate" label and clear of
    --   the interval progress bar drawn below.
    local cW, cH = self._comboW, 20
    local comboY = self:titleBarHeight() + 12
    self.rateCombo = ISComboBox:new(self:getWidth() - cW - 12, comboY, cW, cH,
                                    self, ModProfilerPanel.onRateChanged)
    self.rateCombo.font = UIFont.Small
    self.rateCombo:initialise()
    self:addChild(self.rateCombo)
    self.rateCombo:addOption("10s")
    self.rateCombo:addOption("5s")
    self.rateCombo:addOption("2s")
    self.rateCombo:addOption("1s")
    self.rateCombo:addOption("0.5s")
    self.rateCombo:addOption("0.1s")
    local map = { [600]=1, [300]=2, [120]=3, [60]=4, [30]=5, [6]=6 }
    self.rateCombo.selected = map[self.intervalTicks] or 3
end

function ModProfilerPanel:onRateChanged(combo)
    local ticksByIdx = { 600, 300, 120, 60, 30, 6 }
    local ticks = ticksByIdx[combo.selected] or 120
    self.intervalTicks = ticks
    if ModProfiler.setIntervalTicks then ModProfiler.setIntervalTicks(ticks) end
end

function ModProfilerPanel:onResize()
    ISCollapsableWindow.onResize(self)
    if self.rateCombo then
        self.rateCombo:setX(self:getWidth() - self._comboW - 12)
        self.rateCombo:setY(self:titleBarHeight() + 12)
    end
end

function ModProfilerPanel:close()
    local pinnedList = {}
    for k, v in pairs(self.pinned) do if v then pinnedList[#pinnedList+1] = k end end
    local t = self._ini or {}
    t.x              = math.floor(self:getX())
    t.y              = math.floor(self:getY())
    t.w              = math.floor(self:getWidth())
    t.h              = math.floor(self:getHeight())
    t.visible        = "false"
    t.pinned         = table.concat(pinnedList, ",")
    t.sortColumn     = self.sortColumn or "pctTotal"
    t.sortDescending = self.sortDescending and "true" or "false"
    t.intervalTicks  = tostring(self.intervalTicks or 120)
    ModProfilerINI.save(t)
    ISCollapsableWindow.close(self)
end

---------------------------------------------------------------------------
-- Row builders
---------------------------------------------------------------------------
function ModProfilerPanel:refreshRows()
    local intervalSec = (ModProfiler.getIntervalSeconds and ModProfiler.getIntervalSeconds()) or 2
    local sessionMin  = (ModProfiler.getSessionElapsedMinutes and ModProfiler.getSessionElapsedMinutes()) or 0
    local names = (ModProfiler.getAllModNames and ModProfiler.getAllModNames()) or {}
    local rg = ModProfiler.ringGet
    local scratch = self._scratch
    local rows = {}
    local sumLiveMs = 0

    -- Pass 1: total live-ms across all non-self mods (ring-direct, no copies).
    for _, m in ipairs(names) do
        if m ~= SELF_MOD_NAME then
            local ring = ModProfiler.getModLiveRing(m)
            if ring and ring.count > 0 then
                for i = 1, ring.count do
                    sumLiveMs = sumLiveMs + ((rg(ring, i)).msPerFrame or 0)
                end
            end
        end
    end

    -- Pass 2: per-mod stats. One reusable scratch buffer for OLS + percentile.
    for _, m in ipairs(names) do
        if m ~= SELF_MOD_NAME then
            local ring = ModProfiler.getModLiveRing(m)
            if ring and ring.count > 0 then
                local n = ring.count
                -- Fill scratch with msPerFrame (time-ordered for OLS).
                local modTotal = 0
                for i = 1, n do
                    local v = (rg(ring, i)).msPerFrame or 0
                    scratch[i] = v
                    modTotal = modTotal + v
                end
                for i = n + 1, #scratch do scratch[i] = nil end

                -- Short trend (needs unsorted time-ordered data).
                local shortG, shortC = shortTrend(scratch, intervalSec)
                -- Sort in-place for percentile (scratch order consumed).
                table.sort(scratch)
                local p50 = percentile(scratch, 50)
                local p95 = percentile(scratch, 95)
                local pctTotal = sumLiveMs > 0 and (modTotal / sumLiveMs * 100) or 0

                -- Spikes: iterate ring directly (no scratch needed).
                local spk = spikesPerMinFromRing(ring, intervalSec)

                -- Long trend: refill scratch from minute or period ring.
                local longRing, sampleMin
                if sessionMin < 30 then
                    longRing = ModProfiler.getModMinuteRing(m)
                    sampleMin = 1
                else
                    longRing = ModProfiler.getModPeriodRing(m)
                    sampleMin = 5
                end
                local ln = longRing and longRing.count or 0
                for i = 1, ln do scratch[i] = (rg(longRing, i)).msPerFrame or 0 end
                for i = ln + 1, #scratch do scratch[i] = nil end
                local longG, longC = longTrend(scratch, sampleMin, sessionMin)

                rows[#rows+1] = {
                    mod = m, pctTotal = pctTotal, p50 = p50, p95 = p95,
                    spikesPerMin = spk,
                    shortG = shortG, shortC = shortC,
                    longG = longG, longC = longC,
                    pinned = self.pinned[m] == true,
                }
            end
        end
    end

    local col  = self.sortColumn or "pctTotal"
    local desc = self.sortDescending ~= false
    local function cmp(a, b)
        if a.pinned ~= b.pinned then return a.pinned end
        local av, bv
        if col == "name" then av, bv = a.mod, b.mod
        else av, bv = a[col] or -1, b[col] or -1 end
        if av == bv then return a.mod < b.mod end
        if desc then return av > bv else return av < bv end
    end
    table.sort(rows, cmp)

    local displayed = {}
    for _, r in ipairs(rows) do
        if r.pinned or #displayed < self.topN then displayed[#displayed+1] = r end
    end
    -- Pre-format display strings once per refresh — eliminates ~100
    -- string.format calls per frame from the draw path.
    for _, r in ipairs(displayed) do
        r._fmtName = (r.pinned and "* " or "  ") .. (r.mod or "?")
        r._fmtPct  = string.format("%.1f%%", r.pctTotal or 0)
        r._fmtP50  = string.format("%.2f ms", r.p50 or 0)
        r._fmtP95  = string.format("%.2f ms", r.p95 or 0)
        r._fmtSpk  = r.spikesPerMin and string.format("%.1f", r.spikesPerMin) or "-"
    end
    self.rows = displayed
end

function ModProfilerPanel:refreshBudgetLayers()
    local ring = ModProfiler.getFrameBudgetRing and ModProfiler.getFrameBudgetRing()
    local rg = ModProfiler.ringGet
    local n = ring and ring.count or 0
    self._budgetN = n
    if n < 1 then self._budgetLast = nil; return end

    self._budgetLast = rg(ring, n)
    local uncapped = self._budgetLast.uncapped == true
    self._budgetUncapped = uncapped
    local headroom = self._layerHeadroom
    local engine   = self._layerEngine
    local mods     = self._layerMods
    local sumHr, minHr, maxHr, budgetSum = 0, math.huge, -math.huge, 0
    for i = 1, n do
        local s = rg(ring, i)
        local hr = s.headroomMs or 0
        headroom[i] = uncapped and 0 or hr
        engine[i]   = s.engineMs or 0
        mods[i]     = s.modMs or 0
        sumHr = sumHr + hr
        if hr < minHr then minHr = hr end
        if hr > maxHr then maxHr = hr end
        budgetSum = budgetSum + (s.budgetMs or 16.67)
    end
    -- Nil extras from previous (possibly larger) dataset.
    for i = n + 1, #headroom do headroom[i] = nil end
    for i = n + 1, #engine   do engine[i]   = nil end
    for i = n + 1, #mods     do mods[i]     = nil end
    self._footerAvgHr  = n > 0 and (sumHr / n) or 0
    self._footerMinHr  = n > 0 and minHr or 0
    self._footerMaxHr  = n > 0 and maxHr or 0
    local budgetAvg = n > 0 and (budgetSum / n) or 16.67
    self._footerFreePct = budgetAvg > 0 and (self._footerAvgHr / budgetAvg * 100) or 0
end

function ModProfilerPanel:refreshGapStats()
    -- Compute trend of the unattributed gap (engineMs = cpuMs - modMs).
    -- A rising gap means something outside profiled Lua is growing: GC,
    -- native engine work, asset decoding, physics, etc.
    local ring = ModProfiler.getFrameBudgetRing and ModProfiler.getFrameBudgetRing()
    local rg = ModProfiler.ringGet
    local n = ring and ring.count or 0
    if n < 2 then
        self._fmtGapLine = ""
        self._fmtGapLine2 = ""
        self._gapShortG = "-"; self._gapShortC = TREND_NEUTRAL
        self._gapLongG  = "-"; self._gapLongC  = TREND_NEUTRAL
        return
    end

    local scratch = self._scratch
    local intervalSec = (ModProfiler.getIntervalSeconds and ModProfiler.getIntervalSeconds()) or 2
    local sessionMin  = (ModProfiler.getSessionElapsedMinutes and ModProfiler.getSessionElapsedMinutes()) or 0

    -- Fill scratch with engineMs values (time-ordered) for short trend.
    local last = rg(ring, n)
    local lastGap = last.engineMs or 0
    local lastCpu = last.cpuMs or 0
    local lastMod = last.modMs or 0
    local sumGap = 0
    for i = 1, n do
        local v = (rg(ring, i)).engineMs or 0
        scratch[i] = v
        sumGap = sumGap + v
    end
    for i = n + 1, #scratch do scratch[i] = nil end
    local avgGap = sumGap / n
    local gapPct = lastCpu > 0 and (lastGap / lastCpu * 100) or 0

    -- Short trend: is the gap growing within the live ring window?
    local shortG, shortC = shortTrend(scratch, intervalSec)

    -- Long trend: use the budget ring as-is (it's the only tier for gap).
    local longG, longC
    if sessionMin >= 3 and n >= 3 then
        longG, longC = shortTrend(scratch, intervalSec)
    else
        longG, longC = "-", TREND_NEUTRAL
    end

    self._gapShortG = shortG; self._gapShortC = shortC
    self._gapLongG  = longG;  self._gapLongC  = longC
    self._fmtGapLine = string.format(
        "Unattributed: %.1f ms (avg %.1f ms, %d%% of CPU)   mods: %.1f ms   total: %.1f ms",
        lastGap, avgGap, gapPct + 0.5, lastMod, lastCpu)

    -- Second line: render-sync + heap breakdown (if available)
    local cpuW = last.cpuWaitMs or 0
    local gpuW = last.gpuWaitMs or 0
    local heapFree  = last.heapFreeMb or 0
    local heapTotal = last.heapTotalMb or 0
    local heapAlloc = last.heapAllocMb or 0
    local heapUsed  = heapTotal > 0 and (heapTotal - heapFree) or 0
    local heapPct   = heapTotal > 0 and (heapUsed / heapTotal * 100) or 0

    local parts = {}
    parts[#parts+1] = string.format("render sync: cpu-wait %.1f / gpu-wait %.1f ms", cpuW, gpuW)
    if heapTotal > 0 then
        local allocDir = heapAlloc > 0 and "+" or ""
        parts[#parts+1] = string.format("heap: %dMB / %dMB (%d%%) %s%.0fMB/int",
            heapUsed, heapTotal, heapPct + 0.5, allocDir, heapAlloc)
    else
        parts[#parts+1] = "heap: n/a (SP)"
    end
    self._fmtGapLine2 = table.concat(parts, "   ")
end

function ModProfilerPanel:buildSelfCostRow()
    local dumpRing = ModProfiler.getSelfDumpRing and ModProfiler.getSelfDumpRing()
    if not dumpRing or dumpRing.count < 2 then return nil end
    local wrapMean = (ModProfiler.getSelfWrapperMs and ModProfiler.getSelfWrapperMs()) or 0
    local intervalSec = (ModProfiler.getIntervalSeconds and ModProfiler.getIntervalSeconds()) or 2
    local intervalTicks = intervalSec * 60
    if intervalTicks <= 0 then return nil end

    local rg = ModProfiler.ringGet
    local callsPerInterval = 0
    local modStats = ModProfiler.getModStats and ModProfiler.getModStats() or {}
    local totMin = (ModProfiler.getSessionElapsedMinutes and ModProfiler.getSessionElapsedMinutes()) or 0
    local totalCalls = 0
    for _, s in pairs(modStats) do totalCalls = totalCalls + (s.totalCalls or 0) end
    if totMin > 0 then
        local totalIntervals = (totMin * 60) / intervalSec
        if totalIntervals > 0 then callsPerInterval = totalCalls / totalIntervals end
    end

    local scratch = self._scratch
    local n = dumpRing.count
    for i = 1, n do
        local d = rg(dumpRing, i) or 0
        scratch[i] = (wrapMean * callsPerInterval + d) / intervalTicks
    end
    for i = n + 1, #scratch do scratch[i] = nil end
    table.sort(scratch)
    local p50 = percentile(scratch, 50)
    local p95 = percentile(scratch, 95)

    local row = {
        mod = "00_ModProfiler",
        pctTotal = 0, p50 = p50, p95 = p95,
        spikesPerMin = 0,
        shortG = ">", shortC = TREND_NEUTRAL,
        longG  = ">", longC  = TREND_NEUTRAL,
        pinned = false,
    }
    row._fmtName = "  00_ModProfiler"
    row._fmtPct  = "0.0%"
    row._fmtP50  = string.format("%.2f ms", p50)
    row._fmtP95  = string.format("%.2f ms", p95)
    row._fmtSpk  = "0.0"
    return row
end

---------------------------------------------------------------------------
-- Mouse interaction
---------------------------------------------------------------------------
function ModProfilerPanel:onMouseDown(x, y)
    if self._tableHeaderY and y >= self._tableHeaderY and y <= self._tableHeaderY + 18 then
        for _, c in ipairs(COLS) do
            if x >= c.x and x <= c.x + c.w then
                if self.sortColumn == c.key then
                    self.sortDescending = not self.sortDescending
                else
                    self.sortColumn = c.key
                    self.sortDescending = (c.key ~= "name")
                end
                return
            end
        end
    end
    if self._tableHeaderY and self.rows and y > self._tableHeaderY + 18 and y <= (self._tableBottomY or 0) then
        local idx = math.floor((y - (self._tableHeaderY + 18)) / 15) + 1
        local r = self.rows[idx]
        if r then
            if self.pinned[r.mod] then self.pinned[r.mod] = nil else self.pinned[r.mod] = true end
        end
    end
    ISCollapsableWindow.onMouseDown(self, x, y)
end

function ModProfilerPanel:onRightMouseDown(x, y)
    if self._tableHeaderY and self.rows and y > self._tableHeaderY + 18 and y <= (self._tableBottomY or 0) then
        local idx = math.floor((y - (self._tableHeaderY + 18)) / 15) + 1
        local r = self.rows[idx]
        if r and Clipboard and Clipboard.setClipboard then
            pcall(Clipboard.setClipboard, r.mod)
        end
    end
    ISCollapsableWindow.onRightMouseDown(self, x, y)
end

---------------------------------------------------------------------------
-- prerender
---------------------------------------------------------------------------
function ModProfilerPanel:prerender()
    ISCollapsableWindow.prerender(self)
    local font = UIFont.Small
    -- titleBarHeight() returns the height of the drag/title region.
    -- ISCollapsableWindow also reserves a 1px chrome separator line
    -- just under it; start header content well clear of that line so
    -- the interval-progress bar doesn't visually cut through the title.
    local y = self:titleBarHeight() + 14

    -- Refresh only when the engine produces new interval data (dirty flag).
    -- This aligns the UI rebuild exactly with the user-selected polling
    -- rate — no wasted work, no data misalignment.
    if ModProfiler.isSnapshotDirty and ModProfiler.isSnapshotDirty() then
        ModProfiler.clearSnapshotDirty()
        self:refreshRows()
        self:refreshBudgetLayers()
        self:refreshGapStats()
        self._cachedSelfRow = self:buildSelfCostRow()
        if self._budgetLast then
            self._cachedHeaderCpuMs    = self._budgetLast.cpuMs or 0
            self._cachedHeaderBudgetMs = self._budgetLast.budgetMs or (1000/60)
        end
        self._cachedHeaderPct = self._cachedHeaderBudgetMs > 0
            and (self._cachedHeaderCpuMs / self._cachedHeaderBudgetMs * 100) or 0
        -- Cache formatted strings so the per-frame draw path has zero string.format calls.
        local cpuMs    = self._cachedHeaderCpuMs
        local budgetMs = self._cachedHeaderBudgetMs
        local pct      = self._cachedHeaderPct
        self._fmtHeaderBig      = string.format("%.1f / %.1f ms frame (%d%%)", cpuMs, budgetMs, pct+0.5)
        self._fmtHeaderBigShort = string.format("%.1f/%.1fms", cpuMs, budgetMs)
        self._fmtBudgetFooter   = string.format("Avg headroom: %.1f ms (%d%% free)   min: %.1f   max: %.1f",
                                    self._footerAvgHr, self._footerFreePct+0.5, self._footerMinHr, self._footerMaxHr)
    end

    y = drawHeader(self, y, font)

    y = drawColHeader(self, y + 4, font, self.sortColumn, self.sortDescending)
    self._tableHeaderY = y - 18

    for _, r in ipairs(self.rows or {}) do
        drawModRow(self, r, y, font)
        y = y + 15
    end
    self._tableBottomY = y

    local selfRow = self._cachedSelfRow
    if selfRow then
        -- Separator above self-cost row: give extra gap so the line
        -- doesn't visually merge with the last mod row's text.
        y = y + 4
        self:drawRect(10, y, self:getWidth() - 20, 1, 0.30, 0.34, 0.40, 0.40)
        y = y + 5
        drawModRow(self, selfRow, y, font)
        y = y + 15
        -- Separator below self-cost row: gap before the frame budget section.
        y = y + 3
        self:drawRect(10, y, self:getWidth() - 20, 1, 0.30, 0.34, 0.40, 0.40)
        y = y + 6
    end

    -- Unattributed gap row: shows observed CPU minus profiled mods, with trend.
    -- A rising trend here means hidden costs (GC, native, physics) are growing.
    if #(self._fmtGapLine or "") > 0 then
        -- Gap label + numbers
        self:drawText(self._fmtGapLine, 10, y, TEXT_DIM.r, TEXT_DIM.g, TEXT_DIM.b, 1, font)
        -- Trend glyphs at a fixed position near the right side
        local trendX = self:getWidth() - 80
        local g1 = self._gapShortG or "-"
        local g2 = self._gapLongG or "-"
        self:drawText("trend:", trendX - 50, y, TEXT_DIM.r, TEXT_DIM.g, TEXT_DIM.b, 1, font)
        self:drawText(g1, trendX, y, self._gapShortC.r, self._gapShortC.g, self._gapShortC.b, 1, font)
        local g1w = getTextManager():MeasureStringX(font, g1 .. " ")
        self:drawText(g2, trendX + g1w, y, self._gapLongC.r, self._gapLongC.g, self._gapLongC.b, 1, font)
        y = y + 16
        -- Second line: render sync + heap breakdown
        if #(self._fmtGapLine2 or "") > 0 then
            self:drawText(self._fmtGapLine2, 10, y, TEXT_DIM.r, TEXT_DIM.g, TEXT_DIM.b, 1, font)
            y = y + 16
        end
    end

    local gx = 10
    local gw = self:getWidth() - 20
    local available = self:getHeight() - y - 40
    local gh = math.max(80, math.min(180, math.floor(available)))
    if gh > 40 then
        y = drawBudget(self, gx, y + 6, gw, gh, font)
    end
end

---------------------------------------------------------------------------
-- Module interface
---------------------------------------------------------------------------
ModProfilerUI = ModProfilerUI or {}

local _panel

function ModProfilerUI.show()
    if not _panel then
        _panel = ModProfilerPanel:new(nil, nil, nil, nil)
        _panel:initialise()      -- ISCollapsableWindow:initialise() calls createChildren internally
        _panel:addToUIManager()
    end
    _panel:setVisible(true)
    if _panel.intervalTicks and ModProfiler.setIntervalTicks then
        ModProfiler.setIntervalTicks(_panel.intervalTicks)
    end
    local t = ModProfilerINI.load(); t.visible = "true"; ModProfilerINI.save(t)
end

function ModProfilerUI.hide()
    if _panel then _panel:setVisible(false) end
end

function ModProfilerUI.toggle()
    if _panel and _panel:getIsVisible() then
        _panel:close()
        _panel = nil
    else
        ModProfilerUI.show()
    end
end

function ModProfilerUI.getPanel() return _panel end
