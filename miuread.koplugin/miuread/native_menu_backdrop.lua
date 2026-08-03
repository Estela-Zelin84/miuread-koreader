local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")

local Screen = Device.screen
local live_backdrop

local BackdropWidget = InputContainer:extend{
    name = "miuread_native_menu_backdrop",
    covers_fullscreen = true,
    stop_events_propagation = true,
    _miuread_native_backdrop = true,
    _closed = false,
}

function BackdropWidget:_build()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{x = 0, y = 0, w = sw, h = sh}
    self[1] = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{w = sw, h = sh},
            Widget:new{dimen = Geom:new{w = 1, h = 1}},
        },
    }
end

function BackdropWidget:init()
    self:_build()
end

function BackdropWidget:onSetDimensions()
    self:_build()
    UIManager:setDirty(self, "full")
    return true
end
function BackdropWidget:onScreenResize() return self:onSetDimensions() end
function BackdropWidget:onRotation() return self:onSetDimensions() end
function BackdropWidget:onBack() return true end
function BackdropWidget:onHome() return true end
function BackdropWidget:onCloseWidget()
    self._closed = true
    if live_backdrop == self then live_backdrop = nil end
end

local Backdrop = {}
function Backdrop.current() return live_backdrop end
function Backdrop.is_shown()
    return live_backdrop and not live_backdrop._closed and UIManager:isWidgetShown(live_backdrop)
end
function Backdrop.close()
    local current = live_backdrop
    live_backdrop = nil
    if current and not current._closed and UIManager:isWidgetShown(current) then
        UIManager:close(current)
    end
end
function Backdrop.show()
    if Backdrop.is_shown() then return live_backdrop end
    Backdrop.close()
    local ok, widget = pcall(BackdropWidget.new, BackdropWidget, {})
    if not ok or not widget then return nil, tostring(widget) end
    live_backdrop = widget
    UIManager:show(widget, "ui", widget.dimen)
    return widget
end

return Backdrop
