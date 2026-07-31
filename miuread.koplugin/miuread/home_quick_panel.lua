local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local GestureBridge = require("miuread.gesture_bridge")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local Screen = Device.screen
local live_panel

local function face(name, nominal, maximum)
    return Font:getFace(name, math.min(maximum or nominal, Screen:scaleBySize(nominal)))
end

local OffsetContainer = WidgetContainer:extend{x_off = 0, y_off = 0}
function OffsetContainer:getSize() return self[1]:getSize() end
function OffsetContainer:paintTo(bb, x, y)
    self[1]:paintTo(bb, x + self.x_off, y + self.y_off)
end

local function fixed_frame(width, height, options, content)
    options = options or {}
    local border = tonumber(options.bordersize) or 0
    local padding = tonumber(options.padding) or 0
    local inset = border + padding
    return FrameContainer:new{
        bordersize = border,
        padding = padding,
        margin = 0,
        radius = options.radius or 0,
        background = options.background,
        color = options.color or Blitbuffer.COLOR_BLACK,
        CenterContainer:new{
            dimen = Geom:new{
                w = math.max(1, width - inset * 2),
                h = math.max(1, height - inset * 2),
            },
            content or Widget:new{dimen = Geom:new{w = 1, h = 1}},
        },
    }
end

local TapBox = InputContainer:extend{dimen = nil, callback = nil}
function TapBox:init()
    self.dimen = self.dimen or Geom:new{w = 1, h = 1}
    self.ges_events = {
        TapSelect = {GestureRange:new{ges = "tap", range = self.dimen}},
    }
end
function TapBox:getSize() return Geom:new{w = self.dimen.w, h = self.dimen.h} end
function TapBox:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    if self[1] then self[1]:paintTo(bb, x, y) end
end
function TapBox:onTapSelect()
    if self.callback then self.callback() end
    return true
end

local function tappable(width, height, child, callback)
    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        callback = callback,
    }
    tap[1] = CenterContainer:new{dimen = Geom:new{w = width, h = height}, child}
    return tap
end

local function panel_button(entry, width, height, close_callback)
    local label = tostring(entry.label or entry.text or "")
    local enabled = entry.enabled ~= false
    local content = VerticalGroup:new{
        align = "center",
        TextBoxWidget:new{
            text = label,
            face = face("cfont", 13, 16),
            bold = true,
            width = math.max(1, width - 16),
            height = math.max(24, math.floor(height * .48)),
            height_adjust = false,
            height_overflow_show_ellipsis = true,
            alignment = "center",
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        },
        TextBoxWidget:new{
            text = tostring(entry.detail or ""),
            face = face("smallinfofont", 9, 11),
            width = math.max(1, width - 16),
            height = math.max(18, math.floor(height * .28)),
            height_adjust = false,
            height_overflow_show_ellipsis = true,
            alignment = "center",
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        },
    }
    local layered = OverlapGroup:new{dimen = Geom:new{w = width, h = height}, allow_mirroring = false}
    layered[#layered + 1] = fixed_frame(width, height, {
        bordersize = 0,
        padding = math.max(5, Screen:scaleBySize(4)),
        background = Blitbuffer.COLOR_WHITE,
    }, content)
    layered[#layered + 1] = OffsetContainer:new{
        x_off = math.max(6, math.floor(width * .08)),
        y_off = math.max(0, height - Size.line.thin),
        LineWidget:new{
            background = enabled and Blitbuffer.COLOR_GRAY or (Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_GRAY),
            dimen = Geom:new{w = math.max(1, width - math.max(12, math.floor(width * .16))), h = Size.line.thin},
        },
    }
    return tappable(width, height, layered, function()
        if not enabled then return end
        if entry.keep_open ~= true and close_callback then close_callback() end
        if entry.callback then
            UIManager:nextTick(function()
                local ok, err = pcall(entry.callback)
                if not ok then logger.warn("[MiuRead][QuickPanel] action failed", tostring(err)) end
            end)
        end
    end)
end

local QuickPanelWidget = InputContainer:extend{
    name = "miuread_quick_panel",
    _miuread_transient = true,
    covers_fullscreen = true,
    stop_events_propagation = true,
    opts = nil,
    dimen = nil,
    panel_h = 0,
    _closed = false,
}

function QuickPanelWidget:handleEvent(event)
    if event and event.handler=="onGesture" then
        local ges=event.args and event.args[1]
        local gesture=ges and ges.ges
        local pointer_action=gesture=="tap" or gesture=="hold" or gesture=="hold_release"
            or gesture=="double_tap" or gesture=="two_finger_tap"
        if not pointer_action and not (ges and ges.direction=="north")
            and GestureBridge.dispatch(ges) then return true end
    end
    return InputContainer.handleEvent(self,event)
end

function QuickPanelWidget:_add(children, x, y, widget)
    children[#children + 1] = OffsetContainer:new{x_off = x, y_off = y, widget}
end

function QuickPanelWidget:_close()
    if self._closed then return end
    self._closed = true
    UIManager:close(self)
end

function QuickPanelWidget:_build()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local margin = math.max(12, math.min(22, math.floor(sw * .022)))
    local gap = math.max(7, math.min(12, math.floor(sh * .008)))
    local buttons = type(self.opts.buttons) == "table" and self.opts.buttons or {}
    local columns = sw < sh and 3 or 4
    local rows = math.max(1, math.ceil(#buttons / columns))
    local title_h = math.max(54, math.min(68, math.floor(sh * .055)))
    local status_h = (self.opts.status_text and self.opts.status_text ~= "") and math.max(38, math.min(48, math.floor(sh * .038))) or 0
    local button_h = math.max(62, math.min(78, math.floor(sh * .060)))
    self.panel_h = math.min(sh - margin, margin * 2 + title_h + status_h + gap * (rows + 2) + button_h * rows)
    self.dimen = Geom:new{x = 0, y = 0, w = sw, h = sh}
    self.panel_dimen = Geom:new{x = 0, y = 0, w = sw, h = self.panel_h}

    self.ges_events = {
        TapDismiss = {GestureRange:new{ges = "tap", range = self.dimen}},
        SwipeDismiss = {GestureRange:new{ges = "swipe", range = self.dimen}},
    }

    local children = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    self:_add(children, 0, 0, fixed_frame(sw, self.panel_h, {
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
    }))

    local close_w = math.max(66, math.min(82, math.floor(sw * .09)))
    local title_w = math.max(1, sw - margin * 2 - close_w - gap)
    local title_row = HorizontalGroup:new{
        align = "center",
        LeftContainer:new{dimen = Geom:new{w = title_w, h = title_h}, VerticalGroup:new{
            align = "left",
            TextBoxWidget:new{
                text = tostring(self.opts.title or "快捷控制"),
                face = face("cfont", 18, 22),
                bold = true,
                width = title_w,
                height = math.floor(title_h * .55),
                height_adjust = false,
                height_overflow_show_ellipsis = true,
            },
            TextBoxWidget:new{
                text = tostring(self.opts.subtitle or ""),
                face = face("smallinfofont", 10, 12),
                width = title_w,
                height = math.ceil(title_h * .45),
                height_adjust = false,
                height_overflow_show_ellipsis = true,
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            },
        }},
        HorizontalSpan:new{width = gap},
        tappable(close_w, math.max(36, title_h - 10), fixed_frame(close_w, math.max(36, title_h - 10), {
            bordersize = 0,
            background = Blitbuffer.COLOR_WHITE,
        }, TextWidget:new{text = "收起", face = face("smallinfofont", 11, 13), bold = true}), function() self:_close() end),
    }
    self:_add(children, margin, margin, title_row)

    local y = margin + title_h + gap
    self:_add(children, margin, y,
        LineWidget:new{background = Blitbuffer.COLOR_GRAY, dimen = Geom:new{w = sw - margin * 2, h = Size.line.thin}})
    y = y + Size.line.thin + gap

    local button_gap = math.max(7, gap)
    local button_w = math.floor((sw - margin * 2 - button_gap * (columns - 1)) / columns)
    for index, entry in ipairs(buttons) do
        local row = math.floor((index - 1) / columns)
        local col = (index - 1) % columns
        self:_add(children,
            margin + col * (button_w + button_gap),
            y + row * (button_h + button_gap),
            panel_button(entry, button_w, button_h, function() self:_close() end))
    end
    y = y + rows * button_h + math.max(0, rows - 1) * button_gap + gap

    if status_h > 0 and y + status_h <= self.panel_h - gap then
        self:_add(children, margin, y, fixed_frame(sw - margin * 2, status_h, {
            bordersize = 0,
            padding = math.max(5, Screen:scaleBySize(4)),
            background = Blitbuffer.COLOR_WHITE,
        }, TextBoxWidget:new{
            text = tostring(self.opts.status_text or ""),
            face = face("smallinfofont", 10, 12),
            width = sw - margin * 2 - 20,
            height = status_h - 12,
            height_adjust = false,
            height_overflow_show_ellipsis = true,
            alignment = "left",
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }))
    end

    self:_add(children, 0, self.panel_h - Size.line.thick,
        LineWidget:new{background = Blitbuffer.COLOR_BLACK, dimen = Geom:new{w = sw, h = Size.line.thick}})
    self[1] = children
end

function QuickPanelWidget:init()
    self:_build()
end

function QuickPanelWidget:onTapDismiss(_, ges)
    if not (ges and ges.pos) then return false end
    if ges.pos.y > self.panel_h then
        self:_close()
        return true
    end
    -- Let the matching child button receive the tap. The fullscreen panel's
    -- stop_events_propagation still prevents taps from reaching FileManager.
    return false
end

function QuickPanelWidget:onSwipeDismiss(_, ges)
    if ges and ges.direction == "north" then
        self:_close()
        return true
    end
    return false
end

function QuickPanelWidget:onBack()
    self:_close()
    return true
end

function QuickPanelWidget:onShow()
    UIManager:setDirty(self,function() return "ui",self.panel_dimen end)
end

function QuickPanelWidget:onCloseWidget()
    local region=self.panel_dimen and self.panel_dimen:copy() or nil
    self._closed = true
    if live_panel == self then live_panel = nil end
    if region then UIManager:setDirty(nil,function() return "ui",region end) end
end

local QuickPanel = {}
function QuickPanel.close()
    if live_panel and not live_panel._closed then UIManager:close(live_panel) end
    live_panel = nil
end
function QuickPanel.show(opts)
    QuickPanel.close()
    local ok, panel = pcall(QuickPanelWidget.new, QuickPanelWidget, {opts = opts or {}})
    if not ok or not panel then
        logger.warn("[MiuRead][QuickPanel] build failed", tostring(panel))
        return nil, tostring(panel)
    end
    live_panel = panel
    UIManager:show(panel, "ui", panel.panel_dimen)
    return panel
end
return QuickPanel
