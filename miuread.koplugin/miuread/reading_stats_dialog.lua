local HomeData = require("miuread.home_data")
local ReaderListDialog = require("miuread.reader_list_dialog")

local M = {}
local WEEKDAY = { ["0"]="日", ["1"]="一", ["2"]="二", ["3"]="三", ["4"]="四", ["5"]="五", ["6"]="六" }

local function resolved(data)
    if type(data)=="function" then
        local ok,value=pcall(data)
        if ok and type(value)=="table" then return value end
        return {}
    end
    return type(data)=="table" and data or {}
end

local function duration(value)
    if value == nil then return "暂无" end
    return HomeData.format_duration(value)
end

local function compare_text(value)
    value=tonumber(value)
    if not value then return nil end
    local pct=math.floor(math.abs(value)*100+.5)
    if pct==0 then return "与上期基本持平" end
    return value>0 and ("较上期 ↑"..tostring(pct).."%") or ("较上期 ↓"..tostring(pct).."%")
end

local function intensity(seconds, future)
    if future then return "·" end
    seconds=math.max(0,tonumber(seconds) or 0)
    if seconds<=0 then return "○" end
    if seconds<15*60 then return "◔" end
    if seconds<45*60 then return "◑" end
    return "●"
end

local function week_check_text(rows, threshold)
    rows=HomeData.week_rows(rows,os.time())
    threshold=tonumber(threshold) or 1
    local marks,labels={},{}
    for _,row in ipairs(rows) do
        if row.future then marks[#marks+1]="·"
        elseif (tonumber(row.seconds) or 0)>=threshold then marks[#marks+1]="✓"
        else marks[#marks+1]="—" end
        labels[#labels+1]=WEEKDAY[tostring(row.weekday or "")] or "·"
    end
    return table.concat(marks,"   ").."\n"..table.concat(labels,"   ")
end

local function summary_rows(period, source)
    period=type(period)=="table" and period or {}
    source=tostring(source or "")
    local rows={
        {label=duration(period.total_seconds), detail=(period.label and tostring(period.label) or "当前周期").."累计阅读", arrow=false, bold=true},
    }
    local parts={}
    if period.read_days~=nil then parts[#parts+1]="阅读 "..tostring(math.floor(tonumber(period.read_days) or 0)).." 天" end
    if period.day_average_seconds~=nil then parts[#parts+1]="自然日均 "..duration(period.day_average_seconds) end
    if period.pages~=nil and source=="local" then parts[#parts+1]="阅读 "..tostring(math.floor(tonumber(period.pages) or 0)).." 页" end
    if #parts>0 then rows[#rows+1]={label=table.concat(parts," · "),arrow=false} end
    local compare=compare_text(period.compare)
    if compare then rows[#rows+1]={label=compare,arrow=false} end
    return rows
end

local function append_rank(rows, rank, limit)
    rank=type(rank)=="table" and rank or {}
    limit=math.min(#rank,tonumber(limit) or 5)
    if limit<=0 then return end
    rows[#rows+1]={label="读书排行",detail="按当前周期阅读时长",arrow=false,bold=true,enabled=false}
    local max_seconds=0
    for index=1,limit do max_seconds=math.max(max_seconds,tonumber(rank[index].seconds) or 0) end
    for index=1,limit do
        local item=rank[index]
        local ratio=max_seconds>0 and math.max(1,math.floor((tonumber(item.seconds) or 0)/max_seconds*10+.5)) or 1
        rows[#rows+1]={
            label=tostring(index)..". "..tostring(item.title or "未命名"),
            detail=string.rep("━",ratio),
            value=duration(item.seconds),
            arrow=false,
        }
    end
end

local function month_calendar_rows(daily)
    daily=type(daily)=="table" and daily or {}
    if #daily==0 then return {} end
    local rows={
        {label="阅读日历",detail="○ 未读 · ◔ <15分 · ◑ 15–45分 · ● >45分",arrow=false,bold=true,enabled=false},
        {label="一   二   三   四   五   六   日",arrow=false,enabled=false},
    }
    local week={" "," "," "," "," "," "," "}
    local week_days={"","","","","","",""}
    local function flush()
        local mark_line=table.concat(week,"   ")
        local day_line=table.concat(week_days,"  ")
        rows[#rows+1]={label=mark_line,detail=day_line,arrow=false,enabled=false}
        week={" "," "," "," "," "," "," "}
        week_days={"","","","","","",""}
    end
    for index,row in ipairs(daily) do
        local wd=tonumber(row.weekday)
        local col=wd==0 and 7 or wd
        local day=tostring(row.date or ""):match("%-(%d%d)$") or tostring(index)
        week[col]=intensity(row.seconds,row.future)
        week_days[col]=day
        if col==7 then flush() end
    end
    if table.concat(week_days,"")~="" then flush() end
    return rows
end

local function bucket_rows(buckets, heading)
    buckets=type(buckets)=="table" and buckets or {}
    if #buckets==0 then return {} end
    local rows={{label=heading or "阅读趋势",arrow=false,bold=true,enabled=false}}
    local max_seconds=0
    for _,item in ipairs(buckets) do if not item.future then max_seconds=math.max(max_seconds,tonumber(item.seconds) or 0) end end
    for _,item in ipairs(buckets) do
        if not item.future then
            local ratio=max_seconds>0 and math.floor((tonumber(item.seconds) or 0)/max_seconds*12+.5) or 0
            rows[#rows+1]={label=tostring(item.label or ""),detail=ratio>0 and string.rep("━",math.max(1,ratio)) or "—",value=duration(item.seconds),arrow=false}
        end
    end
    return rows
end

local function read_stat_rows(items)
    local rows={}
    for _,item in ipairs(type(items)=="table" and items or {}) do
        local label=tostring(item.stat or "")
        local value=tostring(item.counts or "")
        if label~="" and value~="" then rows[#rows+1]={label=label,value=value,arrow=false} end
    end
    return rows
end

local function preference_rows(period)
    local rows={}
    local categories=type(period.prefer_category)=="table" and period.prefer_category or {}
    if #categories>0 then
        rows[#rows+1]={label=period.prefer_category_word~="" and period.prefer_category_word or "阅读偏好",arrow=false,bold=true,enabled=false}
        for index=1,math.min(5,#categories) do
            local item=categories[index]
            local title=tostring(item.categoryTitle or item.parentCategoryTitle or "")
            if title~="" then rows[#rows+1]={label=title,value=duration(item.readingTime),arrow=false} end
        end
    end
    local authors=type(period.prefer_author)=="table" and period.prefer_author or {}
    if #authors>0 then
        rows[#rows+1]={label="偏好作者",arrow=false,bold=true,enabled=false}
        for index=1,math.min(4,#authors) do
            local item=authors[index]
            rows[#rows+1]={label=tostring(item.name or "作者"),value=tostring(item.readTime or ((tonumber(item.count) or 0).." 本")),arrow=false}
        end
    end
    if tostring(period.prefer_time_word or "")~="" then rows[#rows+1]={label="阅读时段",value=tostring(period.prefer_time_word),arrow=false} end
    if tonumber(period.read_rate) then rows[#rows+1]={label="文字阅读占比",value=tostring(math.floor(period.read_rate+.5)).."%",arrow=false} end
    return rows
end

local function weread_period(source,key)
    local data=resolved(source)
    return type(data[key])=="table" and data[key] or nil
end

local function local_period(source,key)
    local data=resolved(source)
    local periods=type(data.periods)=="table" and data.periods or {}
    if type(periods[key])=="table" then return periods[key] end
    if key=="weekly" then
        return {label="本周",total_seconds=data.week_seconds,read_days=data.read_days,day_average_seconds=data.day_average_seconds,daily=data.daily,pages=data.today_pages}
    end
    return nil
end

local function category_items(kind,source,key,options)
    local period=kind=="weread" and weread_period(source,key) or local_period(source,key)
    if not period then return {{label="正在获取这一周期的数据…",detail="首次打开年/总统计时需要联网读取",arrow=false,enabled=false}} end
    if period.loading==true then return {{label="正在获取 "..tostring(period.label or "这一周期").."…",detail="读取完成后会自动刷新",arrow=false,enabled=false}} end
    local rows={}
    if key~="overall" and type(options)=="table" and type(options.on_shift_period)=="function" then
        rows[#rows+1]={
            label=tostring(period.label or "当前周期"),detail="点击切换历史周期",bold=true,
            inline_actions={
                {label="‹ 上一周期",callback=function() options.on_shift_period(key,-1) end},
                {label="本期",enabled=period.is_current~=true,callback=function() options.on_shift_period(key,0) end},
                {label="下一周期 ›",enabled=period.is_current~=true,callback=function() options.on_shift_period(key,1) end},
            },
        }
    end
    for _,row in ipairs(summary_rows(period,kind)) do rows[#rows+1]=row end
    if key=="weekly" then
        rows[#rows+1]={label="本周打卡",detail=week_check_text(period.daily,kind=="weread" and 60 or 1),arrow=false,bold=true}
        local daily=HomeData.week_rows(period.daily,os.time())
        for _,day in ipairs(daily) do
            if not day.future then
                rows[#rows+1]={label=tostring(day.date or "").." 周"..(WEEKDAY[tostring(day.weekday or "")] or ""),value=duration(day.seconds),arrow=false}
            end
        end
    elseif key=="monthly" then
        local calendar_daily=kind=="weread" and HomeData.month_rows(period.daily,period.base_time,os.time()) or period.daily
        local cal=month_calendar_rows(calendar_daily)
        for _,row in ipairs(cal) do rows[#rows+1]=row end
    elseif key=="annually" then
        local buckets=period.daily or period.buckets
        local trends=bucket_rows(buckets,"月度阅读趋势")
        for _,row in ipairs(trends) do rows[#rows+1]=row end
    elseif key=="overall" then
        local trends=bucket_rows(period.daily or period.buckets,"历年阅读趋势")
        for _,row in ipairs(trends) do rows[#rows+1]=row end
        if kind=="weread" then
            local stats=read_stat_rows(period.read_stat)
            if #stats>0 then rows[#rows+1]={label="阅读统计",arrow=false,bold=true,enabled=false} end
            for _,row in ipairs(stats) do rows[#rows+1]=row end
        end
    end
    append_rank(rows,period.rank,5)
    if kind=="weread" and (key=="annually" or key=="overall") then
        for _,row in ipairs(preference_rows(period)) do rows[#rows+1]=row end
    end
    return rows
end

function M.show(kind, data, options)
    kind=tostring(kind or "local")
    options=type(options)=="table" and options or {}
    local weread=kind=="weread"
    return ReaderListDialog.show{
        title=weread and "微信读书阅读统计" or "本地阅读统计",
        subtitle=weread and "微信读书账号数据 · 周/月/年/总" or "KOReader 本机记录 · 周/月/年/总",
        categories={
            {key="weekly",label="周",items=function() return category_items(kind,data,"weekly",options) end},
            {key="monthly",label="月",items=function() return category_items(kind,data,"monthly",options) end},
            {key="annually",label="年",items=function() return category_items(kind,data,"annually",options) end},
            {key="overall",label="总",items=function() return category_items(kind,data,"overall",options) end},
        },
        page_size=7,
        on_back=options.on_back,
        on_home=options.on_home,
    }
end

return M
