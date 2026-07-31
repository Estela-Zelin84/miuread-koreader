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
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local Screen = Device.screen

local TapBox = InputContainer:extend{dimen = nil, callback = nil}
function TapBox:init()
    self.dimen = self.dimen or Geom:new{w = 1, h = 1}
    self.ges_events = {TapSelect = {GestureRange:new{ges = "tap", range = self.dimen}}}
end
function TapBox:getSize() return Geom:new{w = self.dimen.w, h = self.dimen.h} end
function TapBox:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    if self[1] then self[1]:paintTo(bb, x, y) end
end
function TapBox:onTapSelect(_, ges)
    if self.callback then self.callback(ges) end
    return true
end
function TapBox:handleEvent(event)
    return InputContainer.handleEvent(self, event)
end

local ProgressTap = TapBox:extend{}
function ProgressTap:onTapSelect(_, ges)
    local pos = ges and ges.pos
    if not pos then return true end
    local ratio = (pos.x - self.dimen.x) / math.max(1, self.dimen.w)
    ratio = math.max(0, math.min(1, ratio))
    if self.callback then self.callback(ratio * 100) end
    return true
end

local function button(label, width, height, callback, primary)
    local border = primary and Size.border.window or Size.border.thin
    local inner_w = math.max(1, width - border * 2)
    local inner_h = math.max(1, height - border * 2)
    local box = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        callback = callback,
    }
    box[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = border,
        padding = 0,
        margin = 0,
        CenterContainer:new{
            dimen = Geom:new{w = inner_w, h = inner_h},
            TextBoxWidget:new{
                text = tostring(label or ""),
                face = Font:getFace("cfont", math.max(13, Screen:scaleBySize(14))),
                bold = primary == true,
                width = math.max(1, inner_w - 8),
                height = inner_h,
                height_adjust = false,
                height_overflow_show_ellipsis = true,
                alignment = "center",
            },
        },
    }
    return box
end

local Dialog = InputContainer:extend{
    name = "miuread_reader_progress_dialog",
    _miuread_transient = true,
    covers_fullscreen = true,
    stop_events_propagation = true,
    percent = 0,
    on_goto_percent = nil,
    on_adjust = nil,
    on_jump = nil,
    closed = false,
}

function Dialog:handleEvent(event)
    return InputContainer.handleEvent(self, event)
end
function Dialog:_close()
    if self.closed then return true end
    self.closed = true
    UIManager:close(self)
    return true
end

function Dialog:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local width = math.max(math.floor(sw * .72), math.min(math.floor(sw * .84), Screen:scaleBySize(760)))
    width = math.min(width, sw - math.max(28, math.floor(sw * .06)))
    local border = Size.border.window
    local pad = math.max(12, Screen:scaleBySize(10))
    local gap = math.max(8, Screen:scaleBySize(7))
    local title_h = math.max(38, Screen:scaleBySize(36))
    local percent_h = math.max(28, Screen:scaleBySize(26))
    local progress_h = math.max(44, Screen:scaleBySize(42))
    local hint_h = math.max(26, Screen:scaleBySize(24))
    local row_h = math.max(52, Screen:scaleBySize(50))
    local row_gap = math.max(8, Screen:scaleBySize(7))
    local content_h = title_h + percent_h + gap + progress_h + hint_h + gap + row_h + row_gap + row_h
    local height = content_h + (border + pad) * 2
    height = math.min(height, sh - math.max(36, math.floor(sh * .08)))

    self.dimen = Geom:new{x = 0, y = 0, w = sw, h = sh}
    self.frame_dimen = Geom:new{
        x = math.floor((sw - width) / 2),
        y = math.floor((sh - height) / 2),
        w = width,
        h = height,
    }
    if Device:isTouchDevice() then
        self.ges_events = {TapDismiss = {GestureRange:new{ges = "tap", range = self.dimen}}}
    end
    if Device:hasKeys() and Device.input and Device.input.group and Device.input.group.Back then
        self.key_events = {Close = {{Device.input.group.Back}}}
    end

    local content_w = width - (border + pad) * 2
    local group = VerticalGroup:new{align = "center"}
    group[#group + 1] = TextBoxWidget:new{
        text = "阅读进度",
        face = Font:getFace("cfont", math.max(16, Screen:scaleBySize(18))),
        bold = true,
        width = content_w,
        height = title_h,
        height_adjust = false,
        alignment = "center",
    }
    group[#group + 1] = TextBoxWidget:new{
        text = tostring(math.floor((tonumber(self.percent) or 0) + .5)) .. "%",
        face = Font:getFace("cfont", math.max(14, Screen:scaleBySize(16))),
        bold = true,
        width = content_w,
        height = percent_h,
        height_adjust = false,
        alignment = "center",
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }
    group[#group + 1] = VerticalSpan:new{height = gap}

    self.progress = ProgressWidget:new{
        width = content_w,
        height = math.max(18, Screen:scaleBySize(18)),
        percentage = math.max(0, math.min(1, (tonumber(self.percent) or 0) / 100)),
        fillcolor = Blitbuffer.COLOR_BLACK,
        padding = Size.padding.small,
        margin = 0,
    }
    local progress_tap = ProgressTap:new{
        dimen = Geom:new{w = content_w, h = progress_h},
        callback = function(target)
            self:_close()
            if self.on_goto_percent then
                UIManager:nextTick(function() self.on_goto_percent(target) end)
            end
        end,
    }
    progress_tap[1] = CenterContainer:new{dimen = progress_tap.dimen:copy(), self.progress}
    group[#group + 1] = progress_tap
    group[#group + 1] = TextBoxWidget:new{
        text = "点击进度条直接跳转",
        face = Font:getFace("smallinfofont", math.max(9, Screen:scaleBySize(10))),
        width = content_w,
        height = hint_h,
        height_adjust = false,
        alignment = "center",
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }
    group[#group + 1] = VerticalSpan:new{height = gap}

    local function adjust(delta)
        self:_close()
        if self.on_adjust then UIManager:nextTick(function() self.on_adjust(delta) end) end
    end
    local function jump()
        self:_close()
        if self.on_jump then UIManager:nextTick(self.on_jump) end
    end

    local small_gap = math.max(6, Screen:scaleBySize(5))
    local small_w = math.floor((content_w - small_gap * 3) / 4)
    group[#group + 1] = HorizontalGroup:new{
        align = "center",
        button("−5%", small_w, row_h, function() adjust(-5) end),
        HorizontalSpan:new{width = small_gap},
        button("−1%", small_w, row_h, function() adjust(-1) end),
        HorizontalSpan:new{width = small_gap},
        button("+1%", small_w, row_h, function() adjust(1) end),
        HorizontalSpan:new{width = small_gap},
        button("+5%", small_w, row_h, function() adjust(5) end),
    }
    group[#group + 1] = VerticalSpan:new{height = row_gap}
    local wide_gap = math.max(8, Screen:scaleBySize(7))
    local wide_w = math.floor((content_w - wide_gap) / 2)
    group[#group + 1] = HorizontalGroup:new{
        align = "center",
        button("输入位置", wide_w, row_h, jump, true),
        HorizontalSpan:new{width = wide_gap},
        button("关闭", wide_w, row_h, function() self:_close() end, false),
    }

    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = border,
        padding = pad,
        margin = 0,
        CenterContainer:new{
            dimen = Geom:new{w = content_w, h = content_h},
            group,
        },
    }
    self[1] = CenterContainer:new{dimen = self.dimen:copy(), self.frame}
end

function Dialog:onTapDismiss(_, ges)
    local pos = ges and ges.pos
    if pos and pos:notIntersectWith(self.frame_dimen) then return self:_close() end
    return false
end
function Dialog:onClose() return self:_close() end
function Dialog:onShow()
    UIManager:setDirty(self, function() return "ui", self.frame_dimen end)
end
function Dialog:onCloseWidget()
    local region = self.frame_dimen and self.frame_dimen:copy() or nil
    self.closed = true
    if region then UIManager:setDirty(nil, function() return "ui", region end) end
end

local M = {}
function M.show(opts)
    opts = opts or {}
    local dialog = Dialog:new{
        percent = opts.percent,
        on_goto_percent = opts.on_goto_percent,
        on_adjust = opts.on_adjust,
        on_jump = opts.on_jump,
    }
    UIManager:show(dialog, "ui", dialog.frame_dimen)
    return dialog
end
return M
