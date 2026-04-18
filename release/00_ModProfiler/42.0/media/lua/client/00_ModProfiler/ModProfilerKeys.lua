-- ModProfilerKeys.lua
-- F9 toggles the overlay. Re-bindable later via PZ key-binding system if desired.

require "00_ModProfiler/ModProfilerUI"

local TOGGLE_KEY = Keyboard.KEY_F9

local function onKeyPressed(key)
    if key == TOGGLE_KEY and ModProfilerUI and ModProfilerUI.toggle then
        ModProfilerUI.toggle()
    end
end

Events.OnKeyPressed.Add(onKeyPressed)

print("[MODPROFILER] UI installed — press F9 to toggle overlay")
