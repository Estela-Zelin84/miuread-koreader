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
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local Screen = Device.screen
local live_dialog

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

local Dialog = InputContainer:extend{
    name = "miuread_reader_settings_dialog",
    _miuread_transient = true,
    covers_fullscreen = true,
    stop_events_propagation = true,
    opts = nil,
    closed = false,
    pending_action = nil,
}

function Dialog:handleEvent(event)
    return InputContainer.handleEvent(self, event)
end

function Dialog:_rows()
    local rows = self.opts and self.opts.rows or {}
    if type(rows) == "function" then
        local ok, result = pcall(rows)
        if ok and type(result) == "table" then return result end
        if not ok then logger.warn("[MiuRead][ReaderSettingsDialog] rows failed", tostring(result)) end
        return {}
    end
    return type(rows) == "table" and rows or {}
end

function Dialog:_subtitle()
    local subtitle = self.opts and self.opts.subtitle or ""
    if type(subtitle) == "function" then
        local ok, result = pcall(subtitle)
        if ok then return tostring(result or "") end
        logger.warn("[MiuRead][ReaderSettingsDialog] subtitle failed", tostring(result))
        return ""
    end
    return tostring(subtitle or "")
end

function Dialog:_close(action, cancel_pending)
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

function Dialog:_run_row(row)
    if not row or row.enabled == false then return true end
    if row.keep_open == true then
        local ok, err = pcall(row.callback or function() end)
        if not ok then logger.warn("[MiuRead][ReaderSettingsDialog] action failed", tostring(err)) end
        if not self.closed then
            UIManager:scheduleIn(.04, function()
                if not self.closed then self:_rebuild() end
            end)
        end
        return true
    end
    return self:_close(row.callback)
end

function Dialog:_row_widget(row, width, height)
    local enabled = row.enabled ~= false
    local value = tostring(row.value or "")
    local value_w = value ~= "" and math.max(92, math.floor(width * .34)) or 0
    local gap = value_w > 0 and math.max(8, Screen:scaleBySize(7)) or 0
    local label_w = math.max(1, width - value_w - gap)
    local row_content = HorizontalGroup:new{
        align = "center",
        LeftContainer:new{dimen = Geom:new{w = label_w, h = height}, TextBoxWidget:new{
            text = tostring(row.label or row.text or ""),
            face = Font:getFace("cfont", math.max(14, Screen:scaleBySize(15))),
            bold = row.bold == true,
            width = label_w,
            height = height,
            height_adjust = false,
            height_overflow_show_ellipsis = true,
            alignment = "left",
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        }},
    }
    if value_w > 0 then
        row_content[#row_content + 1] = HorizontalSpan:new{width = gap}
        row_content[#row_content + 1] = TextBoxWidget:new{
            text = value,
            face = Font:getFace("smallinfofont", math.max(12, Screen:scaleBySize(13))),
            bold = row.value_bold == true or row.checked == true,
            width = value_w,
            height = height,
            height_adjust = false,
            height_overflow_show_ellipsis = true,
            alignment = "right",
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        }
    end
    local layer = OverlapGroup:new{dimen = Geom:new{w = width, h = height}, allow_mirroring = false}
    layer[#layer + 1] = CenterContainer:new{dimen = Geom:new{w = width, h = height}, row_content}
    layer[#layer + 1] = OffsetContainer:new{
        x_off = 0,
        y_off = math.max(0, height - Size.line.thin),
        LineWidget:new{
            background = enabled and Blitbuffer.COLOR_GRAY or (Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_GRAY),
            dimen = Geom:new{w = width, h = Size.line.thin},
        },
    }
    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        enabled = enabled,
        callback = function() self:_run_row(row) end,
    }
    tap[1] = layer
    return tap
end

function Dialog:_build_content()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local rows = self:_rows()
    local width = math.max(math.floor(sw * .78), math.min(math.floor(sw * .86), Screen:scaleBySize(760)))
    width = math.min(width, sw - math.max(30, math.floor(sw * .07)))
    local border = Size.border.window
    local radius = math.max(tonumber(Size.radius.window) or 0, Screen:scaleBySize(7))
    local pad = math.max(13, Screen:scaleBySize(11))
    local title_h = math.max(42, Screen:scaleBySize(40))
    local subtitle = self:_subtitle()
    local subtitle_h = subtitle ~= "" and math.max(30, Screen:scaleBySize(28)) or 0
    local row_h = math.max(54, Screen:scaleBySize(52))
    local close_h = math.max(52, Screen:scaleBySize(50))
    local gap = math.max(9, Screen:scaleBySize(8))
    local content_w = width - (border + pad) * 2
    local content_h = title_h + subtitle_h + gap + #rows * row_h + gap + close_h
    local height = content_h + (border + pad) * 2
    local max_h = sh - math.max(38, math.floor(sh * .08))
    if height > max_h then
        row_h = math.max(44, math.floor((max_h - (border + pad) * 2 - title_h - subtitle_h - gap * 2 - close_h) / math.max(1, #rows)))
        content_h = title_h + subtitle_h + gap + #rows * row_h + gap + close_h
        height = content_h + (border + pad) * 2
    end

    self.dimen = Geom:new{x = 0, y = 0, w = sw, h = sh}
    self.frame_dimen = Geom:new{
        x = math.floor((sw - width) / 2),
        y = math.floor((sh - height) / 2),
        w = width,
        h = height,
    }

    local group = VerticalGroup:new{align = "center"}
    group[#group + 1] = TextBoxWidget:new{
        text = tostring(self.opts.title or "阅读设置"),
        face = Font:getFace("cfont", math.max(18, Screen:scaleBySize(20))),
        bold = true,
        width = content_w,
        height = title_h,
        height_adjust = false,
        height_overflow_show_ellipsis = true,
        alignment = "center",
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    if subtitle_h > 0 then
        group[#group + 1] = TextBoxWidget:new{
            text = subtitle,
            face = Font:getFace("smallinfofont", math.max(12, Screen:scaleBySize(13))),
            width = content_w,
            height = subtitle_h,
            height_adjust = false,
            height_overflow_show_ellipsis = true,
            alignment = "center",
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
    end
    group[#group + 1] = VerticalSpan:new{height = gap}
    for _, row in ipairs(rows) do group[#group + 1] = self:_row_widget(row, content_w, row_h) end
    group[#group + 1] = VerticalSpan:new{height = gap}

    local close = TapBox:new{
        dimen = Geom:new{w = content_w, h = close_h},
        callback = function() self:_close() end,
    }
    close[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.thin,
        radius = math.max(3, math.floor(radius * .55)),
        padding = 0,
        margin = 0,
        CenterContainer:new{dimen = Geom:new{w = content_w - Size.border.thin * 2, h = close_h - Size.border.thin * 2}, TextBoxWidget:new{
            text = "关闭",
            face = Font:getFace("cfont", math.max(14, Screen:scaleBySize(15))),
            bold = true,
            width = content_w - 12,
            height = close_h - 4,
            height_adjust = false,
            alignment = "center",
            fgcolor = Blitbuffer.COLOR_BLACK,
        }},
    }
    group[#group + 1] = close

    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_BLACK,
        bordersize = border,
        radius = radius,
        padding = pad,
        margin = 0,
        CenterContainer:new{dimen = Geom:new{w = content_w, h = content_h}, group},
    }
    self[1] = CenterContainer:new{dimen = self.dimen:copy(), self.frame}
end

function Dialog:_rebuild()
    local old = self.frame_dimen and self.frame_dimen:copy() or nil
    self:_build_content()
    local dirty = self.frame_dimen
    if old then
        dirty = Geom:new{
            x = math.min(old.x, self.frame_dimen.x),
            y = math.min(old.y, self.frame_dimen.y),
            w = math.max(old.x + old.w, self.frame_dimen.x + self.frame_dimen.w) - math.min(old.x, self.frame_dimen.x),
            h = math.max(old.y + old.h, self.frame_dimen.y + self.frame_dimen.h) - math.min(old.y, self.frame_dimen.y),
        }
    end
    UIManager:setDirty(self, function() return "ui", dirty end)
end

function Dialog:init()
    self.opts = self.opts or {}
    self:_build_content()
    if Device:isTouchDevice() then
        self.ges_events = {TapDismiss = {GestureRange:new{ges = "tap", range = self.dimen}}}
    end
    if Device:hasKeys() and Device.input and Device.input.group and Device.input.group.Back then
        self.key_events = {Close = {{Device.input.group.Back}}}
    end
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
    local action = self.pending_action
    self.pending_action = nil
    self.closed = true
    if live_dialog == self then live_dialog = nil end
    if region then UIManager:setDirty(nil, function() return "ui", region end) end
    if action then
        UIManager:scheduleIn(.04, function()
            local ok, err = pcall(action)
            if not ok then logger.warn("[MiuRead][ReaderSettingsDialog] action failed", tostring(err)) end
        end)
    end
end

local M = {}
function M.close()
    if live_dialog and not live_dialog.closed then live_dialog:_close(nil, true) end
    live_dialog = nil
end
function M.show(opts)
    M.close()
    local ok, dialog = pcall(Dialog.new, Dialog, {opts = opts or {}})
    if not ok or not dialog then
        logger.warn("[MiuRead][ReaderSettingsDialog] build failed", tostring(dialog))
        return nil, tostring(dialog)
    end
    live_dialog = dialog
    UIManager:show(dialog, "ui", dialog.frame_dimen)
    return dialog
end
return M
