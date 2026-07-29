local UIManager = require("ui/uimanager")
local logger = require("logger")

local M = {}

local function fallback_text(opts)
    local text = tostring(opts and opts.fallback_text or "")
    if text == "" then text = "没有想法内容" end
    return text
end

function M.show_plain(opts, reason)
    opts = opts or {}
    local title = tostring(opts.fallback_title or "想法")
    local text = fallback_text(opts)

    local ok_viewer, TextViewer = pcall(require, "ui/widget/textviewer")
    if ok_viewer and TextViewer and type(TextViewer.new) == "function" then
        local ok, viewer_or_error = xpcall(function()
            return TextViewer:new{
                title=title,
                text=text,
                justified=false,
            }
        end, debug.traceback)
        if ok then
            local shown, show_error = pcall(UIManager.show, UIManager, viewer_or_error)
            if shown then return true, "native", reason end
            reason = tostring(reason or "") .. "\n" .. tostring(show_error)
        else
            reason = tostring(reason or "") .. "\n" .. tostring(viewer_or_error)
        end
    end

    local ok_info, InfoMessage = pcall(require, "ui/widget/infomessage")
    if ok_info and InfoMessage and type(InfoMessage.new) == "function" then
        local compact = text
        if #compact > 3200 then compact = compact:sub(1, 3200) .. "\n\n内容较长，请在想法窗口中查看完整内容。" end
        local shown, show_error = pcall(function()
            UIManager:show(InfoMessage:new{text=title .. "\n\n" .. compact})
        end)
        if shown then return true, "message", reason end
        reason = tostring(reason or "") .. "\n" .. tostring(show_error)
    end

    logger.warn("[MiuRead][ThoughtPopup] native viewer unavailable", tostring(reason or "unknown"))
    return nil, "native", reason or "无法创建想法窗口"
end

function M.show(opts)
    return M.show_plain(opts, "native_lightweight")
end

function M.prewarm_font()
    return false
end

function M.rich_disabled_reason()
    return "native_lightweight"
end

return M
