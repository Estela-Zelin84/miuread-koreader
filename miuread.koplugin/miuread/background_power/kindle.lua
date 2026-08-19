local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local ok_pluginshare, PluginShare = pcall(require, "pluginshare")
if not ok_pluginshare then PluginShare = nil end

local M = {}

local KEY = "__MIUREAD_KINDLE_BACKGROUND_ALIVE_V1"
local POWER_SOURCES = {
    [1] = "BUTTON_WAKEUP",
    [2] = "BUTTON_SUSPEND",
    [4] = "HALL_SUSPEND",
    [6] = "HALL_WAKEUP",
}

local function state()
    local s = rawget(_G, KEY)
    if type(s) ~= "table" then
        s = {
            active = false,
            session = 0,
            reason = nil,
            entered_at = 0,
            internal_wake_pending = false,
            finish_pending = false,
            finish_session = nil,
            t1_task = nil,
            autosuspend_owned = false,
            autosuspend_previous = nil,
            standby_owned = false,
            tasks = {},
            last_power_kind = nil,
            last_power_source = nil,
            last_power_name = nil,
            last_power_at = 0,
            last_power_self_injected = false,
            injected_expected_kind = nil,
            injected_until = 0,
            injected_ticket = 0,
            injected_reason = nil,
            exit_ticket = nil,
        }
        rawset(_G, KEY, s)
    end
    s.tasks = type(s.tasks) == "table" and s.tasks or {}
    return s
end

local function is_kindle()
    if not (Device and type(Device.isKindle) == "function") then return false end
    local ok, yes = pcall(Device.isKindle, Device)
    return ok and yes == true
end

local function source_name(source, kind)
    local n = tonumber(source)
    return POWER_SOURCES[n] or string.format("UNKNOWN_%s(%s)", tostring(kind or "power"):upper(), tostring(source))
end

local function set_frontlight_hw_off()
    local powerd = Device and Device.powerd
    if powerd and type(powerd.turnOffFrontlightHW) == "function" then
        return pcall(powerd.turnOffFrontlightHW, powerd)
    end
    return false
end

local function pause_autosuspend()
    local s = state()
    if s.autosuspend_owned or not PluginShare then return false end
    s.autosuspend_previous = PluginShare.pause_auto_suspend
    PluginShare.pause_auto_suspend = true
    s.autosuspend_owned = true
    logger.info("[MiuRead][KindleAlive] AutoSuspend paused",
        "previous=", tostring(s.autosuspend_previous))
    return true
end

local function restore_autosuspend(reason)
    local s = state()
    if not s.autosuspend_owned or not PluginShare then return false end
    PluginShare.pause_auto_suspend = s.autosuspend_previous
    logger.info("[MiuRead][KindleAlive] AutoSuspend restored",
        "value=", tostring(s.autosuspend_previous), "reason=", tostring(reason or "unknown"))
    s.autosuspend_previous = nil
    s.autosuspend_owned = false
    return true
end

local function acquire_standby()
    local s = state()
    if s.standby_owned then return true end
    local ok, result = pcall(UIManager.preventStandby, UIManager)
    if not ok or result == false then
        logger.warn("[MiuRead][KindleAlive] preventStandby failed", tostring(ok and result or "call_failed"))
        return false
    end
    s.standby_owned = true
    return true
end

local function release_standby(reason)
    local s = state()
    if not s.standby_owned then return true end
    s.standby_owned = false
    pcall(UIManager.allowStandby, UIManager)
    logger.info("[MiuRead][KindleAlive] standby released", "reason=", tostring(reason or "unknown"))
    return true
end

local function reset_t1()
    local powerd = Device and Device.powerd
    if powerd and type(powerd.resetT1Timeout) == "function" then
        local ok, err = pcall(powerd.resetT1Timeout, powerd)
        if not ok then logger.warn("[MiuRead][KindleAlive] T1 reset failed", tostring(err)) end
        return ok
    end
    return false
end

local function stop_t1_guard()
    local s = state()
    if s.t1_task then
        pcall(UIManager.unschedule, UIManager, s.t1_task)
        s.t1_task = nil
    end
end

local function start_t1_guard(session)
    local s = state()
    stop_t1_guard()
    reset_t1()
    local task
    task = function()
        local current = state()
        if not current.active or current.session ~= session or current.finish_pending then
            if current.t1_task == task then current.t1_task = nil end
            return
        end
        reset_t1()
        UIManager:scheduleIn(12, task)
    end
    s.t1_task = task
    UIManager:scheduleIn(12, task)
end

local function record_power(kind, source)
    local s = state()
    local now = os.time()
    local n = tonumber(source)
    local expected_source = kind == "wake" and 1 or (kind == "suspend" and 2 or nil)
    local self_injected = s.injected_expected_kind == kind
        and expected_source == n
        and now <= (tonumber(s.injected_until) or 0)
    if self_injected then
        s.injected_expected_kind = nil
        s.injected_until = 0
    end
    s.last_power_kind = kind
    s.last_power_source = n
    s.last_power_name = source_name(n, kind)
    s.last_power_at = now
    s.last_power_self_injected = self_injected
    logger.info("[MiuRead][KindleAlive][RawPower]",
        "kind=", tostring(kind), "source=", tostring(s.last_power_name),
        "self_injected=", tostring(self_injected), "active=", tostring(s.active),
        "session=", tostring(s.session), "reason=", tostring(s.injected_reason or "none"))
    if self_injected then s.injected_reason = nil end
    return self_injected
end

local function recent_power(kind, max_age)
    local s = state()
    if kind and s.last_power_kind ~= kind then return nil end
    local age = os.time() - (tonumber(s.last_power_at) or 0)
    if age < 0 or age > (tonumber(max_age) or 3) then return nil end
    return {
        source = tonumber(s.last_power_source),
        name = tostring(s.last_power_name or "unknown"),
        self_injected = s.last_power_self_injected == true,
        age = age,
    }
end

local function power_button(reason, expected_kind)
    local s = state()
    s.injected_ticket = (tonumber(s.injected_ticket) or 0) + 1
    s.injected_expected_kind = expected_kind or "wake"
    s.injected_reason = tostring(reason or "unknown")
    s.injected_until = os.time() + 3
    local issued = false
    local backend = "none"
    local ok_lipc, lipc = pcall(require, "liblipclua")
    if ok_lipc and lipc and type(lipc.init) == "function" then
        local ok_handle, handle = pcall(lipc.init, "com.github.koreader.miuread.background")
        if ok_handle and handle then
            local ok = pcall(handle.set_int_property, handle, "com.lab126.powerd", "powerButton", 1)
            pcall(handle.close, handle)
            issued = ok == true
            backend = "lipc"
        end
    end
    if not issued then
        local ok = os.execute("lipc-set-prop -i com.lab126.powerd powerButton 1 >/dev/null 2>&1")
        issued = ok == true or ok == 0
        backend = "lipc-cli"
    end
    if not issued then
        s.injected_expected_kind = nil
        s.injected_until = 0
        s.injected_reason = nil
    end
    logger.info("[MiuRead][KindleAlive] power transition",
        "reason=", tostring(reason), "expected=", tostring(expected_kind),
        "issued=", tostring(issued), "backend=", backend,
        "ticket=", tostring(s.injected_ticket))
    return issued
end

local function restore_visible_surface(reason)
    local ok_ss, Screensaver = pcall(require, "ui/screensaver")
    if ok_ss and Screensaver and type(Screensaver.close) == "function" then
        pcall(Screensaver.close, Screensaver)
    end
    local powerd = Device and Device.powerd
    if powerd and type(powerd.afterResume) == "function" then
        pcall(powerd.afterResume, powerd)
    end
    pcall(UIManager.setDirty, UIManager, "all", "full")
    logger.warn("[MiuRead][KindleAlive] visible fallback", "reason=", tostring(reason or "unknown"))
end

local function invalidate_session(reason, keep_tasks)
    local s = state()
    stop_t1_guard()
    restore_autosuspend(reason)
    release_standby(reason)
    s.active = false
    s.internal_wake_pending = false
    s.finish_pending = false
    s.finish_session = nil
    s.reason = nil
    s.entered_at = 0
    s.session = (tonumber(s.session) or 0) + 1
    s.injected_expected_kind = nil
    s.injected_until = 0
    s.injected_reason = nil
    if not keep_tasks then s.tasks = {} end
    return s.session
end

local function begin_user_exit(reason, needs_unlock)
    local s = state()
    if not s.active then return false end
    local old_session = s.session
    invalidate_session("user:" .. tostring(reason), true)
    s = state()
    s.exit_ticket = old_session
    if needs_unlock then power_button("user_unlock:" .. tostring(reason), "wake") end
    UIManager:scheduleIn(1.25, function()
        local current = state()
        if current.exit_ticket ~= old_session then return end
        current.exit_ticket = nil
        local screen_saver = Device and Device.screen_saver_mode == true
        if screen_saver then restore_visible_surface("user_exit_timeout:" .. tostring(reason)) end
    end)
    logger.info("[MiuRead][KindleAlive] user exit",
        "source=", tostring(reason), "unlock=", tostring(needs_unlock == true),
        "session=", tostring(old_session))
    return true
end

local function has_tasks()
    local s = state()
    for _, active in pairs(s.tasks or {}) do
        if active == true then return true end
    end
    return false
end

local function confirm_real_suspend()
    local s = state()
    if not s.active or not s.finish_pending then return false end
    logger.info("[MiuRead][KindleAlive] real suspend confirmed", "session=", tostring(s.session))
    invalidate_session("ready_to_suspend", true)
    return true
end

local function install_guards()
    if not is_kindle() then return false end

    if type(Device.intoScreenSaver) == "function" and Device.__miuread_alive_into_guard ~= true then
        local original = Device.intoScreenSaver
        Device.intoScreenSaver = function(self, source, ...)
            record_power("suspend", source)
            return original(self, source, ...)
        end
        Device.__miuread_alive_into_guard = true
    end

    if type(Device.outofScreenSaver) == "function" and Device.__miuread_alive_out_guard ~= true then
        local original = Device.outofScreenSaver
        Device.outofScreenSaver = function(self, source, ...)
            local self_injected = record_power("wake", source)
            local s = state()
            local n = tonumber(source)
            if s.active and not self_injected and (n == 1 or n == 6) then
                begin_user_exit(n == 6 and "HALL_WAKEUP" or "BUTTON_WAKEUP", false)
            end
            return original(self, source, ...)
        end
        Device.__miuread_alive_out_guard = true
    end

    if type(Device.readyToSuspend) == "function" and Device.__miuread_alive_ready_guard ~= true then
        local original = Device.readyToSuspend
        Device.readyToSuspend = function(self, delay, ...)
            local result = original(self, delay, ...)
            confirm_real_suspend()
            return result
        end
        Device.__miuread_alive_ready_guard = true
    end

    local ok_ss, Screensaver = pcall(require, "ui/screensaver")
    if ok_ss and Screensaver and type(Screensaver.close) == "function"
        and Screensaver.__miuread_alive_close_guard ~= true then
        local original_close = Screensaver.close
        Screensaver.close = function(self, ...)
            if state().active then
                logger.info("[MiuRead][KindleAlive] retained sleep screen during background session")
                return false
            end
            return original_close(self, ...)
        end
        Screensaver.__miuread_alive_close_guard = true
    end
    return true
end

install_guards()

function M.supported()
    return is_kindle()
end

function M.active()
    return state().active == true
end

function M.system_active()
    local s = state()
    return s.active and not s.internal_wake_pending and not s.finish_pending
end

function M.set_task(name, active)
    name = tostring(name or "background")
    local s = state()
    s.tasks[name] = active == true or nil
    logger.info("[MiuRead][KindleAlive] task",
        "name=", name, "active=", tostring(active == true), "session=", tostring(s.session))
    if s.active and not has_tasks() then M.finish("last_task_done:" .. name) end
    return true
end

function M.task_active(name)
    return state().tasks[tostring(name or "background")] == true
end

function M.needs_background()
    return has_tasks()
end

function M.begin(reason)
    if not is_kindle() then return false, "unsupported_platform" end
    local s = state()
    if s.active then return true, "already_active" end
    if not has_tasks() then return false, "no_background_task" end
    if not acquire_standby() then return false, "prevent_standby_failed" end
    pause_autosuspend()
    s = state()
    s.active = true
    s.session = (tonumber(s.session) or 0) + 1
    s.reason = tostring(reason or "background")
    s.entered_at = os.time()
    s.internal_wake_pending = true
    s.finish_pending = false
    s.finish_session = nil
    s.exit_ticket = nil
    start_t1_guard(s.session)
    logger.info("[MiuRead][KindleAlive] begin",
        "reason=", s.reason, "session=", tostring(s.session))
    return true, "background_alive"
end

function M.after_suspend()
    local s = state()
    if not s.active or not s.internal_wake_pending or s.finish_pending then return false end
    local session = s.session
    local issued = power_button("enter_background_alive", "wake")
    if issued then
        UIManager:scheduleIn(0.8, function()
            local current = state()
            if current.active and current.session == session and current.internal_wake_pending then
                power_button("enter_background_alive_retry", "wake")
            end
        end)
    end
    return issued
end

function M.on_resume_event()
    local s = state()
    if not s.active then
        s.exit_ticket = nil
        return "normal"
    end
    -- A genuine BUTTON/HALL wake clears active in the raw Device guard before
    -- KOReader reaches this callback. Any Resume still seen while active is the
    -- private wake that keeps powerd ACTIVE behind the retained sleep screen.
    s.internal_wake_pending = false
    set_frontlight_hw_off()
    if not s.finish_pending then start_t1_guard(s.session) end
    logger.info("[MiuRead][KindleAlive] internal resume held", "session=", tostring(s.session))
    return "hold"
end

function M.on_suspend_while_active()
    local s = state()
    if not s.active then return "none" end

    local ev = recent_power("suspend", 3)
    if ev and ev.source == 2 and not ev.self_injected then
        begin_user_exit("BUTTON_SUSPEND", true)
        return "unlock"
    end

    if s.finish_pending then
        -- Background work has ended. This edge is initiated through KOReader's
        -- own UIManager:suspend() path, so hand the lifecycle back to the
        -- normal suspend bookkeeping instead of holding it inside KindleAlive.
        logger.info("[MiuRead][KindleAlive] native suspend commit",
            "source=", tostring(ev and ev.name or "unknown"), "session=", tostring(s.session))
        return "commit"
    end

    -- AutoSuspend is paused and Kindle T1 is refreshed while active. Therefore
    -- any remaining suspend edge is an internal/firmware edge, not a condition
    -- that a download worker must interpret. Bounce powerd back to ACTIVE and
    -- keep the user-facing sleep screen untouched.
    local session = s.session
    s.internal_wake_pending = true
    UIManager:scheduleIn(0.12, function()
        local current = state()
        if current.active and current.session == session and current.internal_wake_pending
            and not current.finish_pending then
            power_button("internal_suspend_hold", "wake")
        end
    end)
    return "hold"
end

function M.finish(reason)
    local s = state()
    if not s.active or s.finish_pending or has_tasks() then return false end
    s.finish_pending = true
    s.finish_session = s.session
    -- Do not let the original physical lock edge (which may be only a couple
    -- seconds old for a short finalizer) get re-used as a fresh user-unlock
    -- signal when we hand the session back to native suspend.
    s.last_power_kind = nil
    s.last_power_source = nil
    s.last_power_name = nil
    s.last_power_at = 0
    s.last_power_self_injected = false
    stop_t1_guard()
    restore_autosuspend("finish")
    release_standby("finish")
    local session = s.session
    logger.info("[MiuRead][KindleAlive] background complete; handing back to KOReader suspend",
        "reason=", tostring(reason or "done"), "session=", tostring(session))

    -- Do NOT toggle com.lab126.powerd powerButton here. That bypasses the
    -- normal KOReader suspend lifecycle and can leave MiuRead/KOReader asleep
    -- state out of sync with powerd. Ask UIManager to suspend normally; the
    -- next onSuspend edge returns "commit" above and runs the ordinary
    -- REAL_SUSPEND bookkeeping before Kindle actually sleeps.
    UIManager:scheduleIn(0, function()
        local current = state()
        if not current.active or current.session ~= session or not current.finish_pending
            or has_tasks() then return end
        -- Native Kindle suspend is ultimately routed through powerd.toggleSuspend(),
        -- which emits the same BUTTON_SUSPEND source (2) as a physical key.
        -- Arm the existing short-lived self-injected classifier *only* around
        -- this immediate native request, so the resulting suspend edge is
        -- committed instead of being mistaken for a user unlock.
        current.injected_expected_kind = "suspend"
        current.injected_reason = "background_complete_native_suspend"
        current.injected_until = os.time() + 3
        local ok, err = pcall(UIManager.suspend, UIManager)
        if not ok then
            current.injected_expected_kind = nil
            current.injected_reason = nil
            current.injected_until = 0
            logger.warn("[MiuRead][KindleAlive] KOReader native suspend request failed",
                "session=", tostring(session), "error=", tostring(err))
            current.finish_pending = false
            invalidate_session("finish_request_failed", true)
            restore_visible_surface("finish_request_failed")
        end
    end)

    -- If KOReader stays runnable but never reaches ReadyToSuspend, fail visible.
    -- On a successful real suspend this timer will not execute until Resume,
    -- by which time readyToSuspend has already invalidated this session.
    UIManager:scheduleIn(6.0, function()
        local current = state()
        if not current.active or current.session ~= session or not current.finish_pending then return end
        logger.warn("[MiuRead][KindleAlive] KOReader native suspend confirmation timeout",
            "session=", tostring(session))
        current.finish_pending = false
        invalidate_session("finish_timeout", true)
        restore_visible_surface("finish_timeout")
    end)
    return true
end

function M.background_task_done(reason)
    if M.active() and not has_tasks() then return M.finish(reason) end
    return true
end

function M.force_clear(reason)
    if not M.active() then return false end
    invalidate_session(reason or "force_clear", true)
    return true
end

function M.mark_user_sleep(origin)
    local s = state()
    s.pending_user_sleep_origin = tostring(origin or "unknown")
    s.pending_user_sleep_at = os.time()
    return true
end

function M.consume_user_sleep_origin()
    local s = state()
    local origin = s.pending_user_sleep_origin
    local age = os.time() - (tonumber(s.pending_user_sleep_at) or 0)
    s.pending_user_sleep_origin = nil
    s.pending_user_sleep_at = 0
    if origin and age >= 0 and age <= 5 then return origin end
    return nil
end

function M.snapshot()
    local s = state()
    local tasks = {}
    for name, active in pairs(s.tasks or {}) do if active == true then tasks[name] = true end end
    return {
        active = s.active == true,
        platform = "kindle",
        system_active = M.system_active(),
        session = tonumber(s.session or 0) or 0,
        reason = s.reason,
        internal_resume_pending = s.internal_wake_pending == true,
        user_exit_pending = false,
        commit_pending = s.finish_pending == true,
        download_active = s.tasks.download == true,
        tasks = tasks,
        autosuspend_pause_owned = s.autosuspend_owned == true,
        standby_owned = s.standby_owned == true,
        last_power_source_name = s.last_power_name,
        last_power_self_injected = s.last_power_self_injected == true,
    }
end

return M
