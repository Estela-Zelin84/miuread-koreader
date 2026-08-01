local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
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
local live_toolbar

local function face(name, nominal, maximum)
    return Font:getFace(name, math.min(maximum or nominal, Screen:scaleBySize(nominal)))
end

local OffsetContainer = WidgetContainer:extend{x_off = 0, y_off = 0}
function OffsetContainer:getSize() return self[1]:getSize() end
function OffsetContainer:paintTo(bb, x, y)
    self[1]:paintTo(bb, x + self.x_off, y + self.y_off)
end

local TapBox = InputContainer:extend{dimen = nil, callback = nil, enabled = true}
function TapBox:init()
    self.dimen = self.dimen or Geom:new{w = 1, h = 1}
    self.ges_events = {TapSelect = {GestureRange:new{ges = "tap", range = self.dimen}}}
end
function TapBox:getSize() return Geom:new{w = self.dimen.w, h = self.dimen.h} end
function TapBox:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    if self[1] then self[1]:paintTo(bb, x, y) end
end
function TapBox:onTapSelect()
    if self.enabled ~= false and self.callback then self.callback() end
    return true
end
function TapBox:handleEvent(event)
    return InputContainer.handleEvent(self, event)
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
        radius = 0,
        background = options.background or Blitbuffer.COLOR_WHITE,
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

local function action_button(entry, width, height, close_callback)
    local enabled = entry.enabled ~= false
    local padding = math.max(6, Screen:scaleBySize(5))
    local inner_w = math.max(1, width - padding * 2)
    local inner_h = math.max(1, height - padding * 2)
    local detail = tostring(entry.detail or "")
    local label_h = detail ~= "" and math.max(22, math.floor(inner_h * .54)) or inner_h
    local detail_h = math.max(1, inner_h - label_h)

    local content = VerticalGroup:new{
        align = "center",
        TextBoxWidget:new{
            text = tostring(entry.label or entry.text or ""),
            face = face("cfont", 13, 16),
            bold = true,
            width = inner_w,
            height = label_h,
            height_adjust = false,
            height_overflow_show_ellipsis = true,
            alignment = "center",
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        },
    }
    if detail ~= "" then
        content[#content + 1] = TextBoxWidget:new{
            text = detail,
            face = face("smallinfofont", 9, 11),
            width = inner_w,
            height = detail_h,
            height_adjust = false,
            height_overflow_show_ellipsis = true,
            alignment = "center",
            fgcolor = enabled and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_GRAY,
        }
    end

    local layered = OverlapGroup:new{dimen = Geom:new{w = width, h = height}, allow_mirroring = false}
    layered[#layered + 1] = fixed_frame(width, height, {
        bordersize = 0,
        padding = padding,
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
    local box = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        enabled = enabled,
        callback = function()
            if entry.keep_open == true then
                if entry.callback then
                    UIManager:nextTick(function()
                        local ok, err = pcall(entry.callback)
                        if not ok then logger.warn("[MiuRead][ReaderToolbar] action failed", tostring(err)) end
                    end)
                end
                return
            end
            close_callback(entry.callback)
        end,
    }
    box[1] = layered
    return box
end

local Toolbar = InputContainer:extend{
    name = "miuread_reader_toolbar",
    _miuread_transient = true,
    covers_fullscreen = true,
    stop_events_propagation = true,
    opts = nil,
    closed = false,
    pending_action = nil,
}

function Toolbar:handleEvent(event)
    return InputContainer.handleEvent(self, event)
end

function Toolbar:_close(action, cancel_pending)
    if cancel_pending then
        self.pending_action = nil
    elseif action and not self.pending_action then
        self.pending_action = action
    end
    if self.closed then return true end
    self.closed = true
    UIManager:close(self)
    return true
end

function Toolbar:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local margin = math.max(10, math.min(18, math.floor(sw * .017)))
    local gap = math.max(6, math.min(10, math.floor(sh * .006)))
    local buttons = type(self.opts.buttons) == "table" and self.opts.buttons or {}
    local columns = math.max(1, math.min(4, tonumber(self.opts.columns) or 4))
    local rows = math.max(1, math.ceil(math.max(1, #buttons) / columns))
    local title_h = math.max(48, math.min(62, math.floor(sh * .046)))
    local button_h = math.max(58, math.min(72, math.floor(sh * .052)))
    local close_w = math.max(58, math.min(76, math.floor(sw * .075)))
    local usable_w = sw - margin * 2
    local button_w = math.max(1, math.floor((usable_w - gap * (columns - 1)) / columns))

    self.panel_h = margin * 2 + title_h + Size.line.thin + gap + rows * button_h + math.max(0, rows - 1) * gap
    self.dimen = Geom:new{x = 0, y = 0, w = sw, h = sh}
    self.panel_dimen = Geom:new{x = 0, y = 0, w = sw, h = self.panel_h}
    self.ges_events = {
        TapDismiss = {GestureRange:new{ges = "tap", range = self.dimen}},
        SwipeDismiss = {GestureRange:new{ges = "swipe", range = self.dimen}},
    }
    if Device:hasKeys() and Device.input and Device.input.group and Device.input.group.Back then
        self.key_events = {Close = {{Device.input.group.Back}}}
    end

    local root = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    root[#root + 1] = fixed_frame(sw, self.panel_h, {background = Blitbuffer.COLOR_WHITE})

    local title_w = math.max(1, usable_w - close_w - gap)
    local title_row = HorizontalGroup:new{
        align = "center",
        LeftContainer:new{
            dimen = Geom:new{w = title_w, h = title_h},
            VerticalGroup:new{
                align = "left",
                TextBoxWidget:new{
                    text = tostring(self.opts.title or "阅读快捷面板"),
                    face = face("cfont", 17, 21),
                    bold = true,
                    width = title_w,
                    height = math.floor(title_h * .56),
                    height_adjust = false,
                    height_overflow_show_ellipsis = true,
                    alignment = "left",
                },
                TextBoxWidget:new{
                    text = tostring(self.opts.subtitle or ""),
                    face = face("smallinfofont", 9, 11),
                    width = title_w,
                    height = math.ceil(title_h * .44),
                    height_adjust = false,
                    height_overflow_show_ellipsis = true,
                    alignment = "left",
                    fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                },
            },
        },
        HorizontalSpan:new{width = gap},
        TapBox:new{
            dimen = Geom:new{w = close_w, h = math.max(34, title_h - 8)},
            callback = function() self:_close() end,
            fixed_frame(close_w, math.max(34, title_h - 8), {
                bordersize = Size.border.thin,
                background = Blitbuffer.COLOR_WHITE,
            }, TextWidget:new{
                text = "收起",
                face = face("smallinfofont", 10, 12),
                bold = true,
            }),
        },
    }
    root[#root + 1] = OffsetContainer:new{x_off = margin, y_off = margin, title_row}
    root[#root + 1] = OffsetContainer:new{
        x_off = margin,
        y_off = margin + title_h,
        LineWidget:new{
            background = Blitbuffer.COLOR_GRAY,
            dimen = Geom:new{w = usable_w, h = Size.line.thin},
        },
    }

    local start_y = margin + title_h + Size.line.thin + gap
    for index, entry in ipairs(buttons) do
        local row = math.floor((index - 1) / columns)
        local col = (index - 1) % columns
        root[#root + 1] = OffsetContainer:new{
            x_off = margin + col * (button_w + gap),
            y_off = start_y + row * (button_h + gap),
            action_button(entry, button_w, button_h, function(action) self:_close(action) end),
        }
    end

    root[#root + 1] = OffsetContainer:new{
        x_off = 0,
        y_off = self.panel_h - Size.line.thin,
        LineWidget:new{
            background = Blitbuffer.COLOR_BLACK,
            dimen = Geom:new{w = sw, h = Size.line.thin},
        },
    }
    self[1] = root
end

function Toolbar:onTapDismiss(_, ges)
    local pos = ges and ges.pos
    if pos and pos.y > self.panel_h then return self:_close() end
    return false
end

function Toolbar:onSwipeDismiss(_, ges)
    if ges and ges.direction == "north" then return self:_close() end
    return false
end

function Toolbar:onClose() return self:_close() end
function Toolbar:onShow()
    UIManager:setDirty(self, function() return "ui", self.panel_dimen end)
end
function Toolbar:onCloseWidget()
    local region = self.panel_dimen and self.panel_dimen:copy() or nil
    local action = self.pending_action
    self.pending_action = nil
    self.closed = true
    if live_toolbar == self then live_toolbar = nil end
    if region then UIManager:setDirty(nil, function() return "ui", region end) end
    if action then
        UIManager:scheduleIn(.04, function()
            local ok, err = pcall(action)
            if not ok then logger.warn("[MiuRead][ReaderToolbar] action failed", tostring(err)) end
        end)
    end
end

local M = {}
function M.close()
    if live_toolbar and not live_toolbar.closed then live_toolbar:_close(nil, true) end
    live_toolbar = nil
end
function M.show(opts)
    M.close()
    local ok, toolbar = pcall(Toolbar.new, Toolbar, {opts = opts or {}})
    if not ok or not toolbar then return nil, tostring(toolbar) end
    live_toolbar = toolbar
    UIManager:show(toolbar, "ui", toolbar.panel_dimen)
    return toolbar
end
return M
