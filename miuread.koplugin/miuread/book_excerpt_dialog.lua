--[[--
书摘卡片交互层：模板/配色/背景选择、预览、本地保存与局域网扫码取图。

渲染由 book_excerpt_card 负责；局域网传输由 book_excerpt_transfer 负责。
本模块只在用户主动打开时工作，关闭/休眠后不保留后台任务。
--]]--

local Device = require("device")
local UIManager = require("ui/uimanager")
local RawButtonDialog = require("ui/widget/buttondialog")
local RawQRMessage = require("ui/widget/qrmessage")
local ImageViewer = require("ui/widget/imageviewer")
local GestureBridge = require("miuread.gesture_bridge")
local Card = require("miuread.book_excerpt_card")
local Transfer = require("miuread.book_excerpt_transfer")
local U = require("miuread.util")
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

local ButtonDialog = gesture_aware_class(RawButtonDialog, {
    _miuread_transient = true,
    _miuread_modal_surface = true,
})
local QRMessage = gesture_aware_class(RawQRMessage, {
    _miuread_transient = true,
    _miuread_modal_surface = true,
})

local M = {}
local active_dialog
local transfer_dialog
local qr_dialog
local chooser_dialog
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

local function clean_text(value)
    return U.trim(tostring(value or ""):gsub("\r\n", "\n"):gsub("\r", "\n"))
end

local function excerpt_preview(text)
    text = clean_text(text):gsub("%s+", " ")
    if text == "" then return "" end
    return U.utf8_truncate(text, 78, "…")
end

local function remove_preview()
    if preview_path then pcall(os.remove, preview_path) end
    preview_path = nil
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
        -- 传图二维码不进入最终卡片；卡片内二维码保留为底层能力但默认关闭。
        qr_url = nil,
    }
end

local function render_card(host, context, selection, preview)
    if clean_text(context.text) == "" then return nil, nil, "没有可生成书摘的文字" end
    if preview then remove_preview() end
    local ok, path, dimen = pcall(Card.render, render_options(context, selection, preview))
    if not ok then
        logger.warn("[MiuRead][BookExcerpt] render crashed", tostring(path))
        return nil, nil, U.first_line(path, 160)
    end
    if not path then return nil, nil, tostring(dimen or "生成失败") end
    if preview then preview_path = path end
    if type(dimen) == "table" and dimen.truncated == true then
        toast(host, "摘录内容较长，当前模板只能显示部分内容", 3)
    end
    return path, dimen
end

local function close_transfer_surfaces(reason)
    local q = qr_dialog
    qr_dialog = nil
    close_widget(q)
    local d = transfer_dialog
    transfer_dialog = nil
    close_widget(d)
    Transfer.stop(reason or "dialog closed")
end

function M.close(reason)
    if closing then return true end
    ui_generation = ui_generation + 1
    closing = true
    close_transfer_surfaces(reason or "close")
    local chooser = chooser_dialog
    chooser_dialog = nil
    close_widget(chooser)
    local d = active_dialog
    active_dialog = nil
    close_widget(d)
    remove_preview()
    closing = false
    return true
end

local function show_qr(url)
    if qr_dialog then close_widget(qr_dialog); qr_dialog = nil end
    local size = math.floor(math.min(Device.screen:getWidth(), Device.screen:getHeight()) * .72)
    local dialog
    dialog = QRMessage:new{
        text = url,
        width = size,
        height = size,
        scale_factor = .92,
        dismiss_callback = function()
            if qr_dialog == dialog then qr_dialog = nil end
            -- 关闭二维码本身不停止传输；用户会回到带说明的扫码页面，
            -- 可以再次显示二维码或点击“完成”结束。
        end,
    }
    qr_dialog = dialog
    UIManager:show(dialog)
end

local function show_transfer(host, context, path)
    close_transfer_surfaces("new transfer")
    local url, details = Transfer.start{
        file_path = path,
        title = context.book_title,
        on_download = function()
            toast(host, "手机已获取书摘图片", 2.5)
        end,
    }
    if not url then
        info(host, tostring(details or "无法开启手机扫码保存"))
        return false
    end

    local dialog
    dialog = ButtonDialog:new{
        title = "手机扫码保存\n\n"
            .. "请让手机和阅读器连接同一个路由器后再扫码。\n\n"
            .. "同一路由器的 2.4G / 5G 均可；访客网络可能无法使用。\n\n"
            .. "阅读器地址：" .. tostring(details.ip or "") .. ":" .. tostring(details.port or ""),
        title_align = "center",
        close_callback = function()
            if transfer_dialog == dialog then transfer_dialog = nil end
            if not closing then
                local q = qr_dialog
                qr_dialog = nil
                close_widget(q)
                Transfer.stop("transfer page closed")
            end
        end,
        buttons = {
            {{text = "显示二维码", callback = function() show_qr(url) end}},
            {{text = "完成", callback = function()
                if transfer_dialog == dialog then transfer_dialog = nil end
                closing = true
                local q = qr_dialog; qr_dialog = nil; close_widget(q)
                close_widget(dialog)
                Transfer.stop("user finished")
                closing = false
            end}},
        },
    }
    transfer_dialog = dialog
    UIManager:show(dialog)
    -- 用户点击手机扫码保存后，说明必须先可见；二维码由明确按钮打开。
    return true
end

local function reopen(host, context)
    local expected_generation = ui_generation
    UIManager:scheduleIn(.04, function()
        if expected_generation ~= ui_generation or closing then return end
        M.show(host, context)
    end)
end

local function close_main_only()
    local d = active_dialog
    active_dialog = nil
    closing = true
    close_widget(d)
    closing = false
end

local function choose_color(host, context)
    close_main_only()
    local current = current_selection().color_idx
    local buttons = {}
    local row = {}
    local chooser
    for index, item in ipairs(Card.COLORS) do
        local i = index
        row[#row + 1] = {
            text = (i == current and "✓ " or "") .. tostring(item.name or ("配色 " .. i)),
            callback = function()
                settings_write(SETTING_COLOR, i)
                chooser._miuread_reopen_suppressed = true
                if chooser_dialog == chooser then chooser_dialog = nil end
                closing = true; close_widget(chooser); closing = false
                reopen(host, context)
            end,
        }
        if #row == 2 then buttons[#buttons + 1] = row; row = {} end
    end
    if #row > 0 then buttons[#buttons + 1] = row end
    buttons[#buttons + 1] = {{text = "取消", callback = function()
        chooser._miuread_reopen_suppressed = true
        if chooser_dialog == chooser then chooser_dialog = nil end
        closing = true; close_widget(chooser); closing = false
        reopen(host, context)
    end}}
    chooser = ButtonDialog:new{
        title = "选择书摘配色",
        close_callback = function()
            if chooser_dialog == chooser then chooser_dialog = nil end
            if not closing and chooser._miuread_reopen_suppressed ~= true then reopen(host, context) end
        end,
        buttons = buttons,
    }
    chooser_dialog = chooser
    UIManager:show(chooser)
end

local function choose_background(host, context)
    close_main_only()
    local current = current_selection().background_idx
    local buttons = {}
    local row = {}
    local chooser
    for index, item in ipairs(Card.BACKGROUND_IMAGES) do
        local i = index
        row[#row + 1] = {
            text = (i == current and "✓ " or "") .. tostring(item.name or ("背景 " .. i)),
            callback = function()
                settings_write(SETTING_BACKGROUND, i)
                chooser._miuread_reopen_suppressed = true
                if chooser_dialog == chooser then chooser_dialog = nil end
                closing = true; close_widget(chooser); closing = false
                reopen(host, context)
            end,
        }
        if #row == 2 then buttons[#buttons + 1] = row; row = {} end
    end
    if #row > 0 then buttons[#buttons + 1] = row end
    buttons[#buttons + 1] = {{text = "取消", callback = function()
        chooser._miuread_reopen_suppressed = true
        if chooser_dialog == chooser then chooser_dialog = nil end
        closing = true; close_widget(chooser); closing = false
        reopen(host, context)
    end}}
    chooser = ButtonDialog:new{
        title = "选择静影背景",
        close_callback = function()
            if chooser_dialog == chooser then chooser_dialog = nil end
            if not closing and chooser._miuread_reopen_suppressed ~= true then reopen(host, context) end
        end,
        buttons = buttons,
    }
    chooser_dialog = chooser
    UIManager:show(chooser)
end

local function show_preview(host, context, selection)
    local path, _, err = render_card(host, context, selection, true)
    if not path then info(host, "书摘卡片生成失败：\n" .. tostring(err or "unknown")); return end
    local viewer = ImageViewer:new{
        file = path,
        modal = true,
        with_title_bar = false,
        buttons_visible = true,
    }
    viewer._miuread_transient = true
    viewer._miuread_modal_surface = true
    UIManager:show(viewer)
end

function M.show(host, context)
    context = context or {}
    context.text = clean_text(context.text)
    if context.text == "" then
        info(host, "没有可生成书摘的文字")
        return false
    end
    close_transfer_surfaces("open card editor")
    if active_dialog then close_main_only() end

    local selection = current_selection()
    local template = Card.TEMPLATES[selection.template_idx] or Card.TEMPLATES[1]
    local color = Card.COLORS[selection.color_idx] or Card.COLORS[1]
    local background = Card.BACKGROUND_IMAGES[selection.background_idx] or Card.BACKGROUND_IMAGES[1]
    local summary = tostring(template.name or "经典") .. " · " .. tostring(color.name or ("配色 " .. selection.color_idx))
    if template.id == "stillness" then summary = summary .. " · " .. tostring(background.name or "背景") end
    local short = excerpt_preview(context.text)

    local buttons = {}
    local template_row = {}
    for index, item in ipairs(Card.TEMPLATES) do
        local i = index
        template_row[#template_row + 1] = {
            text = (i == selection.template_idx and "✓ " or "") .. tostring(item.name or i),
            callback = function()
                settings_write(SETTING_TEMPLATE, i)
                close_main_only()
                reopen(host, context)
            end,
        }
        if #template_row == 3 then buttons[#buttons + 1] = template_row; template_row = {} end
    end
    if #template_row > 0 then buttons[#buttons + 1] = template_row end

    buttons[#buttons + 1] = {
        {text = "配色：" .. tostring(color.name or selection.color_idx), callback = function() choose_color(host, context) end},
        {text = template.id == "stillness" and ("背景：" .. tostring(background.name or selection.background_idx)) or "背景：仅静影", enabled = template.id == "stillness", callback = function() choose_background(host, context) end},
        {text = "查看预览", callback = function() show_preview(host, context, current_selection()) end},
    }
    buttons[#buttons + 1] = {{text = "手机扫码保存", callback = function()
        local current = current_selection()
        local path, _, err = render_card(host, context, current, true)
        if not path then info(host, "书摘卡片生成失败：\n" .. tostring(err or "unknown")); return end
        show_transfer(host, context, path)
    end}}
    buttons[#buttons + 1] = {
        {text = "保存到阅读器", callback = function()
            local path, _, err = render_card(host, context, current_selection(), false)
            if not path then
                info(host, "保存书摘卡片失败：\n" .. tostring(err or "unknown"))
            else
                toast(host, "书摘卡片已保存到阅读器\n" .. tostring(path), 4)
            end
        end},
        {text = "关闭", callback = function() M.close("user close") end},
    }

    local dialog
    dialog = ButtonDialog:new{
        title = "书摘卡片\n\n" .. summary .. (short ~= "" and ("\n\n“" .. short .. "”") or ""),
        title_align = "left",
        close_callback = function()
            if active_dialog == dialog then active_dialog = nil end
            if not closing then
                remove_preview()
                Transfer.stop("card editor closed")
            end
        end,
        buttons = buttons,
    }
    active_dialog = dialog
    UIManager:show(dialog)
    return true
end

return M
