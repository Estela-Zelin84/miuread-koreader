--[[--
书摘卡片交互层：实时预览、本地保存与局域网扫码取图。

beta.9 起不再使用“参数表 -> 查看预览”的多层弹窗：
  * 打开即渲染实时预览；
  * 宽屏使用左预览 + 右样式，窄屏自动改为上下布局；
  * 样式/配色/静影背景在同一编辑器内切换并立即刷新预览；
  * 扫码前先关闭编辑器，再单独显示二维码，避免方框叠加。

渲染由 book_excerpt_card 负责；局域网传输由 book_excerpt_transfer 负责。
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local RawQRMessage = require("ui/widget/qrmessage")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local GestureBridge = require("miuread.gesture_bridge")
local Card = require("miuread.book_excerpt_card")
local Transfer = require("miuread.book_excerpt_transfer")
local U = require("miuread.util")
local Skin = require("miuread.reader_skin")
local Ui = require("miuread.ui_components")
local logger = require("logger")
local util = require("util")
local ffiutil = require("ffi/util")
local DataStorage = require("datastorage")

local function gesture_aware_class(base, attrs)
    local class = base:extend(attrs or {})
    function class:handleEvent(event)
        return GestureBridge.handle(base, self, event)
    end
    return class
end

local QRMessage = gesture_aware_class(RawQRMessage, {
    _miuread_transient = true,
    _miuread_modal_surface = true,
})

local OffsetContainer = WidgetContainer:extend{x_off = 0, y_off = 0}
function OffsetContainer:getSize() return self[1]:getSize() end
function OffsetContainer:paintTo(bb, x, y)
    if self[1] then self[1]:paintTo(bb, x + self.x_off, y + self.y_off) end
end

local TapBox = InputContainer:extend{
    dimen = nil,
    callback = nil,
    enabled = true,
}
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
function TapBox:handleEvent(event) return GestureBridge.handle(InputContainer, self, event) end

local M = {}
local active_dialog
local qr_dialog
local preview_path
local closing = false
local ui_generation = 0

local SETTING_TEMPLATE = "miuread_book_excerpt_template"
local SETTING_COLOR = "miuread_book_excerpt_color"
local SETTING_BACKGROUND = "miuread_book_excerpt_background"

local function settings_read(key, default)
    if _G.G_reader_settings and type(G_reader_settings.readSetting) == "function" then
        local ok, value = pcall(G_reader_settings.readSetting, G_reader_settings, key)
        if ok and value ~= nil then return value end
    end
    return default
end

local function settings_write(key, value)
    if _G.G_reader_settings and type(G_reader_settings.saveSetting) == "function" then
        pcall(G_reader_settings.saveSetting, G_reader_settings, key, value)
    end
end

local function clamp_index(value, list, default)
    local n = math.floor(tonumber(value) or default or 1)
    if n < 1 then n = 1 end
    if n > #list then n = #list end
    return n
end

local function current_selection()
    return {
        template_idx = clamp_index(settings_read(SETTING_TEMPLATE, 1), Card.TEMPLATES, 1),
        color_idx = clamp_index(settings_read(SETTING_COLOR, 1), Card.COLORS, 1),
        background_idx = clamp_index(settings_read(SETTING_BACKGROUND, 1), Card.BACKGROUND_IMAGES, 1),
    }
end

local function copy_selection(value)
    value = type(value) == "table" and value or current_selection()
    return {
        template_idx = clamp_index(value.template_idx, Card.TEMPLATES, 1),
        color_idx = clamp_index(value.color_idx, Card.COLORS, 1),
        background_idx = clamp_index(value.background_idx, Card.BACKGROUND_IMAGES, 1),
    }
end

local function clean_text(value)
    return U.trim(tostring(value or ""):gsub("\r\n", "\n"):gsub("\r", "\n"))
end

local function close_widget(widget)
    if widget then pcall(UIManager.close, UIManager, widget) end
end

local function toast(host, text, seconds)
    if host and type(host.toast) == "function" then
        pcall(host.toast, host, text, seconds or 2.5)
    elseif host and type(host.info) == "function" then
        pcall(host.info, host, text)
    end
end

local function info(host, text)
    if host and type(host.info) == "function" then
        pcall(host.info, host, text)
    else
        toast(host, text, 3)
    end
end

local function temp_dir(context)
    local dir = context and context.temp_dir
    if type(dir) ~= "string" or dir == "" then
        dir = ffiutil.joinPath(DataStorage:getFullDataDir(), "miuread/tmp")
    end
    util.makePath(dir)
    return dir
end

local function render_options(context, selection, preview)
    local font_face = clean_text(context.font_face)
    if font_face == "" then font_face = nil end
    return {
        text = clean_text(context.text),
        book_title = clean_text(context.book_title),
        book_author = clean_text(context.book_author),
        book_id = tostring(context.book_id or "book"),
        font_face = font_face,
        template_idx = selection.template_idx,
        color_idx = selection.color_idx,
        background_idx = selection.background_idx,
        out_dir = preview and temp_dir(context) or nil,
        filename = preview and ("book_excerpt_preview_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)) .. ".png") or nil,
        qr_url = nil,
    }
end

local function remove_preview(path)
    path = path or preview_path
    if path then pcall(os.remove, path) end
    if path == preview_path then preview_path = nil end
end

local function render_card(host, context, selection, preview)
    if clean_text(context.text) == "" then return nil, nil, "没有可生成书摘的文字" end
    local old_preview = preview and preview_path or nil
    local ok, path, dimen = pcall(Card.render, render_options(context, selection, preview))
    if not ok then
        logger.warn("[MiuRead][BookExcerpt] render crashed", tostring(path))
        return nil, nil, U.first_line(path, 160)
    end
    if not path then return nil, nil, tostring(dimen or "生成失败") end
    if preview then
        preview_path = path
        if old_preview and old_preview ~= path then remove_preview(old_preview) end
    end
    if type(dimen) == "table" and dimen.truncated == true then
        toast(host, "摘录内容较长，当前模板只能显示部分内容", 3)
    end
    return path, dimen
end

local function cycle_index(current, delta, list)
    local count = #list
    if count <= 0 then return 1 end
    local n = (tonumber(current) or 1) + (tonumber(delta) or 0)
    while n < 1 do n = n + count end
    while n > count do n = n - count end
    return n
end

local Editor = InputContainer:extend{
    name = "miuread_book_excerpt_editor",
    _miuread_transient = true,
    _miuread_modal_surface = true,
    covers_fullscreen = true,
    stop_events_propagation = true,
    host = nil,
    context = nil,
    selection = nil,
    closed = false,
    pending_action = nil,
    frame_dimen = nil,
    preview_image = nil,
}
function Editor:handleEvent(event) return GestureBridge.handle(InputContainer, self, event) end

function Editor:_close(action)
    if action and not self.pending_action then self.pending_action = action end
    if self.closed then return true end
    self.closed = true
    UIManager:close(self)
    return true
end

function Editor:_button(text, width, height, callback, opts)
    opts = opts or {}
    local enabled = opts.enabled ~= false
    local selected = opts.selected == true
    local fg = selected and Blitbuffer.COLOR_WHITE or (enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY)
    local bg = selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    local border = Skin.line("thin")
    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        enabled = enabled,
        callback = callback,
    }
    tap[1] = Skin.frame(width, height, {
        bordersize = border,
        padding = 0,
        radius = Skin.radius(4, 2, 7),
        background = bg,
        color = enabled and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_GRAY,
    }, Ui.text(tostring(text or ""), math.max(1, width - border * 2), math.max(1, height - border * 2),
        Skin.face("cfont", opts.small and 9.2 or 10.4, opts.small and 12.8 or 14.4, 8.2), {
            bold = selected or opts.bold == true,
            fgcolor = fg,
        }))
    return tap
end

function Editor:_set_template(index)
    if self.closed then return end
    index = clamp_index(index, Card.TEMPLATES, 1)
    if index == self.selection.template_idx then return end
    self.selection.template_idx = index
    settings_write(SETTING_TEMPLATE, index)
    self:_rebuild()
end

function Editor:_cycle_color(delta)
    if self.closed then return end
    self.selection.color_idx = cycle_index(self.selection.color_idx, delta, Card.COLORS)
    settings_write(SETTING_COLOR, self.selection.color_idx)
    self:_rebuild()
end

function Editor:_cycle_background(delta)
    if self.closed then return end
    self.selection.background_idx = cycle_index(self.selection.background_idx, delta, Card.BACKGROUND_IMAGES)
    settings_write(SETTING_BACKGROUND, self.selection.background_idx)
    self:_rebuild()
end

function Editor:_preview_widget(width, height)
    local path, _, err = render_card(self.host, self.context, self.selection, true)
    if not path then
        return Skin.frame(width, height, {bordersize = Skin.line("thin"), background = Blitbuffer.COLOR_WHITE},
            Ui.textbox("书摘卡片生成失败\n" .. tostring(err or "unknown"),
                math.max(1, width - Skin.dp(16, 10, 22)), math.max(1, height - Skin.dp(16, 10, 22)),
                Skin.face("cfont", 10.5, 14.5, 8.5), {alignment = "center", halign = "center"}))
    end
    local image
    local ok, image_err = pcall(function()
        image = ImageWidget:new{
            file = path,
            width = math.max(1, width - Skin.dp(12, 8, 18)),
            height = math.max(1, height - Skin.dp(12, 8, 18)),
            scale_factor = 0,
            file_do_cache = false,
        }
        image:getSize() -- force decode before the old preview file is retired
    end)
    if not ok or not image then
        logger.warn("[MiuRead][BookExcerpt] preview image failed", tostring(image_err))
        return Ui.text("预览暂时无法显示", width, height, Skin.face("cfont", 10.5, 14.5, 8.5), {})
    end
    self._next_preview_image = image
    return Skin.frame(width, height, {
        bordersize = Skin.line("thin"),
        padding = Skin.dp(5, 3, 8),
        radius = Skin.radius(5, 3, 8),
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_DARK_GRAY,
    }, CenterContainer:new{dimen = Geom:new{
        w = math.max(1, width - Skin.dp(18, 12, 26)),
        h = math.max(1, height - Skin.dp(18, 12, 26)),
    }, image})
end

function Editor:_template_stack(width, height, vertical_grid)
    local gap = Skin.dp(6, 4, 9)
    local count = #Card.TEMPLATES
    local root = vertical_grid and VerticalGroup:new{align = "left"} or VerticalGroup:new{align = "left"}
    if vertical_grid then
        local cols = 3
        local rows = math.ceil(count / cols)
        local row_h = math.max(1, math.floor((height - gap * math.max(0, rows - 1)) / math.max(1, rows)))
        local button_w = math.max(1, math.floor((width - gap * (cols - 1)) / cols))
        for r = 1, rows do
            local row = HorizontalGroup:new{align = "center"}
            for c = 1, cols do
                local index = (r - 1) * cols + c
                if index <= count then
                    local item = Card.TEMPLATES[index]
                    row[#row + 1] = self:_button(item.name or tostring(index), button_w, row_h,
                        function() self:_set_template(index) end,
                        {selected = index == self.selection.template_idx})
                else
                    row[#row + 1] = Widget:new{dimen = Geom:new{w = button_w, h = row_h}}
                end
                if c < cols then row[#row + 1] = HorizontalSpan:new{width = gap} end
            end
            root[#root + 1] = row
            if r < rows then root[#root + 1] = VerticalSpan:new{height = gap} end
        end
        return root
    end

    local row_h = math.max(1, math.floor((height - gap * math.max(0, count - 1)) / math.max(1, count)))
    for index, item in ipairs(Card.TEMPLATES) do
        root[#root + 1] = self:_button(item.name or tostring(index), width, row_h,
            function() self:_set_template(index) end,
            {selected = index == self.selection.template_idx})
        if index < count then root[#root + 1] = VerticalSpan:new{height = gap} end
    end
    return root
end

function Editor:_cycle_row(label, value, width, height, callback_prev, callback_next, enabled)
    local gap = Skin.dp(5, 3, 8)
    local arrow_w = math.max(Skin.dp(38, 30, 52), math.floor(width * .18))
    local middle_w = math.max(1, width - arrow_w * 2 - gap * 2)
    local row = HorizontalGroup:new{align = "center"}
    row[#row + 1] = self:_button("‹", arrow_w, height, callback_prev, {enabled = enabled, bold = true})
    row[#row + 1] = HorizontalSpan:new{width = gap}
    row[#row + 1] = self:_button(tostring(label) .. "：" .. tostring(value), middle_w, height, nil,
        {enabled = false, small = true})
    row[#row + 1] = HorizontalSpan:new{width = gap}
    row[#row + 1] = self:_button("›", arrow_w, height, callback_next, {enabled = enabled, bold = true})
    return row
end

function Editor:_action_row(width, height)
    local gap = Skin.dp(8, 5, 11)
    local button_w = math.max(1, math.floor((width - gap * 2) / 3))
    local scan_w = button_w
    local save_w = button_w
    local close_w = math.max(1, width - scan_w - save_w - gap * 2)
    return HorizontalGroup:new{align = "center",
        self:_button("手机扫码保存", scan_w, height, function()
            local host, context, selection = self.host, self.context, copy_selection(self.selection)
            self:_close(function() M._show_qr_transfer(host, context, selection) end)
        end, {bold = true}),
        HorizontalSpan:new{width = gap},
        self:_button("保存到阅读器", save_w, height, function()
            local path, _, err = render_card(self.host, self.context, self.selection, false)
            if not path then
                info(self.host, "保存书摘卡片失败：\n" .. tostring(err or "unknown"))
                return
            end
            local host = self.host
            self:_close(function() toast(host, "书摘卡片已保存到阅读器\n" .. tostring(path), 4) end)
        end, {bold = true}),
        HorizontalSpan:new{width = gap},
        self:_button("关闭", close_w, height, function() self:_close() end, {}),
    }
end

function Editor:_build_content()
    local sw, sh = Device.screen:getWidth(), Device.screen:getHeight()
    self.dimen = Geom:new{w = sw, h = sh}
    local margin = math.max(12, math.floor(math.min(sw, sh) * .025))
    local dialog_w = math.max(1, math.min(sw - margin * 2, math.floor(sw * .94)))
    local dialog_h = math.max(1, math.min(sh - margin * 2, math.floor(sh * .88)))
    local dialog_x = math.floor((sw - dialog_w) / 2)
    local dialog_y = math.floor((sh - dialog_h) / 2)
    local border = Skin.line("thick")
    local pad = math.max(Skin.dp(12, 8, 18), math.floor(math.min(dialog_w, dialog_h) * .018))
    local gap = math.max(Skin.dp(10, 7, 15), math.floor(dialog_w * .012))
    local header_h = math.max(Skin.dp(42, 34, 58), math.floor(dialog_h * .065))
    local footer_h = math.max(Skin.dp(50, 42, 68), math.floor(dialog_h * .075))
    local inner_x, inner_y = dialog_x + border + pad, dialog_y + border + pad
    local inner_w = math.max(1, dialog_w - (border + pad) * 2)
    local inner_h = math.max(1, dialog_h - (border + pad) * 2)
    local content_y = inner_y + header_h + gap
    local content_h = math.max(1, inner_h - header_h - footer_h - gap * 2)
    local footer_y = dialog_y + dialog_h - border - pad - footer_h

    self.frame_dimen = Geom:new{x = dialog_x, y = dialog_y, w = dialog_w, h = dialog_h}
    local root = OverlapGroup:new{dimen = Geom:new{w = sw, h = sh}, allow_mirroring = false}
    root[#root + 1] = OffsetContainer:new{x_off = dialog_x, y_off = dialog_y,
        Skin.frame(dialog_w, dialog_h, {
            bordersize = border,
            padding = 0,
            radius = Skin.radius(8, 5, 12),
            background = Blitbuffer.COLOR_WHITE,
            color = Blitbuffer.COLOR_BLACK,
        }, Widget:new{dimen = Geom:new{w = 1, h = 1}})}

    local template = Card.TEMPLATES[self.selection.template_idx] or Card.TEMPLATES[1]
    local color = Card.COLORS[self.selection.color_idx] or Card.COLORS[1]
    local background = Card.BACKGROUND_IMAGES[self.selection.background_idx] or Card.BACKGROUND_IMAGES[1]
    local summary = tostring(template.name or "经典") .. " · " .. tostring(color.name or "配色")
    if template.id == "stillness" then summary = summary .. " · " .. tostring(background.name or "背景") end

    root[#root + 1] = OffsetContainer:new{x_off = inner_x, y_off = inner_y,
        HorizontalGroup:new{align = "center",
            Ui.text("书摘卡片", math.floor(inner_w * .45), header_h, Skin.face("cfont", 13.0, 18.0, 10.5), {bold = true, halign = "left"}),
            Ui.text(summary, math.max(1, inner_w - math.floor(inner_w * .45)), header_h,
                Skin.face("smallinfofont", 9.2, 12.8, 7.8), {halign = "right", fgcolor = Blitbuffer.COLOR_DARK_GRAY}),
        }}

    -- One layout owner computes every rectangle before widgets are created.
    -- No child gets an independent screen-relative x/y. Side-by-side mode is
    -- enabled only when all six template buttons + option rows fit at their
    -- minimum touch height; otherwise we deliberately fall back to vertical
    -- composition instead of allowing children to spill into the footer.
    local template_count=#Card.TEMPLATES
    local side_button_min=Skin.dp(34,28,46)
    local side_button_gap=Skin.dp(6,4,9)
    local side_label_min=Skin.dp(26,22,36)
    local side_cycle_min=Skin.dp(38,32,52)
    local side_controls_gap=Skin.dp(7,5,10)
    local side_cycle_rows=template.id=="stillness" and 2 or 1
    local side_control_gaps=template.id=="stillness" and 4 or 3
    local side_min_h=side_label_min
        + template_count*side_button_min + math.max(0,template_count-1)*side_button_gap
        + side_cycle_rows*side_cycle_min + side_control_gaps*side_controls_gap
    local side_layout = inner_w >= 700 and content_h >= side_min_h
    if side_layout then
        local options_w = math.max(210, math.floor(inner_w * .34))
        local preview_w = math.max(1, inner_w - options_w - gap)
        local preview_h = content_h
        root[#root + 1] = OffsetContainer:new{x_off = inner_x, y_off = content_y,
            self:_preview_widget(preview_w, preview_h)}

        local options_x = inner_x + preview_w + gap
        local label_h = math.max(Skin.dp(26, 22, 36), math.floor(content_h * .055))
        local cycle_h = math.max(Skin.dp(38, 32, 52), math.floor(content_h * .085))
        local background_h = template.id == "stillness" and cycle_h or 0
        local controls_gap = Skin.dp(7, 5, 10)
        local template_h = math.max(1, content_h - label_h - cycle_h - background_h
            - controls_gap * (template.id == "stillness" and 4 or 3))
        local controls = VerticalGroup:new{align = "left"}
        controls[#controls + 1] = Ui.text("样式", options_w, label_h,
            Skin.face("cfont", 10.5, 14.5, 8.5), {bold = true, halign = "left"})
        controls[#controls + 1] = VerticalSpan:new{height = controls_gap}
        controls[#controls + 1] = self:_template_stack(options_w, template_h, false)
        controls[#controls + 1] = VerticalSpan:new{height = controls_gap}
        controls[#controls + 1] = self:_cycle_row("配色", color.name or self.selection.color_idx,
            options_w, cycle_h,
            function() self:_cycle_color(-1) end,
            function() self:_cycle_color(1) end,
            #Card.COLORS > 1)
        if template.id == "stillness" then
            controls[#controls + 1] = VerticalSpan:new{height = controls_gap}
            controls[#controls + 1] = self:_cycle_row("背景", background.name or self.selection.background_idx,
                options_w, cycle_h,
                function() self:_cycle_background(-1) end,
                function() self:_cycle_background(1) end,
                #Card.BACKGROUND_IMAGES > 1)
        end
        root[#root + 1] = OffsetContainer:new{x_off = options_x, y_off = content_y, controls}
    else
        -- Compact devices use a vertical composition instead of squeezing two
        -- columns until they overlap. Templates become a 3 x 2 grid below the
        -- preview; the footer stays in its own reserved rectangle.
        local controls_gap = Skin.dp(6, 4, 9)
        local extra_rows = template.id == "stillness" and 2 or 1
        local template_rows=math.max(1,math.ceil(#Card.TEMPLATES/3))
        local template_button_min=Skin.dp(36,30,48)
        local cycle_min=Skin.dp(34,28,46)
        local controls_min=template_rows*template_button_min
            + math.max(0,template_rows-1)*controls_gap
            + extra_rows*cycle_min + extra_rows*controls_gap
        -- Reserve the controls rectangle first. On short panels the preview
        -- yields height, never the controls/footer. This is the hard anti-
        -- overlap path for older/smaller e-ink screens.
        local target_preview=math.floor(content_h*.58)
        local preview_floor=math.min(Skin.dp(120,96,160),math.max(1,content_h-gap-controls_min))
        local preview_cap=math.max(1,content_h-gap-controls_min)
        local preview_h=math.max(1,math.min(target_preview,preview_cap))
        if preview_cap>=preview_floor then preview_h=math.max(preview_floor,preview_h) end
        local controls_y = content_y + preview_h + gap
        local controls_h = math.max(1, content_h - preview_h - gap)
        root[#root + 1] = OffsetContainer:new{x_off = inner_x, y_off = content_y,
            self:_preview_widget(inner_w, preview_h)}
        local cycle_h = math.max(cycle_min, math.floor(controls_h * .22))
        -- A very short screen may still leave less than the preferred cycle
        -- height. Clamp cycle rows back down before computing template space.
        local cycle_budget=math.max(1,controls_h
            - (template_rows*template_button_min + math.max(0,template_rows-1)*controls_gap)
            - extra_rows*controls_gap)
        cycle_h=math.max(1,math.min(cycle_h,math.floor(cycle_budget/extra_rows)))
        local template_h = math.max(1, controls_h - cycle_h * extra_rows - controls_gap * extra_rows)
        local controls = VerticalGroup:new{align = "left"}
        controls[#controls + 1] = self:_template_stack(inner_w, template_h, true)
        controls[#controls + 1] = VerticalSpan:new{height = controls_gap}
        controls[#controls + 1] = self:_cycle_row("配色", color.name or self.selection.color_idx,
            inner_w, cycle_h,
            function() self:_cycle_color(-1) end,
            function() self:_cycle_color(1) end,
            #Card.COLORS > 1)
        if template.id == "stillness" then
            controls[#controls + 1] = VerticalSpan:new{height = controls_gap}
            controls[#controls + 1] = self:_cycle_row("背景", background.name or self.selection.background_idx,
                inner_w, cycle_h,
                function() self:_cycle_background(-1) end,
                function() self:_cycle_background(1) end,
                #Card.BACKGROUND_IMAGES > 1)
        end
        root[#root + 1] = OffsetContainer:new{x_off = inner_x, y_off = controls_y, controls}
    end

    root[#root + 1] = OffsetContainer:new{x_off = inner_x, y_off = footer_y,
        self:_action_row(inner_w, footer_h)}
    return root
end

function Editor:_rebuild()
    if self.closed then return false end
    local old_image = self.preview_image
    self._next_preview_image = nil
    local old_region = self.frame_dimen and self.frame_dimen:copy() or nil
    self[1] = self:_build_content()
    self.preview_image = self._next_preview_image
    self._next_preview_image = nil
    if old_image and old_image ~= self.preview_image and type(old_image.free) == "function" then
        pcall(old_image.free, old_image)
    end
    local dirty = self.frame_dimen and self.frame_dimen:copy() or old_region
    UIManager:setDirty(self, function() return "ui", dirty end)
    return true
end

function Editor:init()
    self.selection = copy_selection(self.selection)
    self[1] = self:_build_content()
    self.preview_image = self._next_preview_image
    self._next_preview_image = nil
end

function Editor:onBack() return self:_close() end
function Editor:onScreenResize()
    if self.closed then return true end
    return self:_rebuild()
end
function Editor:onRotation() return self:onScreenResize() end
function Editor:onCloseWidget()
    if active_dialog == self then active_dialog = nil end
    -- 释放静影头图缓存：编辑器关闭后不再需要，避免长会话常驻多张头图
    pcall(Card.clearStillnessHeadCache)
    if self.preview_image and type(self.preview_image.free) == "function" then pcall(self.preview_image.free, self.preview_image) end
    self.preview_image = nil
    local action = self.pending_action
    self.pending_action = nil
    if action then UIManager:nextTick(action) end
    return true
end

local function reopen(host, context, selection, generation)
    local expected = generation or ui_generation
    UIManager:scheduleIn(.04, function()
        if closing or expected ~= ui_generation then return end
        M.show(host, context, selection)
    end)
end

local function show_qr(url, host, context, selection, generation)
    local size = math.floor(math.min(Device.screen:getWidth(), Device.screen:getHeight()) * .72)
    local dialog
    dialog = QRMessage:new{
        text = url,
        width = size,
        height = size,
        scale_factor = .92,
        dismiss_callback = function()
            if qr_dialog == dialog then qr_dialog = nil end
            Transfer.stop("qr page closed")
            if not closing then reopen(host, context, selection, generation) end
        end,
    }
    qr_dialog = dialog
    UIManager:show(dialog)
end

function M._show_qr_transfer(host, context, selection)
    if closing then return false end
    local generation = ui_generation
    local path, _, err = render_card(host, context, selection, true)
    if not path then
        info(host, "书摘卡片生成失败：\n" .. tostring(err or "unknown"))
        reopen(host, context, selection, generation)
        return false
    end
    Transfer.stop("new qr transfer")
    local url, details = Transfer.start{
        file_path = path,
        title = context.book_title,
        on_download = function()
            toast(host, "手机已获取书摘图片", 2.5)
        end,
    }
    if not url then
        info(host, tostring(details or "无法开启手机扫码保存"))
        reopen(host, context, selection, generation)
        return false
    end
    toast(host, "手机与阅读器需连接同一局域网；扫码后可在手机保存原图", 4)
    -- Single-surface rule: the editor is already closed; QR is the only main
    -- overlay. Dismissing it stops the temporary LAN server and restores editor.
    show_qr(url, host, context, selection, generation)
    return true
end

function M.close(reason)
    if closing then return true end
    ui_generation = ui_generation + 1
    closing = true
    local q = qr_dialog
    qr_dialog = nil
    close_widget(q)
    Transfer.stop(reason or "dialog closed")
    local d = active_dialog
    active_dialog = nil
    close_widget(d)
    remove_preview()
    closing = false
    return true
end

function M.show(host, context, selection)
    context = context or {}
    context.text = clean_text(context.text)
    if context.text == "" then
        info(host, "没有可生成书摘的文字")
        return false
    end

    -- Do not stack editor on top of QR/old editor. Every transition first closes
    -- the previous surface; the next one is created only afterwards.
    if qr_dialog then
        local q = qr_dialog
        qr_dialog = nil
        closing = true
        close_widget(q)
        Transfer.stop("open card editor")
        closing = false
    end
    if active_dialog then
        local old = active_dialog
        active_dialog = nil
        closing = true
        close_widget(old)
        closing = false
    end

    local dialog = Editor:new{
        host = host,
        context = context,
        selection = copy_selection(selection or current_selection()),
    }
    active_dialog = dialog
    UIManager:show(dialog)
    return true
end

return M
