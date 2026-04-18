local Env = {}

local PROFILED_EVENTS = {
    "OnTick",
    "OnTickEvenPaused",
    "OnPlayerUpdate",
    "OnRenderUpdate",
    "OnRenderTick",
    "OnPreUIDraw",
    "OnPostUIDraw",
    "EveryOneMinute",
    "EveryTenMinutes",
    "EveryHours",
    "LoadGridsquare",
    "ReuseGridsquare",
    "OnCharacterCollide",
    "OnPlayerMove",
    "OnGameStart",
    "OnGameBoot",
    "OnCreatePlayer",
    "OnInitWorld",
    "OnPreMapLoad",
    "OnPostMapLoad",
    "OnClimateTick",
    "OnRefreshInventoryWindowContainers",
    "OnFillInventoryObjectContextMenu",
    "OnFillWorldObjectContextMenu",
    "OnKeyPressed",
}

local closureInfo = setmetatable({}, { __mode = "k" })
local nowMs = 0
local cpuMs = 0
local averageFps = 60
local performance = nil
local screenWidth = 1920
local screenHeight = 1080
local clipboardText = ""

local function tempFilePath(name)
    return "test/__tmp_" .. tostring(name)
end

local function fontWidth(font)
    if font == "DebugConsole" then return 6 end
    if font == "Medium" then return 9 end
    if font == "Large" then return 12 end
    return 7
end

local function fontHeight(font)
    if font == "DebugConsole" then return 10 end
    if font == "Medium" then return 16 end
    if font == "Large" then return 20 end
    return 12
end

local function makeTextManager()
    local manager = {}
    function manager:MeasureStringX(font, text)
        return #tostring(text or "") * fontWidth(font)
    end
    function manager:MeasureStringY(font, _text)
        return fontHeight(font)
    end
    return manager
end

local function cloneTable(source)
    local out = {}
    for key, value in pairs(source) do
        out[key] = value
    end
    return out
end

local function makeUIClasses()
    local BaseWindow = {}

    function BaseWindow:derive(name)
        local cls = cloneTable(self)
        cls.Type = name
        cls.__index = cls
        return cls
    end

    function BaseWindow:new(x, y, w, h)
        local o = {
            x = x or 0,
            y = y or 0,
            width = w or 0,
            height = h or 0,
            title = "",
            children = {},
            visible = true,
            _drawCalls = {},
        }
        setmetatable(o, self)
        self.__index = self
        return o
    end

    function BaseWindow:initialise() end
    function BaseWindow:createChildren()
        self.resizeWidget = { resizeFunction = nil }
    end
    function BaseWindow:prerender()
        self._drawCalls = {}
    end
    function BaseWindow:render() end
    function BaseWindow:onMouseDown(_x, _y) end
    function BaseWindow:onRightMouseDown(_x, _y) end
    function BaseWindow:setTitle(title) self.title = title end
    function BaseWindow:titleBarHeight() return 18 end
    function BaseWindow:addChild(child) self.children[#self.children + 1] = child end
    function BaseWindow:addToUIManager() self.addedToUIManager = true end
    function BaseWindow:removeFromUIManager() self.addedToUIManager = false end
    function BaseWindow:setVisible(flag) self.visible = flag and true or false end
    function BaseWindow:getWidth() return self.width end
    function BaseWindow:getHeight() return self.height end
    function BaseWindow:getX() return self.x end
    function BaseWindow:getY() return self.y end
    function BaseWindow:setWidth(value) self.width = value end
    function BaseWindow:setHeight(value) self.height = value end
    function BaseWindow:setX(value) self.x = value end
    function BaseWindow:setY(value) self.y = value end
    function BaseWindow:close() self.closed = true end
    function BaseWindow:drawText(text, x, y, r, g, b, a, font)
        self._drawCalls[#self._drawCalls + 1] = {
            kind = "text",
            text = tostring(text),
            x = x,
            y = y,
            r = r,
            g = g,
            b = b,
            a = a,
            font = font,
        }
    end
    function BaseWindow:drawRect(x, y, w, h, a, r, g, b)
        self._drawCalls[#self._drawCalls + 1] = {
            kind = "rect",
            x = x,
            y = y,
            w = w,
            h = h,
            a = a,
            r = r,
            g = g,
            b = b,
        }
    end

    local ComboBox = {}
    function ComboBox:new(x, y, w, h, parent, onChange)
        local o = {
            x = x or 0,
            y = y or 0,
            width = w or 0,
            height = h or 0,
            parent = parent,
            onChange = onChange,
            options = {},
            selected = 1,
            visible = true,
        }
        setmetatable(o, self)
        self.__index = self
        return o
    end
    function ComboBox:initialise() end
    function ComboBox:addOption(label) self.options[#self.options + 1] = label end
    function ComboBox:setX(value) self.x = value end
    function ComboBox:setY(value) self.y = value end
    function ComboBox:setWidth(value) self.width = value end
    function ComboBox:setVisible(flag) self.visible = flag and true or false end

    return BaseWindow, ComboBox
end

local function stringify(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring(select(i, ...))
    end
    return table.concat(parts, "\t")
end

local function makeEvent()
    local listeners = {}
    return {
        _listeners = listeners,
        Add = function(fn)
            listeners[#listeners + 1] = fn
        end,
        Remove = function(fn)
            for i = #listeners, 1, -1 do
                if listeners[i] == fn then
                    table.remove(listeners, i)
                    break
                end
            end
        end,
    }
end

local function installGlobals()
    _G.ModProfiler = nil
    _G.ModProfilerUI = nil
    _G.ModProfilerPanel = nil
    _G.Events = {}
    for _, name in ipairs(PROFILED_EVENTS) do
        _G.Events[name] = makeEvent()
    end

    _G.print = function(...)
        Env.outputs[#Env.outputs + 1] = stringify(...)
    end

    _G.getTimestampMs = function()
        return nowMs
    end

    _G.getCPUTime = function()
        return cpuMs
    end

    _G.getAverageFPS = function()
        return averageFps
    end

    _G.UIFont = {
        DebugConsole = "DebugConsole",
        Small = "Small",
        Medium = "Medium",
        Large = "Large",
    }

    local textManager = makeTextManager()
    _G.getTextManager = function()
        return textManager
    end

    performance = { framerate = 60, uncapped = false }
    function performance:getFramerate()
        return self.framerate
    end
    function performance:isFramerateUncapped()
        return self.uncapped
    end

    _G.getPerformance = function()
        return performance
    end

    local core = {}
    function core:getScreenWidth()
        return screenWidth
    end
    function core:getScreenHeight()
        return screenHeight
    end
    _G.getCore = function()
        return core
    end

    _G.Clipboard = {
        setClipboard = function(value)
            clipboardText = tostring(value)
        end,
    }

    _G.getFileReader = function(name, _create)
        local handle = io.open(tempFilePath(name), "r")
        if not handle then return nil end
        return {
            readLine = function()
                return handle:read("*l")
            end,
            close = function()
                handle:close()
            end,
        }
    end

    _G.getFileWriter = function(name, _append, _binary)
        local handle = assert(io.open(tempFilePath(name), "w"))
        return {
            write = function(_, text)
                handle:write(text)
            end,
            close = function()
                handle:close()
            end,
        }
    end

    local BaseWindow, ComboBox = makeUIClasses()
    _G.ISCollapsableWindow = BaseWindow
    _G.ISComboBox = ComboBox
    package.loaded["ISUI/ISCollapsableWindow"] = nil
    package.loaded["ISUI/ISComboBox"] = nil
    package.preload["ISUI/ISCollapsableWindow"] = function()
        return _G.ISCollapsableWindow
    end
    package.preload["ISUI/ISComboBox"] = function()
        return _G.ISComboBox
    end

    _G.getFilenameOfClosure = function(fn)
        local info = closureInfo[fn]
        return info and info.file or "unknown"
    end

    _G.getFirstLineOfClosure = function(fn)
        local info = closureInfo[fn]
        return info and info.line or 0
    end
end

function Env.reset()
    closureInfo = setmetatable({}, { __mode = "k" })
    nowMs = 0
    cpuMs = 0
    averageFps = 60
    screenWidth = 1920
    screenHeight = 1080
    clipboardText = ""
    Env.outputs = {}
    os.remove(tempFilePath("ModProfiler.ini"))
    installGlobals()
    return Env
end

function Env.advanceMs(delta)
    nowMs = nowMs + delta
end

function Env.setNowMs(value)
    nowMs = value
end

function Env.setCpuTime(value)
    cpuMs = value
end

function Env.setAverageFPS(value)
    averageFps = value
end

function Env.setPerformance(framerate, uncapped)
    performance.framerate = framerate
    performance.uncapped = uncapped == true
end

function Env.setScreenSize(width, height)
    screenWidth = width
    screenHeight = height
end

function Env.annotateCallback(fn, filePath, lineNumber)
    closureInfo[fn] = { file = filePath, line = lineNumber or 1 }
    return fn
end

function Env.getClipboard()
    return clipboardText
end

function Env.readTempFile(name)
    local handle = io.open(tempFilePath(name), "r")
    if not handle then return nil end
    local text = handle:read("*a")
    handle:close()
    return text
end

function Env.fire(eventName, ...)
    local event = assert(_G.Events[eventName], "unknown event: " .. tostring(eventName))
    local snapshot = {}
    for i = 1, #event._listeners do
        snapshot[i] = event._listeners[i]
    end
    for i = 1, #snapshot do
        snapshot[i](...)
    end
end

function Env.loadModProfiler(path)
    local source = path or "media/lua/shared/00_ModProfiler/ModProfiler.lua"
    _G.ModProfiler = nil
    local chunk, err = loadfile(source)
    if not chunk then error(err) end
    chunk()
    return assert(_G.ModProfiler, "ModProfiler global was not created")
end

function Env.loadModProfilerUI(path)
    local source = path or "media/lua/client/00_ModProfiler/ModProfilerUI.lua"
    _G.ModProfilerUI = nil
    local chunk, err = loadfile(source)
    if not chunk then error(err) end
    chunk()
    return assert(_G.ModProfilerUI, "ModProfilerUI global was not created")
end

Env.reset()

return Env
