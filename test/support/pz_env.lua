-- test/support/pz_env.lua
-- Minimal stubs for PZ Kahlua APIs so we can exercise ModProfiler.lua in
-- plain Lua 5.1/5.3. Goal: catch "Tried to call nil" and bad math before
-- redeploying to PZ.

local M = {}

local _now = 0
function _G.getTimestampMs() return _now end
function M.advanceMs(n) _now = _now + n end
function M.setMs(n) _now = n end

-- Event system: minimal Add/Remove + trigger.
local _events = {}
local function eventSlot(name)
    if not _events[name] then _events[name] = { handlers = {} } end
    local slot = _events[name]
    if not slot.Add then
        function slot.Add(fn) slot.handlers[#slot.handlers+1] = fn end
        function slot.Remove(fn)
            for i, h in ipairs(slot.handlers) do
                if h == fn then table.remove(slot.handlers, i); return end
            end
        end
    end
    return slot
end
_G.Events = setmetatable({}, { __index = function(_, k) return eventSlot(k) end })
function M.trigger(name, ...)
    local slot = _events[name]; if not slot then return end
    for _, h in ipairs(slot.handlers) do h(...) end
end

-- Closure introspection: fake source attribution so extractModName runs.
_G.getFilenameOfClosure = function(_) return "media/lua/shared/TestMod/Main.lua" end
_G.getFirstLineOfClosure = function(_) return 42 end

-- Performance / CPU — configurable to exercise missing-method paths.
local perfMock  -- nil | { getFramerate = fn, isFramerateUncapped? = fn, ... }
function M.setPerformance(mock) perfMock = mock end
_G.getPerformance = function() return perfMock end

-- cpuMock can be:
--   nil             — getCPUTime returns nil (simulating missing API)
--   number          — every call returns the same value
--   function        — called with no args each tick; caller drives the stream
local cpuMock
function M.setCPU(v) cpuMock = v end
_G.getCPUTime = function()
    if type(cpuMock) == "function" then return cpuMock() end
    return cpuMock
end

-- Harness helper: returns a CPU-stream function that yields `baseline` on
-- every call EXCEPT a single spike of `spike` on call index `spikeAtIdx`.
-- Used to verify that interval reports average the stream rather than
-- taking an instant sample (which would bias hard toward the spike).
function M.cpuSpikeStream(baseline, spike, spikeAtIdx)
    local i = 0
    return function()
        i = i + 1
        if i == spikeAtIdx then return spike end
        return baseline
    end
end

-- Harness helpers
function M.defaultPerfFull()
    return {
        getFramerate         = function(self) return 60 end,
        isFramerateUncapped  = function(self) return false end,
    }
end
function M.perfMissingUncapped()
    -- Simulates PZ builds where isFramerateUncapped and getUncappedFrameRate
    -- are both nil on the Performance object.
    return { getFramerate = function(self) return 60 end }
end
function M.perfCompletelyMissing() return nil end

return M
