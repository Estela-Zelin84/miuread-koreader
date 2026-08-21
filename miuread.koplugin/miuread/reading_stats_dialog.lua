local HomeData = require("miuread.home_data")
local ReaderListDialog = require("miuread.reader_list_dialog")

local M = {}
local WEEKDAY = { ["0"]="周日", ["1"]="周一", ["2"]="周二", ["3"]="周三", ["4"]="周四", ["5"]="周五", ["6"]="周六" }

local function duration(value)
    if value == nil then return "暂无" end
    return HomeData.format_duration(value)
end

local function daily_rows(rows)
    local out = {}
    for _, row in ipairs(type(rows)=="table" and rows or {}) do
        local label = tostring(row.date or "")
        local weekday = WEEKDAY[tostring(row.weekday or "")]
        if weekday then label = label ~= "" and (label .. "  " .. weekday) or weekday end
        if label == "" and tonumber(row.stamp) then label = os.date("%m-%d", tonumber(row.stamp)) end
        out[#out + 1] = {
            label = label ~= "" and label or "阅读记录",
            value = duration(row.seconds),
            arrow = false,
        }
    end
    if #out == 0 then out[1] = {label="本周期暂无阅读记录", arrow=false, enabled=false} end
    return out
end

local function weread_overview(data)
    data = type(data)=="table" and data or {}
    local rows = {
        {label="今日", value=duration(data.today_seconds), arrow=false},
        {label="本周", value=duration(data.week_seconds or data.total_seconds), arrow=false},
        {label="本月", value=duration(data.month_seconds), arrow=false},
    }
    if data.read_days ~= nil then rows[#rows+1] = {label="本周阅读天数", value=tostring(math.floor(tonumber(data.read_days) or 0)).." 天", arrow=false} end
    if data.day_average_seconds ~= nil then rows[#rows+1] = {label="本周自然日均", value=duration(data.day_average_seconds), arrow=false} end
    return rows
end

local function local_overview(data)
    data = type(data)=="table" and data or {}
    return {
        {label="今日", value=duration(data.today_seconds), arrow=false},
        {label="本周", value=duration(data.week_seconds), arrow=false},
        {label="本月", value=duration(data.month_seconds), arrow=false},
        {label="今日阅读页", value=tostring(math.floor(tonumber(data.today_pages) or 0)).." 页", arrow=false},
    }
end

function M.show(kind, data, options)
    kind = tostring(kind or "local")
    data = type(data)=="table" and data or {}
    options = type(options)=="table" and options or {}
    local weread = kind == "weread"
    return ReaderListDialog.show{
        title = weread and "微信读书阅读统计" or "本地阅读统计",
        subtitle = weread and "微信读书账号数据" or "KOReader 本机记录 · 包含在本机阅读的微信读书书籍",
        categories = {
            {key="overview", label="总览", items=weread and weread_overview(data) or local_overview(data)},
            {key="daily", label="本周", items=daily_rows(data.daily)},
        },
        page_size = 7,
        on_back = options.on_back,
    }
end

return M
