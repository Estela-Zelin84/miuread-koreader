local DataStorage = require("datastorage")
local Device = require("device")
local lfs = require("libs/libkoreader-lfs")

local HomeData = {}
local device_cache

local function clamp_number(value, minimum, maximum)
    value = tonumber(value) or 0
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

function HomeData.quick_device_state()
    local now = os.time()
    if device_cache and now - device_cache.at < 60 then
        return device_cache.value
    end
    local state = {online = nil, battery = nil, charging = false}
    local ok_power, power = pcall(Device.getPowerDevice, Device)
    if ok_power and power then
        if type(power.getCapacity) == "function" then
            local ok, capacity = pcall(power.getCapacity, power)
            if ok and tonumber(capacity) then state.battery = clamp_number(capacity, 0, 100) end
        end
        if type(power.isCharging) == "function" then
            local ok, charging = pcall(power.isCharging, power)
            if ok then state.charging = charging == true end
        end
    end
    local ok_network, network = pcall(require, "ui/network/manager")
    if ok_network and network and type(network.isOnline) == "function" then
        local ok, online = pcall(network.isOnline, network)
        if ok then state.online = online == true end
    end
    return state
end

function HomeData.device_state(force)
    local now = os.time()
    if not force and device_cache and now - device_cache.at < 60 then
        return device_cache.value
    end

    local state = {online = nil, battery = nil, charging = false, storage_free = nil, storage_total = nil}
    local ok_power, power = pcall(Device.getPowerDevice, Device)
    if ok_power and power then
        if type(power.getCapacity) == "function" then
            local ok, capacity = pcall(power.getCapacity, power)
            if ok and tonumber(capacity) then state.battery = clamp_number(capacity, 0, 100) end
        end
        if type(power.isCharging) == "function" then
            local ok, charging = pcall(power.isCharging, power)
            if ok then state.charging = charging == true end
        end
    end

    local ok_network, network = pcall(require, "ui/network/manager")
    if ok_network and network and type(network.isOnline) == "function" then
        local ok, online = pcall(network.isOnline, network)
        if ok then state.online = online == true end
    end

    local ok_util, util = pcall(require, "util")
    if ok_util and util and type(util.diskUsage) == "function" then
        local drive = Device.home_dir or DataStorage:getDataDir() or "/"
        local ok, usage = pcall(util.diskUsage, drive)
        if ok and type(usage) == "table" then
            state.storage_free = tonumber(usage.available)
            state.storage_total = tonumber(usage.total)
        end
    end

    device_cache = {at = now, value = state}
    return state
end

return HomeData
