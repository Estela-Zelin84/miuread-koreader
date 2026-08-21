local DataStorage = require("datastorage")
local Device = require("device")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local HomeData = {}
local stats_cache
local device_cache

local function clamp_number(value, minimum, maximum)
    value = tonumber(value) or 0
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

function HomeData.format_duration(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    if hours > 0 then return tostring(hours) .. " 小时 " .. tostring(minutes) .. " 分" end
    return tostring(minutes) .. " 分钟"
end

function HomeData.reading_stats(force)
    local now = os.time()
    if not force and stats_cache and now - stats_cache.at < 30 then
        return stats_cache.value
    end

    local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    if lfs.attributes(path, "mode") ~= "file" then
        stats_cache = {at = now, value = nil}
        return nil
    end

    local ok, value = pcall(function()
        local SQ3 = require("lua-ljsqlite3/init")
        local conn = SQ3.open(path, "ro")
        local result
        local query_ok, query_error = pcall(function()
            conn:exec("PRAGMA busy_timeout=180;")
            local date = os.date("*t", now)
            local day_start = os.time{
                year = date.year, month = date.month, day = date.day,
                hour = 0, min = 0, sec = 0,
            }
            local week_start = day_start - ((date.wday + 5) % 7) * 86400
            local month_start = os.time{
                year = date.year, month = date.month, day = 1,
                hour = 0, min = 0, sec = 0,
            }

            local total_statement = conn:prepare([[
                SELECT COALESCE(SUM(duration), 0)
                  FROM page_stat_data
                 WHERE start_time >= ?
            ]])
            local function total_since(stamp)
                local row = total_statement:bind(stamp):step()
                local seconds = tonumber(row and row[1]) or 0
                total_statement:clearbind():reset()
                return seconds
            end
            local today_seconds = total_since(day_start)
            local week_seconds = total_since(week_start)
            local month_seconds = total_since(month_start)
            total_statement:close()

            local pages_statement = conn:prepare([[
                SELECT COUNT(DISTINCT (id_book || ':' || page))
                  FROM page_stat_data
                 WHERE start_time >= ?
            ]])
            local pages_row = pages_statement:bind(day_start):step()
            local today_pages = tonumber(pages_row and pages_row[1]) or 0
            pages_statement:close()

            local daily = {}
            local daily_statement = conn:prepare([[
                SELECT COALESCE(SUM(duration), 0)
                  FROM page_stat_data
                 WHERE start_time >= ? AND start_time < ?
            ]])
            for index = 0, 6 do
                local stamp = week_start + index * 86400
                if stamp > day_start then break end
                local row = daily_statement:bind(stamp, stamp + 86400):step()
                daily_statement:clearbind():reset()
                daily[#daily + 1] = {
                    stamp = stamp,
                    date = os.date("%m-%d", stamp),
                    weekday = os.date("%w", stamp),
                    seconds = tonumber(row and row[1]) or 0,
                }
            end
            daily_statement:close()

            result = {
                today_seconds = today_seconds,
                today_pages = today_pages,
                week_seconds = week_seconds,
                month_seconds = month_seconds,
                daily = daily,
                updated_at = now,
            }
        end)
        conn:close()
        if not query_ok then error(query_error) end
        return result
    end)

    if not ok then
        logger.warn("[MiuRead][Home] reading statistics unavailable", tostring(value))
        value = nil
    end
    stats_cache = {at = now, value = value}
    return value
end

local function normalized_timestamp(value)
    local stamp = tonumber(value)
    if not stamp then return nil end
    if stamp > 100000000000 then stamp = math.floor(stamp / 1000) end
    return stamp
end

local function weread_bucket_seconds(read_times, target_date)
    if type(read_times) ~= "table" then return 0 end
    for key, value in pairs(read_times) do
        local stamp = normalized_timestamp(key)
        if stamp and os.date("%Y-%m-%d", stamp) == target_date then
            return math.max(0, tonumber(value) or 0)
        end
    end
    return 0
end

function HomeData.weread_summary(data, now)
    data = type(data) == "table" and data or {}
    now = tonumber(now) or os.time()
    local read_times = type(data.readTimes) == "table" and data.readTimes or {}
    local buckets = {}
    for key, value in pairs(read_times) do
        local stamp = normalized_timestamp(key)
        if stamp then
            buckets[#buckets + 1] = {
                stamp = stamp,
                date = os.date("%m-%d", stamp),
                weekday = os.date("%w", stamp),
                seconds = math.max(0, tonumber(value) or 0),
            }
        end
    end
    table.sort(buckets, function(a, b) return (a.stamp or 0) < (b.stamp or 0) end)
    return {
        today_seconds = weread_bucket_seconds(read_times, os.date("%Y-%m-%d", now)),
        total_seconds = math.max(0, tonumber(data.totalReadTime) or 0),
        read_days = math.max(0, tonumber(data.readDays) or 0),
        day_average_seconds = math.max(0, tonumber(data.dayAverageReadTime) or 0),
        compare = tonumber(data.compare),
        daily = buckets,
        base_time = normalized_timestamp(data.baseTime) or 0,
        fetched_at = now,
    }
end

function HomeData.invalidate_device_state()
    device_cache = nil
end

function HomeData.cached_device_state()
    return device_cache and device_cache.value or nil
end

local function read_power_state()
    local result={battery=nil,charging=false}
    local ok_power,power=pcall(Device.getPowerDevice,Device)
    if ok_power and power then
        if type(power.getCapacity)=="function" then
            local ok,capacity=pcall(power.getCapacity,power)
            if ok and tonumber(capacity) then result.battery=clamp_number(capacity,0,100) end
        end
        if type(power.isCharging)=="function" then
            local ok,charging=pcall(power.isCharging,power)
            if ok then result.charging=charging==true end
        end
    end
    return result
end

-- Refresh battery/charging without touching Wi-Fi, storage or shelf state.
-- Home's minute clock uses this path so an e-ink device can keep a truthful
-- battery number without rebuilding the page or polling the network.
function HomeData.quick_power_state(force)
    local now=os.time()
    if not force and device_cache and tonumber(device_cache.power_at)
        and now-tonumber(device_cache.power_at)<60 then
        local cached=device_cache.value or {}
        return {battery=cached.battery,charging=cached.charging==true}
    end
    local power=read_power_state()
    local state={}
    for key,value in pairs(device_cache and device_cache.value or {}) do state[key]=value end
    state.battery=power.battery
    state.charging=power.charging==true
    device_cache={
        at=device_cache and tonumber(device_cache.at) or 0,
        power_at=now,
        value=state,
    }
    return power
end

function HomeData.quick_device_state(force)
    local now = os.time()
    if not force and device_cache and now - device_cache.at < 60 then
        return device_cache.value
    end
    local state = {online = nil, wifi_on = nil, connected = nil, wifi_name = nil, battery = nil, charging = false}
    local power=read_power_state()
    state.battery=power.battery
    state.charging=power.charging==true
    local ok_network, network = pcall(require, "ui/network/manager")
    if ok_network and network then
        if type(network.queryNetworkState) == "function" then pcall(network.queryNetworkState, network) end
        if type(network.isWifiOn) == "function" then
            local ok, value = pcall(network.isWifiOn, network)
            if ok then state.wifi_on = value == true end
        end
        if state.wifi_on == false then
            state.connected = false
        elseif type(network.isConnected) == "function" then
            local ok, value = pcall(network.isConnected, network)
            if ok then state.connected = value == true end
        end
        if state.connected ~= false and type(network.isOnline) == "function" then
            local ok, online = pcall(network.isOnline, network)
            if ok then state.online = online == true end
        elseif state.connected == false then
            state.online = false
        end
        if state.wifi_on == true and state.connected ~= false and type(network.getCurrentNetwork) == "function" then
            local ok, current = pcall(network.getCurrentNetwork, network)
            if ok and type(current) == "table" then
                local ssid = tostring(current.ssid or current.name or ""):gsub("^%s+", ""):gsub("%s+$", "")
                if ssid ~= "" then state.wifi_name = ssid end
            end
        end
    end
    device_cache = {at = now, power_at=now, value = state}
    return state
end

function HomeData.device_state(force)
    local now = os.time()
    local base = HomeData.quick_device_state(force)
    if not force and device_cache and device_cache.value.storage_checked_at
        and now - device_cache.value.storage_checked_at < 60 then
        return device_cache.value
    end

    local state = {}
    for key, value in pairs(base or {}) do state[key] = value end
    state.storage_free = state.storage_free
    state.storage_total = state.storage_total
    local ok_util, util = pcall(require, "util")
    if ok_util and util and type(util.diskUsage) == "function" then
        local drive = Device.home_dir or DataStorage:getDataDir() or "/"
        local ok, usage = pcall(util.diskUsage, drive)
        if ok and type(usage) == "table" then
            state.storage_free = tonumber(usage.available)
            state.storage_total = tonumber(usage.total)
        end
    end
    state.storage_checked_at = now
    device_cache = {at = now, value = state}
    return state
end

function HomeData.format_bytes(bytes)
    bytes = tonumber(bytes)
    if not bytes or bytes < 0 then return "未知" end
    local gib = bytes / 1024 / 1024 / 1024
    if gib >= 1 then return string.format("%.1f GB", gib) end
    return string.format("%.0f MB", bytes / 1024 / 1024)
end

return HomeData
