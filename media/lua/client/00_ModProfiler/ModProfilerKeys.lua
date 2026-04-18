-- ModProfilerKeys.lua
-- Registers key bindings for overlay toggle and profiling toggle.
-- Both bindings are configurable via Options → Key Bindings (look for
-- the "[Mod Profiler]" category).

if not ModProfiler then return end

local BIND_OVERLAY  = "ModProfiler: Toggle Overlay"
local BIND_PROFILE  = "ModProfiler: Toggle Profiling"

-- Register the binding category + two actions. The keyBinding global
-- is consumed by PZ's options screen to populate the Key Bindings UI.
if keyBinding then
    table.insert(keyBinding, { value = "[Mod Profiler]" })
    table.insert(keyBinding, { value = BIND_OVERLAY, key = Keyboard.KEY_F8 })
    table.insert(keyBinding, { value = BIND_PROFILE, key = Keyboard.KEY_F12 })
end

local function onKeyPressed(key)
    if key == getCore():getKey(BIND_OVERLAY) then
        if ModProfilerUI then ModProfilerUI.toggle() end
    elseif key == getCore():getKey(BIND_PROFILE) then
        ModProfiler.setEnabled(not ModProfiler.isEnabled())
    end
end

-- Register via registerUnwrapped so the key handler doesn't self-measure.
-- OnKeyPressed isn't in the PROFILED_EVENTS list so this is belt-and-braces,
-- but consistent with ModProfilerUI.
ModProfiler.registerUnwrapped("OnKeyPressed", onKeyPressed)
