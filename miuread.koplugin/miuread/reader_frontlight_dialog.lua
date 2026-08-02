local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local Skin = require("miuread.reader_skin")
local Ui = require("miuread.ui_components")

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
function TapBox:handleEvent(event)
    return InputContainer.handleEvent(self, event)
end

local Dialog = InputContainer:extend{
    name = "miuread_reader_frontlight_dialog",
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

local function resolve(value, fallback)
    if type(value) == "function" then
        local ok, result = pcall(value)
        if ok then return result end
        logger.warn("[MiuRead][ReaderFrontlightDialog] resolver failed", tostring(result))
        return fallback
    end
    if value == nil then return fallback end
    return value
end

function Dialog:_setting(name)
    local setting = self.opts and self.opts[name] or nil
    setting = resolve(setting, nil)
    if type(setting) ~= "table" then return nil end
    local minimum = tonumber(resolve(setting.min, 0)) or 0
    local maximum = tonumber(resolve(setting.max, minimum + 1)) or (minimum + 1)
    if maximum <= minimum then maximum = minimum + 1 end
    local value = tonumber(resolve(setting.value, minimum)) or minimum
    value = math.max(minimum, math.min(maximum, value))
    return {
        label = tostring(resolve(setting.label, name == "warmth" and "色温" or "亮度")),
        value = value,
        min = minimum,
        max = maximum,
        on_decrease = setting.on_decrease,
        on_increase = setting.on_increase,
    }
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

function Dialog:_run(action, rebuild)
    if not action then return true end
    local ok, err = pcall(action)
    if not ok then logger.warn("[MiuRead][ReaderFrontlightDialog] action failed", tostring(err)) end
    if rebuild ~= false then
        UIManager:scheduleIn(.04, function()
            if not self.closed then self:_rebuild() end
        end)
    end
    return true
end

function Dialog:_step_button(label, width, height, callback)
    local enabled = callback ~= nil
    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        enabled = enabled,
        callback = function() self:_run(callback, true) end,
    }
    tap[1] = Skin.frame(width, height, {
        bordersize = Skin.line("thin"),
        radius = Skin.radius(6, 5, 10),
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_DARK_GRAY,
    }, Ui.icon(label == "+" and "plus" or "minus",
        width - Skin.dp(8, 6, 12), height - Skin.dp(4, 2, 6), Skin.dp(22, 19, 30), {
            face = Skin.face("cfont", 19, 24, 16),
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        }))
    return tap
end

function Dialog:_slider(setting, width, height)
    local label_h = math.max(Skin.dp(27, 23, 36), math.floor(height * .34))
    local control_h = height - label_h
    local side_w = Skin.dp(52, 45, 70)
    local value_w = Skin.dp(48, 40, 66)
    local gap = Skin.dp(7, 5, 10)
    local bar_w = math.max(1, width - side_w * 2 - value_w - gap * 3)
    local button_h = math.max(Skin.dp(43, 37, 57), math.floor(control_h * .82))
    local track_h = math.max(Skin.line("medium"), Skin.dp(4, 3, 6))
    local marker_w = Skin.dp(10, 8, 14)
    local ratio = (setting.value - setting.min) / math.max(1, setting.max - setting.min)
    ratio = math.max(0, math.min(1, ratio))
    local marker_x = math.floor((bar_w - marker_w) * ratio)

    local label_row = Ui.textbox(setting.label, width, label_h,
        Skin.face("cfont", 11.3, 15.2, 9.6), {bold = true, alignment = "left"})

    local track = OverlapGroup:new{dimen = Geom:new{w = bar_w, h = button_h}, allow_mirroring = false}
    track[#track + 1] = OffsetContainer:new{
        x_off = 0,
        y_off = math.floor((button_h - track_h) / 2),
        LineWidget:new{background = Blitbuffer.COLOR_GRAY, dimen = Geom:new{w = bar_w, h = track_h}},
    }
    local fill_w = math.max(track_h, math.floor((bar_w - marker_w / 2) * ratio))
    track[#track + 1] = OffsetContainer:new{
        x_off = 0,
        y_off = math.floor((button_h - track_h) / 2),
        LineWidget:new{background = Blitbuffer.COLOR_BLACK, dimen = Geom:new{w = fill_w, h = track_h}},
    }
    track[#track + 1] = OffsetContainer:new{
        x_off = marker_x,
        y_off = math.floor((button_h - marker_w) / 2),
        Skin.frame(marker_w, marker_w, {
            bordersize = Skin.line("thin"),
            radius = math.floor(marker_w / 2),
            background = Blitbuffer.COLOR_BLACK,
            color = Blitbuffer.COLOR_BLACK,
        }, Widget:new{dimen = Geom:new{w = 1, h = 1}}),
    }

    local controls = HorizontalGroup:new{
        align = "center",
        self:_step_button("−", side_w, button_h, setting.on_decrease),
        HorizontalSpan:new{width = gap},
        track,
        HorizontalSpan:new{width = gap},
        Ui.textbox(tostring(math.floor(setting.value + .5)), value_w, button_h,
            Skin.face("smallinfofont", 9.2, 12.4, 8), {
                bold = true, alignment = "center", halign = "center",
            }),
        HorizontalSpan:new{width = gap},
        self:_step_button("+", side_w, button_h, setting.on_increase),
    }

    return VerticalGroup:new{align = "left", label_row, controls}
end

function Dialog:_action_button(entry, width, height)
    local enabled = entry and entry.callback ~= nil
    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        enabled = enabled,
        callback = function() self:_run(entry.callback, true) end,
    }
    tap[1] = Skin.frame(width, height, {
        bordersize = Skin.line("thin"),
        radius = Skin.radius(6, 5, 10),
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_DARK_GRAY,
    }, Ui.textbox(tostring(entry and entry.label or ""), width - Skin.dp(10, 8, 14),
        height - Skin.dp(4, 2, 6), Skin.face("cfont", 10.4, 14, 8.9), {
            bold = true, alignment = "center", halign = "center",
            fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        }))
    return tap
end

function Dialog:_build_content()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local portrait = sw < sh
    local outer_margin = Skin.dp(10, 8, 18)
    local top_inset = Skin.dp(3, 2, 5)
    local pad = Skin.dp(12, 9, 18)
    local gap = Skin.dp(10, 7, 14)
    local panel_w = sw - outer_margin * 2
    local content_w = panel_w - pad * 2
    local header_h = math.max(Skin.dp(40, 34, 53), math.floor(sh * .04))
    local slider_h = math.max(Skin.dp(95, 82, 124), math.floor(sh * (portrait and .095 or .14)))
    local action_h = Skin.dp(44, 38, 58)
    local handle_h = Skin.dp(18, 15, 25)
    local brightness = self:_setting("brightness")
    local warmth = self:_setting("warmth")
    local setting_count = brightness and 1 or 0
    if warmth then setting_count = setting_count + 1 end
    setting_count = math.max(1, setting_count)
    self.panel_h = math.min(sh - top_inset - math.max(28, math.floor(sh * .052)),
        pad * 2 + header_h + gap + slider_h * setting_count + gap * math.max(0, setting_count - 1) + gap + action_h + handle_h)
    self.dimen = Geom:new{x = 0, y = 0, w = sw, h = sh}
    self.frame_dimen = Geom:new{x = outer_margin, y = top_inset, w = panel_w, h = self.panel_h}

    local root = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    root[#root + 1] = OffsetContainer:new{
        x_off = outer_margin,
        y_off = top_inset,
        Skin.paper(panel_w, self.panel_h, {accent = false, seed = 13}, Widget:new{dimen = Geom:new{w = 1, h = 1}}),
    }

    local y = top_inset + pad
    local side_w = Skin.dp(44, 38, 58)
    local title_w = math.max(1, content_w - side_w * 2)
    local back = TapBox:new{
        dimen = Geom:new{w = side_w, h = header_h},
        callback = function() self:_close(self.opts and self.opts.on_back or nil) end,
    }
    back[1] = Ui.icon("back", side_w, header_h, Skin.dp(21, 18, 28), {
        face = Skin.face("cfont", 21, 26, 18),
    })
    local home_action = self.opts and self.opts.on_home or nil
    local home = TapBox:new{
        dimen = Geom:new{w = side_w, h = header_h},
        enabled = type(home_action) == "function",
        callback = function() self:_close(home_action) end,
    }
    home[1] = Ui.icon("home", side_w, header_h, Skin.dp(21, 18, 28), {
        face = Skin.face("cfont", 15.8, 20.8, 13.2),
        fgcolor = type(home_action) == "function" and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
    })
    root[#root + 1] = OffsetContainer:new{
        x_off = outer_margin + pad,
        y_off = y,
        HorizontalGroup:new{
            align = "center",
            back,
            Ui.textbox(tostring(self.opts and self.opts.title or "前光"), title_w, header_h,
                Skin.face("cfont", 16.2, 20.8, 13.6), {
                    bold = true, alignment = "center", halign = "center",
                }),
            home,
        },
    }
    y = y + header_h + gap

    local settings = {}
    if brightness then settings[#settings + 1] = brightness end
    if warmth then settings[#settings + 1] = warmth end
    if #settings == 0 then
        root[#root + 1] = OffsetContainer:new{x_off = outer_margin + pad, y_off = y, CenterContainer:new{
            dimen = Geom:new{w = content_w, h = slider_h},
            Ui.textbox("当前设备没有可调前光", content_w, slider_h,
                Skin.face("smallinfofont", 10, 13, 8.5), {
                    alignment = "center", halign = "center", fgcolor = Blitbuffer.COLOR_BLACK,
                }),
        }}
        y = y + slider_h
    else
        for index, setting in ipairs(settings) do
            local card = Skin.frame(content_w, slider_h, {
                bordersize = Skin.line("thin"),
                padding = Skin.dp(10, 8, 14),
                radius = Skin.radius(7, 5, 11),
                background = Blitbuffer.COLOR_WHITE,
                color = Blitbuffer.COLOR_DARK_GRAY,
            }, self:_slider(setting, content_w - Skin.dp(20, 16, 28), slider_h - Skin.dp(20, 16, 28)))
            root[#root + 1] = OffsetContainer:new{x_off = outer_margin + pad, y_off = y, card}
            y = y + slider_h
            if index < #settings then y = y + gap end
        end
    end

    y = y + gap
    local actions = self.opts and self.opts.actions or {}
    local action_count = math.max(1, #actions)
    local action_gap = Skin.dp(7, 5, 10)
    local action_w = math.floor((content_w - action_gap * (action_count - 1)) / action_count)
    local action_row = HorizontalGroup:new{align = "center"}
    for index, entry in ipairs(actions) do
        action_row[#action_row + 1] = self:_action_button(entry, action_w, action_h)
        if index < #actions then action_row[#action_row + 1] = HorizontalSpan:new{width = action_gap} end
    end
    root[#root + 1] = OffsetContainer:new{x_off = outer_margin + pad, y_off = y, action_row}

    local handle_w = Skin.dp(34, 28, 48)
    root[#root + 1] = OffsetContainer:new{
        x_off = outer_margin + math.floor((panel_w - handle_w) / 2),
        y_off = top_inset + self.panel_h - math.floor(handle_h * .55),
        LineWidget:new{
            background = Blitbuffer.COLOR_DARK_GRAY,
            dimen = Geom:new{w = handle_w, h = math.max(1, Skin.line("thin"))},
        },
    }
    self[1] = root
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
    UIManager:setDirty(self, function() return "ui", Skin.expand_region(dirty) end)
end

function Dialog:init()
    self.opts = self.opts or {}
    self:_build_content()
    self.ges_events = {
        TapDismiss = {GestureRange:new{ges = "tap", range = self.dimen}},
        SwipeDismiss = {GestureRange:new{ges = "swipe", range = self.dimen}},
    }
    if Device:hasKeys() and Device.input and Device.input.group and Device.input.group.Back then
        self.key_events = {Close = {{Device.input.group.Back}}}
    end
end

function Dialog:onTapDismiss(_, ges)
    local pos = ges and ges.pos
    if pos and (pos.y > self.frame_dimen.y + self.frame_dimen.h or pos.x < self.frame_dimen.x or pos.x > self.frame_dimen.x + self.frame_dimen.w) then
        return self:_close(self.opts and self.opts.on_back or nil)
    end
    return false
end
function Dialog:onSwipeDismiss(_, ges)
    if ges and ges.direction == "north" then return self:_close(self.opts and self.opts.on_back or nil) end
    return false
end
function Dialog:onClose()
    return self:_close(self.opts and self.opts.on_back or nil)
end
function Dialog:onShow()
    UIManager:setDirty(self, function() return "ui", Skin.expand_region(self.frame_dimen) end)
end
function Dialog:onCloseWidget()
    local region = self.frame_dimen and Skin.expand_region(self.frame_dimen) or nil
    local action = self.pending_action
    self.pending_action = nil
    self.closed = true
    if live_dialog == self then live_dialog = nil end
    if region then UIManager:setDirty(nil, function() return "ui", region end) end
    if action then
        UIManager:scheduleIn(.04, function()
            local ok, err = pcall(action)
            if not ok then logger.warn("[MiuRead][ReaderFrontlightDialog] deferred action failed", tostring(err)) end
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
        logger.warn("[MiuRead][ReaderFrontlightDialog] build failed", tostring(dialog))
        return nil, tostring(dialog)
    end
    live_dialog = dialog
    UIManager:show(dialog, "ui", dialog.frame_dimen)
    return dialog
end
return M
