local RawButtonDialog=require("ui/widget/buttondialog")
local RawConfirmBox=require("ui/widget/confirmbox")
local RawInfoMessage=require("ui/widget/infomessage")
local RawInputDialog=require("ui/widget/inputdialog")
local RawMenu=require("ui/widget/menu")
local RawPathChooser=require("ui/widget/pathchooser")
local UIManager=require("ui/uimanager")
local Device=require("device")
local Event=require("ui/event")
local WidgetContainer=require("ui/widget/container/widgetcontainer")
local logger=require("logger")
local lfs=require("libs/libkoreader-lfs")
local Config=require("miuread.config")
local Text=require("miuread.text")
local U=require("miuread.util")
local Json=require("miuread.json")
local Store=require("miuread.store")
local Http=require("miuread.http")
local Api=require("miuread.api")
local Auth=require("miuread.auth")
local Reader=require("miuread.reader")
local Protocol=require("miuread.protocol")
local MP=require("miuread.mp")
local Access=require("miuread.access")
local Annotations=require("miuread.annotations")
local Downloader=require("miuread.downloader")
local DownloadProgress=require("miuread.download_progress")
local DownloadTask=require("miuread.download_task")
local DownloadResult=require("miuread.download_result")
local EpubInstaller=require("miuread.epub_installer")
local CacheCleanupTask=require("miuread.cache_cleanup_task")
local MemoryMode=require("miuread.memory_mode")
local Library=require("miuread.library")
local ShelfView=require("miuread.shelf_view")
local HomeView=require("miuread.home_view")
local HomeQuickPanel=require("miuread.home_quick_panel")
local NativeMenuBackdrop=require("miuread.native_menu_backdrop")
local GestureBridge=require("miuread.gesture_bridge")
local HomeData=require("miuread.home_data")
local LocalLibrary=require("miuread.local_library")
local LocalMetadata=require("miuread.local_metadata")
local Async=require("miuread.async")
local Sync=require("miuread.sync")
local Updater=require("miuread.updater")
local Cookies=require("miuread.cookies")
local Thoughts=require("miuread.thoughts")
local ThoughtNativePopup=require("miuread.thought_native_popup")
local ReaderToolbar=require("miuread.reader_toolbar")
local ReaderProgressDialog=require("miuread.reader_progress_dialog")
local ReaderSettingsDialog=require("miuread.reader_settings_dialog")
local BookRepair=require("miuread.book_repair")
local StatusToast=require("miuread.status_toast")
local Actions=require("miuread.actions")
local function gesture_aware_class(base, attributes)
    local class=base:extend(attributes or {})
    function class:handleEvent(event)
        return GestureBridge.handle(base,self,event)
    end
    return class
end
local ButtonDialog=gesture_aware_class(RawButtonDialog,{_miuread_transient=true})
local ConfirmBox=gesture_aware_class(RawConfirmBox,{_miuread_transient=true})
local InfoMessage=gesture_aware_class(RawInfoMessage,{_miuread_transient=true})
local InputDialog=gesture_aware_class(RawInputDialog,{_miuread_transient=true})
local Menu=gesture_aware_class(RawMenu,{_miuread_transient=true})
local PathChooser=gesture_aware_class(RawPathChooser,{_miuread_transient=true})
local _=Text.tr
local unpack_args=unpack or table.unpack
local SHELF_CACHE_TTL=15*60
local SHELF_DIRECT_CACHE_TTL=6*60*60
local COVER_GUARD_WINDOW=6*60*60
local HOME_LOCAL_CACHE_TTL=15*60
local HOME_SHELF_REFRESH_TTL=90
local HOME_SECTION_ORDER={"account","generated","local","mp"}
local HOME_QUICK_ITEM_LEGACY_ORDER={"wifi","frontlight","refresh_shelf","full_refresh","settings","koreader_menu","downloads","sync","night","rotate","sleep","restart","quit"}
local HOME_QUICK_ITEM_LEGACY_DEFAULT={wifi=true,frontlight=true,refresh_shelf=true,full_refresh=true,settings=true,koreader_menu=true,downloads=true,sync=true,night=false,rotate=false,sleep=true,restart=false,quit=false}
local HOME_QUICK_ITEM_ORDER={"wifi","frontlight","refresh_shelf","downloads","sync","settings","night","rotate","full_refresh","sleep","restart","quit","koreader_menu"}
local HOME_QUICK_ITEM_DEFAULT={wifi=true,frontlight=true,refresh_shelf=true,downloads=true,sync=true,settings=true,night=false,rotate=false,full_refresh=false,sleep=false,restart=false,quit=false,koreader_menu=false}
local READER_QUICK_ITEM_LEGACY_ORDER={"home","toc","progress","font","typeset","sync","current_book","downloads","full_refresh","koreader_menu","sleep","more"}
local READER_QUICK_ITEM_LEGACY_DEFAULT={home=true,toc=true,progress=true,font=true,typeset=true,sync=true,current_book=true,downloads=false,full_refresh=false,koreader_menu=false,sleep=false,more=true}
local READER_QUICK_ITEM_ORDER={"home","toc","progress","font","sync","more","typeset","current_book","downloads","full_refresh","koreader_menu","sleep"}
local READER_QUICK_ITEM_DEFAULT={home=true,toc=true,progress=true,font=true,sync=true,more=true,typeset=false,current_book=false,downloads=false,full_refresh=false,koreader_menu=false,sleep=false}
local function quick_boolean_layout_matches(actual,expected,order)
    if type(actual)~="table" then return false end
    for _,key in ipairs(order or {}) do
        if (actual[key]==true)~=(expected[key]==true) then return false end
    end
    return true
end
local function quick_order_matches(actual,expected)
    if type(actual)~="table" or #actual~=#expected then return false end
    for index,key in ipairs(expected) do if actual[index]~=key then return false end end
    return true
end
-- ReaderUI and FileManager create separate plugin instances. Keep navigation
-- state in _G so opening/closing a document does not lose its MiuRead origin.
local HOME_SESSION=rawget(_G,"__MIUREAD_HOME_SESSION")
if type(HOME_SESSION)~="table" then
    HOME_SESSION={suppressed=false,native_visit=false,expected_close=false,exiting=false,return_file=nil,reader_origin=false,reader_file=nil}
    rawset(_G,"__MIUREAD_HOME_SESSION",HOME_SESSION)
end
local HOME_SESSION_SUPPRESSED=HOME_SESSION.suppressed==true
local HOME_NATIVE_VISIT=HOME_SESSION.native_visit==true
local HOME_EXPECTED_CLOSE=HOME_SESSION.expected_close==true
local HOME_EXITING=HOME_SESSION.exiting==true
local HOME_RETURN_FILE=HOME_SESSION.return_file
local HOME_READER_ORIGIN=HOME_SESSION.reader_origin==true
local HOME_READER_FILE=HOME_SESSION.reader_file
local function persist_home_session()
    HOME_SESSION.suppressed=HOME_SESSION_SUPPRESSED==true
    HOME_SESSION.native_visit=HOME_NATIVE_VISIT==true
    HOME_SESSION.expected_close=HOME_EXPECTED_CLOSE==true
    HOME_SESSION.exiting=HOME_EXITING==true
    HOME_SESSION.return_file=HOME_RETURN_FILE
    HOME_SESSION.reader_origin=HOME_READER_ORIGIN==true
    HOME_SESSION.reader_file=HOME_READER_FILE
end
local function sync_home_session()
    HOME_SESSION_SUPPRESSED=HOME_SESSION.suppressed==true
    HOME_NATIVE_VISIT=HOME_SESSION.native_visit==true
    HOME_EXPECTED_CLOSE=HOME_SESSION.expected_close==true
    HOME_EXITING=HOME_SESSION.exiting==true
    HOME_RETURN_FILE=HOME_SESSION.return_file
    HOME_READER_ORIGIN=HOME_SESSION.reader_origin==true
    HOME_READER_FILE=HOME_SESSION.reader_file
end
local function normalized_reader_file(path)
    path=tostring(path or "")
    if path=="" then return nil end
    return path
end
local function mark_reader_origin(path)
    HOME_READER_ORIGIN=true
    HOME_NATIVE_VISIT=false
    HOME_READER_FILE=normalized_reader_file(path) or HOME_READER_FILE
    persist_home_session()
end
local THOUGHT_MAINTENANCE=rawget(_G,"__MIUREAD_THOUGHT_MAINTENANCE")
if type(THOUGHT_MAINTENANCE)~="table" then
    THOUGHT_MAINTENANCE={running=false,last_at=0}
    rawset(_G,"__MIUREAD_THOUGHT_MAINTENANCE",THOUGHT_MAINTENANCE)
end
-- Track a temporary KOReader menu visit globally because FileManager and
-- ReaderUI use different plugin instances. A clean fullscreen backdrop hides
-- both native FileManager and MiuRead until the last native menu/dialog closes.
local NATIVE_MENU_GUARD=rawget(_G,"__MIUREAD_NATIVE_MENU_GUARD")
if type(NATIVE_MENU_GUARD)~="table" then
    NATIVE_MENU_GUARD={token=0,active=false,finishing=false,menu=nil,container=nil,watch=nil,backdrop=nil,original_close=nil}
    rawset(_G,"__MIUREAD_NATIVE_MENU_GUARD",NATIVE_MENU_GUARD)
end
local DIRECT_MENU_INSERTED=false
local SCREENSAVER_PATCHED=false

local function install_home_screensaver_patch()
    if SCREENSAVER_PATCHED then return true end
    local ok,Screensaver=pcall(require,"ui/screensaver")
    if not ok or not Screensaver or type(Screensaver.setup)~="function" then return false end
    if Screensaver._miuread_original_setup then SCREENSAVER_PATCHED=true; return true end
    local original=Screensaver.setup
    local keys={"screensaver_type","screensaver_document_cover","screensaver_show_message","screensaver_img_background"}
    local function snapshot()
        local saved={}
        for _,key in ipairs(keys) do
            saved[key]={has=G_reader_settings:has(key),value=G_reader_settings:readSetting(key)}
        end
        return saved
    end
    local function restore(saved)
        for _,key in ipairs(keys) do
            local row=saved[key]
            if row and row.has then G_reader_settings:saveSetting(key,row.value)
            else G_reader_settings:delSetting(key) end
        end
    end
    Screensaver._miuread_original_setup=original
    Screensaver.setup=function(manager,...)
        local args={n=select("#",...),...}
        local current=HomeView.current()
        local opts=current and current.opts or nil
        local target=opts and opts.lockscreen_enabled~=false and tostring(opts.screensaver_file or "") or ""
        if HomeView.is_shown() and target~="" and lfs.attributes(target,"mode")=="file" then
            local saved=snapshot()
            G_reader_settings:saveSetting("screensaver_type","document_cover")
            G_reader_settings:saveSetting("screensaver_document_cover",target)
            G_reader_settings:saveSetting("screensaver_show_message",false)
            G_reader_settings:saveSetting("screensaver_img_background","white")
            local packed={xpcall(function()
                return original(manager,unpack_args(args,1,args.n))
            end,debug.traceback)}
            restore(saved)
            if not packed[1] then error(packed[2]) end
            return unpack_args(packed,2,#packed)
        end
        return original(manager,unpack_args(args,1,args.n))
    end
    SCREENSAVER_PATCHED=true
    return true
end
local source=debug.getinfo(1,"S").source:gsub("^@",""); local ROOT=source:match("^(.*)/main%.lua$") or "."
local Plugin=WidgetContainer:extend{name="miuread",is_doc_only=false,version=Config.VERSION}
local function normalize(v) local b=v.bookInfo or v.book or v; return {bookId=tostring(b.bookId or v.bookId or ""),title=b.title or v.title or "未命名",author=b.author or v.author or "",cover=b.cover or v.cover,category=b.category or v.category,progress=tonumber(v.progress or b.progress or 0) or 0,updateTime=tonumber(v.updateTime or b.updateTime or 0) or 0} end
local function sanitize_saved_auth(store)
    local auth=store:auth()
    local cleaned,changed=Cookies.sanitize(auth.cookies or {})
    if changed then
        auth.cookies=cleaned
        store:save_auth(auth)
        logger.info("[MiuRead][Auth] startup cookie cleanup",
            "names=",table.concat(Cookies.names(cleaned),","))
    end
end
function Plugin:init()
    math.randomseed(os.time()+math.floor(collectgarbage("count")))
    sync_home_session()
    self.store=Store:new()
    if HOME_SESSION.runtime_home_enabled==nil then
        local configured=((self.store:preferences().home_ui or {}).enabled~=false)
        HOME_SESSION.runtime_home_enabled=configured
    end
    self._reader_context=self.ui and self.ui.document~=nil
    if self._reader_context then
        local document=self.ui.document
        local path=normalized_reader_file(document and (document.file or (document.getFilePath and document:getFilePath())) or nil)
        if HOME_READER_ORIGIN or (path and HOME_READER_FILE==path) then
            mark_reader_origin(path)
            logger.info("[MiuRead][Home] reader origin restored",tostring(path or "unknown"))
        end
    end
    self._thought_index_pause_path=self.store.temp_dir.."/thought-index.pause"
    self._reader_active_path="/tmp/miuread-reader-active.flag"
    self._reader_busy_path="/tmp/miuread-reader-busy.until"
    self._thought_popup_marker_path=self.store.temp_dir.."/thought-popup.pending.json"
    self._thought_popup_last_crash_path=self.store.data_dir.."/thought-popup-last-crash.json"
    local pending_popup=U.read_file(self._thought_popup_marker_path,true)
    if pending_popup then
        -- A pending marker can only survive an abnormal exit. Preserve it as a
        -- compact diagnostic instead of letting the next launch mistake it for
        -- a currently active window.
        U.atomic_write(self._thought_popup_last_crash_path,pending_popup,true)
        os.remove(self._thought_popup_marker_path)
        logger.warn("[MiuRead][ThoughtPopup] previous session ended while popup was active")
    end
    self._thought_popup=nil
    self._thought_popup_busy=false
    self._thought_popup_generation=0
    self._reader_checkpoint_task=nil
    self._reader_checkpoint_last=0
    self._reader_checkpoint_dirty=false
    self._reader_returning=false
    self._reader_return_generation=0
    self._reader_return_started=0
    self._reader_return_finish_task=nil
    self._reader_return_completed_generation=nil
    self._reader_native_menu_opening=false
    self._post_reader_work_task=nil
    self._post_reader_work_generation=0
    -- Opening state is shared with the FileManager-side plugin instance so a
    -- slow tap cannot start the same ReaderUI transition twice.
    if tonumber(HOME_SESSION.opening_at or 0)>0
        and os.time()-tonumber(HOME_SESSION.opening_at or 0)>30 then
        HOME_SESSION.opening_file=nil
        HOME_SESSION.opening_at=0
    end
    if self._reader_context then
        U.atomic_write(self._thought_index_pause_path,"1",true)
        U.atomic_write(self._reader_active_path,"1",true)
        U.atomic_write(self._reader_busy_path,tostring(os.time()+3),true)
    else
        os.remove(self._thought_index_pause_path)
        os.remove(self._reader_active_path)
        os.remove(self._reader_busy_path)
    end
    self.memory_mode=MemoryMode:new(self.store)
    self.book_repair=BookRepair:new(self.store)
    logger.info("[MiuRead] initialized", "version=", tostring(Config.VERSION),
        "schema=", tostring(Config.SCHEMA), "root=", tostring(ROOT))
    sanitize_saved_auth(self.store)
    self.http=Http:new(self.store)
    self.reader=Reader:new(self.http,self.store)
    self.api=Api:new(self.http,self.store,self.reader)
    self.mp=MP:new(self.reader,self.http,self.store,self.api)
    self.annotations=Annotations:new(self.api)
    self.downloader=Downloader:new(self.reader,self.api,self.annotations,self.store,self.http)
    self.download_task=DownloadTask:new(self.store)
    self.cache_cleanup_task=CacheCleanupTask:new(self.store)
    self.library=Library:new(self.api,self.http,self.store)
    self.access=Access:new(self.library,self.api,self.reader,self.store)
    self.async=Async:new(self.store,{allow_android=true,disable_fallback=true})
    self.mp_async=Async:new(self.store,{poll_interval=.35,allow_android=true})
    self.search_async=Async:new(self.store,{poll_interval=.4,allow_android=true})
    self.shelf_async=Async:new(self.store,{poll_interval=.4,allow_android=true})
    self.cover_async=Async:new(self.store,{poll_interval=.30,allow_android=true})
    self.identity_async=Async:new(self.store,{poll_interval=.20,allow_android=true,
        disable_fallback=true})
    self.thought_index_async=Async:new(self.store,{poll_interval=.75,allow_android=true,
        disable_fallback=true})
    self.repair_async=Async:new(self.store,{poll_interval=.35,allow_android=true})
    self.home_async=Async:new(self.store,{poll_interval=.45,allow_android=true,disable_fallback=true})
    self.home_cover_async=Async:new(self.store,{poll_interval=.30,allow_android=true})
    self.auth_flow=Auth:new(self.http,self.store,self)
    self.sync=Sync:new(self.reader,self.api,self.store,self,self.async,self.identity_async)
    self.updater=Updater:new(self.http,self.store,self.version,ROOT)
    self._suspended_at=nil
    self._cover_generation=0
    self._cover_refresh_task=nil
    self._cover_index_pending={}
    self._cover_index_flush_task=nil
    self._cover_safe_mode=false
    self._cover_safe_notice_shown=false
    self._shelf_view=nil
    self._last_shelf_mode=false
    self._last_shelf_section="account"
    self._shelf_refresh_generation=0
    self._shelf_main_busy=false
    self._downloads_menu=nil
    self._download_book_menu=nil
    self._cache_cleanup_dialog=nil
    self._download_runtime=nil
    self._download_state_last_write=0
    self._download_state_last_stage=nil
    self._auth_notice_dialog=nil
    self._sync_success_notified=false
    self._home_view=nil
    self._home_scan_generation=0
    self._home_refreshing=false
    self._home_start_generation=0
    self._home_reader_transition=false
    self._home_metadata_generation=0
    self._home_cover_generation=0
    self._home_sections=nil
    self._home_visible_keys=nil
    self._home_active_section=nil
    self._home_hero=nil
    self._home_remote_refreshing=false
    self._home_render_refresh_task=nil

    if not self._reader_context then
        local guard=self.store:cover_guard()
        local guard_age=os.time()-(tonumber(guard.started_at) or 0)
        if guard.active==true and guard_age>=0 and guard_age<COVER_GUARD_WINDOW then
            self._cover_safe_mode=true
            logger.warn("[MiuRead][Cover] previous render did not finish; safe shelf mode enabled",
                "stage=",tostring(guard.stage or ""),"age=",tostring(guard_age))
        end
        if guard.active==true then
            self.store:save_cover_guard({active=false,started_at=0,stage="",version=Config.VERSION})
        end

        local startup_download_state=self.store:download_state()
        if startup_download_state.status=="completed" then self.store:clear_download_state() end
        local recovered=self:_recover_download_state()
        if not recovered then UIManager:scheduleIn(1.0,function() self:_start_next_queued_download() end) end
    end
    Actions.register()
    install_home_screensaver_patch()
    if not DIRECT_MENU_INSERTED then
        local ok_insert, inserter = pcall(require, "ui/plugin/insert_menu")
        if ok_insert and inserter and type(inserter.add) == "function" then
            pcall(inserter.add, "miuread_return_home_direct")
        end
        DIRECT_MENU_INSERTED = true
    end
    self.ui.menu:registerToMainMenu(self)
    if self._reader_context then self:_install_reader_home_bridge() end
    if not self._reader_context then
        local state=self.updater:startup()
        if state=="updated" then
            UIManager:scheduleIn(1,function() self:status_toast("更新完成","当前运行版本 "..tostring(self.version),4) end)
        elseif state=="mismatch" then
            UIManager:scheduleIn(1,function() self:info("更新文件已经替换，但当前运行版本与目标版本不一致。\n\n请完整退出并重新启动 KOReader。\n当前运行："..tostring(self.version)) end)
        end
        UIManager:scheduleIn(.8,function() if not self:_current_document_path() then self:_install_pending_downloads(false) end end)
        UIManager:scheduleIn(1.2,function() self:_show_auth_notice() end)
        UIManager:scheduleIn(8.0,function() self:_start_thought_index_maintenance() end)
        UIManager:scheduleIn(5.0,function() self:maybe_auto_check_update(false) end)
        if self:_home_enabled() and not HOME_SESSION_SUPPRESSED then
            self:_schedule_home_startup(.65)
        end
    end
end

function Plugin:addToMainMenu(items)
    if self.ui and self.ui.document and self:_home_enabled() then
        items.miuread_return_home_direct={
            text="退出阅读并返回觅阅主页",
            sorting_hint="tools",
            callback=self:safe("return-home-direct",function() self:return_to_miuread_home() end),
        }
    elseif not (self.ui and self.ui.document) and self:_home_enabled() then
        -- FileManager caches its menu table. Register this recovery entry
        -- unconditionally while MiuRead home mode is enabled; checking
        -- HOME_NATIVE_VISIT here made the item disappear when the menu table
        -- had been built before the temporary native visit started.
        items.miuread_return_home_direct={
            text="返回觅阅主页",
            sorting_hint="tools",
            callback=self:safe("return-home-direct",function() self:_return_from_native_filemanager() end),
        }
    end
    items.miuread={
        text=Config.NAME,
        sorting_hint="tools",
        sub_item_table_func=function() return self.ui.document and self:reader_menu() or self:home_menu() end,
    }
end
function Plugin:info(t) UIManager:show(InfoMessage:new{text=tostring(t or "")}) end
function Plugin:toast(t,s) UIManager:show(InfoMessage:new{text=tostring(t or ""),timeout=s or 2}) end
function Plugin:status_toast(title,text,timeout)
    local ok,err=pcall(StatusToast.show,{
        title=tostring(title or ""),
        text=tostring(text or ""),
        timeout=timeout or 3,
    })
    if not ok then
        logger.warn("[MiuRead] status toast failed",tostring(err))
        self:toast(tostring(title or "").." · "..tostring(text or ""):gsub("%s+"," "),timeout or 3)
    end
end
function Plugin:_original_weread_plugin_present()
    local plugins_root=ROOT:match("^(.*)/[^/]+$") or "."
    return lfs.attributes(plugins_root.."/weread.koplugin","mode")=="directory"
end
function Plugin:_begin_cover_guard(stage)
    self.store:save_cover_guard({
        active=true,
        started_at=os.time(),
        stage=tostring(stage or "shelf"),
        version=Config.VERSION,
    })
end
function Plugin:_clear_cover_guard()
    local guard=self.store:cover_guard()
    if guard.active==true then
        self.store:save_cover_guard({active=false,started_at=0,stage="",version=Config.VERSION})
    end
end
function Plugin:_shelf_covers_enabled(prefs)
    prefs=prefs or self.store:preferences()
    local enabled=prefs.shelf_covers~=false
    if enabled and self._cover_safe_mode then
        if not self._cover_safe_notice_shown then
            self._cover_safe_notice_shown=true
            self:toast("检测到上次封面加载异常，本次已使用安全书架模式。",4)
        end
        return false
    end
    return enabled
end
function Plugin:safe(label,fn) return function(...) local a={...}; local ok,e=xpcall(function() return fn(unpack_args(a)) end,debug.traceback); if not ok then logger.err("[MiuRead]",label,e); self:info(_("Operation failed")..":\n"..U.first_line(e)) end end end
function Plugin:is_online() local ok,N=pcall(require,"ui/network/manager"); if not ok or not N or not N.isOnline then return true end; local g,v=pcall(N.isOnline,N); return not g or v==true end
function Plugin:online(label,fn) if not self:is_online() then self:info(_("Network unavailable")); return end; UIManager:scheduleIn(.05,self:safe(label,fn)) end
function Plugin:_wait_for_network(label,callback,options)
    options=options or {}
    self._network_wait_tokens=self._network_wait_tokens or {}
    label=tostring(label or "default")
    local token=(tonumber(self._network_wait_tokens[label]) or 0)+1
    self._network_wait_tokens[label]=token
    local started=os.time()
    local minimum=math.max(0,tonumber(options.minimum_delay) or 0)
    local maximum=math.max(minimum+1,tonumber(options.max_wait) or 45)
    local interval=math.max(.5,tonumber(options.interval) or 2)
    local function check()
        if not self._network_wait_tokens or self._network_wait_tokens[label]~=token then return end
        local elapsed=os.time()-started
        if elapsed>=minimum and self:is_online() then
            self._network_wait_tokens[label]=nil
            callback(true)
            return
        end
        if elapsed>=maximum then
            self._network_wait_tokens[label]=nil
            callback(false)
            return
        end
        UIManager:scheduleIn(interval,check)
    end
    UIManager:scheduleIn(math.max(.1,tonumber(options.initial_delay) or .1),check)
    return token
end
function Plugin:_cancel_network_waits()
    self._network_wait_tokens={}
end

function Plugin:list(title,items,empty)
    if not items or #items==0 then self:info(empty or _("No items")); return end
    for _, item in ipairs(items) do
        if type(item)=="table" and (item.sub_item_table_func or item.sub_item_table) then
            return self:_show_standalone_menu(title,items)
        end
    end
    local menu=Menu:new{title=title,item_table=items,is_borderless=true,title_bar_fm_style=true}
    UIManager:show(menu)
    return menu
end
function Plugin:logged_in()
    local a=self.store:auth()
    return tostring(a.api_key or "")~="" and next(a.cookies or {})~=nil
end
function Plugin:require_login()
    if not self:logged_in() then
        self:info(_("Not logged in"))
        return false
    end
    return true
end

local AUTH_CHANNEL_LABELS={
    shelf="书架访问",progress="云端进度读取",download="正文下载",
    annotations="划线与想法访问",read_report="阅读时间上传",
}
local AUTH_CHANNEL_ORDER={"shelf","progress","download","annotations","read_report"}
local function auth_error_code(value)
    if Http.auth_error_code then
        local ok,code=pcall(Http.auth_error_code,value)
        if ok and code then return tostring(code) end
    end
    local text=tostring(value or "")
    return text:match("error_code=([%-]?%d+)") or text:match('"errcode"%s*:%s*([%-]?%d+)') or ""
end
local function auth_row(value)
    return U.merge({state="unknown",checked_at=0,error="",code="",failures=0,retry_at=0,last_ok_at=0},
        type(value)=="table" and value or {})
end
function Plugin:_auth_health()
    if self.store.auth_health then return self.store:auth_health() end
    local auth=self.store:auth()
    return U.merge({state="unknown",last_checked_at=0,last_ok_at=0,last_error_at=0,
        last_error_code="",last_error_message="",last_error_channel="",notice_pending=false,channels={}},auth.health or {})
end
function Plugin:_save_auth_health(health)
    local auth=self.store:auth()
    auth.health=health
    self.store:save_auth(auth)
    return health
end
function Plugin:_recompute_auth_health(health)
    health.channels=health.channels or {}
    if not self:logged_in() then health.state="logged_out"; return health end
    local partial,unknown=false,false
    for _,channel in ipairs(AUTH_CHANNEL_ORDER) do
        local state=tostring(auth_row(health.channels[channel]).state)
        if state=="expired" or state=="error" then partial=true
        elseif state~="ok" then unknown=true end
    end
    health.state=partial and "partial" or (unknown and "unknown" or "ok")
    return health
end
function Plugin:_mark_auth_channel_ok(channel)
    if not self:logged_in() then return end
    local now=os.time()
    local health=self:_auth_health()
    health.channels=health.channels or {}
    health.channels[channel]={state="ok",checked_at=now,error="",code="",failures=0,retry_at=0,last_ok_at=now}
    health.last_checked_at=now
    health.last_ok_at=now
    self:_recompute_auth_health(health)
    if health.state=="ok" then
        health.last_error_at=0
        health.last_error_code=""
        health.last_error_message=""
        health.last_error_channel=""
        health.notice_pending=false
    end
    self:_save_auth_health(health)
end
function Plugin:_mark_auth_channel_error(channel,err,retry_at)
    if not self:logged_in() then return end
    local now=os.time()
    local health=self:_auth_health()
    health.channels=health.channels or {}
    local previous=auth_row(health.channels[channel])
    health.channels[channel]={state="error",checked_at=now,error=U.first_line(err,180),code="",
        failures=(tonumber(previous.failures) or 0)+1,retry_at=tonumber(retry_at) or 0,last_ok_at=previous.last_ok_at or 0}
    health.last_checked_at=now
    health.last_error_at=now
    health.last_error_message=U.first_line(err,220)
    health.last_error_channel=channel
    self:_recompute_auth_health(health)
    self:_save_auth_health(health)
end
function Plugin:_mark_auth_access_denied(channel,err,notify)
    if not self:logged_in() then return false end
    local now=os.time()
    local health=self:_auth_health()
    health.channels=health.channels or {}
    local previous=auth_row(health.channels[channel])
    local failures=(tonumber(previous.failures) or 0)+1
    local threshold=math.max(1,tonumber(Config.AUTH_NOTICE_FAILURE_THRESHOLD) or 2)
    local confirmed=failures>=threshold
    local message=U.first_line(err or "HTTP 403",220)
    health.channels[channel]={state=confirmed and "expired" or "error",checked_at=now,
        error=U.first_line(message,180),code="403",failures=failures,retry_at=0,
        last_ok_at=previous.last_ok_at or 0}
    health.last_checked_at=now
    health.last_error_at=now
    health.last_error_code="403"
    health.last_error_message=message
    health.last_error_channel=channel
    if notify~=false and confirmed then health.notice_pending=true end
    self:_recompute_auth_health(health)
    self:_save_auth_health(health)
    logger.warn("[MiuRead][Auth] feature access denied",
        "channel=",tostring(channel),"failures=",tostring(failures),"confirmed=",tostring(confirmed),
        "error=",U.first_line(message,160))
    if health.notice_pending then UIManager:scheduleIn(.05,function() self:_show_auth_notice() end) end
    return true
end
function Plugin:_mark_auth_problem(channel,err,notify)
    local text=tostring(err or "登录状态暂时不可用")
    if not Http.is_auth_error(text) then return false end
    local now=os.time()
    local health=self:_auth_health()
    health.channels=health.channels or {}
    local previous=auth_row(health.channels[channel])
    local threshold=math.max(1,tonumber(Config.AUTH_NOTICE_FAILURE_THRESHOLD) or 2)
    local failures=(tonumber(previous.failures) or 0)+1
    local confirmed=text:find("自动续期失败",1,true)~=nil
        or text:find("renewal=",1,true)~=nil
        or text:find("refreshed=",1,true)~=nil
    if confirmed then failures=math.max(failures,threshold) end
    local expired=failures>=threshold
    local code=auth_error_code(text)
    health.channels[channel]={state=expired and "expired" or "error",checked_at=now,
        error=U.first_line(text,180),code=code,failures=failures,retry_at=0,last_ok_at=previous.last_ok_at or 0}
    health.last_checked_at=now
    health.last_error_at=now
    health.last_error_code=code
    health.last_error_message=U.first_line(text,220)
    health.last_error_channel=channel
    if notify~=false and expired then health.notice_pending=true end
    self:_recompute_auth_health(health)
    self:_save_auth_health(health)
    logger.warn("[MiuRead][Auth] feature request authentication failed",
        "channel=",tostring(channel),"code=",tostring(code),"failures=",tostring(failures),
        "confirmed=",tostring(confirmed),"error=",U.first_line(text,160))
    if health.notice_pending then UIManager:scheduleIn(.05,function() self:_show_auth_notice() end) end
    return true
end
function Plugin:_clear_auth_notice_pending()
    local health=self:_auth_health()
    if health.notice_pending~=false then
        health.notice_pending=false
        self:_save_auth_health(health)
    end
end
function Plugin:_show_auth_notice()
    if self._auth_notice_dialog or not self:logged_in() then return end
    local health=self:_auth_health()
    if health.notice_pending~=true then return end
    local channel_key=tostring(health.last_error_channel or "")
    local channel=AUTH_CHANNEL_LABELS[channel_key] or "在线功能"
    local annotation_forbidden=channel_key=="annotations" and tostring(health.last_error_code or "")=="403"
    local notice_text=annotation_forbidden
        and "正文下载仍可使用，但划线与想法接口连续拒绝访问。插件已保留正文、已有批注和下载断点。请重新扫码后再次生成书籍。"
        or "只有此功能受到影响，其他功能会继续运行。插件会保留下载断点和待上传阅读时间，并在后续真实请求中自动重试。多次失败后可重新扫码。"
    local dialog
    local function close()
        if self._auth_notice_dialog==dialog then self._auth_notice_dialog=nil end
        UIManager:close(dialog)
    end
    dialog=ButtonDialog:new{
        title=channel.."暂时异常\n\n"..notice_text,
        title_align="center",
        buttons={
            {{text="查看账号状态",callback=function()
                self:_clear_auth_notice_pending(); close(); self:show_account_status()
            end}},
            {{text="重新扫码",callback=function()
                self:_clear_auth_notice_pending(); close(); self.auth_flow:start()
            end}},
            {{text="稍后处理",callback=function()
                self:_clear_auth_notice_pending(); close()
            end}},
        },
    }
    self._auth_notice_dialog=dialog
    UIManager:show(dialog)
end
function Plugin:_account_status_label()
    if not self:logged_in() then return "未登录 · 点击扫码" end
    local auth=self.store:auth()
    local health=self:_auth_health()
    self:_recompute_auth_health(health)
    local name=U.trim(tostring((auth.account or {}).name or ""))
    if health.state=="partial" then
        return name~="" and ("部分功能异常 · "..name) or "部分功能异常 · 点击查看"
    end
    if health.state~="ok" then
        return name~="" and ("已登录 · "..name) or "已登录 · 功能待验证"
    end
    return name~="" and ("已登录 · "..name) or "已登录"
end
local function account_channel_text(row)
    row=auth_row(row)
    local state=tostring(row.state or "unknown")
    if state=="ok" then return "正常" end
    if state=="expired" then return "多次验证失败，可重新扫码" end
    if state=="error" then
        local retry_at=tonumber(row.retry_at or 0) or 0
        return retry_at>os.time() and "暂时失败，等待自动重试" or "暂时失败"
    end
    return "将在实际使用时验证"
end
function Plugin:_account_details_text()
    local auth=self.store:auth()
    local health=self:_auth_health()
    self:_recompute_auth_health(health)
    local name=U.trim(tostring((auth.account or {}).name or ""))
    local lines={"账号状态","","账号："..(name~="" and name or "—")}
    if not self:logged_in() then
        lines[#lines+1]="基础登录：尚未登录"
        return table.concat(lines,"\n")
    end
    lines[#lines+1]="基础登录：正常"
    lines[#lines+1]="在线功能："..(health.state=="ok" and "全部正常" or (health.state=="partial" and "部分暂时异常" or "等待实际使用验证"))
    lines[#lines+1]=""
    for _,channel in ipairs(AUTH_CHANNEL_ORDER) do
        lines[#lines+1]=AUTH_CHANNEL_LABELS[channel].."："..account_channel_text((health.channels or {})[channel])
    end
    lines[#lines+1]=""
    lines[#lines+1]="最后检查："..self:_relative_time(health.last_checked_at)
    if tonumber(health.last_error_at or 0)>0 then
        local channel=AUTH_CHANNEL_LABELS[tostring(health.last_error_channel or "")] or "在线功能"
        local code=tostring(health.last_error_code or "")
        lines[#lines+1]="最近异常："..channel..(code~="" and ("（"..code.."）") or "")
    end
    local sync_status=self.sync and self.sync:status() or {}
    local pending=math.max(0,math.floor(tonumber(sync_status.pending_report_elapsed or 0) or 0))
    if pending>0 then lines[#lines+1]="待上传阅读时间："..tostring(pending).." 秒" end
    lines[#lines+1]=""
    lines[#lines+1]="续期只用于失败后的恢复，不再作为下载或上传的前置条件。"
    return table.concat(lines,"\n")
end
function Plugin:_set_all_auth_ok()
    if not self:logged_in() then return end
    local now=os.time()
    local okrow={state="ok",checked_at=now,error="",code="",failures=0,retry_at=0,last_ok_at=now}
    local health=self:_auth_health()
    health.state="ok"
    health.last_checked_at=now
    health.last_ok_at=now
    health.last_error_at=0
    health.last_error_code=""
    health.last_error_message=""
    health.last_error_channel=""
    health.notice_pending=false
    health.channels={
        shelf=U.copy(okrow),progress=U.copy(okrow),download=U.copy(okrow),
        annotations=U.copy(okrow),read_report=U.copy(okrow),
    }
    self:_save_auth_health(health)
end
function Plugin:check_account_status()
    if not self:logged_in() then self.auth_flow:start(); return end
    self:online("account-status-check",function()
        self:status_toast("账号状态","正在检查基础账号和书架访问",3)
        local shelf_ok,shelf_result=pcall(self.api.shelf,self.api,{retries=0,timeout={7,12}})
        if shelf_ok then
            self:_mark_auth_channel_ok("shelf")
        elseif Http.is_auth_error(shelf_result) then
            self:_mark_auth_problem("shelf",shelf_result,false)
        else
            self:_mark_auth_channel_error("shelf",shelf_result)
        end
        self:show_account_status()
    end)
end
function Plugin:confirm_logout()
    if not self:logged_in() then self:toast("当前没有登录微信读书账号",3); return end
    local downloading=self.download_task and self.download_task:busy()
    local text="退出当前微信读书账号？\n\n已下载书籍、本地阅读记录和下载断点都会保留。"
    if downloading then text=text.."\n\n当前下载会停止；重新登录后可从断点继续。" end
    UIManager:show(ConfirmBox:new{text=text,ok_text="退出登录",ok_callback=function()
        if downloading and self.download_task then self.download_task:cancel() end
        self.auth_flow:cancel()
        self.store:clear_auth()
        self:status_toast("账号","已退出登录",4)
    end})
end

function Plugin:show_account_status()
    local dialog
    local buttons={}
    if self:logged_in() then
        buttons[#buttons+1]={{text="重新检查状态",callback=function() UIManager:close(dialog); self:check_account_status() end}}
        buttons[#buttons+1]={{text="重新扫码登录",callback=function() UIManager:close(dialog); self.auth_flow:start() end}}
        buttons[#buttons+1]={{text="退出登录",callback=function()
            UIManager:close(dialog); self:confirm_logout()
        end}}
    else
        buttons[#buttons+1]={{text="扫码登录",callback=function() UIManager:close(dialog); self.auth_flow:start() end}}
    end
    buttons[#buttons+1]={{text="关闭",callback=function() UIManager:close(dialog) end}}
    dialog=ButtonDialog:new{title=self:_account_details_text(),title_align="left",buttons=buttons}
    UIManager:show(dialog)
end
function Plugin:on_auth_success(name)
    local health=self:_auth_health()
    local web_ready=(((health.channels or {}).download or {}).state=="ok")
    if self._auth_notice_dialog then
        pcall(function() UIManager:close(self._auth_notice_dialog) end)
        self._auth_notice_dialog=nil
    end
    local resumed=false
    local state=self.store:download_state()
    if state.status=="failed" and state.auth_required==true and type(state.book)=="table" then
        state.status="interrupted"
        state.error="登录已恢复，正在继续下载。"
        state.auth_required=nil
        state.updated_at=os.time()
        self.store:save_download_state(state)
        local book,options=U.copy(state.book),U.copy(state.options or {})
        UIManager:scheduleIn(1.0,function()
            if not self._download_runtime and not (self.download_task and self.download_task:busy()) then
                self:download(book,options,false,nil,true)
            end
        end)
        resumed=true
    else
        UIManager:scheduleIn(.8,function() self:_start_next_queued_download() end)
    end
    if self.sync and self.sync.on_auth_restored then
        local ok,value=pcall(self.sync.on_auth_restored,self.sync)
        resumed=resumed or (ok and value==true)
    end
    local title="账号登录成功"
    local detail=tostring(name or "微信读书账号")
        ..(resumed and " · 正在恢复后台任务" or (web_ready and "" or " · 在线功能将在实际使用时验证"))
    self:status_toast(title,detail,5)
end
function Plugin:_download_menu_text()
    if self:_has_download_status() then
        return "下载管理 · "..tostring(self:_download_status_label()):gsub("^后台下载%s*[：·]?%s*","")
    end
    local queue=self.store:download_queue()
    return #queue>0 and ("下载管理 · "..tostring(#queue).." 项等待") or "下载管理"
end
function Plugin:_sync_menu_text()
    return "阅读同步 · "..tostring(self:progress_sync_label())
end
function Plugin:home_menu()
    sync_home_session()
    self:maybe_auto_check_update(false)
    local account={text=self:_account_status_label(),callback=function() self:show_account_status() end}
    local out={
        {text=(self:_home_enabled() and HOME_NATIVE_VISIT) and "返回觅阅主页" or (self:_home_enabled() and "打开觅阅首页" or "打开觅阅首页（本次）"),callback=self:safe("home-ui",function()
            if not (self.ui and self.ui.document) and HOME_NATIVE_VISIT then
                self:_return_from_native_filemanager()
            else
                self:show_miuread_home(false)
            end
        end)},
        {text="我的书架",callback=self:safe("shelf",function() self:show_shelf(false,false,"account") end)},
        {text="搜索书籍",callback=self:safe("search",function() self:search_dialog() end)},
        {text=self:_download_menu_text(),callback=self:safe("downloads",function() self:show_downloads() end)},
        {text=self:_sync_menu_text(),sub_item_table_func=function() return self:sync_menu() end},
        account,
        {text="觅阅设置",sub_item_table_func=function() return self:settings_menu() end},
        {text="KOReader 菜单",callback=function() self:_show_native_koreader_menu() end},
    }
    local health=self:_auth_health()
    self:_recompute_auth_health(health)
    if self:logged_in() and health.state=="partial" then
        for index,row in ipairs(out) do
            if row==account then table.remove(out,index); break end
        end
        table.insert(out,1,account)
    end
    return out
end

function Plugin:_confirm_current_book_rebuild(book,annotations)
    local label=annotations and "划线与想法版" or "纯净版"
    UIManager:show(ConfirmBox:new{
        text="重新生成当前书籍的"..label.."？\n\n新文件会在生成完成后替换对应版本。",
        ok_text="重新生成",
        cancel_text="取消",
        ok_callback=function() self:choose_download_mode(book,{annotations=annotations},false) end,
    })
end

function Plugin:current_book_download_menu(book)
    local items={
        {text="下载当前章",callback=function() self:download_current_chapters(1) end},
        {text="当前章及后续 5 章",callback=function() self:download_current_chapters(6) end},
        {text="当前章及后续 10 章",callback=function() self:download_current_chapters(11) end},
        {text="选择章节范围",callback=function() self:chapters(book) end},
    }
    if self:_has_range_variant(book.bookId) then
        items[#items+1]={text="扩展已有章节版",sub_item_table_func=function() return self:range_extend_menu(book) end}
    end
    return items
end

function Plugin:current_book_rebuild_menu(book)
    return {
        {text="检查与修复本书",callback=function() self:repair_current_book() end},
        {text="重新生成纯净版",callback=function() self:_confirm_current_book_rebuild(book,false) end},
        {text="重新生成划线与想法版",callback=function() self:_confirm_current_book_rebuild(book,true) end},
    }
end

function Plugin:current_book_menu()
    local r=self:_current_book_record()
    if not r or not r.book then return {{text="未识别当前觅阅书籍",enabled=false}} end
    local b={bookId=r.book.book_id,title=r.book.title,author=r.book.author,cover=r.book.cover}
    return {
        {text="书籍详情",callback=function() self:book_details(b) end},
        {text="下载章节",sub_item_table_func=function() return self:current_book_download_menu(b) end},
        {text="重新生成与修复",sub_item_table_func=function() return self:current_book_rebuild_menu(b) end},
        {text="管理本地文件",callback=function() self:downloaded_book_menu(tostring(b.bookId)) end},
    }
end

function Plugin:current_mp_article_menu(mp_context)
    local account={bookId=mp_context.bookId,title=mp_context.account_title or "公众号",author="公众号"}
    local target
    for _,article in ipairs(self.mp:cached_articles(mp_context.bookId) or {}) do
        if tostring(article.reviewId or article.originalId or "")==tostring(mp_context.reviewId or "") then
            target=article; break
        end
    end
    if not target then return {{text="当前文章信息不可用",enabled=false}} end
    local article=U.copy(target)
    return {
        {text="重新下载文章",callback=function() self:open_or_download_mp_article(account,article,true) end},
        {text="删除本篇缓存",callback=function()
            UIManager:show(ConfirmBox:new{text="删除《"..tostring(article.title or "文章").."》的本地缓存？",ok_callback=function()
                local ok,err=self.mp:clear_article(account.bookId,article)
                if not ok then self:info("缓存删除失败：\n"..tostring(err or "无法删除目录")); return end
                self:status_toast("公众号","本篇缓存已删除",4)
            end})
        end},
        {text="公众号缓存管理",sub_item_table_func=function() return self:mp_cache_menu(account,self.mp:cached_articles(account.bookId)) end},
    }
end

function Plugin:reader_menu()
    self:maybe_auto_check_update(false)
    local current_path=self:_current_document_path()
    local mp_context=self.mp and self.mp:identify_path(current_path) or nil
    if mp_context then
        return {
            {text="返回文章列表",callback=self:safe("mp-back",function() self:open_mp_account_by_id(mp_context.bookId,mp_context.account_title) end)},
            {text="上一篇",callback=self:safe("mp-prev",function() self:open_mp_neighbor(-1) end)},
            {text="下一篇",callback=self:safe("mp-next",function() self:open_mp_neighbor(1) end)},
            {text="当前文章",sub_item_table_func=function() return self:current_mp_article_menu(mp_context) end},
            {text=self:_download_menu_text(),callback=function() self:show_downloads() end},
            {text="觅阅设置",sub_item_table_func=function() return self:settings_menu() end},
            {text="KOReader 菜单",callback=function() self:_show_koreader_reader_menu() end},
        }
    end
    return {
        {text=self:_home_enabled() and "退出阅读并返回觅阅主页" or "返回书架",callback=self:safe("shelf",function()
            if self:_home_enabled() then self:return_to_miuread_home()
            else self:show_shelf(false,false,"account") end
        end)},
        {text="当前书籍",sub_item_table_func=function() return self:current_book_menu() end},
        {text=self:_sync_menu_text(),sub_item_table_func=function() return self:sync_menu() end},
        {text=self:_download_menu_text(),callback=function() self:show_downloads() end},
        {text="觅阅设置",sub_item_table_func=function() return self:settings_menu() end},
        {text="KOReader 菜单",callback=function() self:_show_koreader_reader_menu() end},
    }
end

function Plugin:account_menu()
    local out={
        {text="账号状态",callback=function() self:show_account_status() end},
        {text=self:logged_in() and "重新扫码登录" or "扫码登录",callback=self:safe("login",function() self.auth_flow:start() end)},
    }
    if self:logged_in() then
        out[#out+1]={text="退出登录",callback=function() self:confirm_logout() end}
    end
    return out
end

function Plugin:_save_shelf_context(section,mp_mode)
    section=section=="generated" and "generated" or "account"
    local p=self.store:preferences()
    local changed=p.shelf_section~=section
    p.shelf_section=section
    if section=="account" and mp_mode~=nil then
        local kind=mp_mode==true and "mp" or "books"
        if p.account_shelf_kind~=kind then changed=true end
        p.account_shelf_kind=kind
    end
    if changed then self.store:save_preferences(p) end
    self._last_shelf_section=section
    if section=="account" then self._last_shelf_mode=mp_mode==true end
end


function Plugin:_friendly_remote_error(err, context)
    local text=tostring(err or "未知错误")
    local lower=text:lower()
    if text:find("[MiuReadMPNoAccount]",1,true) then
        return "微信读书书架暂时没有返回可用的公众号。"
    end
    if text:find("[MiuReadMPInvalidAccount]",1,true) then
        return "公众号信息无效，请刷新微信读书书架。"
    end
    if lower:find("参数格式错误",1,true) or lower:find("params error",1,true)
        or lower:find("parameter format",1,true) then
        return "公众号数据暂时无法读取，请刷新后重试。"
    end
    if Http.is_auth_error(text) or lower:find("api key",1,true)
        or lower:find("authorization",1,true) then
        return "登录凭证已失效或被拒绝，请在账户设置中重新扫码登录。"
    end
    if lower:find("timeout",1,true) then return "网络请求超时，请检查 Wi-Fi 后重试。" end
    if lower:find("network request failed",1,true) then return "网络连接失败，请检查 Wi-Fi 后重试。" end
    if lower:find("%.lua:%d+:") or lower:find("stack traceback",1,true) then
        return tostring(context or "请求").."失败，请稍后重试。"
    end
    return tostring(context or "请求").."失败：\n"..U.first_line(text,120)
end

function Plugin:_refresh_shelf_async(on_ready,silent)
    local function fail(err)
        if Http.is_auth_error(err) then self:_mark_auth_problem("shelf",err,true) end
        local message=self:_friendly_remote_error(err,"书架加载")
        if on_ready then
            on_ready({}, {}, message)
        elseif not silent or message:find("重新扫码登录",1,true) then
            self:toast(message,4)
        end
        return false,err
    end
    if not self:is_online() then
        return fail("network request failed: offline")
    end

    local async_available=self.shelf_async and self.shelf_async:available()
    if async_available then
        if self.shelf_async:busy() then return fail("书架正在刷新，请稍后重试。") end
    elseif self._shelf_main_busy then
        return fail("书架正在刷新，请稍后重试。")
    end

    self._shelf_refresh_generation=(tonumber(self._shelf_refresh_generation) or 0)+1
    local generation=self._shelf_refresh_generation
    local function succeed(data,mode)
        if generation~=self._shelf_refresh_generation then return end
        self:_mark_auth_channel_ok("shelf")
        local books,mp=self.library:normalize(data or {})
        self.store:save_shelf_cache({books=books,mp=mp,updated_at=os.time()})
        logger.info("[MiuRead][Shelf] refresh completed","mode=",tostring(mode),
            "books=",tostring(#books),"mp=",tostring(#mp))
        if on_ready then on_ready(books,mp,nil) end
    end

    if not async_available then
        self._shelf_main_busy=true
        local loading
        if on_ready and not silent then
            loading=InfoMessage:new{text="正在加载书架……"}
            UIManager:show(loading)
        end
        logger.info("[MiuRead][Shelf] refresh started","mode=direct")
        UIManager:scheduleIn(.05,function()
            local handled,unexpected=xpcall(function()
                if generation~=self._shelf_refresh_generation then return end
                local ok,data=pcall(self.api.shelf,self.api,{retries=0,timeout={7,12}})
                if not ok then error(tostring(data)) end
                if loading then pcall(function() UIManager:close(loading) end); loading=nil end
                succeed(data,"direct")
            end,debug.traceback)
            self._shelf_main_busy=false
            if loading then pcall(function() UIManager:close(loading) end) end
            if not handled and generation==self._shelf_refresh_generation then fail(unexpected) end
        end)
        return true
    end

    local auth=U.copy(self.store:auth())
    logger.info("[MiuRead][Shelf] refresh started","mode=subprocess")
    local started,err=self.shelf_async:run("shelf_refresh",function()
        local HttpChild=require("miuread.http")
        local ApiChild=require("miuread.api")
        local UtilChild=require("miuread.util")
        local child_store={
            auth=function() return UtilChild.copy(auth) end,
            save_auth=function() end,
        }
        return ApiChild:new(HttpChild:new(child_store),child_store):shelf({retries=1,timeout={10,18}})
    end,function(result)
        if generation~=self._shelf_refresh_generation then return end
        if result and result.ok==true then
            succeed(result.value or {},"subprocess")
            return
        end
        fail(result and result.error or "未知错误")
    end,32)
    if not started then return fail(err or "无法启动异步任务") end
    return true
end

function Plugin:load_shelf(cb,force_remote,section)
    section=section=="generated" and "generated" or "account"
    local cached_books,cached_mp,cached_updated=self.library:cached()
    local library_snapshot=self.store:library()
    local local_books,local_mp=self.library:local_books(library_snapshot,self.store:get("sessions",{}))
    local cached_count=#cached_books+#cached_mp
    local local_count=#local_books+#local_mp
    local cache_age=math.max(0,os.time()-(tonumber(cached_updated) or 0))
    local background_available=self.shelf_async and self.shelf_async:available()

    if not force_remote then
        if cached_count>0 then
            cb(cached_books,cached_mp,nil)
            local refresh_after=background_available and SHELF_CACHE_TTL or SHELF_DIRECT_CACHE_TTL
            if self:logged_in() and cache_age>refresh_after then
                self:_refresh_shelf_async(function(_,_,err)
                    if not err and self._shelf_view and not self._shelf_view._miu_closed then
                        self:_reopen_shelf(self._last_shelf_mode,self._last_shelf_section)
                    end
                end,true)
            end
            return
        end
        if local_count>0 then
            if section=="account" and self:logged_in() then
                self:toast("正在加载账号书架…",2)
                self:_refresh_shelf_async(function(books,mp,err)
                    cb(books,mp,err)
                end,false)
                return
            end
            self:toast("账号书架暂未加载，可先查看“已生成书籍”。",3)
            cb({}, {}, "账号书架正在后台加载。")
            if self:logged_in() then
                self:_refresh_shelf_async(function(_,_,err)
                    if not err and self._shelf_view and not self._shelf_view._miu_closed then
                        self:_reopen_shelf(self._last_shelf_mode,self._last_shelf_section)
                    end
                end,true)
            end
            return
        end
    end
    if not self:logged_in() then
        cb(cached_books,cached_mp,"当前未登录，仅使用已缓存的账号书架和已生成书籍。")
        return
    end
    self:_refresh_shelf_async(function(books,mp,err)
        if err and cached_count>0 then cb(cached_books,cached_mp,err) else cb(books,mp,err) end
    end,false)
end

function Plugin:_shelf_rows(section,mp_mode,remote_books,remote_mp,remote_status_known)
    if remote_books==nil or remote_mp==nil then remote_books,remote_mp=self.library:cached() end
    local library_snapshot=self.store:library()
    local sessions=self.store:get("sessions",{})
    local local_books,local_mp=self.library:local_books(library_snapshot,sessions)
    section=section=="generated" and "generated" or "account"
    if section=="generated" then
        -- Public-account articles are standalone HTML files and no longer
        -- participate in the generated EPUB shelf.
        local rows=self.library:generated_rows(remote_books or {},{},local_books,{},remote_status_known)
        for _,row in ipairs(rows) do row.shelf_section="generated" end
        return rows
    end
    local remote_rows=mp_mode and (remote_mp or {}) or (remote_books or {})
    local local_rows=mp_mode and local_mp or local_books
    local rows=self.library:account_rows(remote_rows,local_rows)
    for _,row in ipairs(rows) do row.shelf_section="account" end
    return rows
end

function Plugin:_prepare_shelf_rows(rows)
    local cover_index=self.store:get("cover_index",{})
    for id,path in pairs(self._cover_index_pending or {}) do cover_index[id]=path end
    local cover_index_changed=false
    local download_state=self:_download_state()
    for _,b in ipairs(rows or {}) do
        local removed
        b.cover_path,removed=self.library:cached_cover_path(b.bookId,cover_index)
        if removed then
            cover_index_changed=true
            if self._cover_index_pending then self._cover_index_pending[tostring(b.bookId)]=nil end
        end
        if b.annotation_pending==true or b.annotation_fallback==true then
            b.download_status=DownloadResult.shelf_status({
                annotation_pending=b.annotation_pending==true,
                annotation_fallback=b.annotation_fallback==true,
            },false)
        else
            b.download_status=nil
        end
        if tostring(download_state.book_id or "")~="" and tostring(download_state.book_id)==tostring(b.bookId or "") then
            if download_state.status=="active" then b.download_status="生成中 "..tostring(self:_download_percent(download_state)).."%"
            elseif download_state.status=="pending_install" then
                b.download_status=DownloadResult.shelf_status(download_state,true)
            elseif download_state.status=="failed" or download_state.status=="interrupted" then b.download_status="生成未完成"
            elseif download_state.status=="annotation_pending" then b.download_status="生成未完成"
            elseif download_state.status=="completed" and download_state.annotation_fallback==true then b.download_status="已生成"
            elseif download_state.status=="completed" and download_state.seen~=true then b.download_status="刚刚生成完成" end
        end
        b.status_text=self:_shelf_status_text(b)
    end
    if cover_index_changed then self.store:set("cover_index",cover_index) end
    return rows
end

function Plugin:_flush_cover_index()
    if self._cover_index_flush_task then
        UIManager:unschedule(self._cover_index_flush_task)
        self._cover_index_flush_task=nil
    end
    local pending=self._cover_index_pending or {}
    if not next(pending) then return end
    local index=self.store:get("cover_index",{})
    for id,path in pairs(pending) do index[id]=path end
    self.store:set("cover_index",index)
    self._cover_index_pending={}
end

function Plugin:_remember_cover_path(id,path)
    if not id or not path then return end
    self._cover_index_pending=self._cover_index_pending or {}
    self._cover_index_pending[tostring(id)]=path
    if self._cover_index_flush_task then return end
    local task
    task=function()
        if self._cover_index_flush_task~=task then return end
        self._cover_index_flush_task=nil
        self:_flush_cover_index()
    end
    self._cover_index_flush_task=task
    UIManager:scheduleIn(.75,task)
end

function Plugin:_shelf_status_text(b)
    if b.download_status and b.download_status~="" then return b.download_status end
    if tostring(b.content_type or "")=="mp_account" then return "公众号" end
    local state
    if b.shelf_section=="generated" then
        if b.remote_status_known~=true then state="本地书籍"
        elseif b.in_account_shelf==true then state="账号书架中"
        else state="已移出账号书架 · 本地可读" end
        if b.hasClean and b.hasNotes then state=state.." · 两个版本"
        elseif b.hasNotes then state=state.." · 划线与想法版"
        elseif b.hasClean then state=state.." · 纯净版" end
    else
        state=b.downloaded and "已生成" or "未生成"
        if b.isTop then state="置顶 · "..state end
    end
    local progress=tonumber(b.progress or 0) or 0
    if progress>=100 then return state.." · 已读完" end
    if progress>0 then return state.." · "..tostring(math.floor(progress+.5)).."%" end
    return state
end

function Plugin:_shelf_select(b)
    local id=tostring(b and (b.bookId or b.book_id) or "")
    if id=="" then return end
    if Protocol.is_mp_account(id) then self:mp_account(b); return end
    local record=self:_preferred_record(id)
    if record and record.file and U.file_exists(record.file) then
        self:open_file(record.file)
    else
        self:book_menu(b)
    end
end
function Plugin:_shelf_hold(b)
    local id=tostring(b and (b.bookId or b.book_id) or "")
    if id=="" then return end
    if Protocol.is_mp_account(id) then self:mp_account(b); return end
    self:book_menu(b)
end

function Plugin:show_shelf_search_dialog(mp_mode,source_rows,section)
    section=section=="generated" and "generated" or "account"
    if not source_rows then
        local remote_books,remote_mp=self.library:cached()
        source_rows=self:_shelf_rows(section,mp_mode,remote_books,remote_mp,#remote_books+#remote_mp>0)
    end
    local d
    d=InputDialog:new{
        title=section=="generated" and "搜索已生成书籍" or "搜索账号书架",input="",
        buttons={{
            {text=_("Cancel"),id="close",callback=function() UIManager:close(d) end},
            {text=_("Search"),is_enter_default=true,callback=function()
                local q=U.trim(d:getInputText())
                UIManager:close(d)
                if q=="" then return end
                local results=self.library:search(source_rows,q)
                if #results==0 then self:info("没有找到相关书籍") return end
                self:_prepare_shelf_rows(results)
                local prefs=self.store:preferences()
                local show_covers=self:_shelf_covers_enabled(prefs)
                if show_covers then self:_begin_cover_guard("shelf_search_open") end
                local ok,view=pcall(ShelfView.show,{
                    title=(section=="generated" and "已生成书籍 · " or "账号书架 · ").."搜索 “"..q.."” · "..tostring(#results).."本",
                    books=results,
                    show_actions=false,
                    show_tabs=false,
                    show_covers=show_covers,
                    on_select=function(b) self:_shelf_select(b) end,
                    on_hold=function(b) self:_shelf_hold(b) end,
                    on_page_changed=function(page,first,last,current)
                        if show_covers then self:_on_shelf_page(results,current,page,first,last) end
                    end,
                    on_rendered=function() self:_clear_cover_guard() end,
                    on_close=function()
                        self:_cancel_cover_loading()
                        collectgarbage("step",120)
                    end,
                })
                if ok and view then return end
                self:_clear_cover_guard()
                logger.warn("[MiuRead][ShelfSearch] custom view unavailable",tostring(view))
                local items={}
                for _,book in ipairs(results) do
                    local b=book
                    items[#items+1]={
                        text=(b.downloaded and "✓ " or "")..tostring(b.title or "未命名"),
                        post_text=(tostring(b.author or "")~="" and (tostring(b.author).." · ") or "")..self:_shelf_status_text(b),
                        callback=function() self:_shelf_select(b) end,
                    }
                end
                self:list("搜索书架 · "..q,items)
            end},
        }},
    }
    UIManager:show(d)
    d:onShowKeyboard()
end
function Plugin:_cancel_cover_loading()
    self._cover_generation=(tonumber(self._cover_generation) or 0)+1
    if self.cover_async then self.cover_async:cancel("shelf page changed") end
    if self._cover_refresh_task then
        UIManager:unschedule(self._cover_refresh_task)
        self._cover_refresh_task=nil
    end
    self:_clear_cover_guard()
end
function Plugin:_schedule_shelf_cover_refresh(view,generation,delay)
    if self._cover_refresh_task then return end
    local task
    task=function()
        if self._cover_refresh_task~=task then return end
        self._cover_refresh_task=nil
        if generation~=self._cover_generation or not view or view._miu_closed then return end
        self:_begin_cover_guard("shelf_cover_refresh")
        view._suppress_page_callback=true
        local ok,err=pcall(view.updateItems,view,nil,true)
        view._suppress_page_callback=false
        if ok then
            self:_clear_cover_guard()
            collectgarbage("step",160)
        else
            self._cover_safe_mode=true
            logger.warn("[MiuRead][Cover] shelf refresh failed",tostring(err))
        end
    end
    self._cover_refresh_task=task
    UIManager:scheduleIn(delay or .18,task)
end
function Plugin:_schedule_cover_continue(rows,view,page,first,last,generation,index,delay)
    UIManager:scheduleIn(delay or .06,function()
        self:_cache_shelf_page_covers(rows,view,page,first,last,generation,index)
    end)
end
function Plugin:_cache_shelf_page_covers(rows,view,page,first,last,generation,index)
    index=index or first
    if generation~=self._cover_generation or not view or view._miu_closed or tonumber(view.page or 1)~=tonumber(page) then return end
    if index>last then return end
    local book=rows[index]
    if not book or not book.cover or book.cover=="" then
        self:_schedule_cover_continue(rows,view,page,first,last,generation,index+1,.04)
        return
    end
    local cached=book.cover_path or self.library:cached_cover_path(book.bookId)
    if cached then
        book.cover_path=cached
        local changed=false
        for _,entry in ipairs(view.item_table or {}) do
            if tostring(entry.book_id)==tostring(book.bookId) then
                if entry.cover_path~=cached then entry.cover_path=cached; changed=true end
                break
            end
        end
        if changed then self:_schedule_shelf_cover_refresh(view,generation,.12) end
        self:_schedule_cover_continue(rows,view,page,first,last,generation,index+1,.04)
        return
    end
    if not self.cover_async then return end
    if self.cover_async:busy() then
        self:_schedule_cover_continue(rows,view,page,first,last,generation,index,.25)
        return
    end
    local background_available=self.cover_async:available()
    local download_options=background_available
        and {retries=1,timeout={8,15}}
        or {retries=0,timeout={4,7}}
    local book_copy={bookId=book.bookId,cover=book.cover}
    local worker
    if background_available then
        local covers_dir=self.store.covers_dir
        worker=function()
            local HttpChild=require("miuread.http")
            local LibraryChild=require("miuread.library")
            local store={
                covers_dir=covers_dir,
                auth=function() return {cookies={}} end,
                save_auth=function() end,
                get=function(_,_,default) return default end,
                set=function() end,
            }
            local http=HttpChild:new(store)
            local options={
                retries=download_options.retries,
                timeout=download_options.timeout,
                persist_index=false,
                skip_index_lookup=true,
            }
            return LibraryChild:new(nil,http,store):cache_cover(book_copy,options)
        end
    else
        worker=function() return self.library:cache_cover(book_copy,download_options) end
    end
    local started=self.cover_async:run("shelf_cover_page",worker,function(result)
        if generation~=self._cover_generation or not view or view._miu_closed or tonumber(view.page or 1)~=tonumber(page) then return end
        if result and result.ok and result.value then
            if background_available then self:_remember_cover_path(book.bookId,result.value) end
            book.cover_path=result.value
            for _,entry in ipairs(view.item_table or {}) do
                if tostring(entry.book_id)==tostring(book.bookId) then entry.cover_path=result.value; break end
            end
            self:_schedule_shelf_cover_refresh(view,generation,.18)
        elseif result and result.error then
            logger.warn("[MiuRead][Cover] download failed","book_id=",tostring(book.bookId),
                "error=",U.first_line(result.error,160))
        end
        self:_schedule_cover_continue(rows,view,page,first,last,generation,index+1,background_available and .06 or .18)
    end,background_available and 35 or 14)
    if not started then
        self:_schedule_cover_continue(rows,view,page,first,last,generation,index,.3)
    end
end
function Plugin:_on_shelf_page(rows,view,page,first,last)
    self:_cancel_cover_loading()
    local generation=self._cover_generation
    self:_cache_shelf_page_covers(rows,view,page,first,last,generation,first)
end
function Plugin:_cancel_shelf_refresh(reason)
    self._shelf_refresh_generation=(tonumber(self._shelf_refresh_generation) or 0)+1
    self._shelf_main_busy=false
    if self.shelf_async then self.shelf_async:cancel(reason or "shelf closed") end
end

function Plugin:_close_current_shelf()
    local view=self._shelf_view
    self._shelf_view=nil
    self:_cancel_cover_loading()
    self:_cancel_shelf_refresh("shelf replaced")
    if view and not view._miu_closed then pcall(function() UIManager:close(view) end) end
end
function Plugin:_reopen_shelf(mp_mode,section,force_remote)
    section=section=="generated" and "generated" or "account"
    self:_save_shelf_context(section,mp_mode)
    UIManager:scheduleIn(0,function()
        self:_close_current_shelf()
        self:show_shelf(mp_mode,force_remote,section)
    end)
end

function Plugin:_shelf_tabs(selected)
    return {
        {id="books",label="书籍",callback=function()
            if selected~="books" then self:_reopen_shelf(false,"account") end
        end},
        {id="mp",label="公众号",callback=function()
            if selected~="mp" then self:_reopen_shelf(true,"account") end
        end},
        {id="generated",label="已生成",callback=function()
            if selected~="generated" then self:_reopen_shelf(false,"generated") end
        end},
    }
end

function Plugin:_refresh_mp_accounts(on_done,silent)
    if not self:logged_in() then
        if not silent then self.auth_flow:start() end
        if on_done then on_done(nil,"尚未登录") end
        return false
    end
    if not self:is_online() then
        if on_done then on_done(nil,"网络不可用") end
        if not silent then self:info(_("Network unavailable")) end
        return false
    end
    if self.mp_async:busy() then
        if on_done then on_done(nil,"另一项公众号任务正在进行中") end
        if not silent then self:info("另一项公众号任务正在进行中。") end
        return false
    end
    if not silent then self:status_toast("公众号","正在获取公众号列表",2) end
    local started,err=self.mp_async:run("mp-accounts",function()
        return self.mp:accounts({force=true})
    end,function(result)
        self.store:reload()
        if result and result.ok and type(result.value)=="table" then
            if on_done then on_done(result.value,nil) end
        else
            local cached=self.mp:cached_accounts()
            local message=result and result.error or "公众号列表加载失败"
            logger.warn("[MiuRead][MP] account list refresh failed",tostring(message))
            if on_done then on_done(#cached>0 and cached or nil,message) end
        end
    end,60)
    if not started then
        if on_done then on_done(nil,err or "无法启动公众号列表任务") end
        if not silent then self:info(self:_friendly_remote_error(err or "无法启动公众号列表任务","公众号列表加载")) end
    end
    return started
end

function Plugin:show_mp_shelf(force_remote)
    self:_save_shelf_context("account", true)

    local function render(accounts, remote_error)
        accounts = type(accounts) == "table" and accounts or {}
        local rows = {}
        for _, account in ipairs(accounts) do
            local row = self:_mp_normalize_book(account)
            if Protocol.is_mp_account(row.bookId) then
                row.content_type = "mp_account"
                row.author = row.author ~= "" and row.author or "公众号"
                row.status_text = "点击查看文章"
                row.show_cover = false
                rows[#rows + 1] = row
            end
        end

        local function refresh()
            self:_refresh_mp_accounts(function(value, err)
                if value then self:show_mp_shelf(false)
                elseif err then self:info(self:_friendly_remote_error(err, "公众号列表加载")) end
            end, false)
        end

        local function search()
            local dialog
            dialog = InputDialog:new{
                title="搜索公众号", input="",
                buttons={{
                    {text=_("Cancel"), id="close", callback=function() UIManager:close(dialog) end},
                    {text=_("Search"), is_enter_default=true, callback=function()
                        local query=U.trim(dialog:getInputText()):lower()
                        UIManager:close(dialog)
                        if query=="" then return end
                        local found={}
                        for _, row in ipairs(rows) do
                            local hay=(tostring(row.title or "").." "..tostring(row.author or "")):lower()
                            if hay:find(query,1,true) then found[#found+1]=row end
                        end
                        if #found==0 then self:info("没有找到相关公众号")
                        elseif #found==1 then self:mp_account(found[1])
                        else
                            local items={}
                            for _, row in ipairs(found) do
                                local account=row
                                items[#items+1]={text=account.title,post_text=account.author,callback=function() self:mp_account(account) end}
                            end
                            self:list("公众号 · 搜索结果",items)
                        end
                    end},
                }},
            }
            UIManager:show(dialog)
            dialog:onShowKeyboard()
        end

        if #rows == 0 then
            local items={
                {text="书籍",callback=function() self:_reopen_shelf(false,"account") end},
                {text="公众号",enabled=false},
                {text="已生成",callback=function() self:_reopen_shelf(false,"generated") end},
                {text="刷新公众号",enabled=self:logged_in(),callback=refresh},
            }
            if not self:logged_in() then
                items[#items+1]={text="扫码登录",callback=function() self.auth_flow:start() end}
            end
            if remote_error then
                items[#items+1]={text=self:_friendly_remote_error(remote_error,"公众号列表加载"),enabled=false}
            else
                items[#items+1]={text="仅显示微信读书书架返回的公众号",enabled=false}
            end
            self:list("我的书架 · 公众号",items,"暂未识别到公众号")
            return
        end

        local ok, view = pcall(ShelfView.show, {
            title="我的书架 · 公众号 · "..tostring(#rows).."个",
            books=rows, selected_tab="mp", tabs=self:_shelf_tabs("mp"),
            show_covers=false, on_search=search, on_refresh=refresh,
            on_select=function(book) self:mp_account(book) end,
            on_close=function(current)
                if self._shelf_view==current then self._shelf_view=nil end
            end,
        })
        if ok and view then self._shelf_view=view; return end
        logger.warn("[MiuRead][MP] shelf view unavailable",tostring(view))
        local items={
            {text="书籍",callback=function() self:_reopen_shelf(false,"account") end},
            {text="公众号",enabled=false},
            {text="已生成",callback=function() self:_reopen_shelf(false,"generated") end},
            {text="搜索",callback=search},
            {text="刷新公众号",callback=refresh},
        }
        for _,row in ipairs(rows) do
            local account=row
            items[#items+1]={text=account.title,post_text=account.author,callback=function() self:mp_account(account) end}
        end
        self:list("我的书架 · 公众号",items)
    end

    local cached=self.mp:cached_accounts()
    if not force_remote and #cached>0 then
        render(cached,nil)
        if self.mp:accounts_stale() and self:logged_in() and self:is_online() and not self.mp_async:busy() then
            self:_refresh_mp_accounts(function(value)
                if value and self._shelf_view and not self._shelf_view._miu_closed then
                    self:_reopen_shelf(true,"account")
                end
            end,true)
        end
        return
    end
    self:_refresh_mp_accounts(function(value,err)
        if value then render(value,err) else render(cached,err) end
    end,false)
end

function Plugin:show_shelf(mp_mode,force_remote,section)
    local prefs=self.store:preferences()
    section=section or prefs.shelf_section or "account"
    section=section=="generated" and "generated" or "account"
    if mp_mode==nil then mp_mode=tostring(prefs.account_shelf_kind or "books")=="mp" end
    self:_save_shelf_context(section,mp_mode)
    if section=="account" and mp_mode==true then
        return self:show_mp_shelf(force_remote==true)
    end
    self:load_shelf(function(remote_books,remote_mp,remote_error)
        local remote_known=remote_error==nil and (self:logged_in() or (#remote_books+#remote_mp)>0)
        local all_rows=self:_shelf_rows(section,mp_mode,remote_books,remote_mp,remote_known)
        local rows=self.library:sort_filter(all_rows,{section=section})
        self:_prepare_shelf_rows(rows)
        local show_covers=self:_shelf_covers_enabled(self.store:preferences())
        local title=section=="generated" and "已生成书籍" or (mp_mode and "公众号" or "账号书架")
        if remote_error and #rows>0 then self:toast(remote_error,3) end
        local function open_account()
            if section=="account" and not mp_mode then return end
            self:_reopen_shelf(false,"account")
        end
        local function open_generated()
            if section=="generated" then return end
            self:_reopen_shelf(mp_mode,"generated")
        end
        local function refresh()
            if not self:logged_in() then self.auth_flow:start(); return end
            self:_reopen_shelf(mp_mode,section,true)
        end
        if #rows==0 then
            local items={
                {text=(section=="account" and "✓ " or "").."书籍",callback=open_account},
                {text="公众号",callback=function() self:_reopen_shelf(true,"account") end},
                {text=(section=="generated" and "✓ " or "").."已生成",callback=open_generated},
                {text="搜索",callback=function() self:show_shelf_search_dialog(mp_mode,all_rows,section) end},
                {text="刷新书架",enabled=self:logged_in(),callback=refresh},
            }
            if not self:logged_in() then items[#items+1]={text="扫码登录",callback=function() self.auth_flow:start() end} end
            if remote_error then table.insert(items,3,{text=remote_error,enabled=false}) end
            self:list(title,items,"书架为空")
            return
        end
        if show_covers then self:_begin_cover_guard("shelf_open") end
        local ok,view=pcall(ShelfView.show,{
            title="我的书架 · "..(section=="generated" and "已生成" or "书籍").." · "..tostring(#rows).."本",
            books=rows,selected_tab=section=="generated" and "generated" or "books",
            tabs=self:_shelf_tabs(section=="generated" and "generated" or "books"),
            show_covers=show_covers,
            on_search=function() self:show_shelf_search_dialog(mp_mode,all_rows,section) end,
            on_refresh=refresh,on_select=function(b) self:_shelf_select(b) end,
            on_hold=function(b) self:_shelf_hold(b) end,
            on_page_changed=function(page,first,last,current)
                if show_covers then self:_on_shelf_page(rows,current,page,first,last) end
            end,
            on_rendered=function() self:_clear_cover_guard() end,
            on_close=function(current)
                if self._shelf_view==current then self._shelf_view=nil end
                self:_cancel_cover_loading(); self:_cancel_shelf_refresh("shelf closed"); collectgarbage("step",160)
            end,
        })
        if ok and view then self._shelf_view=view; return end
        self:_clear_cover_guard()
        logger.warn("[MiuRead][Shelf] custom view unavailable",tostring(view))
        local items={
            {text=(section=="account" and "✓ " or "").."书籍",callback=open_account},
            {text="公众号",callback=function() self:_reopen_shelf(true,"account") end},
            {text=(section=="generated" and "✓ " or "").."已生成",callback=open_generated},
            {text="搜索",callback=function() self:show_shelf_search_dialog(mp_mode,all_rows,section) end},
            {text="刷新书架",enabled=self:logged_in(),callback=refresh},
        }
        for _,b in ipairs(rows) do local book=b; items[#items+1]={text=book.title,post_text=self:_shelf_status_text(book),callback=function() self:_shelf_select(book) end} end
        self:list(title,items)
    end,force_remote,section)
end


function Plugin:_home_preferences()
    local preferences=self.store:preferences()
    preferences.home_ui=type(preferences.home_ui)=="table" and preferences.home_ui or {}
    local home=preferences.home_ui
    local changed=false
    if home.enabled==nil then home.enabled=true; changed=true end
    local old_layout_version=tonumber(home.layout_version) or 0
    if old_layout_version<20 then
        home.layout_version=20
        home.layout_style=home.layout_style=="compact" and "compact" or "desk"
        -- Keep the selected mode and page positions while upgrading the home
        -- structure. Removed experimental widget fields are no longer read.
        home.widgets=nil
        home.preset=nil
        home.goal_minutes=nil
        home.swipe_quick=nil
        home.initial_page=nil
        changed=true
    end
    if home.layout_style~="compact" and home.layout_style~="desk" then
        home.layout_style="desk"
        changed=true
    end
    if home.auto_scan==nil then home.auto_scan=true; changed=true end
    if type(home.visible_sections)~="table" then home.visible_sections={}; changed=true end
    for _,section in ipairs(HOME_SECTION_ORDER) do
        if home.visible_sections[section]==nil then home.visible_sections[section]=true; changed=true end
    end
    if type(home.source_order)~="table" then home.source_order={}; changed=true end
    local source_seen,source_order={},{}
    for _,section in ipairs(home.source_order) do
        if home.visible_sections[section]~=nil and not source_seen[section] then
            source_seen[section]=true
            source_order[#source_order+1]=section
        end
    end
    for _,section in ipairs(HOME_SECTION_ORDER) do
        if not source_seen[section] then source_seen[section]=true; source_order[#source_order+1]=section end
    end
    if table.concat(source_order,"|")~=table.concat(home.source_order,"|") then changed=true end
    home.source_order=source_order
    if home.auto_hide_empty==nil then home.auto_hide_empty=false; changed=true end
    if type(home.quick_items)~="table" then home.quick_items={}; changed=true end
    if type(home.quick_order)~="table" then home.quick_order={}; changed=true end
    if (tonumber(home.quick_layout_version) or 0)<2 then
        local empty_items=next(home.quick_items)==nil
        local empty_order=#home.quick_order==0
        local legacy_default=quick_boolean_layout_matches(home.quick_items,HOME_QUICK_ITEM_LEGACY_DEFAULT,HOME_QUICK_ITEM_LEGACY_ORDER)
            and quick_order_matches(home.quick_order,HOME_QUICK_ITEM_LEGACY_ORDER)
        if empty_items or empty_order or legacy_default then
            home.quick_items={}
            for _,key in ipairs(HOME_QUICK_ITEM_ORDER) do home.quick_items[key]=HOME_QUICK_ITEM_DEFAULT[key]==true end
            home.quick_order=U.copy(HOME_QUICK_ITEM_ORDER)
        end
        home.quick_layout_version=2
        changed=true
    end
    for _,key in ipairs(HOME_QUICK_ITEM_ORDER) do
        if home.quick_items[key]==nil then home.quick_items[key]=HOME_QUICK_ITEM_DEFAULT[key]==true; changed=true end
    end
    local quick_seen,quick_order={},{}
    for _,key in ipairs(home.quick_order) do
        if HOME_QUICK_ITEM_DEFAULT[key]~=nil and not quick_seen[key] then quick_seen[key]=true; quick_order[#quick_order+1]=key end
    end
    for _,key in ipairs(HOME_QUICK_ITEM_ORDER) do
        if not quick_seen[key] then quick_seen[key]=true; quick_order[#quick_order+1]=key end
    end
    if table.concat(quick_order,"|")~=table.concat(home.quick_order,"|") then changed=true end
    home.quick_order=quick_order
    if home.active_section~="account" and home.active_section~="generated" and home.active_section~="local" and home.active_section~="mp" then home.active_section="account"; changed=true end
    if home.lockscreen_recent==nil then home.lockscreen_recent=true; changed=true end
    home.local_root=tostring(home.local_root or "")
    if type(home.page_by_section)~="table" then home.page_by_section={}; changed=true end
    if changed then self.store:save_preferences(preferences) end
    return home,preferences
end

function Plugin:_save_home_preferences(home,preferences)
    preferences=preferences or self.store:preferences()
    preferences.home_ui=home
    self.store:save_preferences(preferences)
end

function Plugin:_home_enabled()
    if HOME_SESSION.runtime_home_enabled~=nil then
        return HOME_SESSION.runtime_home_enabled~=false
    end
    local home=self:_home_preferences()
    return home.enabled~=false
end

function Plugin:_configured_home_enabled()
    local home=self:_home_preferences()
    return home.enabled~=false
end

function Plugin:_home_mode_label()
    local configured=self:_configured_home_enabled()
    local running=self:_home_enabled()
    local configured_label=configured and "觅阅桌面" or "插件模式"
    if configured~=running then return configured_label.." · 重启后生效" end
    return configured_label
end

function Plugin:_set_home_mode(use_miuread_home)
    local enabled=use_miuread_home==true
    local home,preferences=self:_home_preferences()
    if (home.enabled~=false)==enabled then
        self:toast(enabled and "已选择觅阅桌面模式" or "已选择插件模式",2)
        return false
    end
    home.enabled=enabled
    home.layout_version=21
    self:_save_home_preferences(home,preferences)
    local text
    if enabled then
        text="重启后将使用觅阅桌面。KOReader 启动及关闭从觅阅打开的书籍后，会优先返回觅阅主页。其他桌面插件可能不会自动显示。"
    else
        text="重启后将使用插件模式。觅阅不会替代 KOReader 或其他美化界面，下载、评论、同步、修复和账号功能仍可使用。"
    end
    if not self:_notice_enabled("mode_switch") then
        self:toast("运行模式已保存，重启 KOReader 后生效",3)
        return true
    end
    local dialog
    dialog=ButtonDialog:new{title=text,title_align="center",buttons={
        {{text="立即重启",callback=function() UIManager:close(dialog); self:_restart_koreader() end}},
        {{text="稍后重启",callback=function() UIManager:close(dialog); self:toast("运行模式将在重启后生效",3) end}},
        {{text="稍后重启并不再提示",callback=function()
            UIManager:close(dialog); self:_set_notice_enabled("mode_switch",false); self:toast("运行模式将在重启后生效",3)
        end}},
    }}
    UIManager:show(dialog)
    return true
end

function Plugin:home_mode_menu()
    return {
        {text="觅阅桌面模式",post_text="启动及关书后返回觅阅主页",checked_func=function() return self:_configured_home_enabled() end,callback=function()
            self:_set_home_mode(true)
        end},
        {text="插件模式",post_text="保留 KOReader 或其他美化界面",checked_func=function() return not self:_configured_home_enabled() end,callback=function()
            self:_set_home_mode(false)
        end},
        {text="当前运行",post_text=self:_home_enabled() and "觅阅桌面" or "插件模式",enabled=false},
    }
end

function Plugin:_refresh_home_view(message,refresh_kind)
    if message and message~="" then self:toast(message,2) end
    if HomeView.is_shown() then
        UIManager:scheduleIn(.05,function()
            if HomeView.is_shown() and not self:_active_reader_ui() then
                self:_show_miuread_home_now(false,true,true,refresh_kind or "content")
            end
        end)
    end
end

function Plugin:_notify_home_data_changed(refresh_kind)
    self._home_refresh_pending=true
    local priority={header=1,section=2,content=3,full=4}
    local requested=refresh_kind or "content"
    local current=self._home_refresh_pending_kind or "header"
    if (priority[requested] or 3)>(priority[current] or 1) then
        self._home_refresh_pending_kind=requested
    elseif not self._home_refresh_pending_kind then
        self._home_refresh_pending_kind=requested
    end
    if self._home_refresh_task then return end
    local task
    task=function()
        if self._home_refresh_task~=task then return end
        self._home_refresh_task=nil
        local kind=self._home_refresh_pending_kind or "content"
        self._home_refresh_pending_kind=nil
        if HomeView.is_shown() and not self:_active_reader_ui() then
            self._home_refresh_pending=false
            self:_refresh_home_view(nil,kind)
        end
    end
    self._home_refresh_task=task
    UIManager:scheduleIn(.55,task)
end

function Plugin:_home_schedule_render_refresh(kind)
    if self._home_render_refresh_task then return end
    local task
    task=function()
        if self._home_render_refresh_task~=task then return end
        self._home_render_refresh_task=nil
        if HomeView.is_shown() and not self:_active_reader_ui() then
            HomeView.refresh(kind or "content")
        end
    end
    self._home_render_refresh_task=task
    UIManager:scheduleIn(.12,task)
end

function Plugin:_home_apply_cover_path(book_id,path)
    book_id=tostring(book_id or "")
    path=tostring(path or "")
    if book_id=="" or path=="" then return false end
    local changed=false
    local function apply(book)
        if type(book)=="table" and tostring(book.bookId or book.book_id or "")==book_id
            and tostring(book.cover_path or "")~=path then
            book.cover_path=path
            changed=true
        end
    end
    local hero_id=tostring(self._home_hero and (self._home_hero.bookId or self._home_hero.book_id) or "")
    apply(self._home_hero)
    for _,section in pairs(self._home_sections or {}) do
        for _,book in ipairs(section.rows or {}) do apply(book) end
    end
    if hero_id==book_id then
        local current=HomeView.current()
        if current and current.opts then current.opts.screensaver_file=path end
    end
    return changed
end

function Plugin:_home_refresh_remote(force,user_requested)
    if self._home_remote_refreshing or self:_active_reader_ui() then return false end
    local _,_,updated_at=self.library:cached()
    local age=math.max(0,os.time()-(tonumber(updated_at) or 0))
    if force~=true and age<HOME_SHELF_REFRESH_TTL then return false end
    if not self:logged_in() then
        if user_requested then self:toast("登录后才能刷新微信书架",3) end
        return false
    end
    if not self:is_online() then
        if user_requested then self:toast("当前没有网络连接",3) end
        return false
    end
    self._home_remote_refreshing=true
    if user_requested then self:toast("正在刷新书架…",2) end
    local started=self:_refresh_shelf_async(function(_,_,err)
        self._home_remote_refreshing=false
        if err then
            if user_requested then self:toast(self:_friendly_remote_error(err,"书架刷新"),4) end
            return
        end
        if HomeView.is_shown() and not self:_active_reader_ui() then
            self:_show_miuread_home_now(false,true,true,"content")
        end
        if user_requested then self:toast("书架已刷新",2) end
    end,true)
    if not started then self._home_remote_refreshing=false end
    return started==true
end

function Plugin:_home_manual_refresh()
    local remote=self:_home_refresh_remote(true,true)
    local local_started=self:_home_scan_local(true)
    if not remote and not local_started and self:logged_in() and self:is_online() then
        self:toast("书架已经是最新状态",2)
    end
    return remote or local_started
end

function Plugin:_set_home_layout(style)
    style=style=="compact" and "compact" or "desk"
    local home,preferences=self:_home_preferences()
    home.layout_style=style
    home.layout_version=20
    self:_save_home_preferences(home,preferences)
    self:_refresh_home_view(style=="compact" and "已切换到紧凑布局" or "已切换到标准布局","full")
end

function Plugin:_home_open_section(section)
    if section=="account" then return self:_home_leave_and_run("account shelf",function() self:show_shelf(false,false,"account") end) end
    if section=="generated" then return self:_home_leave_and_run("generated shelf",function() self:show_shelf(false,false,"generated") end) end
    if section=="local" then return self:_home_leave_and_run("local shelf",function() self:show_home_local_library() end) end
    return self:_home_leave_and_run("mp shelf",function() self:show_mp_shelf(false) end)
end

function Plugin:_home_visible_section_keys(sections,home)
    sections=sections or self._home_sections or {}
    home=home or self:_home_preferences()
    home.visible_sections=type(home.visible_sections)=="table" and home.visible_sections or {}
    local keys={}
    for _,section in ipairs(home.source_order or HOME_SECTION_ORDER) do
        local entry=sections[section]
        local enabled=home.visible_sections[section]~=false
        local empty=not entry or #(entry.rows or {})==0
        if enabled and (home.auto_hide_empty~=true or not empty) then keys[#keys+1]=section end
    end
    -- Never leave the home without a selectable source. When every visible
    -- source is empty, keep the first user-enabled one as an empty-state tab.
    if #keys==0 then
        for _,section in ipairs(home.source_order or HOME_SECTION_ORDER) do
            if home.visible_sections[section]~=false then keys[1]=section; break end
        end
    end
    if #keys==0 then
        home.visible_sections.account=true
        keys[1]="account"
    end
    return keys
end

function Plugin:_home_build_tabs(active)
    local tabs={}
    for _,section in ipairs(self._home_visible_keys or HOME_SECTION_ORDER) do
        local tab_section=section
        local entry=self._home_sections and self._home_sections[tab_section] or nil
        tabs[#tabs+1]={
            title=entry and entry.title or tab_section,
            count=entry and #(entry.rows or {}) or 0,
            selected=active==tab_section,
            on_tap=function() self:_set_home_section(tab_section) end,
        }
    end
    return tabs
end

function Plugin:_home_page_limit()
    return Device.screen:getWidth()<Device.screen:getHeight() and 6 or 8
end

function Plugin:_home_preview_page(rows,hero,page,limit)
    limit=math.max(1,tonumber(limit) or self:_home_page_limit())
    local filtered,seen={},{}
    -- “继续阅读”是快捷入口，不应从对应书架中隐藏同一本书。
    -- 保留书架项目，确保标题数量、分页数量和实际可见内容一致。
    for _,book in ipairs(rows or {}) do
        local key=self:_home_book_key(book)
        if key~="" and not seen[key] then
            seen[key]=true
            filtered[#filtered+1]=book
        end
    end
    local total_pages=math.max(1,math.ceil(#filtered/limit))
    page=math.max(1,math.min(total_pages,tonumber(page) or 1))
    local first=(page-1)*limit+1
    local preview={}
    for index=first,math.min(#filtered,first+limit-1) do preview[#preview+1]=filtered[index] end
    return preview,page,total_pages,#filtered
end

function Plugin:_home_page_for(section)
    local home=self:_home_preferences()
    home.page_by_section=type(home.page_by_section)=="table" and home.page_by_section or {}
    return math.max(1,tonumber(home.page_by_section[section]) or 1)
end

function Plugin:_home_change_page(delta)
    local section=self._home_active_section or "account"
    local selected=self._home_sections and self._home_sections[section]
    if not selected then return false end
    local home,preferences=self:_home_preferences()
    home.page_by_section=type(home.page_by_section)=="table" and home.page_by_section or {}
    local _,current,total=self:_home_preview_page(selected.rows,self._home_hero,home.page_by_section[section],self:_home_page_limit())
    local target=math.max(1,math.min(total,current+(tonumber(delta) or 0)))
    if target==current then return true end
    home.page_by_section[section]=target
    self:_save_home_preferences(home,preferences)
    return self:_home_apply_section(section)
end

function Plugin:_home_apply_section(section)
    local selected=self._home_sections and self._home_sections[section]
    if not selected or not HomeView.is_shown() then return false end
    self._home_active_section=section
    local home=self:_home_preferences()
    local preview,page,total_pages=self:_home_preview_page(
        selected.rows,self._home_hero,
        home.page_by_section and home.page_by_section[section],
        self:_home_page_limit()
    )
    if not home.page_by_section or tonumber(home.page_by_section[section])~=page then
        local current,preferences=self:_home_preferences()
        current.page_by_section=type(current.page_by_section)=="table" and current.page_by_section or {}
        current.page_by_section[section]=page
        self:_save_home_preferences(current,preferences)
    end
    local updated=HomeView.update_section{
        tabs=self:_home_build_tabs(section),
        shelf_title=selected.title.." · "..tostring(#selected.rows).."本",
        shelf_books=preview,
        shelf_page=page,
        shelf_pages=total_pages,
        empty_text=selected.empty,
        on_open_book=function(book) self:_home_open_book(book) end,
        on_shelf_all=function() self:_home_open_section(section) end,
        on_shelf_page=function(delta) self:_home_change_page(delta) end,
    }
    if updated then
        self:_home_schedule_local_metadata(preview)
        self:_home_schedule_remote_covers(preview)
    end
    return updated
end

function Plugin:_set_home_section(section)
    local allowed={}
    for _,key in ipairs(self._home_visible_keys or HOME_SECTION_ORDER) do allowed[key]=true end
    section=allowed[section] and section or (self._home_visible_keys and self._home_visible_keys[1]) or "account"
    local home,preferences=self:_home_preferences()
    if home.active_section==section and self._home_active_section==section then return end
    home.active_section=section
    self:_save_home_preferences(home,preferences)
    if self:_home_apply_section(section) then
        logger.info("[MiuRead][Home] section updated partial",tostring(section))
    else
        self:_refresh_home_view(nil,"section")
    end
end

function Plugin:_toggle_home_lockscreen(confirmed)
    local home,preferences=self:_home_preferences()
    local enabling=home.lockscreen_recent==false
    if enabling and confirmed~=true and self:_notice_enabled("lockscreen") then
        local dialog
        dialog=ButtonDialog:new{title="锁屏封面需要生成和写入图片，关闭书籍或刷新主页时可能会稍慢。",title_align="center",buttons={
            {{text="开启",callback=function() UIManager:close(dialog); self:_toggle_home_lockscreen(true) end}},
            {{text="开启并不再提示",callback=function() UIManager:close(dialog); self:_set_notice_enabled("lockscreen",false); self:_toggle_home_lockscreen(true) end}},
            {{text="取消",callback=function() UIManager:close(dialog) end}},
        }}
        UIManager:show(dialog)
        return
    end
    home.lockscreen_recent=enabling
    self:_save_home_preferences(home,preferences)
    self:_refresh_home_view(home.lockscreen_recent and "主页锁屏将显示最近阅读封面" or "已恢复 KOReader 原锁屏设置","header")
end

function Plugin:home_layout_settings_menu()
    local home=self:_home_preferences()
    return {
        {text="标准布局",post_text="继续阅读与分类书架",checked_func=function() return home.layout_style~="compact" end,callback=function()
            self:_set_home_layout("desk")
        end},
        {text="紧凑布局",post_text="缩小内容，适合旧设备",checked_func=function() return home.layout_style=="compact" end,callback=function()
            self:_set_home_layout("compact")
        end},
    }
end

function Plugin:_home_toggle_source(section)
    local allowed={account=true,generated=true,["local"]=true,mp=true}
    if not allowed[section] then return false end
    local home,preferences=self:_home_preferences()
    home.visible_sections=type(home.visible_sections)=="table" and home.visible_sections or {}
    local currently=home.visible_sections[section]~=false
    if currently then
        local enabled=0
        for _,key in ipairs(HOME_SECTION_ORDER) do
            if home.visible_sections[key]~=false then enabled=enabled+1 end
        end
        if enabled<=1 then self:toast("至少保留一个书架来源",2); return false end
    end
    home.visible_sections[section]=not currently
    local visible=self:_home_visible_section_keys(self._home_sections,home)
    local active_ok=false
    for _,key in ipairs(visible) do if key==home.active_section then active_ok=true; break end end
    if not active_ok then home.active_section=visible[1] or "account" end
    self:_save_home_preferences(home,preferences)
    self:_refresh_home_view(nil,"content")
    return true
end

function Plugin:_toggle_home_auto_hide_empty()
    local home,preferences=self:_home_preferences()
    home.auto_hide_empty=home.auto_hide_empty~=true
    local visible=self:_home_visible_section_keys(self._home_sections,home)
    local active_ok=false
    for _,key in ipairs(visible) do if key==home.active_section then active_ok=true; break end end
    if not active_ok then home.active_section=visible[1] or "account" end
    self:_save_home_preferences(home,preferences)
    self:_refresh_home_view(nil,"content")
end

local HOME_SOURCE_LABELS={account="微信书架",generated="已下载",["local"]="本地书籍",mp="公众号"}

function Plugin:_home_move_source(key,delta)
    local home,preferences=self:_home_preferences()
    local order=home.source_order or HOME_SECTION_ORDER
    local index
    for i,name in ipairs(order) do if name==key then index=i; break end end
    if not index then return false end
    local target=index+(tonumber(delta) or 0)
    if target<1 or target>#order then return false end
    order[index],order[target]=order[target],order[index]
    home.source_order=order
    self:_save_home_preferences(home,preferences)
    self:_refresh_home_view(nil,"content")
    return true
end

function Plugin:home_source_order_menu()
    local home=self:_home_preferences()
    local rows={}
    for index,key in ipairs(home.source_order or HOME_SECTION_ORDER) do
        local item_key,item_index=key,index
        rows[#rows+1]={
            text=HOME_SOURCE_LABELS[item_key] or item_key,
            post_text=tostring(item_index),
            sub_item_table_func=function()
                local current=self:_home_preferences().source_order or HOME_SECTION_ORDER
                local current_index
                for i,name in ipairs(current) do if name==item_key then current_index=i; break end end
                current_index=current_index or item_index
                return {
                    {text="上移",enabled_func=function() return current_index>1 end,callback=function() self:_home_move_source(item_key,-1) end},
                    {text="下移",enabled_func=function() return current_index<#current end,callback=function() self:_home_move_source(item_key,1) end},
                }
            end,
        }
    end
    return rows
end

function Plugin:home_source_settings_menu()
    local home=self:_home_preferences()
    local rows={}
    for _,section in ipairs(home.source_order or HOME_SECTION_ORDER) do
        local key=section
        rows[#rows+1]={
            text=HOME_SOURCE_LABELS[key],
            checked_func=function() return self:_home_preferences().visible_sections[key]~=false end,
            keep_menu_open=true,
            callback=function() self:_home_toggle_source(key) end,
        }
    end
    rows[#rows+1]={
        text="自动隐藏空来源",
        checked_func=function() return self:_home_preferences().auto_hide_empty==true end,
        keep_menu_open=true,
        callback=function() self:_toggle_home_auto_hide_empty() end,
    }
    rows[#rows+1]={text="调整来源顺序",sub_item_table_func=function() return self:home_source_order_menu() end}
    rows[#rows+1]={text="恢复默认顺序",callback=function()
        local current,preferences=self:_home_preferences()
        current.source_order=U.copy(HOME_SECTION_ORDER)
        self:_save_home_preferences(current,preferences)
        self:_refresh_home_view("书架来源顺序已恢复默认","content")
    end}
    return rows
end

local HOME_QUICK_LABELS={
    wifi="Wi-Fi",frontlight="前光",refresh_shelf="刷新书架",full_refresh="全屏刷新",
    settings="觅阅设置",koreader_menu="KOReader 菜单",downloads="下载管理",sync="阅读同步",
    night="夜间模式",rotate="旋转屏幕",sleep="休眠",restart="重启 KOReader",quit="退出 KOReader",
}

function Plugin:_home_toggle_quick_item(key)
    local home,preferences=self:_home_preferences()
    local currently=home.quick_items[key]==true
    local count=0
    for _,name in ipairs(HOME_QUICK_ITEM_ORDER) do if home.quick_items[name]==true then count=count+1 end end
    if not currently and count>=9 then
        self:toast("快捷面板最多显示九项",2)
        return false
    end
    home.quick_items[key]=not currently
    count=count+(currently and -1 or 1)
    if count<4 then
        home.quick_items[key]=true
        self:toast("快捷面板至少保留四项",2)
        return false
    end
    self:_save_home_preferences(home,preferences)
    return true
end

function Plugin:_home_move_quick_item(key,delta)
    local home,preferences=self:_home_preferences()
    local order=home.quick_order or {}
    local index
    for i,name in ipairs(order) do if name==key then index=i; break end end
    if not index then return false end
    local target=index+(tonumber(delta) or 0)
    if target<1 or target>#order then return false end
    order[index],order[target]=order[target],order[index]
    home.quick_order=order
    self:_save_home_preferences(home,preferences)
    return true
end

function Plugin:home_quick_panel_order_menu()
    local home=self:_home_preferences()
    local rows={}
    for index,key in ipairs(home.quick_order or HOME_QUICK_ITEM_ORDER) do
        local item_key,item_index=key,index
        rows[#rows+1]={
            text=HOME_QUICK_LABELS[item_key] or item_key,
            post_text=tostring(item_index),
            sub_item_table_func=function()
                return {
                    {text="上移",enabled_func=function() return item_index>1 end,callback=function() self:_home_move_quick_item(item_key,-1) end},
                    {text="下移",enabled_func=function() return item_index<#(self:_home_preferences().quick_order or {}) end,callback=function() self:_home_move_quick_item(item_key,1) end},
                }
            end,
        }
    end
    return rows
end

function Plugin:home_quick_panel_settings_menu()
    local rows={}
    for _,key in ipairs(HOME_QUICK_ITEM_ORDER) do
        local item_key=key
        rows[#rows+1]={
            text=HOME_QUICK_LABELS[item_key] or item_key,
            checked_func=function() return self:_home_preferences().quick_items[item_key]==true end,
            keep_menu_open=true,
            callback=function() self:_home_toggle_quick_item(item_key) end,
        }
    end
    rows[#rows+1]={text="调整顺序",sub_item_table_func=function() return self:home_quick_panel_order_menu() end}
    rows[#rows+1]={text="恢复推荐布局",callback=function()
        local home,preferences=self:_home_preferences()
        home.quick_items={}
        for _,key in ipairs(HOME_QUICK_ITEM_ORDER) do home.quick_items[key]=HOME_QUICK_ITEM_DEFAULT[key]==true end
        home.quick_order=U.copy(HOME_QUICK_ITEM_ORDER)
        home.quick_layout_version=2
        self:_save_home_preferences(home,preferences)
        self:toast("快捷面板已恢复推荐布局")
    end}
    return rows
end

local READER_QUICK_LABELS={
    home="觅阅书架",toc="目录",progress="阅读进度",font="字体与字号",
    typeset="完整排版",sync="阅读同步",current_book="当前书籍",downloads="下载管理",
    full_refresh="全屏刷新",koreader_menu="KOReader 菜单",sleep="休眠",more="更多",
}

function Plugin:_reader_preferences()
    local preferences=self.store:preferences()
    local reader=type(preferences.reader_ui)=="table" and preferences.reader_ui or {}
    local changed=false
    if reader.enabled==nil then reader.enabled=true; changed=true end
    if reader.plugin_mode_enabled==nil then reader.plugin_mode_enabled=false; changed=true end
    if reader.show_title==nil then reader.show_title=true; changed=true end
    if reader.show_status==nil then reader.show_status=true; changed=true end
    if type(reader.quick_items)~="table" then reader.quick_items={}; changed=true end
    if type(reader.quick_order)~="table" then reader.quick_order={}; changed=true end
    if (tonumber(reader.quick_layout_version) or 0)<2 then
        local empty_items=next(reader.quick_items)==nil
        local empty_order=#reader.quick_order==0
        local legacy_default=quick_boolean_layout_matches(reader.quick_items,READER_QUICK_ITEM_LEGACY_DEFAULT,READER_QUICK_ITEM_LEGACY_ORDER)
            and quick_order_matches(reader.quick_order,READER_QUICK_ITEM_LEGACY_ORDER)
        if empty_items or empty_order or legacy_default then
            reader.quick_items={}
            for _,key in ipairs(READER_QUICK_ITEM_ORDER) do reader.quick_items[key]=READER_QUICK_ITEM_DEFAULT[key]==true end
            reader.quick_order=U.copy(READER_QUICK_ITEM_ORDER)
        end
        reader.quick_layout_version=2
        changed=true
    end
    for _,key in ipairs(READER_QUICK_ITEM_ORDER) do
        if reader.quick_items[key]==nil then reader.quick_items[key]=READER_QUICK_ITEM_DEFAULT[key]==true; changed=true end
    end
    local seen,order={},{}
    for _,key in ipairs(reader.quick_order) do
        if READER_QUICK_ITEM_DEFAULT[key]~=nil and not seen[key] then seen[key]=true; order[#order+1]=key end
    end
    for _,key in ipairs(READER_QUICK_ITEM_ORDER) do
        if not seen[key] then seen[key]=true; order[#order+1]=key end
    end
    if table.concat(order,"|")~=table.concat(reader.quick_order,"|") then reader.quick_order=order; changed=true end
    preferences.reader_ui=reader
    if changed then self.store:save_preferences(preferences) end
    return reader,preferences
end

function Plugin:_reader_panel_active()
    local reader=self:_reader_preferences()
    if reader.enabled==false then return false end
    if self:_home_enabled() then return true end
    return reader.plugin_mode_enabled==true
end

function Plugin:_save_reader_preferences(reader,preferences)
    preferences=preferences or self.store:preferences()
    preferences.reader_ui=reader
    self.store:save_preferences(preferences)
end

function Plugin:_toggle_reader_quick_item(key)
    local reader,preferences=self:_reader_preferences()
    local current=reader.quick_items[key]==true
    local count=0
    for _,name in ipairs(READER_QUICK_ITEM_ORDER) do if reader.quick_items[name]==true then count=count+1 end end
    if not current and count>=8 then self:toast("阅读面板最多显示八项",2); return false end
    reader.quick_items[key]=not current
    count=count+(current and -1 or 1)
    if count<4 then reader.quick_items[key]=true; self:toast("阅读面板至少保留四项",2); return false end
    self:_save_reader_preferences(reader,preferences)
    return true
end

function Plugin:_move_reader_quick_item(key,delta)
    local reader,preferences=self:_reader_preferences()
    local order=reader.quick_order or {}
    local index
    for i,name in ipairs(order) do if name==key then index=i; break end end
    if not index then return false end
    local target=index+(tonumber(delta) or 0)
    if target<1 or target>#order then return false end
    order[index],order[target]=order[target],order[index]
    reader.quick_order=order
    self:_save_reader_preferences(reader,preferences)
    return true
end

function Plugin:reader_quick_panel_order_menu()
    local reader=self:_reader_preferences()
    local rows={}
    for index,key in ipairs(reader.quick_order or READER_QUICK_ITEM_ORDER) do
        local item_key,item_index=key,index
        rows[#rows+1]={text=READER_QUICK_LABELS[item_key] or item_key,post_text=tostring(item_index),sub_item_table_func=function()
            local current=self:_reader_preferences().quick_order or READER_QUICK_ITEM_ORDER
            local current_index
            for i,name in ipairs(current) do if name==item_key then current_index=i; break end end
            current_index=current_index or item_index
            return {
                {text="上移",enabled_func=function() return current_index>1 end,callback=function() self:_move_reader_quick_item(item_key,-1) end},
                {text="下移",enabled_func=function() return current_index<#current end,callback=function() self:_move_reader_quick_item(item_key,1) end},
            }
        end}
    end
    return rows
end

function Plugin:reader_quick_panel_items_menu()
    local rows={}
    for _,key in ipairs(READER_QUICK_ITEM_ORDER) do
        local item_key=key
        rows[#rows+1]={text=READER_QUICK_LABELS[item_key] or item_key,checked_func=function()
            return self:_reader_preferences().quick_items[item_key]==true
        end,keep_menu_open=true,callback=function() self:_toggle_reader_quick_item(item_key) end}
    end
    rows[#rows+1]={text="调整顺序",sub_item_table_func=function() return self:reader_quick_panel_order_menu() end}
    rows[#rows+1]={text="恢复推荐布局",callback=function()
        local reader,preferences=self:_reader_preferences()
        reader.quick_items={}
        for _,key in ipairs(READER_QUICK_ITEM_ORDER) do reader.quick_items[key]=READER_QUICK_ITEM_DEFAULT[key]==true end
        reader.quick_order=U.copy(READER_QUICK_ITEM_ORDER)
        reader.quick_layout_version=2
        self:_save_reader_preferences(reader,preferences)
        self:toast("阅读面板已恢复推荐布局")
    end}
    return rows
end

function Plugin:reader_quick_panel_settings_menu()
    return {
        {text="启用觅阅阅读面板",checked_func=function() return self:_reader_preferences().enabled~=false end,keep_menu_open=true,callback=function()
            local reader,preferences=self:_reader_preferences(); reader.enabled=reader.enabled==false; self:_save_reader_preferences(reader,preferences)
        end},
        {text="插件模式下显示阅读面板",post_text="默认关闭，避免影响其他 UI",checked_func=function() return self:_reader_preferences().plugin_mode_enabled==true end,keep_menu_open=true,callback=function()
            local reader,preferences=self:_reader_preferences(); reader.plugin_mode_enabled=reader.plugin_mode_enabled~=true; self:_save_reader_preferences(reader,preferences)
            self:toast("重开书籍后生效",2)
        end},
        {text="显示书名",checked_func=function() return self:_reader_preferences().show_title~=false end,keep_menu_open=true,callback=function()
            local reader,preferences=self:_reader_preferences(); reader.show_title=reader.show_title==false; self:_save_reader_preferences(reader,preferences)
        end},
        {text="显示阅读状态",checked_func=function() return self:_reader_preferences().show_status~=false end,keep_menu_open=true,callback=function()
            local reader,preferences=self:_reader_preferences(); reader.show_status=reader.show_status==false; self:_save_reader_preferences(reader,preferences)
        end},
        {text="快捷项目与顺序",sub_item_table_func=function() return self:reader_quick_panel_items_menu() end},
    }
end

function Plugin:_notice_enabled(key)
    local notices=self.store:preferences().notices or {}
    return notices[key]~=false
end

function Plugin:_set_notice_enabled(key,enabled)
    local p=self.store:preferences(); p.notices=type(p.notices)=="table" and p.notices or {}
    p.notices[key]=enabled==true
    self.store:save_preferences(p)
end

local NOTICE_LABELS={
    reader_download="阅读时下载提醒",low_battery="低电量下载提醒",low_storage="存储空间提醒",
    full_refresh="全屏刷新说明",lockscreen="锁屏封面影响说明",library_scan="扫描书库提醒",
    repair_while_reading="阅读中修复提醒",mode_switch="运行模式切换说明",
}

function Plugin:notice_settings_menu()
    local order={"reader_download","low_battery","low_storage","full_refresh","lockscreen","library_scan","repair_while_reading","mode_switch"}
    local rows={}
    for _,key in ipairs(order) do
        local notice_key=key
        rows[#rows+1]={text=NOTICE_LABELS[notice_key] or notice_key,checked_func=function() return self:_notice_enabled(notice_key) end,keep_menu_open=true,callback=function()
            self:_set_notice_enabled(notice_key,not self:_notice_enabled(notice_key))
        end}
    end
    rows[#rows+1]={text="恢复全部使用提醒",callback=function()
        for _,key in ipairs(order) do self:_set_notice_enabled(key,true) end
        self:toast("使用提醒已恢复")
    end}
    rows[#rows+1]={text="数据删除与覆盖确认",post_text="始终保留",enabled=false}
    return rows
end

function Plugin:download_reader_policy_menu()
    local choices={{"ask","每次询问（推荐）"},{"allow","允许阅读时后台下载"},{"after_reading","退出阅读后再下载"}}
    local rows={}
    for _,choice in ipairs(choices) do
        local key,label=choice[1],choice[2]
        rows[#rows+1]={text=label,radio=true,checked_func=function() return tostring(self.store:preferences().download_reader_policy or "ask")==key end,callback=function()
            local p=self.store:preferences(); p.download_reader_policy=key; self.store:save_preferences(p); self:toast("阅读时下载策略已更新")
        end}
    end
    return rows
end

function Plugin:show_home_layout_dialog()
    local dialog
    local home=self:_home_preferences()
    local current=home.layout_style=="compact" and "紧凑布局" or "标准布局"
    local function choose(style)
        if dialog then UIManager:close(dialog) end
        self:_set_home_layout(style)
    end
    dialog=ButtonDialog:new{
        title="页面布局 · 当前："..current,
        title_align="center",
        buttons={
            {{text=(home.layout_style~="compact" and "✓ " or "").."标准布局",callback=function() choose("desk") end}},
            {{text=(home.layout_style=="compact" and "✓ " or "").."紧凑布局",callback=function() choose("compact") end}},
            {{text="关闭",callback=function() UIManager:close(dialog) end}},
        },
    }
    UIManager:show(dialog)
end

function Plugin:_home_close_to_native(show_notice)
    -- This is the only temporary path that intentionally reveals FileManager.
    self:_cancel_native_menu_guard()
    HOME_SESSION_SUPPRESSED=false
    HOME_NATIVE_VISIT=true
    HOME_READER_ORIGIN=false
    HOME_READER_FILE=nil
    HOME_EXPECTED_CLOSE=true
    self:_home_stop_background("temporary native visit")
    -- Ensure there is always a native page below the fullscreen MiuRead home.
    self:_ensure_filemanager_base(HOME_RETURN_FILE)
    HomeQuickPanel.close()
    HomeView.close()
    self._home_view=nil
    HOME_EXPECTED_CLOSE=false
    persist_home_session()
    if show_notice~=false then
        self:toast("已进入 KOReader；可从“返回觅阅主页”回到觅阅",3)
    end
    return true
end

function Plugin:_home_leave_and_run(reason,callback)
    sync_home_session()
    HOME_SESSION_SUPPRESSED=false
    HOME_NATIVE_VISIT=false
    persist_home_session()
    self._home_child_reason=reason or "home action"
    local runner=function()
        local ok,err=xpcall(callback,debug.traceback)
        if not ok then
            logger.warn("[MiuRead][Home] action failed",tostring(reason),tostring(err))
            self:info("这个入口暂时无法打开。\n\n"..tostring(err))
        end
    end
    if type(UIManager.tickAfterNext)=="function" then UIManager:tickAfterNext(runner)
    else UIManager:scheduleIn(.05,runner) end
end

function Plugin:_show_standalone_menu(title,items,options)
    options=options or {}
    items=type(items)=="table" and items or {}
    if #items==0 then self:info("没有可用选项"); return nil end
    local menu
    local close_standalone
    local rows={}
    for _,entry in ipairs(items) do
        local source=entry
        local enabled=source.enabled~=false
        if type(source.enabled_func)=="function" then
            local ok,value=pcall(source.enabled_func)
            enabled=ok and value~=false
        end
        local label=tostring(source.text or (type(source.text_func)=="function" and source.text_func() or ""))
        if type(source.checked_func)=="function" then
            local ok,checked=pcall(source.checked_func)
            if ok and checked==true then label="✓ "..label end
        end
        local row={
            text=label,
            post_text=source.post_text,
            enabled=enabled,
            separator=source.separator,
        }
        if source.sub_item_table_func or source.sub_item_table then
            row.post_text=row.post_text or "›"
            row.callback=function()
                local child=source.sub_item_table
                if type(source.sub_item_table_func)=="function" then
                    local ok,value=xpcall(source.sub_item_table_func,debug.traceback)
                    if not ok then self:info("这个入口暂时无法打开。\n\n"..tostring(value)); return end
                    child=value
                end
                self:_show_standalone_menu(tostring(source.text or title),child,options)
            end
        elseif type(source.callback)=="function" then
            row.callback=function(...)
                logger.info("[MiuRead][Menu] standalone item tapped",tostring(source.text or ""))
                local args={...}
                local function run_action()
                    local ok,err=xpcall(function() return source.callback(unpack_args(args)) end,debug.traceback)
                    if not ok then
                        logger.warn("[MiuRead][Menu] standalone action failed",tostring(source.text or ""),tostring(err))
                        self:info("这个入口暂时无法打开。\n\n"..tostring(err))
                        return
                    end
                    if source.keep_menu_open==true and menu and UIManager:isWidgetShown(menu) then
                        UIManager:scheduleIn(.05,function()
                            if menu and UIManager:isWidgetShown(menu) then
                                local refreshed=self:_standalone_rows(title,items,menu)
                                if refreshed then menu.item_table=refreshed; pcall(menu.updateItems,menu) end
                            end
                        end)
                    end
                end
                if source.close_before_action==true and close_standalone then
                    if close_standalone()~=false then UIManager:scheduleIn(.04,run_action)
                    else run_action() end
                else
                    run_action()
                end
            end
        end
        rows[#rows+1]=row
    end
    -- Reader-side menus must receive their own title-bar tap before any
    -- ReaderUI gesture zone. RawMenu keeps KOReader's native event order; the
    -- bridged Menu remains unchanged for MiuRead home pages.
    local MenuClass=options.native_input==true and RawMenu or Menu
    menu=MenuClass:new{title=tostring(title or "觅阅"),item_table=rows,is_borderless=true,title_bar_fm_style=true}
    menu._miuread_transient=true
    -- TitleBar captures a dynamic self:onClose() call when it is created.
    -- Replacing Menu:onClose on this concrete instance is sufficient and avoids
    -- mutating already-built child button fields that differ across KOReader
    -- versions.
    close_standalone=function()
        if not menu or menu._miuread_closing then return true end
        menu._miuread_closing=true
        local ok,err=pcall(UIManager.close,UIManager,menu)
        if not ok then
            menu._miuread_closing=false
            logger.warn("[MiuRead][Menu] standalone close failed",tostring(err))
            return false
        end
        return true
    end
    menu.onClose=close_standalone
    menu.onCloseAllMenus=close_standalone
    UIManager:show(menu)
    return menu
end

-- Small helper used only when a standalone toggle menu stays open.
function Plugin:_standalone_rows(title,items,menu)
    local rows={}
    for _,entry in ipairs(items or {}) do
        local source=entry
        local enabled=source.enabled~=false
        if type(source.enabled_func)=="function" then local ok,v=pcall(source.enabled_func); enabled=ok and v~=false end
        local label=tostring(source.text or (type(source.text_func)=="function" and source.text_func() or ""))
        if type(source.checked_func)=="function" then local ok,v=pcall(source.checked_func); if ok and v==true then label="✓ "..label end end
        local row={text=label,post_text=source.post_text,enabled=enabled,separator=source.separator}
        if source.sub_item_table_func or source.sub_item_table then
            row.post_text=row.post_text or "›"
            row.callback=function()
                local child=source.sub_item_table
                if type(source.sub_item_table_func)=="function" then local ok,v=xpcall(source.sub_item_table_func,debug.traceback); if not ok then self:info(tostring(v)); return end; child=v end
                self:_show_standalone_menu(tostring(source.text or title),child)
            end
        elseif type(source.callback)=="function" then
            row.callback=function(...) return source.callback(...) end
        end
        rows[#rows+1]=row
    end
    return rows
end

function Plugin:_home_status_line()
    local parts={os.date("%H:%M")}
    local ok_network,NetworkMgr=pcall(require,"ui/network/manager")
    if ok_network and NetworkMgr and type(NetworkMgr.isWifiOn)=="function" then
        local ok,value=pcall(NetworkMgr.isWifiOn,NetworkMgr)
        if ok then parts[#parts+1]=value==true and "Wi-Fi" or "离线" end
    end
    local device=HomeData.device_state()
    if tonumber(device.battery) then
        parts[#parts+1]=tostring(math.floor(tonumber(device.battery)+.5)).."%"
    end
    return table.concat(parts,"  ")
end

function Plugin:_schedule_home_startup(delay)
    self._home_start_generation=(tonumber(self._home_start_generation) or 0)+1
    local generation=self._home_start_generation
    local function attempt(number)
        if generation~=self._home_start_generation then return end
        sync_home_session()
        if HOME_SESSION_SUPPRESSED or HOME_NATIVE_VISIT or HOME_EXITING or UIManager._exit_code~=nil or not self:_home_enabled() then return end
        if HomeView.is_shown() or self:_active_reader_ui() then return end
        local ready=false
        local ok,FileManager=pcall(require,"apps/filemanager/filemanager")
        if ok and FileManager and FileManager.instance then ready=true end
        if not ready and number>=4 then
            ready=self:_ensure_filemanager_base(HOME_RETURN_FILE)
        end
        if ready then
            local shown=self:_show_miuread_home_now(false,false,true)
            if shown or HomeView.is_shown() then
                logger.info("[MiuRead][Home] startup bookshelf shown","attempt=",tostring(number))
                return
            end
        end
        if number<40 then
            UIManager:scheduleIn(.25,function() attempt(number+1) end)
        else
            logger.warn("[MiuRead][Home] startup bookshelf was not shown")
        end
    end
    UIManager:scheduleIn(tonumber(delay) or .5,function() attempt(1) end)
end

function Plugin:_home_status_text(book,is_local)
    book=book or {}
    local id=tostring(book.bookId or book.book_id or "")
    local state=self:_download_state()
    local state_id=tostring(state.book_id or (state.book and state.book.bookId) or "")
    if id~="" and state_id==id then
        if state.status=="active" then
            local percent=self:_download_percent(state)
            local generating={underlines=true,thoughts=true,footnotes=true,images=true,package=true}
            return (generating[tostring(state.stage or "")] and "生成中 " or "下载中 ")..tostring(percent).."%"
        end
        if state.status=="failed" then return "失败" end
        if state.status=="interrupted" or state.status=="pending_install" or state.status=="annotation_pending" then return "待修复" end
    end
    if id~="" then
        for _,job in ipairs(self.store:download_queue()) do
            local queued_id=tostring(job.book and (job.book.bookId or job.book.book_id) or "")
            if queued_id==id then return "排队中" end
        end
    end
    if is_local or book.source=="local" or book.local_file==true then return "本地" end
    local file=tostring(book.file or "")
    if book.source=="miuread" or book.shelf_section=="generated" or (file~="" and U.file_exists(file)) then return "已生成" end
    if Protocol.is_mp_account(id) or book.source=="mp" then return "公众号" end
    return "未生成"
end

function Plugin:_home_root()
    local prefs=self.store:preferences().home_ui or {}
    local explicit=U.trim(tostring(prefs.local_root or ""))
    if explicit~="" and lfs.attributes(explicit,"mode")=="directory" then return explicit end

    local native_home=""
    if _G.G_reader_settings and type(_G.G_reader_settings.readSetting)=="function" then
        local ok,value=pcall(_G.G_reader_settings.readSetting,_G.G_reader_settings,"home_dir")
        if ok then native_home=U.trim(tostring(value or "")) end
    end
    local download_root=tostring(self.store.default_books_dir or ""):gsub("/+$","")
    local normalized_home=native_home:gsub("/+$","")
    if download_root~="" and (normalized_home==download_root or normalized_home:sub(1,#download_root+1)==download_root.."/") then
        -- KOReader often remembers the MiuRead download folder as its current
        -- home. That is not the user's full local library.
        native_home=""
    end

    for _,candidate in ipairs({
        "/mnt/us/documents",
        "/mnt/onboard",
        native_home,
        "/mnt/us/books",
        self.store.default_books_dir,
    }) do
        if candidate and candidate~="" and candidate~="/" and lfs.attributes(candidate,"mode")=="directory" then
            return candidate
        end
    end
    return self.store.default_books_dir
end

function Plugin:_home_local_cache()
    local value=self.store:get("home_local_index",{})
    if type(value)~="table" then value={} end
    value.books=type(value.books)=="table" and value.books or {}
    return value
end

function Plugin:_home_local_rows()
    local cache=self:_home_local_cache()
    local quick_changed=false
    local checked=0
    local checked_paths={}
    local function read_quick(book)
        local filepath=tostring(book and book.file or "")
        if filepath=="" or checked_paths[filepath] or not LocalMetadata.needs_refresh(book,false) then return end
        checked_paths[filepath]=true
        checked=checked+1
        local metadata=LocalMetadata.read(filepath,self:_home_local_metadata_dir(),{open_document=false,use_bim=false})
        if metadata and LocalMetadata.merge(book,metadata) then quick_changed=true end
    end
    local lastfile=""
    if _G.G_reader_settings and type(_G.G_reader_settings.readSetting)=="function" then
        local ok,value=pcall(_G.G_reader_settings.readSetting,_G.G_reader_settings,"lastfile")
        if ok then lastfile=tostring(value or "") end
    end
    if lastfile~="" then
        for _,book in ipairs(cache.books or {}) do
            if tostring(book.file or "")==lastfile then read_quick(book); break end
        end
    end
    for _,book in ipairs(cache.books or {}) do
        if checked>=80 then break end
        read_quick(book)
    end
    if quick_changed then self.store:set("home_local_index",cache) end
    local rows={}
    local known_paths={}
    local function remember(path)
        path=tostring(path or ""):gsub("\\","/"):gsub("/+","/")
        if path~="" then known_paths[path]=true end
    end
    for _,book in pairs(self.store:library() or {}) do
        for _,record in pairs(book.variants or {}) do
            if type(record)=="table" then remember(record.file); remember(record.original_file) end
        end
        for _,chapter in pairs(book.chapters or {}) do
            for _,record in pairs(chapter or {}) do
                if type(record)=="table" then remember(record.file); remember(record.original_file) end
            end
        end
    end
    for _,row in ipairs(cache.books or {}) do
        local path=tostring(row.file or "")
        local key=path:gsub("\\","/"):gsub("/+","/")
        if path~="" and U.file_exists(path) and not known_paths[key] then
            local copy=U.copy(row)
            copy.local_file=true
            copy.source="local"
            copy.status_text=self:_home_status_text(copy,true)
            rows[#rows+1]=copy
        end
    end
    table.sort(rows,function(a,b)
        local am=tonumber(a.last_read_at or a.modified_at) or 0
        local bm=tonumber(b.last_read_at or b.modified_at) or 0
        if am~=bm then return am>bm end
        return tostring(a.title or ""):lower()<tostring(b.title or ""):lower()
    end)
    return rows,cache
end

function Plugin:_home_attach_local_record(row)
    if type(row)~="table" then return row end
    local id=tostring(row.bookId or row.book_id or "")
    if id=="" then return row end
    local stored=type(row.local_record)=="table" and row.local_record or self.store:book(id)
    if type(stored)=="table" then
        for _,key in ipairs({"description","intro","summary","category","publisher","series","translator","language","pages","wordCount","word_count","format","variant","annotation_requested","metadata_source","metadata_mtime","metadata_checked_at","metadata_complete"}) do
            if (row[key]==nil or row[key]=="") and stored[key]~=nil and stored[key]~="" then row[key]=stored[key] end
        end
        if not row.cover_path and stored.cover_path then row.cover_path=stored.cover_path end
    end
    local record=self:_preferred_record(id)
    if record and record.file and U.file_exists(record.file) then
        row.file=record.file
        for _,key in ipairs({"description","author","title","category","publisher","series","translator","language","pages","wordCount","word_count","format","variant","annotation_requested","metadata_source","metadata_mtime","metadata_checked_at","metadata_complete"}) do
            if (row[key]==nil or row[key]=="") and record[key]~=nil and record[key]~="" then row[key]=record[key] end
        end
        if not row.cover_path and record.cover_path then row.cover_path=record.cover_path end
    end
    return row
end

function Plugin:_home_miuread_rows()
    local remote_books,remote_mp=self.library:cached()
    remote_books=type(remote_books)=="table" and remote_books or {}
    local remote_by_id={}
    for _,book in ipairs(remote_books) do
        local id=tostring(book.bookId or book.book_id or "")
        if id~="" then remote_by_id[id]=book end
    end
    local rows=self:_shelf_rows("generated",false,remote_books,{},#remote_books>0)
    rows=self.library:sort_filter(rows,{section="generated"})
    table.sort(rows,function(a,b)
        local ar,br=tonumber(a.lastReadTime) or 0,tonumber(b.lastReadTime) or 0
        if ar~=br then return ar>br end
        local ad,bd=tonumber(a.downloadedAt) or 0,tonumber(b.downloadedAt) or 0
        if ad~=bd then return ad>bd end
        return tostring(a.title or ""):lower()<tostring(b.title or ""):lower()
    end)
    self:_prepare_shelf_rows(rows)
    local fields={"title","author","description","intro","summary","category","publisher","translator","wordCount","cover"}
    for _,row in ipairs(rows) do
        self:_home_attach_local_record(row)
        local id=tostring(row.bookId or row.book_id or "")
        local remote=remote_by_id[id]
        if remote then
            for _,key in ipairs(fields) do
                if (row[key]==nil or row[key]=="") and remote[key]~=nil and remote[key]~="" then row[key]=remote[key] end
            end
        end
        row.description=row.description or row.intro or row.summary
        row.source="miuread"
        row.status_text=self:_home_status_text(row,false)
    end
    return rows
end

function Plugin:_home_book_time(book)
    local value=tonumber(book and (book.lastReadTime or book.readUpdateTime or book.cloudUpdatedAt or book.last_read_at or book.opened_at or book.updateTime or book.downloadedAt or book.modified_at) or 0) or 0
    if value>100000000000 then value=math.floor(value/1000) end
    return value
end

function Plugin:_home_recent_book(miuread_rows,local_rows,account_rows)
    local best
    for _,list in ipairs({miuread_rows or {},local_rows or {},account_rows or {}}) do
        for _,book in ipairs(list) do
            local progress=tonumber(book.progress) or 0
            if progress>0 and progress<100 and (not best or self:_home_book_time(book)>self:_home_book_time(best)) then best=book end
        end
    end
    return best or (miuread_rows and miuread_rows[1]) or (local_rows and local_rows[1]) or (account_rows and account_rows[1])
end

function Plugin:_home_last_read_text(book)
    local stamp=self:_home_book_time(book)
    if stamp<=0 then return "" end
    local now=os.time()
    local day=os.date("%Y-%m-%d",stamp)
    if day==os.date("%Y-%m-%d",now) then return "今天 "..os.date("%H:%M",stamp) end
    if day==os.date("%Y-%m-%d",now-24*60*60) then return "昨天 "..os.date("%H:%M",stamp) end
    if os.date("%Y",stamp)==os.date("%Y",now) then return os.date("%m月%d日",stamp) end
    return os.date("%Y年%m月%d日",stamp)
end

function Plugin:_home_source_text(book)
    if not book then return "" end
    if book.source=="local" or book.local_file==true then
        local format=tostring(book.format or ""):upper()
        return format~="" and ("本地 · "..format) or "本地书籍"
    end
    if book.source=="miuread" or book.shelf_section=="generated" then return "微信书架" end
    if Protocol.is_mp_account(tostring(book.bookId or book.book_id or "")) then return "公众号" end
    local category=U.trim(tostring(book.category or ""))
    return category~="" and ("微信书架 · "..category) or "微信书架"
end

function Plugin:_home_open_book(book)
    if book and (book.source=="local" or book.local_file==true) then return self:_home_open_local(book) end
    local id=tostring(book and (book.bookId or book.book_id) or "")
    if Protocol.is_mp_account(id) then
        return self:_home_leave_and_run("mp account",function() self:mp_account(book) end)
    end
    return self:_home_open_miuread(book)
end

function Plugin:_home_book_key(book)
    if not book then return "" end
    local id=tostring(book.bookId or book.book_id or "")
    if id~="" then return "book:"..id end
    local path=tostring(book.file or "")
    if path~="" then return "file:"..path end
    return tostring(book.title or "").."|"..tostring(book.author or "")
end

function Plugin:_home_recent_books(miuread_rows,local_rows,account_rows,hero,limit)
    local rows={}
    local hero_key=self:_home_book_key(hero)
    local seen={}
    if hero_key~="" then seen[hero_key]=true end
    for _,list in ipairs({miuread_rows or {},local_rows or {},account_rows or {}}) do
        for _,book in ipairs(list) do
            local progress=tonumber(book.progress) or 0
            local key=self:_home_book_key(book)
            if progress>0 and key~="" and not seen[key] then
                seen[key]=true
                rows[#rows+1]=book
            end
        end
    end
    table.sort(rows,function(a,b)
        local at,bt=self:_home_book_time(a),self:_home_book_time(b)
        if at~=bt then return at>bt end
        return tostring(a.title or ""):lower()<tostring(b.title or ""):lower()
    end)
    local result={}
    for i=1,math.min(math.max(1,tonumber(limit) or 3),#rows) do result[#result+1]=rows[i] end
    return result
end

function Plugin:_home_download_notice()
    local state=self:_download_state()
    local queue=self.store:download_queue()
    local notice
    if state.status=="active" then
        local percent=self:_download_percent(state)
        notice={
            title="正在下载《"..tostring(state.title or "书籍").."》",
            detail="已完成 "..tostring(percent).."%",
            progress=percent/100,
        }
    elseif state.status=="failed" then
        notice={
            title="有一项下载未完成",
            detail=state.auth_required==true and "账号需要重新登录" or "点击查看并继续下载",
            important=true,
        }
    elseif state.status=="interrupted" or state.status=="pending_install" or state.status=="annotation_pending" then
        notice={
            title="下载等待继续",
            detail=self:_download_status_label():gsub("^后台下载%s*[·：]?%s*",""),
            important=true,
        }
    elseif #queue>0 then
        notice={title=tostring(#queue).." 项等待下载",detail="点击查看下载队列"}
    end
    if notice then
        notice.on_tap=function() self:_home_leave_and_run("downloads",function() self:show_downloads() end) end
    end
    return notice
end

function Plugin:_home_library_sections(account_count,generated_count,local_count,mp_count)
    return {
        {title="微信书架",detail="账号中的全部书籍",count=account_count,on_tap=function()
            self:_home_leave_and_run("account shelf",function() self:show_shelf(false,false,"account") end)
        end},
        {title="已下载",detail="已保存到设备",count=generated_count,on_tap=function()
            self:_home_leave_and_run("generated shelf",function() self:show_shelf(false,false,"generated") end)
        end},
        {title="本地书籍",detail="KOReader 普通文件",count=local_count,on_tap=function()
            self:_home_leave_and_run("local shelf",function() self:show_home_local_library() end)
        end},
        {title="公众号",detail="公众号与文章",count=mp_count,on_tap=function()
            self:_home_leave_and_run("mp shelf",function() self:show_mp_shelf(false) end)
        end},
    }
end

function Plugin:_home_alerts()
    local alerts={}
    local health=self:_auth_health(); self:_recompute_auth_health(health)
    local auth=self.store:auth()
    local account=type(auth.account)=="table" and auth.account or {}
    local previously_logged_in=U.trim(tostring(account.name or ""))~="" or (tonumber(account.logged_at) or 0)>0
    if not self:logged_in() and previously_logged_in then
        alerts[#alerts+1]={title="微信读书账号需要重新登录",detail="点击重新扫码；已下载书籍和本地阅读记录不会删除",important=true,on_tap=function() self:_home_leave_and_run("login",function() self.auth_flow:start() end) end}
    elseif health.state=="partial" then
        alerts[#alerts+1]={title="账号部分功能需要处理",detail="点击查看状态；必要时重新扫码即可恢复",important=true,on_tap=function() self:_home_leave_and_run("account status",function() self:show_account_status() end) end}
    end
    return alerts
end

function Plugin:_home_stop_background(reason)
    self._home_scan_generation=(tonumber(self._home_scan_generation) or 0)+1
    self._home_metadata_generation=(tonumber(self._home_metadata_generation) or 0)+1
    self._home_cover_generation=(tonumber(self._home_cover_generation) or 0)+1
    self._home_refreshing=false
    if self.home_async then self.home_async:cancel(reason or "home hidden") end
    if self.home_cover_async then self.home_cover_async:cancel(reason or "home hidden") end
    if self.thought_index_async then self.thought_index_async:cancel(reason or "reader opening") end
    if self._thought_index_pause_path then U.atomic_write(self._thought_index_pause_path,"1",true) end
end

function Plugin:_home_scan_local(force)
    if self:_active_reader_ui() then return false end
    local root=self:_home_root()
    local cache=self:_home_local_cache()
    local age=os.time()-(tonumber(cache.scanned_at) or 0)
    if not force and tostring(cache.root or "")==root and age>=0 and age<HOME_LOCAL_CACHE_TTL then return false end
    if not self.home_async or self.home_async:busy() then return false end
    if not self.home_async:available() then
        logger.warn("[MiuRead][Home] local scan unavailable","root=",root)
        return false
    end
    self._home_scan_generation=(tonumber(self._home_scan_generation) or 0)+1
    local generation=self._home_scan_generation
    self._home_refreshing=true
    local started,err=self.home_async:run("home-local-library",function()
        return LocalLibrary.scan(root,{limit=900,max_depth=8})
    end,function(result)
        if generation~=self._home_scan_generation then return end
        self._home_refreshing=false
        if result and result.ok==true and type(result.value)=="table" then
            local old_by_file={}
            for _,row in ipairs(cache.books or {}) do old_by_file[tostring(row.file or "")]=row end
            for _,row in ipairs(result.value.books or {}) do
                local old=old_by_file[tostring(row.file or "")]
                if old and tonumber(old.modified_at or 0)==tonumber(row.modified_at or 0) then
                    LocalMetadata.merge(row,old)
                end
            end
            self.store:set("home_local_index",result.value)
            logger.info("[MiuRead][Home] local library refreshed",
                "root=",tostring(root),"count=",tostring(#(result.value.books or {})),
                "truncated=",tostring(result.value.truncated==true))
            if HomeView.is_shown() then UIManager:scheduleIn(.05,function() self:_show_miuread_home_now(false,true,true,"content") end) end
        else
            logger.warn("[MiuRead][Home] local library refresh failed",tostring(result and result.error or "unknown"))
        end
    end,180)
    if not started then
        self._home_refreshing=false
        logger.warn("[MiuRead][Home] local scan not started",tostring(err))
        return false
    end
    -- Do not repaint the page merely to show that a background scan started.
    -- The completed result is applied once to the content region.
    return true
end

function Plugin:_home_local_metadata_dir()
    local path=self.store.covers_dir.."/local"
    U.mkdir(path)
    return path
end

function Plugin:_home_reset_local_metadata()
    local dir=self:_home_local_metadata_dir()
    U.remove_tree(dir)
    U.mkdir(dir)
    local prefix=tostring(dir):gsub("\\","/"):gsub("/+","/").."/"
    local cache=self:_home_local_cache()
    local changed=false
    for _,book in ipairs(cache.books or {}) do
        local cover=tostring(book.cover_path or ""):gsub("\\","/"):gsub("/+","/")
        if cover:sub(1,#prefix)==prefix then book.cover_path=nil; changed=true end
        for _,key in ipairs({"metadata_source","metadata_mtime","metadata_checked_at","metadata_complete"}) do
            if book[key]~=nil then book[key]=nil; changed=true end
        end
    end
    if changed then self.store:set("home_local_index",cache) end
end

function Plugin:_home_update_local_cache(filepath,metadata)
    local cache=self:_home_local_cache()
    local changed=false
    for _,row in ipairs(cache.books or {}) do
        if tostring(row.file or "")==tostring(filepath or "") then
            if LocalMetadata.merge(row,metadata) then changed=true end
            row.status_text=self:_home_status_text(row,true)
            break
        end
    end
    if changed then
        cache.scanned_at=tonumber(cache.scanned_at) or os.time()
        self.store:set("home_local_index",cache)
    end
    return changed
end

function Plugin:_home_update_miuread_metadata(filepath,metadata)
    local book,record=self.store:identify_file(filepath,true)
    if type(book)~="table" then return false end
    local changed=LocalMetadata.merge(book,metadata)
    if type(record)=="table" and LocalMetadata.merge(record,metadata) then changed=true end
    local id=tostring(book.book_id or (record and record.book_id) or "")
    if changed and id~="" then self.store:save_book(id,book) end
    return changed
end

function Plugin:_home_schedule_local_metadata(books)
    if not HomeView.is_shown() then return end
    self._home_metadata_generation=(tonumber(self._home_metadata_generation) or 0)+1
    local generation=self._home_metadata_generation
    local queue,seen={},{}
    for _,book in ipairs(books or {}) do
        local filepath=tostring(book and book.file or "")
        if filepath~="" and not seen[filepath] and LocalMetadata.needs_refresh(book,true) then
            seen[filepath]=true
            queue[#queue+1]={
                file=filepath,
                local_book=book.source=="local" or book.local_file==true,
            }
            if #queue>=10 then break end
        end
    end
    if #queue==0 then return end
    local index,changed_any=1,false
    local function finish()
        if changed_any and generation==self._home_metadata_generation and HomeView.is_shown() then
            self:_show_miuread_home_now(false,true,true,"content")
        end
    end
    local function next_book()
        if generation~=self._home_metadata_generation or not HomeView.is_shown() or self:_active_reader_ui() then return end
        local item=queue[index]
        if not item then finish(); return end
        local metadata,err=LocalMetadata.read(item.file,self:_home_local_metadata_dir(),{
            -- MiuRead books already carry remote metadata.  Prefer the cheap
            -- embedded/BIM path on the home screen instead of opening the full
            -- document, which can block gestures and make the screen flash.
            open_document=item.local_book==true,
            use_bim=true,
        })
        if metadata then
            if not item.local_book then metadata.metadata_complete=true end
            local changed=item.local_book
                and self:_home_update_local_cache(item.file,metadata)
                or self:_home_update_miuread_metadata(item.file,metadata)
            if changed then changed_any=true end
        else
            logger.warn("[MiuRead][Home] metadata unavailable",tostring(item.file),tostring(err))
        end
        index=index+1
        if queue[index] then UIManager:scheduleIn(.18,next_book) else finish() end
    end
    UIManager:scheduleIn(.22,next_book)
end

function Plugin:_home_schedule_remote_covers(books)
    self._home_cover_generation=(tonumber(self._home_cover_generation) or 0)+1
    local generation=self._home_cover_generation
    local queue,seen={},{}
    for _,book in ipairs(books or {}) do
        local id=tostring(book and (book.bookId or book.book_id) or "")
        if id~="" and not seen[id] and book.cover and book.cover~="" and not book.cover_path then
            seen[id]=true
            queue[#queue+1]={bookId=id,cover=book.cover,book=book}
            if #queue>=10 then break end
        end
    end
    if #queue==0 or not self.home_cover_async then return end
    local index,changed_any=1,false
    local function finish()
        if changed_any and generation==self._home_cover_generation and HomeView.is_shown() then
            self:_home_schedule_render_refresh("content")
        end
    end
    local function next_cover()
        if generation~=self._home_cover_generation or not HomeView.is_shown() or self:_active_reader_ui() then return end
        if self.home_cover_async:busy() then UIManager:scheduleIn(.3,next_cover); return end
        local item=queue[index]
        if not item then finish(); return end
        local background=self.home_cover_async:available()
        local covers_dir=self.store.covers_dir
        local worker
        if background then
            worker=function()
                local HttpChild=require("miuread.http")
                local LibraryChild=require("miuread.library")
                local store={
                    covers_dir=covers_dir,
                    auth=function() return {cookies={}} end,
                    save_auth=function() end,
                    get=function(_,_,default) return default end,
                    set=function() end,
                }
                return LibraryChild:new(nil,HttpChild:new(store),store):cache_cover(item,{
                    retries=1,timeout={8,15},persist_index=false,skip_index_lookup=true,
                })
            end
        else
            worker=function() return self.library:cache_cover(item,{retries=0,timeout={4,7}}) end
        end
        local started=self.home_cover_async:run("home-cover",worker,function(result)
            if generation~=self._home_cover_generation then return end
            if result and result.ok and result.value then
                if background then self:_remember_cover_path(item.bookId,result.value) end
                if item.book then item.book.cover_path=result.value end
                self:_home_apply_cover_path(item.bookId,result.value)
                changed_any=true
                -- Update the visible cover as soon as it is ready instead of
                -- waiting for every item in the page to finish or time out.
                self:_home_schedule_render_refresh("content")
            elseif result and result.error then
                logger.warn("[MiuRead][Home] cover download failed",tostring(item.bookId),U.first_line(result.error,120))
            end
            index=index+1
            if queue[index] then UIManager:scheduleIn(.08,next_cover) else finish() end
        end,background and 35 or 14)
        if not started then UIManager:scheduleIn(.35,next_cover) end
    end
    UIManager:scheduleIn(.12,next_cover)
end

function Plugin:_home_open_miuread(book)
    self:_home_stop_background("opening book")
    local id=tostring(book and (book.bookId or book.book_id) or "")
    local record=id~="" and self:_preferred_record(id) or nil
    if record and record.file and U.file_exists(record.file) then
        return self:_open_file_direct(record.file)
    end
    if id~="" then self:book_menu(book) else self:info("本地书籍记录不存在") end
end

function Plugin:_home_open_local(book)
    local path=tostring(book and book.file or "")
    if path=="" or not U.file_exists(path) then self:info("本地文件不存在"); return end
    self:_home_stop_background("opening local book")
    return self:_open_file_direct(path)
end

function Plugin:_home_schedule_local_shelf_metadata(rows,view)
    self._home_metadata_generation=(tonumber(self._home_metadata_generation) or 0)+1
    local generation=self._home_metadata_generation
    local queue={}
    for _,book in ipairs(rows or {}) do
        if LocalMetadata.needs_refresh(book,true) then
            queue[#queue+1]=book
            if #queue>=18 then break end
        end
    end
    if #queue==0 then return end
    local index=1
    local function next_book()
        if generation~=self._home_metadata_generation or self:_active_reader_ui() then return end
        local book=queue[index]
        if not book then return end
        local metadata,err=LocalMetadata.read(book.file,self:_home_local_metadata_dir(),{open_document=true,use_bim=true})
        if metadata then
            LocalMetadata.merge(book,metadata)
            book.status_text=self:_home_status_text(book,true)
            self:_home_update_local_cache(book.file,metadata)
            if view and not view._miu_closed and type(view.updateItems)=="function" then
                pcall(view.updateItems,view,nil,true)
            end
        else
            logger.warn("[MiuRead][Home] local shelf metadata unavailable",tostring(book.file),tostring(err))
        end
        index=index+1
        if queue[index] then UIManager:scheduleIn(.18,next_book) end
    end
    UIManager:scheduleIn(.12,next_book)
end

function Plugin:show_home_local_library(rows)
    rows=rows or select(1,self:_home_local_rows())
    if #rows==0 then self:info("没有发现普通本地书籍"); return end
    for index=1,math.min(12,#rows) do
        local book=rows[index]
        if LocalMetadata.needs_refresh(book,false) then
            local metadata=LocalMetadata.read(book.file,self:_home_local_metadata_dir(),{open_document=false,use_bim=false})
            if metadata then
                LocalMetadata.merge(book,metadata)
                book.status_text=self:_home_status_text(book,true)
                self:_home_update_local_cache(book.file,metadata)
            end
        end
    end
    local ok,view=pcall(ShelfView.show,{
        title="本地书籍 · "..tostring(#rows).."本",books=rows,
        show_actions=false,show_tabs=false,show_covers=true,
        on_select=function(book) self:_home_open_local(book) end,
    })
    if ok and view then
        self:_home_schedule_local_shelf_metadata(rows,view)
        return
    end
    logger.warn("[MiuRead][Home] local shelf unavailable",tostring(view))
    local items={}
    for _,book in ipairs(rows) do
        local row=book
        items[#items+1]={text=tostring(row.title or "未命名"),post_text=tostring(row.format or ""),callback=function() self:_home_open_local(row) end}
    end
    self:list("本地书籍",items)
end

function Plugin:_home_account_name()
    local auth=self.store:auth()
    local account=type(auth.account)=="table" and auth.account or {}
    local name=U.trim(tostring(account.name or ""))
    if name~="" then return name end
    return self:logged_in() and "已登录" or "未登录"
end

function Plugin:_cancel_native_menu_guard()
    local menu=NATIVE_MENU_GUARD.menu
    local original=NATIVE_MENU_GUARD.original_close
    if menu and original and menu.onCloseFileManagerMenu~=original then
        menu.onCloseFileManagerMenu=original
    end
    NATIVE_MENU_GUARD.token=(tonumber(NATIVE_MENU_GUARD.token) or 0)+1
    NATIVE_MENU_GUARD.active=false
    NATIVE_MENU_GUARD.finishing=false
    NATIVE_MENU_GUARD.menu=nil
    NATIVE_MENU_GUARD.container=nil
    NATIVE_MENU_GUARD.watch=nil
    NATIVE_MENU_GUARD.backdrop=nil
    NATIVE_MENU_GUARD.original_close=nil
    NativeMenuBackdrop.close()
end

function Plugin:_return_from_native_filemanager()
    sync_home_session()
    if HOME_EXITING or UIManager._exit_code~=nil or not self:_home_enabled() then return false end
    local ok_fm,FileManager=pcall(require,"apps/filemanager/filemanager")
    local fm=ok_fm and FileManager and FileManager.instance or nil
    local menu=NATIVE_MENU_GUARD.menu or (fm and fm.menu) or nil
    if menu and menu.menu_container and type(menu.onCloseFileManagerMenu)=="function" then
        pcall(menu.onCloseFileManagerMenu,menu)
    end
    self:_cancel_native_menu_guard()
    HOME_SESSION_SUPPRESSED=false
    HOME_NATIVE_VISIT=false
    HOME_EXPECTED_CLOSE=false
    HOME_READER_ORIGIN=false
    HOME_READER_FILE=nil
    persist_home_session()
    local shown=self:show_miuread_home(false)
    if shown then HomeView.raise() end
    return shown
end

function Plugin:_native_menu_overlay_present()
    local ok_fm,FileManager=pcall(require,"apps/filemanager/filemanager")
    local fm=ok_fm and FileManager and FileManager.instance or nil
    local reader=self:_active_reader_ui()
    local backdrop=NativeMenuBackdrop.current()
    for _,window in ipairs(UIManager._window_stack or {}) do
        local widget=window and window.widget or nil
        if widget and widget~=fm and widget~=reader and widget~=HomeView.current()
            and widget~=backdrop and widget.toast~=true then
            return true
        end
    end
    return false
end

function Plugin:_finish_native_menu_visit(token,reason)
    if token~=NATIVE_MENU_GUARD.token or not NATIVE_MENU_GUARD.active or NATIVE_MENU_GUARD.finishing then return false end
    NATIVE_MENU_GUARD.finishing=true
    sync_home_session()
    if HOME_EXITING or UIManager._exit_code~=nil or not self:_home_enabled() then
        self:_cancel_native_menu_guard()
        return false
    end

    -- A book opened from this temporary menu still belongs to the MiuRead
    -- navigation session. The exact file is filled in as soon as ReaderUI is
    -- available.
    HOME_SESSION_SUPPRESSED=false
    HOME_NATIVE_VISIT=false
    HOME_READER_ORIGIN=true
    HOME_EXPECTED_CLOSE=false
    persist_home_session()

    local function settle(attempt)
        if token~=NATIVE_MENU_GUARD.token or not NATIVE_MENU_GUARD.active then return end
        sync_home_session()
        if HOME_EXITING or UIManager._exit_code~=nil or not self:_home_enabled() then
            self:_cancel_native_menu_guard()
            return
        end
        local reader=self:_active_reader_ui()
        if reader then
            local file=reader.document and reader.document.file or nil
            mark_reader_origin(file)
            self:_cancel_native_menu_guard()
            logger.info("[MiuRead][Home] native menu closed into reader",tostring(reason or "closed"))
            return
        end
        -- Native settings and plugin dialogs sit above the clean backdrop.
        -- Keep the backdrop until the last native layer is closed so neither
        -- MiuRead nor FileManager flashes between pages.
        if self:_native_menu_overlay_present() then
            local delay=attempt<20 and .12 or (attempt<80 and .3 or .7)
            UIManager:scheduleIn(delay,function() settle(attempt+1) end)
            return
        end

        self:_cancel_native_menu_guard()
        HOME_SESSION_SUPPRESSED=false
        HOME_NATIVE_VISIT=false
        HOME_READER_ORIGIN=false
        HOME_READER_FILE=nil
        HOME_EXPECTED_CLOSE=false
        persist_home_session()
        logger.info("[MiuRead][Home] native menu closed; MiuRead home revealed",tostring(reason or "closed"))
        if HomeView.is_shown() then
            HomeView.raise()
        else
            self:_ensure_filemanager_base(HOME_RETURN_FILE)
            self:_restore_home_after_reader_close(1)
        end
    end
    UIManager:scheduleIn(.04,function() settle(1) end)
    return true
end

function Plugin:_guard_native_koreader_menu(menu)
    if not menu then return nil end
    NATIVE_MENU_GUARD.token=(tonumber(NATIVE_MENU_GUARD.token) or 0)+1
    local token=NATIVE_MENU_GUARD.token
    NATIVE_MENU_GUARD.active=true
    NATIVE_MENU_GUARD.finishing=false
    NATIVE_MENU_GUARD.menu=menu
    NATIVE_MENU_GUARD.container=menu.menu_container
    NATIVE_MENU_GUARD.backdrop=NativeMenuBackdrop.current()
    NATIVE_MENU_GUARD.original_close=nil

    HOME_SESSION_SUPPRESSED=false
    HOME_NATIVE_VISIT=false
    HOME_READER_ORIGIN=true
    HOME_EXPECTED_CLOSE=false
    persist_home_session()

    if type(menu.onCloseFileManagerMenu)=="function" then
        local original=menu.onCloseFileManagerMenu
        NATIVE_MENU_GUARD.original_close=original
        menu.onCloseFileManagerMenu=function(native_menu,...)
            if native_menu.onCloseFileManagerMenu~=original then
                native_menu.onCloseFileManagerMenu=original
            end
            if token==NATIVE_MENU_GUARD.token then
                NATIVE_MENU_GUARD.original_close=nil
            end
            local result=original(native_menu,...)
            self:_finish_native_menu_visit(token,"close callback")
            return result
        end
    end

    local function watch()
        if token~=NATIVE_MENU_GUARD.token or not NATIVE_MENU_GUARD.active then return end
        sync_home_session()
        if HOME_EXITING or UIManager._exit_code~=nil or not self:_home_enabled() then
            self:_cancel_native_menu_guard()
            return
        end
        local container=menu.menu_container or NATIVE_MENU_GUARD.container
        if not container or not UIManager:isWidgetShown(container) then
            self:_finish_native_menu_visit(token,"watchdog")
            return
        end
        UIManager:scheduleIn(.16,watch)
    end
    NATIVE_MENU_GUARD.watch=watch
    UIManager:scheduleIn(.16,watch)
    return token
end

function Plugin:_show_native_koreader_menu()
    sync_home_session()
    if HOME_EXITING or UIManager._exit_code~=nil then return false end
    self:_cancel_native_menu_guard()
    self:_ensure_filemanager_base(HOME_RETURN_FILE)

    local backdrop,backdrop_err=NativeMenuBackdrop.show()
    if not backdrop then
        logger.warn("[MiuRead][Home] native menu backdrop failed",tostring(backdrop_err or "unknown"))
        if HomeView.is_shown() then HomeView.raise() end
        self:info("KOReader 菜单暂时无法打开")
        return false
    end

    HOME_SESSION_SUPPRESSED=false
    HOME_NATIVE_VISIT=false
    HOME_READER_ORIGIN=true
    HOME_EXPECTED_CLOSE=false
    persist_home_session()

    local candidates={}
    local ok_fm,FileManager=pcall(require,"apps/filemanager/filemanager")
    local fm=ok_fm and FileManager and FileManager.instance or nil
    if fm and fm.menu then candidates[#candidates+1]=fm.menu end
    if self.ui and self.ui.menu and self.ui.menu~=(fm and fm.menu) then
        candidates[#candidates+1]=self.ui.menu
    end
    for _,menu in ipairs(candidates) do
        if menu and type(menu.onShowMenu)=="function" then
            local ok,err=xpcall(function() menu:onShowMenu() end,debug.traceback)
            if ok then
                self:_guard_native_koreader_menu(menu)
                logger.info("[MiuRead][Home] native KOReader menu opened over clean backdrop")
                return true
            end
            logger.warn("[MiuRead][Home] native menu failed",tostring(err))
        end
    end

    self:_cancel_native_menu_guard()
    HOME_READER_ORIGIN=false
    HOME_READER_FILE=nil
    persist_home_session()
    if HomeView.is_shown() then HomeView.raise() end
    logger.warn("[MiuRead][Home] no native KOReader menu available")
    self:info("KOReader 菜单暂时无法打开")
    return false
end

function Plugin:_home_wifi_toggle()
    local ok_nm,NetworkMgr=pcall(require,"ui/network/manager")
    if not ok_nm or not NetworkMgr then self:info("当前设备无法使用网络设置"); return false end
    local on=false
    local ok_state,value=pcall(NetworkMgr.isWifiOn,NetworkMgr)
    if ok_state then on=value==true end
    local ok
    if on then
        if type(NetworkMgr.toggleWifiOff)=="function" then ok=pcall(NetworkMgr.toggleWifiOff,NetworkMgr)
        elseif type(NetworkMgr.turnOffWifi)=="function" then ok=pcall(NetworkMgr.turnOffWifi,NetworkMgr) end
        if ok then self:toast("Wi-Fi 已关闭",1.5) end
    else
        if type(NetworkMgr.toggleWifiOn)=="function" then ok=pcall(NetworkMgr.toggleWifiOn,NetworkMgr)
        elseif type(NetworkMgr.turnOnWifi)=="function" then ok=pcall(NetworkMgr.turnOnWifi,NetworkMgr) end
        if ok then self:toast("正在开启 Wi-Fi",1.5) end
    end
    UIManager:scheduleIn(1,function() self:_refresh_home_view(nil,"header") end)
    return ok==true
end

function Plugin:_home_wifi_settings()
    local ok_nm,NetworkMgr=pcall(require,"ui/network/manager")
    if not ok_nm or not NetworkMgr then self:info("当前设备无法使用网络设置"); return false end
    local function open_picker()
        if type(NetworkMgr.toggleWifiOn)=="function" then
            local ok=pcall(NetworkMgr.toggleWifiOn,NetworkMgr,nil,true,true)
            if ok then return true end
        end
        if type(NetworkMgr.turnOnWifi)=="function" then
            pcall(NetworkMgr.turnOnWifi,NetworkMgr)
        end
        self:_show_native_koreader_menu()
        return true
    end
    local on=false
    local ok_state,value=pcall(NetworkMgr.isWifiOn,NetworkMgr)
    if ok_state then on=value==true end
    if on and type(NetworkMgr.toggleWifiOff)=="function" then
        local ok=pcall(NetworkMgr.toggleWifiOff,NetworkMgr,function() open_picker() end,true)
        if ok then return true end
    end
    return open_picker()
end

function Plugin:_home_frontlight()
    local ok_fl,has_fl=pcall(Device.hasFrontlight,Device)
    if not ok_fl or not has_fl then self:info("当前设备不支持前光"); return false end
    local ok,widget=pcall(function() return require("ui/widget/frontlightwidget"):new{} end)
    if not ok or not widget then self:info("前光设置暂时无法打开"); return false end
    UIManager:show(widget)
    return true
end

function Plugin:_home_toggle_night()
    UIManager:broadcastEvent(Event:new("ToggleNightMode"))
    UIManager:scheduleIn(.2,function() UIManager:setDirty("all","full") end)
    return true
end

function Plugin:_home_rotate()
    local Screen=Device.screen
    local current=Screen:getRotationMode()
    local next_mode
    if current==Screen.DEVICE_ROTATED_CLOCKWISE then
        next_mode=Screen.DEVICE_ROTATED_UPSIDE_DOWN
    elseif current==Screen.DEVICE_ROTATED_UPSIDE_DOWN then
        next_mode=Screen.DEVICE_ROTATED_COUNTER_CLOCKWISE
    elseif current==Screen.DEVICE_ROTATED_COUNTER_CLOCKWISE then
        next_mode=Screen.DEVICE_ROTATED_UPRIGHT
    else
        next_mode=Screen.DEVICE_ROTATED_CLOCKWISE
    end
    UIManager:broadcastEvent(Event:new("SetRotationMode",next_mode))
    return true
end

function Plugin:_home_full_refresh(confirmed)
    if confirmed~=true and self:_notice_enabled("full_refresh") then
        local dialog
        dialog=ButtonDialog:new{title="全屏刷新可以清除墨水屏残影，屏幕会短暂闪烁。",title_align="center",buttons={
            {{text="立即刷新",callback=function() UIManager:close(dialog); self:_home_full_refresh(true) end}},
            {{text="刷新并不再提示",callback=function() UIManager:close(dialog); self:_set_notice_enabled("full_refresh",false); self:_home_full_refresh(true) end}},
            {{text="取消",callback=function() UIManager:close(dialog) end}},
        }}
        UIManager:show(dialog)
        return true
    end
    UIManager:setDirty("all","full")
    return true
end

function Plugin:_home_sleep()
    if Device:canSuspend() then
        UIManager:flushSettings()
        UIManager:suspend()
        return true
    end
    self:info("当前设备不支持休眠")
    return false
end

function Plugin:_home_preview_books(rows,hero,limit)
    local out,seen={},{}
    local hero_key=self:_home_book_key(hero)
    if hero_key~="" then seen[hero_key]=true end
    for _,book in ipairs(rows or {}) do
        local key=self:_home_book_key(book)
        if key~="" and not seen[key] then
            seen[key]=true
            out[#out+1]=book
            if #out>=math.max(1,tonumber(limit) or 4) then break end
        end
    end
    return out
end

function Plugin:show_home_quick_panel()
    local state=HomeData.device_state(true)
    local wifi_on=nil
    local ok_nm,NetworkMgr=pcall(require,"ui/network/manager")
    if ok_nm and NetworkMgr and type(NetworkMgr.isWifiOn)=="function" then
        local ok,value=pcall(NetworkMgr.isWifiOn,NetworkMgr)
        if ok then wifi_on=value==true end
    end

    local download_detail=""
    if self:_has_download_status() or #self.store:download_queue()>0 then
        download_detail=self:_download_menu_text():gsub("^下载管理%s*[·：]?%s*","")
    end
    local definitions={
        wifi={label="Wi-Fi",detail=wifi_on==nil and "状态未知" or (wifi_on and "已开启" or "已关闭"),callback=function() self:_home_wifi_toggle() end},
        refresh_shelf={label="刷新书架",detail="",callback=function() self:_home_manual_refresh() end},
        full_refresh={label="全屏刷新",detail="",callback=function() self:_home_full_refresh() end},
        settings={label="觅阅设置",detail="",callback=function() self:_show_standalone_menu("觅阅设置",self:settings_menu()) end},
        koreader_menu={label="KOReader 菜单",detail="",callback=function() self:_show_native_koreader_menu() end},
        downloads={label="下载管理",detail=download_detail,callback=function() self:show_downloads() end},
        sync={label="阅读同步",detail=self:progress_sync_label(),callback=function() self:_show_standalone_menu("阅读同步",self:sync_menu()) end},
        night={label="夜间模式",detail="",callback=function() self:_home_toggle_night() end},
        rotate={label="旋转屏幕",detail="",callback=function() self:_home_rotate() end},
        restart={label="重启 KOReader",detail="",callback=function() self:_restart_koreader() end},
        quit={label="退出 KOReader",detail="",callback=function() self:_quit_koreader() end},
    }
    if Device:hasFrontlight() then
        definitions.frontlight={label="前光",detail="",callback=function() self:_home_frontlight() end}
    end
    if Device:canSuspend() then
        definitions.sleep={label="休眠",detail="",callback=function() self:_home_sleep() end}
    end

    local home=self:_home_preferences()
    local buttons={}
    for _,key in ipairs(home.quick_order or HOME_QUICK_ITEM_ORDER) do
        if home.quick_items[key]==true and definitions[key] then buttons[#buttons+1]=definitions[key] end
        if #buttons>=9 then break end
    end

    local battery=tonumber(state.battery) and (tostring(math.floor(state.battery+.5)).."%") or "未知"
    local connection=wifi_on==nil and "网络状态未知" or (wifi_on and "Wi-Fi 已开启" or "Wi-Fi 已关闭")
    local notice=self:_home_download_notice()
    local status_text
    if notice then
        status_text=tostring(notice.title or "")
        if notice.detail and notice.detail~="" then status_text=status_text.." · "..tostring(notice.detail) end
    end
    local header_action
    if home.quick_items.koreader_menu~=true then
        header_action={label="KOReader",callback=function() self:_show_native_koreader_menu() end}
    end
    local panel,err=HomeQuickPanel.show{
        title=os.date("%H:%M").."　电量 "..battery,
        subtitle=connection,
        status_text=status_text,
        header_action=header_action,
        buttons=buttons,
    }
    if not panel then
        logger.warn("[MiuRead][QuickPanel] unavailable",tostring(err or "unknown"))
        self:info("快捷控制暂时无法打开")
    end
end

function Plugin:_begin_koreader_exit(reason)
    self:_cancel_native_menu_guard()
    HOME_EXITING=true
    HOME_SESSION_SUPPRESSED=true
    HOME_NATIVE_VISIT=false
    HOME_RETURN_FILE=nil
    HOME_READER_ORIGIN=false
    HOME_READER_FILE=nil
    HOME_EXPECTED_CLOSE=true
    persist_home_session()
    self._home_start_generation=(tonumber(self._home_start_generation) or 0)+1
    self:_home_stop_background(reason or "KOReader exit")
    HomeQuickPanel.close()
    HomeView.close()
    self._home_view=nil
end

function Plugin:_quit_koreader()
    local active=(self.download_task and self.download_task:busy()) or self._download_runtime~=nil
    local queued=#self.store:download_queue()>0
    local detail=""
    if active and queued then
        detail="\n\n当前任务会中断，重新启动后可继续；排队任务会保留。"
    elseif active then
        detail="\n\n当前任务会中断，重新启动后可继续。"
    elseif queued then
        detail="\n\n当前有一个排队任务，重新启动后仍会保留。"
    end
    UIManager:show(ConfirmBox:new{
        text="退出 KOReader？"..detail,
        ok_text="退出",
        cancel_text="取消",
        ok_callback=function()
            self:_begin_koreader_exit("quit")
            pcall(function() self:onFlushSettings() end)
            if Device and Device.saveSettings then pcall(Device.saveSettings,Device) end
            -- Use KOReader's normal Exit event so FileManager/ReaderUI can tear
            -- down the entire widget stack. Calling UIManager:quit() directly
            -- can leave a fullscreen replacement home as the last visible UI.
            UIManager:nextTick(function() UIManager:broadcastEvent(Event:new("Exit")) end)
        end,
    })
    return true
end

function Plugin:show_home_menu()
    -- The status area and the header menu button share one action list.
    return self:show_home_quick_panel()
end

function Plugin:home_preview_menu()
    return {
        {text="打开觅阅菜单",callback=function() self:show_home_menu() end},
        {text="切换到插件模式",callback=function() self:_set_home_mode(false) end},
        {text="KOReader 文件管理器",callback=function() self:_home_close_to_native() end},
    }
end

function Plugin:_mark_reader_busy(seconds)
    local path=tostring(self._reader_busy_path or "")
    if path=="" then return false end
    local target=os.time()+math.max(1,tonumber(seconds) or 4)
    if tonumber(self._reader_busy_until or 0)>=target-1 then return true end
    self._reader_busy_until=target
    return U.atomic_write(path,tostring(target),true)==true
end

function Plugin:_reader_progress_percent()
    local ui=self.ui
    local document=ui and ui.document
    if not ui or not document then return nil end
    local current,total
    if type(ui.getCurrentPage)=="function" and type(document.getPageCount)=="function" then
        local ok_current,value_current=pcall(ui.getCurrentPage,ui)
        local ok_total,value_total=pcall(document.getPageCount,document)
        if ok_current and ok_total then current,total=tonumber(value_current),tonumber(value_total) end
    end
    if current and total and total>0 then
        return math.max(0,math.min(100,current/total*100))
    end
    local rolling=ui.rolling
    local pos=rolling and tonumber(rolling.current_page or rolling.current_pos)
    local pages=rolling and tonumber(rolling.page_count or rolling.full_height)
    if pos and pages and pages>0 then return math.max(0,math.min(100,pos/pages*100)) end
    return nil
end

function Plugin:_reader_jump_percent(delta)
    local current=self:_reader_progress_percent()
    if not current then self:info("当前文档暂时无法按百分比调整进度"); return false end
    local target=math.max(0,math.min(100,current+(tonumber(delta) or 0)))
    self:_mark_reader_busy(4)
    self.ui:handleEvent(Event:new("GotoPercent",target))
    return true
end

function Plugin:_reader_adjust_font_size(delta)
    local ui=self.ui
    local font=ui and ui.font
    local configurable=ui and ui.document and ui.document.configurable or nil
    local current=font and tonumber(font.font_size)
        or (ui and ui.rolling and tonumber(ui.rolling.font_size))
        or (configurable and tonumber(configurable.font_size))
    if not current then
        self:info("当前文档暂时无法直接调整字号")
        return false
    end
    local target=math.max(12,math.min(72,current+(tonumber(delta) or 0)))
    self:_mark_reader_busy(5)
    if font and type(font.onSetFontSize)=="function" then
        local ok=pcall(font.onSetFontSize,font,target)
        if ok then return true end
    end
    if ui and type(ui.handleEvent)=="function" then
        ui:handleEvent(Event:new("SetFontSize",target))
        return true
    end
    return false
end

function Plugin:_reader_goto_percent(target)
    target=math.max(0,math.min(100,tonumber(target) or 0))
    if not (self.ui and type(self.ui.handleEvent)=="function") then return false end
    self:_mark_reader_busy(5)
    self.ui:handleEvent(Event:new("GotoPercent",target))
    return true
end

function Plugin:_show_reader_progress_control()
    if not (self.ui and self.ui.document) then return false end
    self:_mark_reader_busy(8)
    ReaderProgressDialog.show{
        percent=self:_reader_progress_percent() or 0,
        on_goto_percent=function(target) self:_reader_goto_percent(target) end,
        on_adjust=function(delta) self:_reader_jump_percent(delta) end,
        on_jump=function() self:_show_reader_position_jump() end,
    }
    return true
end

function Plugin:_show_reader_position_jump()
    local ui=self.ui
    local gotopage=ui and ui.gotopage
    if gotopage and type(gotopage.onShowGotoDialog)=="function" then
        self:_mark_reader_busy(5)
        gotopage:onShowGotoDialog()
        return true
    end
    self:info("当前文档暂时无法跳转位置")
    return false
end

function Plugin:_show_reader_toc()
    local toc=self.ui and self.ui.toc
    if toc and type(toc.onShowToc)=="function" then
        self:_mark_reader_busy(5)
        toc:onShowToc()
        return true
    end
    local menu=self.ui and self.ui.menu
    if menu and type(menu.onShowMenu)=="function" then menu:onShowMenu(1); return true end
    return false
end

function Plugin:_show_reader_typeset_menu()
    local ui=self.ui
    if ui and type(ui.handleEvent)=="function" then
        self:_mark_reader_busy(6)
        ui:handleEvent(Event:new("ShowConfigMenu"))
        return true
    end
    self:info("当前文档暂时无法打开排版控制")
    return false
end

function Plugin:_thought_font_size_label()
    local level=tostring((self.store:preferences().thoughts or {}).font or "standard")
    if level=="large" then return "适中" end
    if level=="xlarge" then return "接近正文" end
    return "较小"
end

function Plugin:_set_thought_font_size(level)
    local p=self.store:preferences(); p.thoughts=p.thoughts or {}
    p.thoughts.font=level
    self.store:save_preferences(p)
    return true
end

function Plugin:_toggle_thought_follow_body_font()
    local p=self.store:preferences(); p.thoughts=p.thoughts or {}
    p.thoughts.follow_body_font=p.thoughts.follow_body_font~=true
    self.store:save_preferences(p)
    return true
end

function Plugin:_show_reader_comment_settings()
    ReaderSettingsDialog.show{
        title="评论显示",
        subtitle=function()
            local prefs=self.store:preferences().thoughts or {}
            return (prefs.follow_body_font==true and "字体跟随正文" or self:_thought_font_face_label(prefs)).." · "..self:_thought_font_size_label()
        end,
        rows=function()
            local prefs=self.store:preferences().thoughts or {}
            local follow=prefs.follow_body_font==true
            local level=tostring(prefs.font or "standard")
            return {
                {label="评论字体跟随正文",value=follow and "已开启" or "已关闭",value_bold=true,keep_open=true,callback=function() self:_toggle_thought_follow_body_font() end},
                {label="固定字体",value=self:_thought_font_face_label(prefs),enabled=not follow,callback=function()
                    self:_show_standalone_menu("评论字体",self:thought_font_face_menu(),{native_input=true})
                end},
                {label="较小",value=level=="standard" and "已选择" or "",checked=level=="standard",keep_open=true,callback=function() self:_set_thought_font_size("standard") end},
                {label="适中",value=level=="large" and "已选择" or "",checked=level=="large",keep_open=true,callback=function() self:_set_thought_font_size("large") end},
                {label="接近正文",value=level=="xlarge" and "已选择" or "",checked=level=="xlarge",keep_open=true,callback=function() self:_set_thought_font_size("xlarge") end},
            }
        end,
    }
    return true
end

function Plugin:_reader_font_label()
    local ui=self.ui
    local font=ui and ui.font
    local configurable=ui and ui.document and ui.document.configurable or nil
    local name=font and font.font_face or (configurable and (configurable.font_face or configurable.font))
    name=U.trim(tostring(name or ""))
    return name~="" and name or "KOReader 默认"
end

function Plugin:_reader_font_size_label()
    local ui=self.ui
    local font=ui and ui.font
    local configurable=ui and ui.document and ui.document.configurable or nil
    local current=font and tonumber(font.font_size)
        or (ui and ui.rolling and tonumber(ui.rolling.font_size))
        or (configurable and tonumber(configurable.font_size))
    return current and tostring(math.floor(current+.5)) or "未知"
end

function Plugin:_reader_toolbar_title()
    local current=self:_current_book_record()
    local title=current and current.book and current.book.title or nil
    if not title or title=="" then
        local path=self:_current_document_path()
        title=path and path:match("([^/]+)$") or "正在阅读"
    end
    local percent=self:_reader_progress_percent()
    local progress=percent and (tostring(math.floor(percent+.5)).."%") or "位置未知"
    local sync=self.store:preferences().sync or {}
    local progress_sync=sync.progress_enabled~=false and "进度同步开" or "进度同步关"
    local time_sync=sync.time_enabled==true and "时间同步开" or "时间同步关"
    local status=progress.." · 字号 "..self:_reader_font_size_label().." · "..progress_sync.." · "..time_sync
    return tostring(title),status,progress
end

function Plugin:_show_reader_font_panel()
    ReaderSettingsDialog.show{
        title="字体与字号",
        subtitle=function() return self:_reader_font_label().." · 字号 "..self:_reader_font_size_label() end,
        rows=function()
            return {
                {label="字号减小",value="− 1",value_bold=true,keep_open=true,callback=function() self:_reader_adjust_font_size(-1) end},
                {label="字号增大",value="+ 1",value_bold=true,keep_open=true,callback=function() self:_reader_adjust_font_size(1) end},
                {label="正文字体与完整排版",value="进入",callback=function() self:_show_reader_typeset_menu() end},
                {label="评论显示",value=self:_thought_font_size_label(),callback=function() self:_show_reader_comment_settings() end},
            }
        end,
    }
    return true
end

function Plugin:_show_reader_sync_panel()
    ReaderSettingsDialog.show{
        title="阅读同步",
        subtitle=function()
            local sync=self.store:preferences().sync or {}
            return "进度"..(sync.progress_enabled~=false and "开" or "关").." · 时间"..(sync.time_enabled==true and "开" or "关")
        end,
        rows=function()
            local sync=self.store:preferences().sync or {}
            return {
                {label="同步状态",value=self:progress_sync_label(),callback=function() self:show_sync_status(false) end},
                {label="自动同步阅读进度",value=sync.progress_enabled~=false and "已开启" or "已关闭",value_bold=true,callback=function() self:toggle_progress_sync() end},
                {label="自动同步阅读时间",value=sync.time_enabled==true and "已开启" or "已关闭",value_bold=true,callback=function() self:toggle_time_sync() end},
                {label="同步成功提醒",value=self:_sync_success_notice_enabled() and "已开启" or "已关闭",callback=function() self:toggle_sync_success_notice() end},
                {label="立即上传当前进度",value="执行",callback=function() self:upload_local_progress(true) end},
                {label="重新读取云端进度",value="执行",callback=function() self:manual_sync() end},
                {label="同步诊断",value="进入",callback=function()
                    self:_show_standalone_menu("同步诊断",self:sync_diagnostics_menu(),{native_input=true})
                end},
            }
        end,
    }
    return true
end

function Plugin:_show_reader_current_book_panel()
    self:_show_standalone_menu("当前书籍",self:current_book_menu(),{native_input=true})
    return true
end

function Plugin:_show_koreader_reader_menu()
    local current_ui=self.ui
    if not (current_ui and current_ui.document) then return false end
    if self._reader_native_menu_opening then return true end
    local current_menu=current_ui.menu
    if current_menu and current_menu.menu_container and UIManager:isWidgetShown(current_menu.menu_container) then return true end
    self._reader_native_menu_opening=true
    self:_close_miuread_transients()
    UIManager:scheduleIn(.04,function()
        local ui=self.ui
        local menu=ui and ui.menu or nil
        if not (ui and ui.document) then
            self._reader_native_menu_opening=false
            return
        end
        if menu and menu.menu_container and UIManager:isWidgetShown(menu.menu_container) then
            self._reader_native_menu_opening=false
            return
        end
        local ok,err=xpcall(function()
            if menu and type(menu.onShowMenu)=="function" then menu:onShowMenu()
            else ui:handleEvent(Event:new("ShowMenu")) end
        end,debug.traceback)
        self._reader_native_menu_opening=false
        if not ok then
            logger.warn("[MiuRead][Reader] native menu open failed",tostring(err))
            self:_close_miuread_transients()
            self:info("KOReader 菜单暂时无法打开")
        end
    end)
    return true
end

function Plugin:show_reader_more_panel()
    if not (self.ui and self.ui.document) then return false end
    local items={
        {text="书籍",enabled=false},
        {text="当前书籍",sub_item_table_func=function() return self:current_book_menu() end},
        {text="评论显示",callback=function() self:_show_reader_comment_settings() end},
        {text="下载管理",callback=function() self:show_downloads() end},
        {text="显示",enabled=false},
        {text="完整排版",callback=function() self:_show_reader_typeset_menu() end},
        {text="全屏刷新",callback=function() self:_home_full_refresh() end},
        {text="KOReader 菜单",close_before_action=true,callback=function() self:_show_koreader_reader_menu() end},
    }
    if Device:hasFrontlight() or Device:canSuspend() then items[#items+1]={text="设备",enabled=false} end
    if Device:hasFrontlight() then items[#items+1]={text="前光",callback=function() self:_home_frontlight() end} end
    if Device:canSuspend() then items[#items+1]={text="休眠",callback=function() self:_home_sleep() end} end
    self:_show_standalone_menu("更多阅读功能",items,{native_input=true})
    return true
end

function Plugin:_reader_panel_definitions(progress)
    local home_label=self:_home_enabled() and "觅阅主页" or "觅阅书架"
    return {
        home={label=home_label,detail=self:_home_enabled() and "退出阅读并返回" or "打开插件书架",callback=function()
            if self:_home_enabled() then self:return_to_miuread_home() else self:show_shelf(false,false,"account") end
        end},
        toc={label="目录",detail="查看章节",callback=function() self:_show_reader_toc() end},
        progress={label="阅读进度",detail=progress.." · 跳转位置",callback=function() self:_show_reader_progress_control() end},
        font={label="字体与字号",detail=self:_reader_font_label().." · "..self:_reader_font_size_label(),callback=function() self:_show_reader_font_panel() end},
        typeset={label="完整排版",detail="字体、行距与页边距",callback=function() self:_show_reader_typeset_menu() end},
        sync={label="阅读同步",detail=self:progress_sync_label().." · 时间"..((self.store:preferences().sync or {}).time_enabled==true and "开" or "关"),callback=function() self:_show_reader_sync_panel() end},
        current_book={label="当前书籍",detail=self:_current_book_record() and "详情、修复与下载" or "当前文件未识别",callback=function() self:_show_reader_current_book_panel() end},
        downloads={label="下载管理",detail=self:_download_status_label(),callback=function() self:show_downloads() end},
        full_refresh={label="全屏刷新",detail="清除墨水屏残影",callback=function() self:_home_full_refresh() end},
        koreader_menu={label="KOReader 菜单",detail="完整原生菜单",callback=function() self:_show_koreader_reader_menu() end},
        sleep={label="休眠",detail="进入设备休眠",enabled=Device:canSuspend(),callback=function() self:_home_sleep() end},
        more={label="更多",detail="评论、前光与系统功能",callback=function() self:show_reader_more_panel() end},
    }
end

function Plugin:show_reader_quick_panel()
    if not (self.ui and self.ui.document) then return false end
    self:_mark_reader_busy(8)
    local title,status,progress=self:_reader_toolbar_title()
    local reader=self:_reader_preferences()
    local definitions=self:_reader_panel_definitions(progress)
    local buttons={}
    for _,key in ipairs(reader.quick_order or READER_QUICK_ITEM_ORDER) do
        if reader.quick_items[key]==true and definitions[key] then buttons[#buttons+1]=definitions[key] end
        if #buttons>=8 then break end
    end
    local screen=Device.screen
    local columns=(screen:getWidth()<screen:getHeight()) and 3 or 4
    local panel,err=ReaderToolbar.show{
        title=reader.show_title~=false and title or "阅读快捷面板",
        subtitle=reader.show_status~=false and status or "",
        columns=columns,
        buttons=buttons,
    }
    if not panel then
        logger.warn("[MiuRead][ReaderToolbar] unavailable",tostring(err or "unknown"))
        return false
    end
    logger.info("[MiuRead][ReaderToolbar] opened")
    return true
end

function Plugin:_close_miuread_transients()
    HomeQuickPanel.close()
    ReaderToolbar.close()
    ReaderSettingsDialog.close()
    local pending={}
    for index=#(UIManager._window_stack or {}),1,-1 do
        local window=UIManager._window_stack[index]
        local widget=window and window.widget or nil
        if widget and widget~=HomeView.current() and widget._miuread_transient==true
            and UIManager:isWidgetShown(widget) then
            pending[#pending+1]=widget
        end
    end
    for _,widget in ipairs(pending) do pcall(function() UIManager:close(widget) end) end
end

function Plugin:_reader_file(readerui,file)
    local path=normalized_reader_file(file)
    if path then return path end
    local document=readerui and readerui.document or nil
    if document then
        path=normalized_reader_file(document.file or (document.getFilePath and document:getFilePath()) or nil)
    end
    return path
end

function Plugin:_reader_should_return_home(readerui,file)
    sync_home_session()
    if not self:_home_enabled() or HOME_SESSION_SUPPRESSED or HOME_NATIVE_VISIT
        or HOME_EXITING or UIManager._exit_code~=nil then return false end
    local path=self:_reader_file(readerui,file)
    if HOME_READER_ORIGIN then
        if path and not HOME_READER_FILE then mark_reader_origin(path) end
        return true
    end
    if path and HOME_READER_FILE and path==HOME_READER_FILE then
        mark_reader_origin(path)
        return true
    end
    return false
end

function Plugin:_install_reader_quick_panel_zone()
    local readerui=self.ui
    if not readerui or not readerui.document then return false end
    -- Keep KOReader's own touch-zone geometry and priority. The menu bridge
    -- below redirects only the native menu handler after links, footnotes,
    -- highlights and normal page gestures have had their normal chance.
    if not readerui._miuread_native_menu_zone_preserved then
        readerui._miuread_native_menu_zone_preserved=true
        logger.info("[MiuRead][ReaderToolbar] native menu touch zones preserved")
    end
    return true
end

function Plugin:_install_reader_menu_bridge()
    local readerui=self.ui
    local menu=readerui and readerui.menu or nil
    if not readerui or not readerui.document or not menu then return false end
    if menu._miuread_bridge_owner==self then return true end

    local original_tap=menu.onTapShowMenu
    local original_swipe=menu.onSwipeShowMenu
    local original_press=menu.onPressMenu
    local original_key=menu.onKeyPressShowMenu
    local plugin=self

    menu._miuread_bridge_owner=self
    menu._miuread_original_onTapShowMenu=original_tap
    menu._miuread_original_onSwipeShowMenu=original_swipe
    menu._miuread_original_onPressMenu=original_press
    menu._miuread_original_onKeyPressShowMenu=original_key

    menu.onTapShowMenu=function(native_menu,ges)
        if plugin and plugin.ui==readerui and readerui.document and plugin:_reader_panel_active() then
            local activation=native_menu.activation_menu
                or (G_reader_settings and G_reader_settings:readSetting("activate_menu")) or "swipe_tap"
            if activation~="swipe" then return plugin:show_reader_quick_panel() end
            return nil
        end
        if type(original_tap)=="function" then return original_tap(native_menu,ges) end
    end
    menu.onSwipeShowMenu=function(native_menu,ges)
        if plugin and plugin.ui==readerui and readerui.document and plugin:_reader_panel_active() then
            local activation=native_menu.activation_menu
                or (G_reader_settings and G_reader_settings:readSetting("activate_menu")) or "swipe_tap"
            if activation~="tap" and ges and ges.direction=="south" then
                local shown=plugin:show_reader_quick_panel()
                if shown then readerui:handleEvent(Event:new("HandledAsSwipe")) end
                return shown
            end
            return nil
        end
        if type(original_swipe)=="function" then return original_swipe(native_menu,ges) end
    end
    menu.onPressMenu=function(native_menu,...)
        if plugin and plugin.ui==readerui and readerui.document and plugin:_reader_panel_active() then
            return plugin:show_reader_quick_panel()
        end
        if type(original_press)=="function" then return original_press(native_menu,...) end
    end
    menu.onKeyPressShowMenu=function(native_menu,...)
        if plugin and plugin.ui==readerui and readerui.document and plugin:_reader_panel_active() then
            return plugin:show_reader_quick_panel()
        end
        if type(original_key)=="function" then return original_key(native_menu,...) end
    end
    logger.info("[MiuRead][ReaderToolbar] native menu handlers redirected; touch zones unchanged")
    return true
end

function Plugin:_install_reader_home_bridge()
    local readerui=self.ui
    if not readerui or not readerui.document or type(readerui.onHome)~="function" then return false end
    local plugin=self
    if not readerui._miuread_original_onHome then
        local original=readerui.onHome
        readerui._miuread_original_onHome=original
        readerui.onHome=function(ui,...)
            if plugin and plugin._reader_context and plugin:_reader_should_return_home(ui) then
                logger.info("[MiuRead][Reader] native bookshelf redirected before FileManager")
                return plugin:return_to_miuread_home()
            end
            return original(ui,...)
        end
    end
    if type(readerui.showFileManager)=="function" and not readerui._miuread_original_showFileManager then
        local original_show_filemanager=readerui.showFileManager
        readerui._miuread_original_showFileManager=original_show_filemanager
        readerui.showFileManager=function(ui,file,...)
            if plugin and plugin:_reader_should_return_home(ui,file) then
                local path=plugin:_reader_file(ui,file)
                HOME_RETURN_FILE=path or HOME_RETURN_FILE
                mark_reader_origin(path)
                logger.info("[MiuRead][Reader] FileManager transition suppressed; returning to MiuRead")
                local generation=plugin:_begin_reader_return("native filemanager",path)
                plugin:_schedule_reader_return_finish(generation,.02,"native filemanager")
                return true
            end
            return original_show_filemanager(ui,file,...)
        end
    end
    return true
end

function Plugin:onHome()
    if self.ui and self.ui.document and self:_reader_should_return_home(self.ui) then
        logger.info("[MiuRead][Reader] Home event redirected to MiuRead home")
        return self:return_to_miuread_home()
    end
    sync_home_session()
    if not (self.ui and self.ui.document) and self:_home_enabled()
        and HOME_NATIVE_VISIT and not HOME_EXITING then
        logger.info("[MiuRead][Home] FileManager Home event redirected to MiuRead home")
        return self:_return_from_native_filemanager()
    end
    return false
end

function Plugin:_active_reader_ui()
    local ok,ReaderUI=pcall(require,"apps/reader/readerui")
    if not ok or not ReaderUI then return nil end
    local instance=ReaderUI.instance
    return instance and instance.document and instance or nil
end

function Plugin:_show_miuread_home_now(force_scan,from_refresh,quiet,refresh_kind)
    sync_home_session()
    if HOME_EXITING or UIManager._exit_code~=nil then return false end
    HOME_SESSION_SUPPRESSED=false
    HOME_NATIVE_VISIT=false
    HOME_EXPECTED_CLOSE=false
    -- The home can remain alive underneath ReaderUI. Background cover or
    -- metadata refreshes must not clear the reader-origin token, otherwise the
    -- native bookshelf button will leak to FileManager later in the session.
    if not self:_active_reader_ui() then
        HOME_READER_ORIGIN=false
        HOME_READER_FILE=nil
        HOME_RETURN_FILE=nil
    end
    persist_home_session()

    if force_scan==true then self:_home_reset_local_metadata() end
    local miuread_rows=self:_home_miuread_rows()
    local local_rows=self:_home_local_rows()
    local cached_books,cached_mp=self.library:cached()
    cached_books=type(cached_books)=="table" and cached_books or {}
    cached_mp=type(cached_mp)=="table" and cached_mp or {}

    local account_rows=self:_shelf_rows("account",false,cached_books,{},#cached_books>0)
    self:_prepare_shelf_rows(account_rows)
    for _,row in ipairs(account_rows) do
        self:_home_attach_local_record(row)
        row.source="account"
        row.description=row.description or row.intro or row.summary
        row.status_text=self:_home_status_text(row,false)
    end
    local mp_rows=self:_shelf_rows("account",true,{},cached_mp,#cached_mp>0)
    self:_prepare_shelf_rows(mp_rows)
    for _,row in ipairs(mp_rows) do
        row.source="mp"
        row.status_text=self:_home_status_text(row,false)
    end

    local home=self:_home_preferences()
    local hero=self:_home_recent_book(miuread_rows,local_rows,account_rows)
    if hero then
        hero=U.copy(hero)
        hero.heading="最近阅读"
        hero.source_text=self:_home_source_text(hero)
        hero.last_read_text=self:_home_last_read_text(hero)
        hero.status_text=self:_home_status_text(hero,hero.source=="local" or hero.local_file==true)
        if U.trim(tostring(hero.format or ""))=="" then
            local extension=tostring(hero.file or ""):match("%.([%w]+)$")
            if extension then hero.format=extension:upper() end
        end
        local variant=tostring(hero.variant or "")
        if hero.annotation_requested==true or variant:find("notes",1,true) then
            hero.edition_text="含评论"
        elseif variant:find("clean",1,true) then
            hero.edition_text="纯净版"
        end
        hero.on_tap=function() self:_home_open_book(hero) end
    end

    local sections={
        account={title="微信书架",rows=account_rows,empty="这里还没有微信书架内容"},
        generated={title="已下载",rows=miuread_rows,empty="这里还没有已下载书籍"},
        ["local"]={title="本地书籍",rows=local_rows,empty="这里还没有本地书籍\n导入书籍后会显示在这里"},
        mp={title="公众号",rows=mp_rows,empty="这里还没有公众号内容"},
    }
    self._home_sections=sections
    local visible_keys=self:_home_visible_section_keys(sections,home)
    self._home_visible_keys=visible_keys
    local active=visible_keys[1] or "account"
    for _,key in ipairs(visible_keys) do
        if key==home.active_section then active=key; break end
    end
    local selected=sections[active]
    if home.active_section~=active then
        home.active_section=active
        local _,preferences=self:_home_preferences()
        self:_save_home_preferences(home,preferences)
    end
    self._home_active_section=active
    self._home_hero=hero
    local preview_limit=self:_home_page_limit()
    local selected_preview,shelf_page,shelf_pages=self:_home_preview_page(
        selected.rows,hero,home.page_by_section and home.page_by_section[active],preview_limit
    )
    home.page_by_section=type(home.page_by_section)=="table" and home.page_by_section or {}
    if tonumber(home.page_by_section[active])~=shelf_page then
        home.page_by_section[active]=shelf_page
        local _,preferences=self:_home_preferences()
        self:_save_home_preferences(home,preferences)
    end
    local tabs=self:_home_build_tabs(active)

    local view,err=HomeView.show({
        title="觅阅",
        status_line=self:_home_status_line(),
        account_name=self:_home_account_name(),
        layout_style=home.layout_style,
        hero=hero,
        tabs=tabs,
        shelf_title=selected.title.." · "..tostring(#selected.rows).."本",
        shelf_books=selected_preview,
        shelf_page=shelf_page,
        shelf_pages=shelf_pages,
        empty_text=selected.empty,
        download_notice=self:_home_download_notice(),
        alerts=self:_home_alerts(),
        lockscreen_enabled=home.lockscreen_recent~=false,
        screensaver_file=hero and hero.cover_path or nil,
        on_quick_panel=function() self:show_home_quick_panel() end,
        on_account=function() self:_home_leave_and_run("account status",function() self:show_account_status() end) end,
        on_menu=function() self:show_home_menu() end,
        on_empty_account=function() self:_home_open_section(active) end,
        on_open_book=function(book) self:_home_open_book(book) end,
        on_shelf_all=function() self:_home_open_section(active) end,
        on_shelf_page=function(delta) self:_home_change_page(delta) end,
        on_close=function(current)
            if self._home_view==current then self._home_view=nil end
            if HOME_EXPECTED_CLOSE or HOME_NATIVE_VISIT or HOME_EXITING or UIManager._exit_code~=nil then return end
            if not self._home_reader_transition and not HOME_SESSION_SUPPRESSED and self:_home_enabled() then
                UIManager:scheduleIn(.6,function()
                    if HOME_EXPECTED_CLOSE or HOME_NATIVE_VISIT or HOME_EXITING or UIManager._exit_code~=nil then return end
                    if not HomeView.is_shown() and not self:_active_reader_ui() and not HOME_SESSION_SUPPRESSED then
                        self:_restore_home_after_reader_close(1)
                    end
                end)
            end
        end,
    },refresh_kind)
    if not view then
        logger.warn("[MiuRead][Home] bookshelf unavailable",tostring(err or "unknown"))
        if not quiet then self:info("觅阅首页暂时无法显示：\n"..tostring(err or "未知错误")) end
        return false
    end
    self._home_view=view
    self._home_refresh_pending=false
    if self._thought_index_pause_path then os.remove(self._thought_index_pause_path) end

    local metadata_targets={}
    local cover_targets={}
    if hero then
        metadata_targets[#metadata_targets+1]=hero
        cover_targets[#cover_targets+1]=hero
    end
    for _,book in ipairs(selected_preview) do
        metadata_targets[#metadata_targets+1]=book
        cover_targets[#cover_targets+1]=book
    end
    self:_home_schedule_local_metadata(metadata_targets)
    self:_home_schedule_remote_covers(cover_targets)

    if not from_refresh then
        self:_home_scan_local(force_scan==true)
        UIManager:scheduleIn(.35,function()
            if HomeView.is_shown() and not self:_active_reader_ui() then self:_home_refresh_remote(false,false) end
        end)
    end
    if not force_scan then UIManager:scheduleIn(2.5,function()
        if HomeView.is_shown() and not self._home_refreshing then self:_start_thought_index_maintenance() end
    end) end
    return true
end

function Plugin:show_miuread_home(force_scan,from_refresh)
    if self:_active_reader_ui() then return self:return_to_miuread_home() end
    return self:_show_miuread_home_now(force_scan,from_refresh)
end

function Plugin:_ensure_filemanager_base(file)
    local ok,FileManager=pcall(require,"apps/filemanager/filemanager")
    if not ok or not FileManager then return false end
    if FileManager.instance then return true end
    local target=tostring(file or HOME_RETURN_FILE or "")
    local dir=target~="" and target:match("^(.*)/[^/]+$") or nil
    local selected=target~="" and target or nil
    local shown,err=xpcall(function() FileManager:showFiles(dir,selected) end,debug.traceback)
    if not shown then
        logger.warn("[MiuRead][Home] failed to recreate FileManager base",tostring(err))
        return false
    end
    return true
end

function Plugin:_restore_home_after_reader_close(attempt,generation)
    sync_home_session()
    attempt=tonumber(attempt) or 1
    if generation==nil then
        self._home_restore_generation=(tonumber(self._home_restore_generation) or 0)+1
        generation=self._home_restore_generation
    end
    if generation~=self._home_restore_generation then return false end
    if HOME_SESSION_SUPPRESSED or HOME_NATIVE_VISIT or HOME_EXITING or UIManager._exit_code~=nil or not self:_home_enabled() then return false end
    if self:_active_reader_ui() then
        if attempt<24 then
            UIManager:scheduleIn(.15,function() self:_restore_home_after_reader_close(attempt+1,generation) end)
        end
        return false
    end
    local ok_fm,FileManager=pcall(require,"apps/filemanager/filemanager")
    local has_base=ok_fm and FileManager and FileManager.instance~=nil
    if HomeView.is_shown() then
        if not has_base then
            self:_ensure_filemanager_base(HOME_RETURN_FILE or HOME_READER_FILE)
        end
        -- FileManager provides KOReader's docless services and gesture manager,
        -- but it must stay below the MiuRead root.
        HomeView.raise()
        HOME_READER_ORIGIN=false
        HOME_READER_FILE=nil
        HOME_RETURN_FILE=nil
        persist_home_session()
        return true
    end

    if not has_base then
        self:_ensure_filemanager_base(HOME_RETURN_FILE)
        if attempt<24 then
            UIManager:scheduleIn(.12,function() self:_restore_home_after_reader_close(attempt+1,generation) end)
        end
        return false
    end

    local shown=self:_show_miuread_home_now(false,false)
    if shown then HOME_RETURN_FILE=nil end
    return shown
end

function Plugin:_begin_reader_return(reason,file)
    local now=os.time()
    if self._reader_returning then
        local age=now-(tonumber(self._reader_return_started) or now)
        if age>=0 and age<30 then
            return tonumber(self._reader_return_generation) or 0,false
        end
        logger.warn("[MiuRead][Reader] stale return state reset",tostring(self._reader_return_reason or "unknown"))
        self:_clear_reader_return(self._reader_return_generation,"stale state")
    end
    self._reader_return_generation=(tonumber(self._reader_return_generation) or 0)+1
    self._reader_returning=true
    self._reader_return_started=now
    self._reader_return_reason=tostring(reason or "return home")
    self._reader_return_completed_generation=nil
    self._home_reader_transition=true
    if self._reader_return_finish_task then
        UIManager:unschedule(self._reader_return_finish_task)
        self._reader_return_finish_task=nil
    end
    local path=self:_reader_file(self:_active_reader_ui(),file)
    HOME_RETURN_FILE=path or HOME_RETURN_FILE
    if path then mark_reader_origin(path) end
    return self._reader_return_generation,true
end

function Plugin:_clear_reader_return(generation,reason)
    if generation and generation~=self._reader_return_generation then return false end
    if self._reader_return_finish_task then
        UIManager:unschedule(self._reader_return_finish_task)
        self._reader_return_finish_task=nil
    end
    self._reader_returning=false
    self._reader_return_started=0
    self._reader_return_reason=nil
    self._home_reader_transition=false
    self._miuread_return_requested=false
    logger.info("[MiuRead][Reader] return state cleared",tostring(reason or "complete"))
    return true
end

function Plugin:_schedule_reader_return_finish(generation,delay,reason)
    if generation~=self._reader_return_generation
        or self._reader_return_completed_generation==generation then return false end
    if self._reader_return_finish_task then
        UIManager:unschedule(self._reader_return_finish_task)
        self._reader_return_finish_task=nil
    end
    local task
    task=function()
        if self._reader_return_finish_task~=task then return end
        self._reader_return_finish_task=nil
        self:_finish_reader_return(generation,1,reason)
    end
    self._reader_return_finish_task=task
    UIManager:scheduleIn(math.max(0,tonumber(delay) or .02),task)
    return true
end

function Plugin:_finish_reader_return(generation,attempt,reason)
    if generation~=self._reader_return_generation then return false end
    if self._reader_return_completed_generation==generation then return true end
    attempt=tonumber(attempt) or 1
    if self:_active_reader_ui() then
        if attempt<80 then
            local task
            task=function()
                if self._reader_return_finish_task~=task then return end
                self._reader_return_finish_task=nil
                self:_finish_reader_return(generation,attempt+1,reason)
            end
            self._reader_return_finish_task=task
            UIManager:scheduleIn(attempt<10 and .12 or .35,task)
        else
            logger.warn("[MiuRead][Reader] reader still active after close request",tostring(reason or "return"))
            self:_clear_reader_return(generation,"close wait expired")
            self:info("书籍仍在关闭中，请稍后再试")
        end
        return false
    end

    -- Mark this generation complete before any repaint. CloseDocument and a
    -- watchdog may arrive together, but only the first one is allowed to raise
    -- and redraw the MiuRead home screen.
    self._reader_return_completed_generation=generation
    if self._reader_return_finish_task then
        UIManager:unschedule(self._reader_return_finish_task)
        self._reader_return_finish_task=nil
    end
    self:_ensure_filemanager_base(HOME_RETURN_FILE or HOME_READER_FILE)
    self:_close_miuread_transients()
    HomeView.raise()
    self:_restore_home_after_reader_close(1)
    self:_clear_reader_return(generation,reason or "home restored")
    return true
end

function Plugin:return_to_miuread_home(reason)
    sync_home_session()
    if HOME_EXITING or UIManager._exit_code~=nil then return false end
    self:_cancel_native_menu_guard()
    HOME_SESSION_SUPPRESSED=false
    HOME_NATIVE_VISIT=false
    HOME_EXPECTED_CLOSE=false
    self._miuread_return_requested=true
    persist_home_session()

    local readerui=self:_active_reader_ui()
    if readerui then
        local file=self:_reader_file(readerui,HOME_RETURN_FILE)
        local generation,started=self:_begin_reader_return(reason or "explicit return",file)
        if not started then return true end
        self:_close_miuread_transients()
        UIManager:nextTick(function()
            if generation~=self._reader_return_generation then return end
            local active=self:_active_reader_ui() or readerui
            if not active or not active.document then
                self:_schedule_reader_return_finish(generation,.02,"reader already closed")
                return
            end
            pcall(function() active:handleEvent(Event:new("CloseReaderMenu")) end)
            pcall(function() active:handleEvent(Event:new("CloseConfigMenu")) end)
            local ok_close,err_close=xpcall(function()
                active:onClose(false)
            end,debug.traceback)
            if not ok_close then
                logger.warn("[MiuRead][Reader] return home close failed",tostring(err_close))
                self:_clear_reader_return(generation,"close failed")
                if active.dialog then pcall(UIManager.setDirty,UIManager,active.dialog,"ui") end
                self:info("书籍暂时无法关闭，请稍后重试")
                return
            end
            -- CloseDocument is the primary completion signal. This watchdog is
            -- deliberately slow and is cancelled as soon as that event arrives.
            self:_schedule_reader_return_finish(generation,5,"return watchdog")
        end)
        return true
    end

    self._miuread_return_requested=false
    self:_close_miuread_transients()
    self:_ensure_filemanager_base(HOME_RETURN_FILE)
    HomeView.raise()
    return self:_restore_home_after_reader_close(1)
end

function Plugin:search_dialog()
    if not self:require_login() then return end
    local d
    d=InputDialog:new{
        title=_("Search books"), input="",
        buttons={{
            {text=_("Cancel"),id="close",callback=function() UIManager:close(d) end},
            {text=_("Search"),is_enter_default=true,callback=function()
                local q=U.trim(d:getInputText())
                UIManager:close(d)
                if q~="" then self:search(q) end
            end},
        }},
    }
    UIManager:show(d)
    d:onShowKeyboard()
end

function Plugin:_cancel_search(reason)
    self._search_generation=(tonumber(self._search_generation) or 0)+1
    if self.search_async then self.search_async:cancel(reason or "cancelled") end
    local dialog=self._search_dialog
    self._search_dialog=nil
    if dialog then pcall(UIManager.close,UIManager,dialog) end
end

function Plugin:search(q)
    if not self:require_login() then return end
    if not self:is_online() then self:info(_("Network unavailable")); return end
    if self.search_async and self.search_async:busy() then self:_cancel_search("new_search") end

    self._search_generation=(tonumber(self._search_generation) or 0)+1
    local generation=self._search_generation
    local closing=false
    local dialog
    dialog=ButtonDialog:new{
        title="正在搜索《"..tostring(q).."》……\n\n可按返回键或点击取消。",
        title_align="center",
        close_callback=function()
            if closing then return end
            closing=true
            if generation==self._search_generation and self.search_async then
                self.search_async:cancel("search_dialog_closed")
                self._search_generation=self._search_generation+1
            end
            self._search_dialog=nil
        end,
        buttons={
            {{text="取消搜索",callback=function()
                if closing then return end
                closing=true
                if generation==self._search_generation and self.search_async then
                    self.search_async:cancel("user_cancelled")
                end
                self._search_generation=self._search_generation+1
                self._search_dialog=nil
                UIManager:close(dialog)
            end}},
        },
    }
    self._search_dialog=dialog
    UIManager:show(dialog)

    local function finish(result)
        if generation~=self._search_generation then return end
        closing=true
        self._search_dialog=nil
        UIManager:close(dialog)
        if not result or result.ok~=true then
            self:info(self:_friendly_remote_error(result and result.error or "未知错误","搜索"))
            return
        end
        local data=result.value or {}
        local items={}
        local function add(r)
            local b=normalize(r)
            if b.bookId~="" then
                items[#items+1]={text=b.title,post_text=b.author,callback=function() self:book_menu(b) end}
            end
        end
        for _,g in ipairs(data.results or data.books or {}) do
            if g.books then for _,r in ipairs(g.books) do add(r) end else add(g) end
        end
        self:list(_("Search").." · "..q,items,"没有找到相关书籍")
    end

    local function run_on_main_thread()
        UIManager:scheduleIn(.10,function()
            if generation~=self._search_generation then return end
            local ok,value=xpcall(function() return self.api:search(q,0,40) end,debug.traceback)
            finish(ok and {ok=true,value=value} or {ok=false,error=tostring(value)})
        end)
    end

    if not self.search_async or not self.search_async:available() then
        run_on_main_thread()
        return
    end

    local auth=U.copy(self.store:auth())
    local started,err=self.search_async:run("book_search",function()
        local HttpChild=require("miuread.http")
        local ApiChild=require("miuread.api")
        local UtilChild=require("miuread.util")
        local child_store={
            auth=function() return UtilChild.copy(auth) end,
            save_auth=function() end,
        }
        local api=ApiChild:new(HttpChild:new(child_store),child_store)
        return api:search(q,0,40)
    end,finish,32)
    if not started then
        logger.warn("[MiuRead][Search] async unavailable; falling back",tostring(err or "worker busy"))
        run_on_main_thread()
    end
end
function Plugin:_variant_exists(book_id,kind)
    local r=self.store:variant(book_id,kind)
    return r and r.file and U.file_exists(r.file) and r or nil
end
function Plugin:_book_has_cache(book_id)
    local stored=self.store:book(book_id)
    if not stored then return false end
    for _,r in pairs(stored.variants or {}) do if r.file and U.file_exists(r.file) then return true end end
    for _,row in pairs(stored.chapters or {}) do for _,r in pairs(row or {}) do if r.file and U.file_exists(r.file) then return true end end end
    return false
end
function Plugin:_preferred_record(book_id)
    local session=self.store:session(book_id) or {}
    local last=tostring(session.last_read_path or "")
    local b=self.store:book(book_id)
    local fallback
    if not b then return nil end
    local function consider(record)
        if type(record)~="table" or not record.file then return end
        if tostring(record.file)==last or tostring(record.original_file or "")==last then fallback=record; return true end
        if not fallback then fallback=record end
    end
    for _,kind in ipairs({"notes","clean","range_notes","range_clean","preview_notes","preview_clean"}) do
        if consider(b.variants and b.variants[kind]) then return fallback end
    end
    for _,row in pairs(b.chapters or {}) do
        for _,kind in ipairs({"notes","clean","range_notes","range_clean","preview_notes","preview_clean"}) do
            if consider(row and row[kind]) then return fallback end
        end
    end
    return fallback
end
function Plugin:reverify_book_and_open(book_id,preferred_path)
    book_id=tostring(book_id or "")
    local record
    if preferred_path then local _,matched=self.store:identify_file(preferred_path,false); record=matched end
    record=record or self:_preferred_record(book_id) or self.access:first_record(book_id,nil,false)
    local path=preferred_path or (record and record.file)
    if not path then self:info("本地书籍记录不存在，请重新生成本书。"); return end
    local resolved=self.access:resolve_path(book_id,path)
    if resolved and U.file_exists(resolved) then self:_open_file_direct(resolved)
    else self:info("本地 EPUB 不存在，请重新生成本书。") end
end


local function mp_date(value)
    value=tonumber(value or 0) or 0
    return value>0 and os.date("%Y-%m-%d",value) or ""
end

function Plugin:_mp_normalize_book(book)
    local original=type(book)=="table" and book or {}
    local normalized=U.merge(original,normalize(original))
    normalized.bookId=tostring(normalized.bookId or normalized.book_id or "")
    return normalized
end

function Plugin:_refresh_mp_articles(book,silent,on_done)
    book=self:_mp_normalize_book(book)
    if not self:logged_in() then
        if not silent then self.auth_flow:start() end
        if on_done then on_done(nil,"尚未登录") end
        return false
    end
    if not self:is_online() then
        if not silent then self:info(_("Network unavailable")) end
        if on_done then on_done(nil,"网络不可用") end
        return false
    end
    if self.mp_async:busy() then
        if not silent then self:info("另一项公众号任务正在进行中。") end
        return false
    end
    if not silent then self:status_toast("公众号","正在刷新文章列表",2) end
    local book_copy=U.copy(book)
    local started,err=self.mp_async:run("mp-articles",function()
        return self.mp:articles(book_copy.bookId,{force=true,title=book_copy.title})
    end,function(result)
        self.store:reload()
        if result and result.ok and type(result.value)=="table" then
            if on_done then on_done(result.value,nil) end
            if not silent then self:show_mp_articles(book_copy,result.value) end
        else
            local cached=self.mp:cached_articles(book_copy.bookId)
            local message=result and result.error or "文章列表刷新失败"
            logger.warn("[MiuRead][MP] article list refresh failed",tostring(message))
            if on_done then on_done(#cached>0 and cached or nil,message) end
            if not silent then
                if #cached>0 then self:toast("刷新失败，继续显示本地文章列表",3); self:show_mp_articles(book_copy,cached)
                else self:info(self:_friendly_remote_error(message,"公众号文章列表加载")) end
            end
        end
    end,75)
    if not started and not silent then self:info(self:_friendly_remote_error(err or "无法启动文章列表任务","公众号文章列表加载")) end
    return started
end

function Plugin:mp_account(book)
    book=self:_mp_normalize_book(book)
    if not Protocol.is_mp_account(book.bookId) then
        self:info("微信读书书架没有返回可用的公众号。")
        return
    end
    book.content_type="mp_account"
    self.store:save_book(book.bookId,{
        book_id=book.bookId,title=book.title,author=book.author,cover=book.cover,
        content_type="mp_account",updated_at=os.time(),
    })
    local cached=self.mp:cached_articles(book.bookId)
    if #cached>0 then
        self:show_mp_articles(book,cached)
        if self.mp:list_stale(book.bookId) and self:logged_in() and self:is_online() and not self.mp_async:busy() then
            self:_refresh_mp_articles(book,true)
        end
    else
        self:_refresh_mp_articles(book,false)
    end
end

function Plugin:open_mp_account_by_id(book_id,title)
    local found
    local accounts=self.mp:cached_accounts()
    for _,book in ipairs(accounts or {}) do
        if tostring(book.bookId or book.book_id)==tostring(book_id) then found=book; break end
    end
    if not found then
        local _,cached_mp=self.library:cached()
        for _,book in ipairs(cached_mp or {}) do
            if tostring(book.bookId or book.book_id)==tostring(book_id) then found=book; break end
        end
    end
    found=found or {bookId=book_id,title=title or "公众号",author="公众号",content_type="mp_account"}
    self:mp_account(found)
end

function Plugin:show_mp_articles(book,articles,title_suffix)
    book=self:_mp_normalize_book(book)
    articles=type(articles)=="table" and articles or {}
    local items={
        {text="搜索文章",callback=function() self:mp_search_dialog(book,articles) end},
        {text="刷新文章列表",post_text="最近 100 篇",callback=function() self:_refresh_mp_articles(book,false) end},
        {text="管理本号缓存",callback=function()
            self:list("缓存管理 · "..tostring(book.title or "公众号"),self:mp_cache_menu(book,self.mp:cached_articles(book.bookId)),"暂无缓存")
        end},
    }
    for _,row in ipairs(articles) do
        local article=U.copy(row)
        local record=self.mp:article_record(book.bookId,article)
        local post=mp_date(article.createTime)
        if record then post=(post~="" and (post.." · ") or "").."已缓存" end
        items[#items+1]={
            text=tostring(article.title or "文章"),post_text=post,
            callback=function() self:open_or_download_mp_article(book,article) end,
        }
    end
    local title=tostring(book.title or "公众号").." · "..tostring(#articles).."篇"
    if title_suffix then title=title.." · "..tostring(title_suffix) end
    self:list(title,items,"暂无文章")
end

function Plugin:mp_search_dialog(book,articles)
    local dialog
    dialog=InputDialog:new{
        title="搜索本号文章",input="",
        buttons={{
            {text=_("Cancel"),id="close",callback=function() UIManager:close(dialog) end},
            {text=_("Search"),is_enter_default=true,callback=function()
                local query=U.trim(dialog:getInputText()):lower()
                UIManager:close(dialog)
                if query=="" then return end
                local results={}
                for _,article in ipairs(articles or {}) do
                    if tostring(article.title or ""):lower():find(query,1,true) then results[#results+1]=article end
                end
                if #results==0 then self:info("没有找到相关文章") else self:show_mp_articles(book,results,"搜索结果") end
            end},
        }},
    }
    UIManager:show(dialog); dialog:onShowKeyboard()
end

function Plugin:_close_mp_download_dialog()
    local dialog=self._mp_download_dialog
    self._mp_download_dialog=nil
    if dialog then pcall(function() UIManager:close(dialog) end) end
end

function Plugin:_start_mp_article_download(book,article,force)
    if self.mp_async:busy() then self:info("另一项公众号任务正在进行中。") return false end
    local title=tostring(article.title or "文章")
    local cancelled=false
    local dialog
    dialog=ButtonDialog:new{
        title="正在下载公众号文章\n\n"..title.."\n\n文章通常较小，下载完成后会自动打开。",
        title_align="left",
        buttons={{{text="取消下载",callback=function()
            cancelled=true
            if self.mp_async and self.mp_async:busy() then self.mp_async:cancel("user_cancelled") end
            self:_close_mp_download_dialog()
            self:status_toast("公众号","已取消下载",3)
        end}}},
    }
    self._mp_download_dialog=dialog
    UIManager:show(dialog)

    local book_copy,article_copy=U.copy(book),U.copy(article)
    local prefs=self.store:preferences()
    local started,err=self.mp_async:run("mp-article",function()
        return self.mp:fetch_article(book_copy,article_copy,{images=prefs.mp_images==true,force=force==true})
    end,function(result)
        self:_close_mp_download_dialog()
        if cancelled then return end
        self.store:reload()
        if result and result.ok and type(result.value)=="table" and result.value.file then
            self:open_file(result.value.file)
            return
        end
        local fallback=self.mp:article_record(book_copy.bookId,article_copy)
        if fallback then
            self:status_toast("公众号","下载未完整完成，已打开原缓存",4)
            self:open_file(fallback.file)
        else
            logger.warn("[MiuRead][MP] article download failed",tostring(result and result.error))
            self:info("文章下载失败：\n"..U.first_line(result and result.error or "未知错误",180))
        end
    end,120)
    if not started then
        self:_close_mp_download_dialog()
        self:info("无法启动文章下载：\n"..tostring(err))
        return false
    end
    return true
end

function Plugin:open_or_download_mp_article(book,article,force)
    local record=self.mp:article_record(book.bookId,article)
    if record and force~=true then self:open_file(record.file); return end
    if not self:require_login() then return end
    if not self:is_online() then
        if record then self:open_file(record.file) else self:info(_("Network unavailable")) end
        return
    end
    if force==true then
        self:_start_mp_article_download(book,article,true)
        return
    end
    UIManager:show(ConfirmBox:new{
        text="《"..tostring(article.title or "文章").."》尚未缓存。\n\n是否下载并打开？公众号文章通常只需几秒。",
        ok_text="下载并打开",
        ok_callback=function() self:_start_mp_article_download(book,article,false) end,
    })
end

function Plugin:mp_cache_menu(book,articles)
    local items={}
    local cached_count=0
    for _,article in ipairs(articles or {}) do
        if self.mp:article_record(book.bookId,article) then cached_count=cached_count+1 end
    end
    items[#items+1]={text="已缓存文章",post_text=tostring(cached_count).." 篇",enabled=false}
    for _,row in ipairs(articles or {}) do
        local article=U.copy(row)
        if self.mp:article_record(book.bookId,article) then
            items[#items+1]={text=tostring(article.title or "文章"),post_text=mp_date(article.createTime),callback=function()
                self:mp_article_cache_menu(book,article)
            end}
        end
    end
    items[#items+1]={text="清理本号文章缓存",callback=function()
        UIManager:show(ConfirmBox:new{text="清理《"..tostring(book.title or "公众号").."》的文章列表和单篇缓存？",ok_callback=function()
            local ok,err=self.mp:clear_account(book.bookId)
            if not ok then self:info("缓存删除失败：\n"..tostring(err or "无法删除目录")); return end
            self:status_toast("公众号","本号缓存已清理",4)
            UIManager:scheduleIn(.15,function() self:show_mp_articles(book,articles,"缓存已清理") end)
        end})
    end}
    return items
end

function Plugin:mp_article_cache_menu(book,article)
    local items={
        {text="打开文章",callback=function() self:open_or_download_mp_article(book,article) end},
        {text="重新下载文章",callback=function() self:open_or_download_mp_article(book,article,true) end},
        {text="删除单篇缓存",callback=function()
            UIManager:show(ConfirmBox:new{text="删除《"..tostring(article.title or "文章").."》的单篇缓存？",ok_callback=function()
                local ok,err=self.mp:clear_article(book.bookId,article)
                if not ok then self:info("缓存删除失败：\n"..tostring(err or "无法删除目录")); return end
                self:status_toast("公众号","本篇缓存已删除",4)
                UIManager:scheduleIn(.15,function()
                    self:list("缓存管理 · "..tostring(book.title or "公众号"),self:mp_cache_menu(book,self.mp:cached_articles(book.bookId)),"暂无缓存")
                end)
            end})
        end},
    }
    self:list(article.title or "文章",items)
end

function Plugin:mp_global_cache_menu()
    return {
        {text="清理全部公众号缓存",callback=function()
            UIManager:show(ConfirmBox:new{text="清理全部公众号列表和单篇文章缓存？",ok_callback=function()
                local ok,err=U.remove_tree(self.store:mp_root())
                if not ok then self:info("缓存删除失败：\n"..tostring(err or "无法删除目录")); return end
                if not U.mkdir(self.store:mp_root()) then self:info("缓存目录重建失败，请重启 KOReader。") return end
                self:status_toast("公众号","全部缓存已清理",4)
            end})
        end},
    }
end

function Plugin:open_mp_neighbor(delta)
    local context=self.mp:identify_path(self:_current_document_path())
    if not context then self:info("当前不是觅阅公众号文章。") return end
    local articles=self.mp:cached_articles(context.bookId)
    local index
    for i,article in ipairs(articles or {}) do
        if tostring(article.reviewId or article.originalId)==tostring(context.reviewId) then index=i; break end
    end
    if not index then self:info("本地文章列表中找不到当前位置。") return end
    local target=articles[index+(tonumber(delta) or 0)]
    if not target then self:toast((delta or 0)<0 and "已经是第一篇" or "已经是最后一篇",2); return end
    self:open_or_download_mp_article({bookId=context.bookId,title=context.account_title or "公众号",author="公众号"},target)
end

function Plugin:book_menu(b)
    local original=type(b)=="table" and b or {}
    b=U.merge(original,normalize(original))
    if Protocol.is_mp_account(b.bookId) then self:mp_account(b); return end
    local items={}
    local records={{kind="clean",label="纯净版"},{kind="notes",label="划线与想法版"},
        {kind="range_clean",label="章节版 · 纯净版"},{kind="range_notes",label="章节版 · 划线与想法版"},
        {kind="preview_clean",label="试读版 · 纯净版"},{kind="preview_notes",label="试读版 · 划线与想法版"}}
    for _,entry in ipairs(records) do
        local record=self:_variant_exists(b.bookId,entry.kind)
        if record then
            items[#items+1]={text="打开"..entry.label,callback=function() self:open_file(record.file) end}
        end
    end
    items[#items+1]={text="生成／更新书籍",callback=function() self:choose_download(b,nil,false) end}
    items[#items+1]={text="按章节下载",callback=function() self:chapters(b) end}
    if self:_has_range_variant(b.bookId) then
        items[#items+1]={text="扩展已有章节版",sub_item_table_func=function() return self:range_extend_menu(b) end}
    end
    if self:_book_has_cache(b.bookId) or self.store:book_has_partial_cache(b.bookId) then
        items[#items+1]={text="管理本书文件",callback=function() self:downloaded_book_menu(tostring(b.bookId)) end}
    end
    items[#items+1]={text="书籍详情",callback=function() self:book_details(b) end}
    self:list(b.title,items)
end

function Plugin:book_details(b)
    self:online("details",function() local x=self.api:book(b.bookId); local z=normalize(x); self:info(z.title.."\n"..z.author.."\n\n"..tostring(x.intro or x.description or "")) end)
end
function Plugin:_download_preflight(callback)
    local state=HomeData.device_state(true) or {}
    local function check_battery()
        local battery=tonumber(state.battery)
        if self:_notice_enabled("low_battery") and battery and battery<20 and state.charging~=true then
            local dialog
            dialog=ButtonDialog:new{title="当前电量较低。继续下载整本书可能明显缩短使用时间。",title_align="center",buttons={
                {{text="继续下载",callback=function() UIManager:close(dialog); callback() end}},
                {{text="继续并不再提示",callback=function() UIManager:close(dialog); self:_set_notice_enabled("low_battery",false); callback() end}},
                {{text="取消",callback=function() UIManager:close(dialog) end}},
            }}
            UIManager:show(dialog)
            return true
        end
        callback()
        return true
    end
    local free=tonumber(state.storage_free)
    if free and free>0 and free<64*1024*1024 then
        self:info("剩余存储空间不足，无法安全开始下载。\n\n请先在“下载与存储”中清理本地文件。")
        return false
    end
    if self:_notice_enabled("low_storage") and free and free>0 and free<256*1024*1024 then
        local dialog
        dialog=ButtonDialog:new{title="剩余存储空间较少。下载图片或生成 EPUB 后可能无法正常保存。",title_align="center",buttons={
            {{text="继续下载",callback=function() UIManager:close(dialog); check_battery() end}},
            {{text="打开下载管理",callback=function() UIManager:close(dialog); self:show_downloads() end}},
            {{text="继续并不再提示",callback=function() UIManager:close(dialog); self:_set_notice_enabled("low_storage",false); check_battery() end}},
        }}
        UIManager:show(dialog)
        return true
    end
    return check_battery()
end

function Plugin:choose_download_mode(b,opt,open_after)
    local dialog
    local function launch(background,defer_until_reader_closed)
        if defer_until_reader_closed==true then
            if dialog then UIManager:close(dialog) end
            self:_queue_download(b,opt,open_after,{defer_until_reader_closed=true,reason="退出阅读后下载"})
            return
        end
        if self._download_launch_pending then
            self:toast("下载操作正在准备，请勿重复点击",2)
            return
        end
        self._download_launch_pending=true
        if dialog then UIManager:close(dialog) end
        self:status_toast("觅阅",tostring(b and b.title or "未命名")..
            (background and "正在准备后台下载" or "正在准备下载"),2)
        UIManager:scheduleIn(.20,function()
            self._download_launch_pending=false
            self:download(b,opt,open_after,nil,background)
        end)
    end
    local function begin_after_preflight(background)
        local active_reader=self:_active_reader_ui()~=nil
        if not active_reader then launch(background); return end
        local preferences=self.store:preferences()
        local policy=tostring(preferences.download_reader_policy or "ask")
        if policy=="allow" or preferences.download_reader_warning==false or not self:_notice_enabled("reader_download") then
            launch(background)
            return
        end
        if policy=="after_reading" then
            launch(true,true)
            return
        end
        if dialog then UIManager:close(dialog) end
        dialog=ButtonDialog:new{title="阅读时下载会增加耗电，并可能导致翻页、评论或菜单响应变慢。",title_align="center",buttons={
            {{text="继续后台下载",callback=function() UIManager:close(dialog); dialog=nil; launch(true) end}},
            {{text="退出阅读后下载",callback=function() UIManager:close(dialog); dialog=nil; launch(true,true) end}},
            {{text="取消",callback=function() UIManager:close(dialog) end}},
        }}
        UIManager:show(dialog)
    end
    local function start(background)
        if dialog then UIManager:close(dialog); dialog=nil end
        self:_download_preflight(function() begin_after_preflight(background) end)
    end
    dialog=ButtonDialog:new{title="下载方式",title_align="center",buttons={
        {{text="后台下载",callback=function() start(true) end}},
        {{text="留在当前页面下载",callback=function() start(false) end}},
        {{text="取消",callback=function() UIManager:close(dialog) end}},
    }}
    UIManager:show(dialog)
end
function Plugin:choose_download(b,limit,open_after,uid)
    local dialog
    local function choose_version(annotations)
        UIManager:close(dialog)
        self:choose_download_mode(b,{annotations=annotations,limit=limit,chapter_uid=uid},open_after)
    end
    dialog=ButtonDialog:new{
        title="下载《"..tostring(b.title or "未命名").."》",title_align="center",
        buttons={
            {{text="纯净版",callback=function() choose_version(false) end}},
            {{text="划线与想法版",callback=function() choose_version(true) end}},
            {{text="取消",callback=function() UIManager:close(dialog) end}},
        },
    }
    UIManager:show(dialog)
end
function Plugin:_download_summary(rec,opt)
    local preview=tostring(rec and rec.access_scope or "")=="preview" and not (opt and opt.chapter_uid)
    local preview_mode=tostring(rec and rec.preview_mode or "complete")
    local heading=preview and (preview_mode=="info" and "试读信息版生成完成"
        or (preview_mode=="partial" and "部分试读版生成完成" or "试读版生成完成")) or "下载完成"
    local lines={heading}
    local annotation_note=DownloadResult.summary_note(rec)
    if annotation_note then lines[#lines+1]=annotation_note end
    lines[#lines+1]="保存位置："..tostring(rec.file or "")
    lines[#lines+1]="打开一次后会出现在 KOReader 最近阅读中"
    if rec and rec.partial_range==true then
        lines[#lines+1]="章节版不会上传整书阅读进度，避免局部比例覆盖云端位置。"
    end
    if preview and preview_mode=="info" then lines[#lines+1]="本文件只包含书籍信息和权限说明。" end
    return table.concat(lines,"\n")
end

function Plugin:_refresh_local_files()
    local ui=self.ui
    if not ui then return end
    local chooser=ui.file_chooser
    if chooser then
        if type(chooser.refreshPath)=="function" then pcall(chooser.refreshPath,chooser)
        elseif type(chooser.refresh)=="function" then pcall(chooser.refresh,chooser) end
    end
    if type(ui.onRefresh)=="function" then pcall(ui.onRefresh,ui) end
end
function Plugin:_update_open_shelf_download_status(book_id,status)
    local view=self._shelf_view
    if not view or view._miu_closed or type(view.item_table)~="table" then return false end
    local changed=false
    for _,entry in ipairs(view.item_table) do
        if tostring(entry.book_id or "")==tostring(book_id or "") then
            entry.status=tostring(status or "")
            changed=true
        end
    end
    if changed and type(view.updateItems)=="function" then pcall(view.updateItems,view,nil,true) end
    return changed
end
local DOWNLOAD_STAGE_LABELS={
    prepare="准备下载",catalog="读取目录",resume="恢复断点",content="下载正文",
    underlines="获取划线",thoughts="获取想法",footnotes="处理脚注",
    images="处理图片",package="生成 EPUB",restart="断点恢复",done="下载完成",error="下载失败",
    cancelled="下载已取消",
}
function Plugin:_on_download_progress(runtime,state)
    if self._download_runtime~=runtime then return end
    runtime.last_state=U.copy(state or {})
    runtime.task=self.download_task and self.download_task:descriptor() or runtime.task
    if runtime.dialog then runtime.dialog:set_state(state) end
    self:_write_download_state("active",self:_active_download_payload(runtime,state),false)
    local home_percent=self:_download_percent(state)
    local home_mark=math.floor(home_percent/10)*10
    local home_stage=tostring(state and state.stage or "")
    if runtime.home_progress_mark~=home_mark or runtime.home_progress_stage~=home_stage then
        runtime.home_progress_mark=home_mark
        runtime.home_progress_stage=home_stage
        self:_notify_home_data_changed("section")
    end
    if state and state.stage=="rate_limit" then
        local wait=tonumber(state.wait_seconds) or 0
        self:_update_open_shelf_download_status(runtime.book.bookId,
            wait>0 and ("请求受限 · "..tostring(wait).."秒") or "请求受限 · 等待恢复")
    elseif state and state.stage=="restart" then
        self:_update_open_shelf_download_status(runtime.book.bookId,"从断点自动恢复")
    elseif state and state.waiting_network==true then
        self:_update_open_shelf_download_status(runtime.book.bookId,"等待网络")
    end
    if runtime.background and self.store:preferences().download_notice_enabled~=false then
        runtime.notified_milestones=runtime.notified_milestones or {}
        local percent=self:_download_percent(state)
        for _,mark in ipairs({25,50,75}) do
            if percent>=mark and not runtime.notified_milestones[mark] then
                runtime.notified_milestones[mark]=true
                self:_update_open_shelf_download_status(runtime.book.bookId,"生成中 "..tostring(mark).."%")
                self:status_toast("后台下载",tostring(runtime.book.title or "未命名").." · "..tostring(mark).."%",3)
            end
        end
    end
end
function Plugin:_finish_download_runtime(runtime,result)
    if self._download_runtime~=runtime then return end
    local b=runtime.book or {}
    local opt=runtime.options or {}
    local done=runtime.done
    local open_after=runtime.open_after==true
    local was_background=runtime.background==true
    self:_close_download_dialog()
    if self.download_task then self.download_task:set_backgrounded(false) end
    self._download_runtime=nil
    if not result or result.ok~=true then
        local err=result and result.error or "未知下载错误"
        logger.warn("[MiuRead][Download] failed",tostring(err))
        if tostring(err)=="下载已取消" then
            self.store:clear_download_state()
            self:_update_open_shelf_download_status(b.bookId,"生成已取消")
            self:_notify_home_data_changed("content")
            if was_background then self:status_toast("觅阅","下载已取消",3) else self:toast("下载已取消",3) end
            self:_start_next_queued_download()
            return
        end
        local auth_required=Http.is_auth_error(err)
        local rate_limited=Http.is_rate_limit_error(err)
        local network_failed=Http.is_network_error and Http.is_network_error(err)
        local content_pending=tostring(err):find("[MiuReadAnnotationPending]",1,true)~=nil
        local validation_failed=tostring(err):find("EPUB 完整性验证失败",1,true)~=nil
        local wait_seconds=tonumber(tostring(err):match("wait_seconds=(%d+)"))
        if auth_required then self:_mark_auth_problem("download",err,true) end
        self:_write_download_state("failed",{
            title=b.title,book_id=b.bookId,book=U.copy(b),options=U.copy(opt),
            error=tostring(err),stage=runtime.last_state and runtime.last_state.stage,
            current=runtime.last_state and runtime.last_state.current,total=runtime.last_state and runtime.last_state.total,
            percent=runtime.last_state and runtime.last_state.percent,seen=false,
            auth_required=auth_required or nil,
            error_kind=auth_required and "authentication" or (rate_limited and "rate_limit"
                or (network_failed and "network" or (content_pending and "content_pending"
                or (validation_failed and "validation" or nil)))),
            wait_seconds=rate_limited and wait_seconds or nil,
        },true)
        self:_update_open_shelf_download_status(b.bookId,
            auth_required and "等待重新登录" or (rate_limited and "请求受限 · 稍后继续"
                or (network_failed and "等待网络 · 可继续" or "生成未完成")))
        self:_notify_home_data_changed("content")
        local first
        if auth_required then
            first="微信读书登录已失效。下载断点已经保留，请重新扫码登录后继续。"
        elseif rate_limited then
            first="微信读书暂时限制了请求频率。插件已停止继续请求，正文和断点均已保留，请稍后继续下载。"
        elseif network_failed then
            first="网络连接暂时中断。已完成章节和下载断点均已保留，网络恢复后可继续下载。"
        elseif content_pending then
            first="生成未完成，原文件和下载进度已保留。请稍后使用“生成／更新书籍”重试。"
        elseif validation_failed then
            first="生成的书籍校验未通过，原文件和下载进度已保留。请重试；若仍失败，请反馈日志。"
        else
            first=U.first_line(err)
        end
        if was_background then
            local toast_title=auth_required and "下载登录验证失败" or (rate_limited and "请求受限"
                or (network_failed and "等待网络" or "觅阅"))
            local toast_text=auth_required and "后台下载已暂停，重新扫码后自动继续"
                or (rate_limited and "已停止继续请求，下载断点已保留"
                or (network_failed and "下载断点已保留，网络恢复后可继续"
                or (content_pending and "生成未完成，原文件和进度已保留"
                or (tostring(b.title or "未命名").."下载未完成，进度已保留"))))
            self:status_toast(toast_title,toast_text,5)
        else self:info(first) end
        -- Any failed book pauses the single waiting task. The user decides whether
        -- to retry the current book or skip it, avoiding repeated requests after an
        -- account, network, validation or content problem.
        if #self.store:download_queue()>0 then
            self:status_toast("下载队列","等待任务已暂停，请先处理当前失败任务",5)
        end
        return
    end
    self:_mark_auth_channel_ok("download")
    local rec=self:_merge_download_result(result,b,opt)
    if opt.annotations==true then
        if DownloadResult.annotation_pending(rec) then
            local kind=tostring(rec.annotation_error_kind or ((rec.annotation_summary or {}).error_kind) or "incomplete")
            local errors=type(rec.annotation_summary)=="table" and rec.annotation_summary.errors or nil
            local detail="划线与想法未完整获取"
            if type(errors)=="table" and #errors>0 then
                local first=errors[1]
                detail=type(first)=="table" and tostring(first.error or detail) or tostring(first or detail)
            end
            if kind=="forbidden" then
                self:_mark_auth_access_denied("annotations",detail,true)
            elseif kind=="authentication" then
                self:_mark_auth_problem("annotations",detail,true)
            else
                self:_mark_auth_channel_error("annotations",detail)
            end
        else
            self:_mark_auth_channel_ok("annotations")
        end
    end
    if rec.pending_install and tostring(self:_current_document_path() or "")~=tostring(rec.file or "") then
        self:_install_pending_downloads(false)
        self.store:reload()
        local kind=rec.variant or (opt.annotations and "notes" or "clean")
        local refreshed=opt.chapter_uid and self.store:chapter_variant(b.bookId,opt.chapter_uid,kind)
            or self.store:variant(b.bookId,kind)
        if refreshed then rec=U.copy(refreshed) end
    end
    self:_refresh_local_files()
    local pending=rec.pending_install==true and rec.pending_file and U.file_exists(rec.pending_file)
    local annotation_pending=DownloadResult.annotation_pending(rec)
    local annotation_fallback=DownloadResult.annotation_fallback(rec)
    self:_update_open_shelf_download_status(b.bookId,DownloadResult.shelf_status(rec,pending))
    if pending or annotation_pending then
        self:_write_download_state(DownloadResult.state(rec,pending),{
            title=b.title,book_id=b.bookId,book=U.copy(b),options=U.copy(opt),file=rec.file,
            pending_file=pending and rec.pending_file or nil,pending_install=pending or nil,percent=1,
            current=rec.chapter_count,total=rec.expected_chapter_count,completed_at=os.time(),
            annotation_pending=annotation_pending or nil,
            annotation_fallback=annotation_fallback or nil,
            annotation_error_kind=rec.annotation_error_kind,
        },true)
    else
        self.store:clear_download_state()
    end
    self:_notify_home_data_changed("content")
    if done then done(rec,was_background); self:_start_next_queued_download(); return end
    if pending then
        local text=DownloadResult.notice(b.title,rec,true)
        if was_background then self:status_toast("觅阅",text,5) else self:info(text) end
    elseif was_background then
        if self.store:preferences().download_complete_notice~=false or annotation_pending or annotation_fallback then
            self:status_toast("觅阅",DownloadResult.notice(b.title,rec,false),5)
        end
    elseif open_after and rec.file then
        if not annotation_pending then self.store:clear_download_state() end
        self:open_file(rec.file)
    else
        self:_show_download_complete(rec,opt,b)
    end
    self:_start_next_queued_download()
end
function Plugin:_recover_download_state()
    local state=self.store:download_state()
    if state.status~="active" then return false end
    local runtime={
        book=U.copy(state.book or {bookId=state.book_id,title=state.title}),
        options=U.copy(state.options or {}),
        last_state={stage=state.stage,current=state.current,total=state.total,percent=state.percent,
            chapter=state.chapter,message=state.message},
        background=true,dialog=nil,started_at=state.started_at,task=U.copy(state.task),
        open_after=false,done=nil,recovered=true,
    }
    if type(runtime.task)=="table" then
        self._download_runtime=runtime
        local ok,err=self.download_task:attach(runtime.task,
            function(progress) self:_on_download_progress(runtime,progress) end,
            function(result) self:_finish_download_runtime(runtime,result) end,
            runtime.book,runtime.options)
        if ok then
            runtime.task=self.download_task:descriptor() or runtime.task
            self.download_task:set_backgrounded(true)
            self:_write_download_state("active",self:_active_download_payload(runtime,runtime.last_state),true)
            logger.info("[MiuRead][Download] active task recovered","pid=",tostring(runtime.task.pid),
                "book=",tostring(runtime.book.bookId or ""))
            return true
        end
        self._download_runtime=nil
        logger.warn("[MiuRead][Download] active task recovery failed",tostring(err))
    end
    state.status="interrupted"
    state.error="上次下载已停止，已完成内容仍保存在断点缓存；再次下载时会继续。"
    state.updated_at=os.time()
    self.store:save_download_state(state)
    return false
end
function Plugin:_download_percent(state)
    state=state or {}
    local p=tonumber(state.percent)
    if not p then
        local current,total=tonumber(state.current) or 0,tonumber(state.total) or 0
        p=total>0 and current/total or 0
    elseif p>1 then p=p/100 end
    if p<0 then p=0 elseif p>1 then p=1 end
    return math.floor(p*100+0.5)
end
function Plugin:_download_state()
    local runtime=self._download_runtime
    if runtime and self.download_task and self.download_task:busy() then
        local state=U.copy(runtime.last_state or {})
        state.status="active"
        state.title=runtime.book and runtime.book.title or state.title
        state.book_id=runtime.book and runtime.book.bookId or state.book_id
        state.background=runtime.background==true
        return state
    end
    return self.store:download_state()
end
function Plugin:_has_download_status()
    if self.download_task and self.download_task:busy() then return true end
    local state=self.store:download_state()
    if state.status=="completed" then self.store:clear_download_state(); return false end
    return state.status=="failed" or state.status=="interrupted" or state.status=="pending_install"
        or state.status=="annotation_pending"
end
function Plugin:_download_status_label()
    local state=self:_download_state()
    if state.status=="active" then
        if state.stage=="rate_limit" then
            local wait=tonumber(state.wait_seconds) or 0
            return wait>0 and ("后台下载 · 请求受限，"..tostring(wait).."秒后继续") or "后台下载 · 请求受限，等待恢复"
        end
        if state.stage=="restart" then return "后台下载 · 正在从断点恢复" end
        if state.waiting_network==true then return "后台下载 · 等待网络" end
        local title=U.utf8_truncate(state.title or "未命名",9)
        return "后台下载：《"..title.."》 "..tostring(self:_download_percent(state)).."%"
    end
    if state.status=="pending_install" then
        return "后台下载 · 等待更新"
    end
    if state.status=="annotation_pending" then return "后台下载 · 生成未完成" end
    if state.status=="completed" then return "后台下载 · 已完成" end
    if state.status=="failed" and state.auth_required==true then return "后台下载 · 等待重新登录" end
    if state.status=="failed" and state.error_kind=="network" then return "后台下载 · 等待网络，可继续" end
    if state.status=="failed" then return "后台下载 · 未完成" end
    if state.status=="interrupted" then return "后台下载 · 可继续" end
    return "后台下载"
end
function Plugin:_write_download_state(status,patch,force)
    local now=os.time()
    local stage=patch and patch.stage
    if not force and status=="active" and now-(self._download_state_last_write or 0)<2 and stage==self._download_state_last_stage then return end
    local state
    if force or status~="active" then state=U.copy(patch or {})
    else state=U.merge(self.store:download_state(),patch or {}) end
    state.status=status
    state.updated_at=now
    self.store:save_download_state(state)
    self._download_state_last_write=now
    self._download_state_last_stage=stage
end
function Plugin:_active_download_payload(runtime,state)
    local task=(self.download_task and self.download_task:descriptor()) or runtime.task
    return {
        title=runtime.book and runtime.book.title or "未命名",
        book_id=runtime.book and runtime.book.bookId or "",
        book=U.copy(runtime.book or {}),
        options=U.copy(runtime.options or {}),
        background=runtime.background==true,
        stage=state and state.stage or "prepare",
        current=state and state.current or 0,
        total=state and state.total or 0,
        percent=state and state.percent or 0,
        chapter=state and state.chapter or "",
        message=state and state.message or "",
        waiting_network=state and state.waiting_network==true or nil,
        wait_seconds=state and state.wait_seconds or nil,
        rate_limit_code=state and state.rate_limit_code or nil,
        started_at=runtime.started_at,
        task=U.copy(task),
    }
end
function Plugin:_close_download_dialog()
    local runtime=self._download_runtime
    if not runtime or not runtime.dialog then return end
    local dialog=runtime.dialog
    runtime.dialog=nil
    pcall(function() dialog:close() end)
end
function Plugin:_send_download_to_background()
    local runtime=self._download_runtime
    if not runtime or not self.download_task or not self.download_task:busy() then return end
    runtime.background=true
    self:_close_download_dialog()
    self.download_task:set_backgrounded(true)
    self:_write_download_state("active",self:_active_download_payload(runtime,runtime.last_state),true)
    self:status_toast("觅阅",tostring(runtime.book.title or "未命名").."已转入后台下载",3)
end
function Plugin:_show_active_download_dialog()
    local runtime=self._download_runtime
    if not runtime or not self.download_task or not self.download_task:busy() then self:show_download_status(); return end
    if runtime.dialog then return end
    runtime.background=false
    self.download_task:set_backgrounded(false)
    local dialog
    dialog=DownloadProgress:new{
        title="正在下载《"..tostring(runtime.book.title or "未命名").."》",
        on_cancel=function() if self.download_task then self.download_task:cancel() end end,
        on_background=function() self:_send_download_to_background() end,
    }
    runtime.dialog=dialog
    dialog:show()
    if runtime.last_state then dialog:set_state(runtime.last_state) end
    self:_write_download_state("active",self:_active_download_payload(runtime,runtime.last_state),true)
end
function Plugin:_merge_download_result(result,book,opt)
    self.store:reload()
    if type(result.auth)=="table" then
        local current=self.store:auth()
        local current_account=type(current.account)=="table" and current.account or {}
        local child_account=type(result.auth.account)=="table" and result.auth.account or {}
        local snapshot=type(result.auth_snapshot)=="table" and result.auth_snapshot or {}
        local snapshot_vid=tostring(snapshot.vid or child_account.vid or "")
        local snapshot_logged=tonumber(snapshot.logged_at or child_account.logged_at or 0) or 0
        local same_login=snapshot_vid~=""
            and snapshot_vid==tostring(current_account.vid or "")
            and snapshot_logged==tonumber(current_account.logged_at or 0)
        if same_login then
            local merged_cookies=U.copy(current.cookies or {})
            local core={wr_vid=true,wr_skey=true,wr_rt=true}
            local child_ticket_time=tonumber(result.auth.ticket_updated_at or 0) or 0
            local current_ticket_time=tonumber(current.ticket_updated_at or 0) or 0
            for name,value in pairs(result.auth.cookies or {}) do
                if not core[name] or child_ticket_time>=current_ticket_time then
                    merged_cookies[name]=value
                end
            end
            merged_cookies=Cookies.sanitize(merged_cookies)
            current.cookies=merged_cookies
            if tostring(result.auth.api_key or "")~="" then current.api_key=result.auth.api_key end
            if child_ticket_time>=current_ticket_time then
                if tostring(result.auth.wr_ticket or "")~="" then current.wr_ticket=result.auth.wr_ticket end
                if tostring(result.auth.wr_wrpa or "")~="" then current.wr_wrpa=result.auth.wr_wrpa end
                if child_ticket_time>current_ticket_time then current.ticket_updated_at=child_ticket_time end
            end
            self.store:save_auth(current)
        else
            logger.warn("[MiuRead][Download] child authentication merge skipped",
                "snapshot_vid=",snapshot_vid,
                "current_vid=",tostring(current_account.vid or ""),
                "snapshot_logged_at=",tostring(snapshot_logged),
                "current_logged_at=",tostring(current_account.logged_at or 0))
        end
    end

    local rec=result.value or {}
    local kind=rec.variant or (opt.annotations and "notes" or "clean")
    if opt.chapter_uid then self.store:save_chapter_variant(book.bookId,opt.chapter_uid,kind,rec)
    else self.store:save_variant(book.bookId,kind,rec) end
    if rec.pending_install==true and rec.pending_file then
        self.store:add_pending_install(book.bookId,kind,opt.chapter_uid,rec)
    else
        self.store:remove_pending_install(book.bookId,kind,opt.chapter_uid)
    end
    local existing_book=self.store:book(book.bookId)
    local preserve_catalog=opt.chapter_uid~=nil or rec.partial_range==true
    local catalog=preserve_catalog and existing_book and existing_book.catalog or rec.chapter_map
    self.store:save_book(book.bookId,{
        book_id=tostring(book.bookId),title=book.title,author=book.author,cover=book.cover,
        directory=rec.directory,updated_at=os.time(),catalog=catalog,access=nil,
        content_type=book.content_type,
    })
    if type(self.store.clear_book_access)=="function" then self.store:clear_book_access(book.bookId) end
    self.access:unlock_book(book.bookId,"all")

    if type(result.session)=="table" then
        local allowed={"psvts","pclts","token","reader_url","chapters","context_updated_at","app_id"}
        local patch={}
        for _,key in ipairs(allowed) do if result.session[key]~=nil then patch[key]=result.session[key] end end
        if next(patch) then self.store:save_session(book.bookId,patch) end
    end
    return rec
end
function Plugin:_show_download_complete(rec,opt,book)
    local dialog
    local buttons={
        {{text="立即阅读",callback=function() UIManager:close(dialog); self:open_file(rec.file) end}},
    }
    buttons[#buttons+1]={{text="关闭",callback=function() UIManager:close(dialog) end}}
    dialog=ButtonDialog:new{title=self:_download_summary(rec,opt),title_align="center",buttons=buttons}
    UIManager:show(dialog)
end
function Plugin:show_download_status()
    if self.download_task and self.download_task:busy() then self:_show_active_download_dialog(); return end
    local state=self.store:download_state()
    if not state.status or state.status=="" then self:info("当前没有后台下载记录。") return end
    if state.status=="completed" then
        self.store:clear_download_state()
        self:info("下载已经完成，记录已自动清除。\n\n可在下载管理的已完成列表中打开书籍。")
        return
    end
    local title=tostring(state.title or "未命名")
    local lines={}
    if state.status=="completed" then lines[#lines+1]="下载完成"
    elseif state.status=="annotation_pending" then lines[#lines+1]="生成未完成，请稍后重新生成"
    elseif state.status=="pending_install" then
        if state.annotation_pending==true then lines[#lines+1]="新版本已下载完成"
        elseif state.annotation_fallback==true then lines[#lines+1]="新版本已下载完成"
        else lines[#lines+1]="新版本已下载完成" end
    elseif state.status=="failed" and state.auth_required==true then lines[#lines+1]="等待重新登录"
    elseif state.status=="failed" and state.error_kind=="rate_limit" then lines[#lines+1]="请求频率受限，稍后可继续"
    elseif state.status=="failed" and state.error_kind=="network" then lines[#lines+1]="网络中断，断点已保留"
    elseif state.status=="failed" then lines[#lines+1]="下载未完成"
    elseif state.status=="interrupted" then lines[#lines+1]="上次下载已中断"
    else lines[#lines+1]=tostring(state.status) end
    lines[#lines+1]="《"..title.."》"
    if state.current and state.total and tonumber(state.total)>0 then lines[#lines+1]="章节 "..tostring(state.current).." / "..tostring(state.total) end
    if state.error and state.error~="" then lines[#lines+1]="\n"..U.first_line(state.error) end
    if state.status=="pending_install" then lines[#lines+1]="\n关闭当前书籍后会自动安装新版本。" end
    local buttons={}
    local dialog
    if (state.status=="completed" or state.status=="annotation_pending") and state.file and U.file_exists(state.file) then
        buttons[#buttons+1]={{text="立即阅读",callback=function()
            UIManager:close(dialog)
            if state.status~="annotation_pending" then self.store:clear_download_state() end
            self:open_file(state.file)
        end}}
    end
    if state.status=="annotation_pending" and type(state.book)=="table" then
        buttons[#buttons+1]={{text="重新生成",callback=function()
            UIManager:close(dialog)
            self:choose_download(state.book,nil,false)
        end}}
    elseif state.status=="failed" and state.auth_required==true then
        buttons[#buttons+1]={{text="重新扫码登录",callback=function() UIManager:close(dialog); self.auth_flow:start() end}}
    elseif (state.status=="failed" or state.status=="interrupted") and type(state.book)=="table" then
        buttons[#buttons+1]={{text="继续下载",callback=function() UIManager:close(dialog); self:download(state.book,state.options or {},false) end}}
    end
    if (state.status=="failed" or state.status=="interrupted") and #self.store:download_queue()>0 then
        buttons[#buttons+1]={{text="跳过并开始等待书籍",callback=function()
            UIManager:close(dialog); self.store:clear_download_state(); self:_start_next_queued_download()
        end}}
        buttons[#buttons+1]={{text="停止全部下载",callback=function()
            UIManager:close(dialog); self.store:clear_download_state(); self.store:save_download_queue({}); self:toast("下载任务已全部停止")
        end}}
    end
    buttons[#buttons+1]={{text="清除记录",callback=function() UIManager:close(dialog); self.store:clear_download_state() end}}
    buttons[#buttons+1]={{text="关闭",callback=function() UIManager:close(dialog) end}}
    dialog=ButtonDialog:new{title=table.concat(lines,"\n"),title_align="center",buttons=buttons}
    UIManager:show(dialog)
end
function Plugin:_install_pending_record(book_id,kind,chapter_uid,record)
    local pending=tostring(record and record.pending_file or "")
    local target=tostring(record and record.file or "")
    if pending=="" or target=="" or not U.file_exists(pending) then return false,"等待安装文件不存在" end
    local validation={book_id=book_id,variant=record.variant or kind,chapters=record.chapter_map,
        previous_chapters=record.previous_chapter_map}
    local ok,mode_or_error=EpubInstaller.install(pending,target,validation)
    if not ok then return false,"无法安装新 EPUB："..tostring(mode_or_error) end
    local updated=U.copy(record)
    updated.pending_file=nil
    updated.pending_install=nil
    updated.previous_chapter_map=nil
    updated.installed_at=os.time()
    updated.file_size=U.file_size(target)
    if chapter_uid then self.store:save_chapter_variant(book_id,chapter_uid,kind,updated)
    else self.store:save_variant(book_id,kind,updated) end
    self.store:remove_pending_install(book_id,kind,chapter_uid)
    return true,updated
end

function Plugin:_install_pending_downloads(notify)
    local current=tostring(self:_current_document_path() or "")
    self.store:reload()
    local pending=self.store:prune_pending_installs()
    if #pending==0 then return false end
    local installed_records={}
    for _,item in ipairs(pending) do
        local book_id=tostring(item.book_id or "")
        local kind=tostring(item.kind or "")
        local chapter_uid=item.chapter_uid and tostring(item.chapter_uid) or nil
        local book=self.store:book(book_id)
        local record
        if chapter_uid then
            local row=book and book.chapters and book.chapters[chapter_uid]
            record=row and row[kind]
        else
            record=book and book.variants and book.variants[kind]
        end
        if not record or record.pending_install~=true or not U.file_exists(record.pending_file) then
            self.store:remove_pending_install(book_id,kind,chapter_uid)
        elseif tostring(record.file or "")~=current then
            local ok,value=self:_install_pending_record(book_id,kind,chapter_uid,record)
            if ok then
                value.book_id=value.book_id or book_id
                value._kind=kind
                value._chapter_uid=chapter_uid
                installed_records[#installed_records+1]=value
            else
                logger.warn("[MiuRead][Download] pending install failed",tostring(value))
            end
        end
    end
    local installed=#installed_records
    if installed>0 then
        local remaining=self.store:prune_pending_installs()
        local state=self.store:download_state()
        local aggregate=DownloadResult.aggregate(installed_records)
        local any_pending=aggregate.annotation_pending==true
        local any_fallback=aggregate.annotation_fallback==true
        local pending_record,last_record=nil,installed_records[#installed_records]
        for _,record in ipairs(installed_records) do
            if record.annotation_pending==true and not pending_record then pending_record=record end
        end
        if #remaining==0 then
            state.status=any_pending and "annotation_pending" or "completed"
            state.annotation_pending=any_pending or nil
            state.annotation_fallback=any_fallback or nil
            state.annotation_error_kind=pending_record and pending_record.annotation_error_kind or nil
            state.pending_install=nil
            state.pending_file=nil
            state.seen=false
            if installed==1 then
                local record=installed_records[1]
                state.file=record.file
                state.book_id=record.book_id
                local stored=self.store:book(record.book_id)
                state.title=stored and stored.title or record.title
                state.book=stored and {bookId=record.book_id,title=stored.title,author=stored.author,cover=stored.cover} or nil
                state.options=self:_annotation_retry_options(record._kind,record,record._chapter_uid)
            else
                state.file=pending_record and pending_record.file or (last_record and last_record.file)
                state.book=nil
                state.options=nil
                state.title="多个新版本"
            end
        else
            state.status="pending_install"
            state.pending_install=true
            state.annotation_pending=any_pending or state.annotation_pending
            state.annotation_fallback=any_fallback or state.annotation_fallback
        end
        state.updated_at=os.time()
        self.store:save_download_state(state)
        self:_refresh_local_files()
        if notify then
            local text
            if any_pending then text=installed>1 and "多个新版本已安装" or "新版本已安装"
            elseif any_fallback then text=installed>1 and "多个新版本已安装" or "新版本已安装"
            else text=installed>1 and "多个新版本已安装" or "新版本已安装" end
            self:status_toast("觅阅",text,4)
        end
        return true
    end
    return false
end

function Plugin:_download_job_key(book,opt)
    opt=opt or {}
    local kind=opt.annotations and "notes" or "clean"
    return table.concat({
        tostring(book and book.bookId or ""),kind,tostring(opt.chapter_uid or "full"),
        tostring(opt.limit or "all"),tostring(opt.range_start_index or ""),
        tostring(opt.range_end_index or ""),
    },":")
end
function Plugin:_queue_download(book,opt,open_after,extra)
    extra=type(extra)=="table" and extra or {}
    local key=self:_download_job_key(book,opt)
    local book_id=tostring(book and (book.bookId or book.book_id) or "")
    local runtime=self._download_runtime
    local runtime_id=tostring(runtime and runtime.book and (runtime.book.bookId or runtime.book.book_id) or "")
    if runtime and ((book_id~="" and runtime_id==book_id) or self:_download_job_key(runtime.book,runtime.options)==key) then
        self:info("这本书已经在下载中。\n\n请在下载管理中查看当前状态。")
        return false
    end
    local queue=self.store:download_queue()
    for _,job in ipairs(queue) do
        local queued_id=tostring(job.book and (job.book.bookId or job.book.book_id) or "")
        if (book_id~="" and queued_id==book_id) or tostring(job.key or "")==key then
            self:info("这本书已经在等待下载。\n\n请在下载管理中查看或移除等待任务。")
            return false
        end
    end
    local job={key=key,book=U.copy(book or {}),options=U.copy(opt or {}),open_after=open_after==true,
        queued_at=os.time(),defer_until_reader_closed=extra.defer_until_reader_closed==true or nil,
        wait_reason=extra.reason}
    local position,reason=self.store:enqueue_download(job)
    if not position then
        if reason=="full" then
            local waiting=queue[1] or {}
            local waiting_title=tostring(waiting.book and waiting.book.title or "未命名")
            local new_title=tostring(book and book.title or "未命名")
            local dialog
            dialog=ButtonDialog:new{title="等待位置中已有《"..waiting_title.."》。\n\n最多只能有一本正在下载、一本等待。",title_align="center",buttons={
                {{text="替换为《"..U.utf8_truncate(new_title,12).."》",callback=function()
                    UIManager:close(dialog)
                    self.store:save_download_queue({job})
                    self:status_toast("下载队列","等待任务已替换",3)
                    self:_notify_home_data_changed("content")
                end}},
                {{text="保留原等待任务",callback=function() UIManager:close(dialog) end}},
                {{text="查看下载",callback=function() UIManager:close(dialog); self:show_downloads() end}},
            }}
            UIManager:show(dialog)
        else
            self:info("暂时无法加入下载队列。")
        end
        return false
    end
    local title=extra.defer_until_reader_closed and "已安排退出阅读后下载" or "新的任务已加入等待"
    self:status_toast("下载队列",title,3)
    self:_notify_home_data_changed("content")
    return true
end
function Plugin:_start_next_queued_download()
    if self.download_task and self.download_task:busy() then return false end
    if self._download_runtime then return false end
    local state=self.store:download_state()
    if state.status=="active" or state.status=="failed" or state.status=="interrupted" then
        return false
    end
    if not self:is_online() or not self:logged_in() then return false end
    local queue=self.store:download_queue()
    local next_job=queue[1]
    if not next_job then return false end
    if next_job.defer_until_reader_closed==true and self:_active_reader_ui() then return false end
    local job=self.store:dequeue_download()
    if not job then return false end
    UIManager:scheduleIn(.15,function()
        self:download(job.book or {},job.options or {},job.open_after==true,nil,true,true)
    end)
    return true
end
function Plugin:show_waiting_downloads()
    local queue=self.store:download_queue()
    if #queue==0 then self:info("当前没有等待下载的任务。") return end
    local job=queue[1]
    local title=tostring(job.book and job.book.title or "未命名")
    local variant=(job.options and job.options.annotations) and "划线与想法版" or "纯净版"
    if job.options and job.options.range_start_index then variant="章节版 · "..variant end
    if job.defer_until_reader_closed==true then variant=variant.." · 退出阅读后开始" end
    local items={
        {text=title,post_text=variant,callback=function()
            UIManager:show(ConfirmBox:new{text="从等待队列移除《"..title.."》？",ok_text="移除",cancel_text="保留",ok_callback=function()
                self.store:remove_queued_download(1); self:toast("已移出等待队列")
            end})
        end},
    }
    self:list("等待下载 · 最多一本",items)
end

function Plugin:download(b,opt,open_after,done,start_in_background,from_queue)
    if not self:require_login() then return end
    if not self:is_online() then self:info(_("Network unavailable")); return end
    opt=U.copy(opt or {})
    local requested_id=tostring(b and (b.bookId or b.book_id) or "")
    if from_queue~=true and requested_id~="" then
        for _,job in ipairs(self.store:download_queue()) do
            local queued_id=tostring(job.book and (job.book.bookId or job.book.book_id) or "")
            if queued_id==requested_id then
                self:info("这本书已经在等待下载。\n\n请在下载管理中查看或移除等待任务。")
                return false
            end
        end
    end
    if self.download_task and self.download_task:busy() then
        if from_queue then
            self:_queue_download(b,opt,open_after)
            return false
        end
        return self:_queue_download(b,opt,open_after)
    end
    local stored=self.store:download_state()
    if stored.status=="active" and self:_recover_download_state() then
        if from_queue then
            self:_queue_download(b,opt,open_after)
            return false
        end
        return self:_queue_download(b,opt,open_after)
    end
    if self.cache_cleanup_task and self.cache_cleanup_task:busy() then self:info("缓存正在清理，完成后再开始下载。"); return end
    if b and b.bookId and tostring(b.bookId)~="" then
        self.store:save_book(b.bookId,{book_id=tostring(b.bookId),title=b.title,author=b.author,
            content_type=b.content_type,updated_at=os.time()})
    end
    local prefs=self.store:preferences()
    opt.images=prefs.images
    opt.active_document_path=self:_current_document_path()
    local runtime={book=U.copy(b),options=U.copy(opt),last_state={stage="prepare",current=0,total=1,percent=0,chapter=b.title or ""},background=start_in_background==true,dialog=nil,started_at=os.time(),open_after=open_after==true,done=done,notified_milestones={}}
    self._download_runtime=runtime
    self:_write_download_state("active",self:_active_download_payload(runtime,runtime.last_state),true)
    self:_notify_home_data_changed("content")
    local ok,err=self.download_task:start(b,opt,
        function(state) self:_on_download_progress(runtime,state) end,
        function(result) self:_finish_download_runtime(runtime,result) end)
    if not ok then
        self._download_runtime=nil
        self.store:clear_download_state()
        self:_notify_home_data_changed("content")
        if from_queue then self:_queue_download(b,opt,open_after) end
        self:info("无法启动下载任务：\n"..tostring(err))
        return false
    end
    runtime.task=self.download_task:descriptor()
    self:_write_download_state("active",self:_active_download_payload(runtime,runtime.last_state),true)
    if runtime.background then
        self.download_task:set_backgrounded(true)
        self:_update_open_shelf_download_status(b.bookId,"生成中 0%")
        if self.store:preferences().download_notice_enabled~=false then
            self:status_toast("觅阅",tostring(b.title or "未命名").."已转入后台下载",3)
        end
    else
        self:_show_active_download_dialog()
    end
end



function Plugin:_range_variant(book_id,kind)
    local record=self.store:variant(book_id,kind)
    if record and record.file and U.file_exists(record.file) and record.partial_range==true then return record end
end
function Plugin:_has_range_variant(book_id)
    return self:_range_variant(book_id,"range_notes")~=nil or self:_range_variant(book_id,"range_clean")~=nil
end
function Plugin:range_extend_menu(b)
    local items={}
    local clean=self:_range_variant(b.bookId,"range_clean")
    local notes=self:_range_variant(b.bookId,"range_notes")
    if clean then items[#items+1]={text="扩展章节版 · 纯净版",callback=function() self:show_range_extend_options(b,false,clean) end} end
    if notes then items[#items+1]={text="扩展章节版 · 划线与想法版",callback=function() self:show_range_extend_options(b,true,notes) end} end
    if #items==0 then return {{text="当前没有可扩展的章节版",enabled=false}} end
    return items
end
function Plugin:show_range_extend_options(b,annotations,record)
    self:online("range-extend",function()
        local _,rows=self.downloader:catalog(b.bookId)
        rows=rows or {}
        local first=math.max(1,tonumber(record.range_start_index) or 1)
        local last=math.min(#rows,tonumber(record.range_end_index) or first)
        local items={}
        for _,count in ipairs({5,10,20}) do
            local target=math.min(#rows,last+count)
            items[#items+1]={text="追加后续 "..tostring(math.max(0,target-last)).." 章",enabled=target>last,
                callback=function()
                    self:choose_download_mode(b,{annotations=annotations,range_start_index=first,range_end_index=target,
                        range_start_title=rows[first] and rows[first].title,range_end_title=rows[target] and rows[target].title},false)
                end}
        end
        items[#items+1]={text="扩展到指定章节",enabled=last<#rows,callback=function()
            self:_chapter_list_menu(b,rows,"选择新的结束章节",function(target)
                self:choose_download_mode(b,{annotations=annotations,range_start_index=first,range_end_index=target,
                    range_start_title=rows[first] and rows[first].title,range_end_title=rows[target] and rows[target].title},false)
            end,last+1)
        end}
        items[#items+1]={text="重新选择章节范围",callback=function() self:chapters(b) end}
        self:list("扩展章节版 · 当前 "..tostring(last-first+1).." 章",items)
    end)
end
function Plugin:_current_catalog_index(record,rows)
    if not record or not record.record then return nil end
    local local_map=record.record.chapter_map or {}
    if #local_map==0 then return nil end
    local ratio=self.sync:local_ratio() or 0
    local position=self.sync:position(record,ratio,local_map)
    local uid=tostring(position and position.chapter_uid or "")
    if uid=="" then
        local local_index=math.max(1,math.min(#local_map,math.floor(ratio*#local_map)+1))
        local chapter=local_map[local_index] or {}
        uid=tostring(chapter.uid or chapter.chapterUid or chapter.chapter_uid or "")
    end
    if uid~="" then
        for index,chapter in ipairs(rows or {}) do
            if tostring(chapter.chapterUid or chapter.uid or "")==uid then return index end
        end
    end
    local local_index=math.max(1,math.min(#local_map,math.floor(ratio*#local_map)+1))
    local hinted=tonumber(local_map[local_index] and local_map[local_index].index)
    if hinted and rows and rows[hinted] then return hinted end
    return nil
end
function Plugin:download_current_chapters(count)
    local record=self:_current_book_record()
    if not record or not record.book then self:info("当前不是觅阅生成的书籍。") return end
    local b={bookId=record.book.book_id,title=record.book.title,author=record.book.author,cover=record.book.cover}
    local wanted=math.max(1,tonumber(count) or 1)
    self:online("current-chapter-download",function()
        local _,rows=self.downloader:catalog(b.bookId)
        rows=rows or {}
        local first=self:_current_catalog_index(record,rows)
        if not first or not rows[first] then self:info("暂时无法确定当前章节，请使用“选择章节范围”。") return end
        local last=math.min(#rows,first+wanted-1)
        self:_choose_range_version(b,rows,first,last,false)
    end)
end

function Plugin:_chapter_state_text(book_id,chapter)
    local uid=tostring(chapter.chapterUid or chapter.uid or "")
    local states={}
    for _,entry in ipairs({{"clean","纯净版"},{"notes","划线与想法版"}}) do
        local record=self.store:chapter_variant(book_id,uid,entry[1])
        if record and record.file and U.file_exists(record.file) then states[#states+1]=entry[2] end
    end
    return #states>0 and table.concat(states," · ") or tostring(chapter.wordCount or "")
end
function Plugin:_chapter_list_menu(b,rows,title,callback,start_index)
    local items={}
    for index,ch in ipairs(rows or {}) do
        if not start_index or index>=start_index then
            local chapter=ch
            items[#items+1]={
                text=chapter.title or tostring(chapter.chapterUid or chapter.uid or index),
                post_text=self:_chapter_state_text(b.bookId,chapter),
                callback=function() callback(index,chapter) end,
            }
        end
    end
    self:list(title,items,"没有可用章节")
end
function Plugin:_choose_range_version(b,rows,first,last,open_after)
    first=math.max(1,tonumber(first) or 1)
    last=math.min(#rows,tonumber(last) or first)
    if last<first then first,last=last,first end
    local first_ch,last_ch=rows[first],rows[last]
    local count=last-first+1
    local dialog
    local function choose(annotations)
        UIManager:close(dialog)
        self:choose_download_mode(b,{
            annotations=annotations,range_start_index=first,range_end_index=last,
            range_start_title=first_ch and first_ch.title,range_end_title=last_ch and last_ch.title,
        },open_after==true)
    end
    dialog=ButtonDialog:new{
        title="下载章节版\n"..tostring(first_ch and first_ch.title or ("第 "..first.." 章"))
            .." 至 "..tostring(last_ch and last_ch.title or ("第 "..last.." 章"))
            .."\n共 "..tostring(count).." 章",
        title_align="center",buttons={
            {{text="纯净版",callback=function() choose(false) end}},
            {{text="划线与想法版",callback=function() choose(true) end}},
            {{text="取消",callback=function() UIManager:close(dialog) end}},
        },
    }
    UIManager:show(dialog)
end
function Plugin:_range_count_menu(b,rows,first)
    local start_ch=rows[first]
    local items={}
    for _,count in ipairs({1,3,5,10,20}) do
        local actual=math.min(count,#rows-first+1)
        items[#items+1]={text="下载接下来 "..tostring(actual).." 章",post_text=actual<count and "已到全书末尾" or nil,
            callback=function() self:_choose_range_version(b,rows,first,first+actual-1,false) end}
    end
    items[#items+1]={text="选择结束章节",callback=function()
        self:_chapter_list_menu(b,rows,"选择结束章节",function(last) self:_choose_range_version(b,rows,first,last,false) end,first)
    end}
    self:list("从《"..tostring(start_ch and start_ch.title or "所选章节").."》开始",items)
end
function Plugin:chapters(b)
    self:online("chapters",function()
        local _,rows=self.downloader:catalog(b.bookId)
        rows=rows or {}
        local items={
            {text="下载单章",callback=function()
                self:_chapter_list_menu(b,rows,"选择单章 · "..tostring(b.title or "未命名"),function(_,chapter) self:chapter_menu(b,chapter) end)
            end},
            {text="下载章节范围",callback=function()
                self:_chapter_list_menu(b,rows,"选择起始章节",function(first)
                    self:_chapter_list_menu(b,rows,"选择结束章节",function(last) self:_choose_range_version(b,rows,first,last,false) end,first)
                end)
            end},
            {text="从指定章节开始",callback=function()
                self:_chapter_list_menu(b,rows,"选择起始章节",function(first) self:_range_count_menu(b,rows,first) end)
            end},
        }
        self:list("章节下载 · "..tostring(b.title or "未命名"),items,"没有可用章节")
    end)
end
function Plugin:chapter_menu(b,ch)
    local uid=tostring(ch.chapterUid or ch.uid or "")
    local clean=self.store:chapter_variant(b.bookId,uid,"clean")
    local notes=self.store:chapter_variant(b.bookId,uid,"notes")
    if not (clean and clean.file and U.file_exists(clean.file)) then clean=nil end
    if not (notes and notes.file and U.file_exists(notes.file)) then notes=nil end
    local items={}
    for _,entry in ipairs({{record=clean,label="纯净版"},{record=notes,label="划线与想法版"}}) do
        local record=entry.record
        if record then
            local label=DownloadResult.variant_label(entry.label,record)
            items[#items+1]={text="阅读"..label,callback=function() self:open_file(record.file) end}
        end
    end
    items[#items+1]={text=(clean or notes) and "更新本章" or "下载本章",callback=function() self:choose_download(b,nil,true,uid) end}
    if clean or notes then items[#items+1]={text="删除本章文件",callback=function() self:_confirm_delete_chapter_cache(b.bookId,uid,ch.title or uid) end} end
    self:list(ch.title or uid,items)
end

function Plugin:_open_file_direct(path)
    path=normalized_reader_file(path)
    if not path or not U.file_exists(path) then self:info(_("No cached file")); return false end
    sync_home_session()
    local now=os.time()
    local opening=tostring(HOME_SESSION.opening_file or "")
    local opening_age=now-(tonumber(HOME_SESSION.opening_at) or 0)
    if opening~="" and opening_age>=0 and opening_age<12 then
        if opening==path then
            logger.info("[MiuRead][Reader] duplicate open ignored",opening)
            self:status_toast("正在打开书籍","请稍候",2)
            return true
        end
        logger.info("[MiuRead][Reader] replacing pending open target",opening,"with",path)
    end
    HOME_SESSION.opening_file=path
    HOME_SESSION.opening_at=now

    if self:_home_enabled() and not HOME_NATIVE_VISIT and not HOME_SESSION_SUPPRESSED then
        HOME_RETURN_FILE=path
        mark_reader_origin(path)
        self._home_reader_transition=true
        self:_home_stop_background("reader opening")
        -- Leave only the root MiuRead home beneath ReaderUI. Closing the book
        -- can then reveal MiuRead immediately without walking back through old
        -- shelf or settings dialogs.
        self:_close_miuread_transients()
    end

    local function fail(err)
        if tostring(HOME_SESSION.opening_file or "")==path then
            HOME_SESSION.opening_file=nil
            HOME_SESSION.opening_at=0
        end
        self._home_reader_transition=false
        logger.warn("[MiuRead][Reader] open failed",path,tostring(err))
        local active=self:_active_reader_ui()
        if active and active.dialog then pcall(UIManager.setDirty,UIManager,active.dialog,"ui")
        else HomeView.raise() end
        self:info("书籍暂时无法打开：\n"..U.first_line(err,120))
        return false
    end

    if self.ui and self.ui.document and type(self.ui.switchDocument)=="function" then
        local ok,result=xpcall(function() return self.ui:switchDocument(path) end,debug.traceback)
        if not ok then return fail(result) end
        if result==false then return fail("KOReader 拒绝切换到目标书籍") end
        return result==nil and true or result
    end
    local ReaderUI=require("apps/reader/readerui")
    local ok,result=xpcall(function()
        UIManager:broadcastEvent(Event:new("SetupShowReader"))
        return ReaderUI:showReader(path)
    end,debug.traceback)
    if not ok then return fail(result) end
    if result==false then return fail("KOReader 拒绝打开目标书籍") end
    return result==nil and true or result
end

function Plugin:open_file(path)
    if not path then self:info(_("No cached file")); return end
    local book=self.store:identify_file(path,false)
    local book_id=book and tostring(book.book_id or book.bookId or "") or ""
    local resolved=book_id~="" and self.access:resolve_path(book_id,path) or path
    if not resolved or not U.file_exists(resolved) then self:info(_("No cached file")); return end
    self:_open_file_direct(resolved)
end

function Plugin:_current_document_path()
    local doc=self.ui and self.ui.document
    return doc and (doc.file or (doc.getFilePath and doc:getFilePath())) or nil
end
function Plugin:_variant_label(kind)
    kind=tostring(kind or "clean")
    local preview=kind:sub(1,8)=="preview_"
    local range=kind:sub(1,6)=="range_"
    local base=preview and kind:sub(9) or (range and kind:sub(7) or kind)
    local label=base=="notes" and "划线与想法版" or "纯净版"
    if preview then return "试读版 · "..label end
    if range then return "章节版 · "..label end
    return label
end
function Plugin:_close_download_menus()
    local detail=self._download_book_menu; self._download_book_menu=nil
    local root=self._downloads_menu; self._downloads_menu=nil
    if detail then pcall(function() UIManager:close(detail) end) end
    if root and root~=detail then pcall(function() UIManager:close(root) end) end
end
function Plugin:_cache_action_blocked()
    if self.download_task and self.download_task:busy() then self:info("下载任务进行中，暂时不能修改下载文件。") return true end
    local state=self.store:download_state()
    if state.status=="active" then self:info("后台下载状态正在恢复，暂时不能清理文件。") return true end
    if self.cache_cleanup_task and self.cache_cleanup_task:busy() then self:info("缓存任务正在运行，请勿重复操作。") return true end
    return false
end
local function human_size(bytes)
    bytes=tonumber(bytes) or 0
    if bytes>=1024*1024*1024 then return string.format("%.2f GB",bytes/(1024*1024*1024)) end
    if bytes>=1024*1024 then return string.format("%.1f MB",bytes/(1024*1024)) end
    if bytes>=1024 then return string.format("%.1f KB",bytes/1024) end
    return tostring(bytes).." B"
end
local function path_name(path) return tostring(path or ""):match("([^/]+)$") or "" end
local function is_download_temp_name(name)
    name=tostring(name or "")
    return name=="download-task-owner.json"
        or name:match("^download%-settings%-.+%.lua$")
        or name:match("^download%-progress%-.+%.json$")
        or name:match("^download%-result%-.+%.json$")
        or name:match("^download%-cancel%-.+")
end
local function is_epub_residue_name(name)
    name=tostring(name or "")
    return name:match("%.miuread%-new%-%d+%-%d+$")
        or name:match("%.miuread%-backup$")
        or name:match("%.miuread%-linkfix$")
        or name:match("%.miuread%-linkbak$")
end
local function is_pending_epub_name(name)
    return tostring(name or ""):match("%.miuread%-pending$")~=nil
end
function Plugin:_all_partial_cache_paths()
    local paths={}
    for _,book_path in ipairs(U.list(self.store.cache_books_dir)) do
        if lfs.attributes(book_path,"mode")=="directory" then
            for _,path in ipairs(U.list(book_path)) do
                if path_name(path):match("^%.miuread%-partial%-") then paths[#paths+1]=path end
            end
        end
    end
    return paths
end
function Plugin:_download_residue_paths()
    local paths={}
    for _,path in ipairs(U.list(self.store.temp_dir)) do
        if is_download_temp_name(path_name(path)) then paths[#paths+1]=path end
    end
    for _,path in ipairs(U.list(self.store:books_root())) do
        if is_epub_residue_name(path_name(path)) then paths[#paths+1]=path end
    end
    for _,path in ipairs(self:_all_partial_cache_paths()) do paths[#paths+1]=path end
    return paths
end
function Plugin:_storage_categories()
    local categories={books={},partial={},protected={},covers={self.store.covers_dir},temp={}}
    for _,path in ipairs(U.list(self.store:books_root())) do
        local name=path_name(path)
        if (name:lower():match("%.epub$") or name:lower():match("%.epub%.miuread%-locked$")) and not is_epub_residue_name(name) then
            categories.books[#categories.books+1]=path
        elseif is_epub_residue_name(name) or is_pending_epub_name(name) then
            categories.temp[#categories.temp+1]=path
        end
    end
    for _,book_path in ipairs(U.list(self.store.cache_books_dir)) do
        if lfs.attributes(book_path,"mode")=="directory" then
            for _,path in ipairs(U.list(book_path)) do
                if path_name(path):match("^%.miuread%-partial%-") then
                    categories.partial[#categories.partial+1]=path
                else
                    categories.protected[#categories.protected+1]=path
                end
            end
        end
    end
    for _,path in ipairs(U.list(self.store.temp_dir)) do
        if is_download_temp_name(path_name(path)) then categories.temp[#categories.temp+1]=path end
    end
    return categories
end
function Plugin:_run_cache_cleanup(paths,options)
    options=options or {}
    if self:_cache_action_blocked() then return end
    local unique,seen={},{}
    for _,path in ipairs(paths or {}) do
        path=tostring(path or "")
        if path~="" and not seen[path] then seen[path]=true; unique[#unique+1]=path end
    end
    self:_close_download_menus()
    local dialog=InfoMessage:new{text=tostring(options.progress_text or "正在清理，请稍候……")}
    self._cache_cleanup_dialog=dialog
    UIManager:show(dialog)

    local function close_progress()
        if self._cache_cleanup_dialog then pcall(function() UIManager:close(self._cache_cleanup_dialog) end) end
        self._cache_cleanup_dialog=nil
    end
    local function finish(result)
        local ok,unexpected=xpcall(function()
            close_progress()
            result=type(result)=="table" and result or {ok=false,error="未知错误"}
            result.finished_at=os.time()
            result.operation=tostring(options.operation or options.done_text or "缓存清理")
            self.store:reload()
            local commit_ok=true
            if result.ok==true and options.commit then
                local committed,err=xpcall(options.commit,debug.traceback)
                if not committed then
                    commit_ok=false
                    result.commit_error=tostring(err)
                    logger.err("[MiuRead][CacheCleanup] commit failed",tostring(err))
                    self.store:prune_missing_files()
                end
            elseif result.ok~=true then
                self.store:prune_missing_files()
            end
            U.mkdir(self.store.cache_books_dir); U.mkdir(self.store.covers_dir); U.mkdir(self.store.temp_dir)
            self.store:save_cleanup_result(result)
            self:_refresh_local_files()

            local freed=tonumber(result.freed_bytes or 0) or 0
            local removed=tonumber(result.removed or 0) or 0
            local message
            if result.ok==true and commit_ok then
                if freed>0 or removed>0 then
                    message=(options.done_text or _("Cache cleared"))
                        .."\n释放空间："..human_size(freed)
                        .."\n清理项目："..tostring(removed)
                elseif options.success_even_if_empty==true then
                    message=options.done_text or _("Cache cleared")
                else
                    message="没有可清理内容"
                end
            elseif result.ok==true then
                message="文件已清理，但记录刷新失败。重启 KOReader 后会自动重新检查。"
            else
                local err=result.error or table.concat(result.errors or {},"\n") or "未知错误"
                message="清理未完全完成"
                if freed>0 then message=message.."\n已释放："..human_size(freed) end
                message=message.."\n"..U.first_line(err,260)
            end
            self:toast(message,4)
            if options.refresh~=false then UIManager:scheduleIn(.30,function() self:show_downloads() end) end
        end,debug.traceback)
        if not ok then
            close_progress()
            logger.err("[MiuRead][CacheCleanup] result handling failed",tostring(unexpected))
            pcall(function() self:info("清理任务已经结束，但结果显示失败。请重启 KOReader 后检查存储占用。") end)
        end
    end
    if #unique==0 then finish({ok=true,removed=0,missing=0,freed_bytes=0,errors={}}); return end
    local ok,err=self.cache_cleanup_task:start(unique,finish,options.policy)
    if not ok then
        close_progress()
        self:info("无法开始清理：\n"..tostring(err))
        UIManager:scheduleIn(.15,function() self:show_downloads() end)
    end
end

function Plugin:_confirm_delete_variant(book_id,kind,title)
    if self:_cache_action_blocked() then return end
    local record=self.store:variant(book_id,kind)
    if not (record and record.file and U.file_exists(record.file)) then self.store:forget_variant(book_id,kind); self:toast("该版本已经不存在"); self:show_downloads(); return end
    local label=self:_variant_label(kind)
    UIManager:show(ConfirmBox:new{
        text="删除《"..tostring(title or book_id).."》的"..label.."？\n\n只删除这个 EPUB，其他版本和下载断点会保留。",
        ok_callback=function()
            local paths=self.store:variant_paths(book_id,kind)
            self:_run_cache_cleanup(paths,{
                progress_text="正在删除"..label.."……",
                done_text=label.."已删除",
                commit=function() self.store:forget_variant(book_id,kind) end,
                policy={mode="variant_delete"},operation="删除单个 EPUB",
            })
        end,
    })
end

function Plugin:_confirm_delete_chapter_cache(book_id,uid,title)
    if self:_cache_action_blocked() then return end
    local paths=self.store:chapter_paths(book_id,uid)
    if #paths==0 then self.store:forget_chapter_all(book_id,uid); self:toast("本章文件已经不存在"); return end
    UIManager:show(ConfirmBox:new{
        text="删除“"..tostring(title or uid).."”的全部单章文件？",
        ok_callback=function()
            self:_run_cache_cleanup(self.store:chapter_paths(book_id,uid),{
                progress_text="正在删除本章文件……",
                done_text="本章文件已删除",
                commit=function() self.store:forget_chapter_all(book_id,uid) end,
                policy={mode="chapter_delete"},operation="删除单章 EPUB",
            })
        end,
    })
end

function Plugin:_confirm_clear_partial_cache(book_id,title)
    if self:_cache_action_blocked() then return end
    local paths=self.store:partial_cache_paths(book_id)
    if #paths==0 then self:toast("没有未完成下载缓存"); return end
    UIManager:show(ConfirmBox:new{
        text="清理《"..tostring(title or book_id).."》的未完成下载缓存？\n\n已生成的 EPUB 不会删除；下次下载将重新获取尚未完成的内容。",
        ok_callback=function()
            self:_run_cache_cleanup(self.store:partial_cache_paths(book_id),{
                progress_text="正在清理未完成下载缓存……",
                done_text="下载断点已清理",
                commit=function() self.store:prune_missing_files() end,
                policy={mode="download_residue"},operation="清理单本下载断点",
            })
        end,
    })
end
local function add_complete_delete_path(paths,seen,path)
    path=tostring(path or ""):gsub("\\","/"):gsub("/+","/")
    if #path>1 then path=path:gsub("/$","") end
    if path~="" and not seen[path] then seen[path]=true; paths[#paths+1]=path end
end

function Plugin:_complete_book_delete_plan(book_id)
    book_id=tostring(book_id or "")
    local paths,seen,documents={},{},{}
    local function add(path) add_complete_delete_path(paths,seen,path) end
    local function add_document(path)
        path=tostring(path or "")
        if path=="" then return end
        documents[#documents+1]=path
        add(path)
        local ok,DocSettings=pcall(require,"docsettings")
        if ok and DocSettings then
            local settings=DocSettings:open(path)
            if settings then
                add(settings:getSidecarDir(path,"doc"))
                add(settings:getSidecarDir(path,"dir"))
                if DocSettings.isHashLocationEnabled and DocSettings.isHashLocationEnabled() then
                    add(settings:getSidecarDir(path,"hash"))
                end
                add(settings:getHistoryPath(path))
            end
        end
    end

    local function add_record(record)
        if type(record)~="table" then return end
        add_document(record.file)
        add_document(record.original_file)
        add_document(record.pending_file)
    end
    local book=self.store:book(book_id)
    if book then
        for _,record in pairs(book.variants or {}) do add_record(record) end
        for _,row in pairs(book.chapters or {}) do
            for _,record in pairs(row or {}) do add_record(record) end
        end
    end
    add(self.store:book_cache_path(book_id))
    add(self.store:cover_path(book_id))
    local cover_index=self.store:get("cover_index",{})
    add(cover_index[book_id])
    for _,row in ipairs(self.store:pending_installs()) do
        if tostring(row.book_id or "")==book_id then
            add_document(row.file)
            add_document(row.pending_file)
        end
    end
    local state=self.store:download_state()
    local state_id=tostring(state.book_id or (state.book and (state.book.bookId or state.book.book_id)) or "")
    if state_id==book_id then
        add_document(state.file); add_document(state.original_file); add_document(state.pending_file)
    end
    return paths,documents
end

function Plugin:_commit_complete_book_delete(book_id,documents)
    book_id=tostring(book_id or "")
    local ok_history,history=pcall(require,"readhistory")
    if ok_history and history and type(history.removeItemByPath)=="function" then
        for _,path in ipairs(documents or {}) do pcall(history.removeItemByPath,history,path) end
    end
    self.store:forget_book_local_state(book_id)
    if self._cover_index_pending then self._cover_index_pending[book_id]=nil end
    local repair_pending=self._book_repair_pending
    if type(repair_pending)=="table" then repair_pending[book_id]=nil end
    Thoughts.clear_memory_cache()
    self.store:prune_missing_files()
    self:_notify_home_data_changed("content")
end

function Plugin:_confirm_delete_book_downloads(book_id,title)
    if self:_cache_action_blocked() then return end
    book_id=tostring(book_id or "")
    local paths,documents=self:_complete_book_delete_plan(book_id)
    local current=tostring(self:_current_document_path() or "")
    for _,path in ipairs(documents) do
        if current~="" and current==tostring(path) then
            self:info("请先退出正在阅读的《"..tostring(title or book_id).."》，再删除这本书。")
            return
        end
    end
    UIManager:show(ConfirmBox:new{
        text="删除《"..tostring(title or book_id).."》？\n\n将删除本机中的全部版本、单章文件、下载断点、封面、想法与评论缓存、阅读记录和本书设置。删除后无法恢复，重新阅读需要再次下载。\n\n微信读书云端书架、进度、划线和想法不会受到影响。",
        ok_text="删除全部",
        cancel_text="取消",
        ok_callback=function()
            self:_run_cache_cleanup(paths,{
                progress_text="正在完整删除本书……",
                done_text="本书及全部本机相关内容已删除",
                commit=function() self:_commit_complete_book_delete(book_id,documents) end,
                policy={mode="book_delete",allowed_paths=U.copy(paths)},
                operation="完整删除本书",
                success_even_if_empty=true,
            })
        end,
    })
end
function Plugin:_annotation_retry_options(kind,record,chapter_uid)
    record=type(record)=="table" and record or {}
    local opt={annotations=true}
    if chapter_uid then
        opt.chapter_uid=tostring(chapter_uid)
    elseif tostring(kind or ""):sub(1,6)=="range_" or record.partial_range==true then
        opt.range_start_index=tonumber(record.range_start_index)
        opt.range_end_index=tonumber(record.range_end_index)
        opt.range_start_title=record.range_start_title
        opt.range_end_title=record.range_end_title
    end
    return opt
end

function Plugin:_download_book_labels(b)
    local labels={}
    for _,kind in ipairs({"clean","notes","range_clean","range_notes","preview_clean","preview_notes"}) do
        local r=b.variants and b.variants[kind]
        if r and r.file and U.file_exists(r.file) then
            labels[#labels+1]=DownloadResult.variant_label(self:_variant_label(kind),r)
        end
    end
    local chapter_count=0
    for _,row in pairs(b.chapters or {}) do
        for _,r in pairs(row or {}) do
            if r.file and U.file_exists(r.file) then
                chapter_count=chapter_count+1
            end
        end
    end
    if chapter_count>0 then
        labels[#labels+1]="单章 "..tostring(chapter_count)
    end
    if self.store:book_has_partial_cache(b.book_id) then labels[#labels+1]="未完成缓存" end
    return labels,chapter_count
end

function Plugin:show_storage_usage()
    if self.cache_cleanup_task and self.cache_cleanup_task:busy() then self:info("缓存任务正在运行，请稍候。") return end
    local categories=self:_storage_categories()
    local dialog=InfoMessage:new{text="正在统计存储占用……"}
    UIManager:show(dialog)
    local function done(result)
        local ok,unexpected=xpcall(function()
            pcall(function() UIManager:close(dialog) end)
            if not (result and result.ok==true and type(result.sizes)=="table") then
                self:info("存储统计失败：\n"..U.first_line(result and result.error or "未知错误",220))
                return
            end
            local size=result.sizes
            self:info("存储占用\n\n已下载书籍："..human_size(size.books)
                .."\n下载断点："..human_size(size.partial)
                .."\n想法与章节数据（受保护）："..human_size(size.protected)
                .."\n封面缓存："..human_size(size.covers)
                .."\n临时与待安装文件："..human_size(size.temp))
        end,debug.traceback)
        if not ok then
            pcall(function() UIManager:close(dialog) end)
            logger.err("[MiuRead][Storage] result handling failed",tostring(unexpected))
            pcall(function() self:info("存储统计结果显示失败。") end)
        end
    end
    local started,err=self.cache_cleanup_task:start_scan(categories,done)
    if not started then pcall(function() UIManager:close(dialog) end); self:info("无法开始统计：\n"..tostring(err)) end
end
function Plugin:_clear_download_residue()
    if self:_cache_action_blocked() then return end
    local paths=self:_download_residue_paths()
    UIManager:show(ConfirmBox:new{text="清理全部下载断点和失败任务留下的临时文件？\n\n不会删除已生成 EPUB、想法与章节数据、待安装文件和封面。",ok_callback=function()
        self:_run_cache_cleanup(paths,{progress_text="正在清理下载断点与临时文件……",done_text="下载断点与临时文件已清理",operation="清理下载断点与临时文件",policy={mode="download_residue"},commit=function()
            U.mkdir(self.store.temp_dir); self.store:prune_missing_files()
            local state=self.store:download_state()
            if state.status=="failed" or state.status=="interrupted" then self.store:clear_download_state() end
        end})
    end})
end
function Plugin:_clear_cover_cache()
    if self:_cache_action_blocked() then return end
    UIManager:show(ConfirmBox:new{text="清理全部封面缓存？\n\n不会删除书籍、想法、章节数据或阅读记录；下次进入书架时会按需重新下载封面。",ok_callback=function()
        self:_run_cache_cleanup({self.store.covers_dir},{progress_text="正在清理封面缓存……",done_text="封面缓存已清理",operation="清理封面缓存",policy={mode="cover_cache"},commit=function()
            U.mkdir(self.store.covers_dir); self.store:set("cover_index",{})
        end})
    end})
end
function Plugin:show_download_cleanup_dialog()
    if self:_cache_action_blocked() then return end
    local dialog
    dialog=ButtonDialog:new{title="清理下载与缓存",title_align="center",buttons={
        {{text="清理下载断点与临时文件",callback=function() UIManager:close(dialog); self:_clear_download_residue() end}},
        {{text="清理封面缓存",callback=function() UIManager:close(dialog); self:_clear_cover_cache() end}},
        {{text="取消",callback=function() UIManager:close(dialog) end}},
    }}
    UIManager:show(dialog)
end

function Plugin:show_downloads()
    if self.cache_cleanup_task and self.cache_cleanup_task:busy() then self:info("缓存正在清理，请稍候。") return end
    self.store:reload(); self.store:prune_missing_files()
    if self._download_book_menu then pcall(function() UIManager:close(self._download_book_menu) end); self._download_book_menu=nil end
    if self._downloads_menu then pcall(function() UIManager:close(self._downloads_menu) end); self._downloads_menu=nil end
    local items={}
    if self:_has_download_status() then items[#items+1]={text=self:_download_status_label(),callback=function() self:show_download_status() end} end
    local queue=self.store:download_queue()
    items[#items+1]={text="等待下载",post_text=tostring(#queue).." 项",callback=function() self:show_waiting_downloads() end}
    items[#items+1]={text="存储占用",callback=function() self:show_storage_usage() end}
    items[#items+1]={text="存储与清理",callback=function() self:show_download_cleanup_dialog() end}
    items[#items+1]={text="已完成",enabled=false}
    for _,b in ipairs(self.store:all_books()) do
        local labels=self:_download_book_labels(b)
        if #labels>0 then
            local book_id=tostring(b.book_id)
            items[#items+1]={text=b.title or book_id,post_text=table.concat(labels," · "),callback=function() self:downloaded_book_menu(book_id) end}
        end
    end
    local menu=Menu:new{title="下载管理",item_table=items,is_borderless=true,title_bar_fm_style=true}
    self._downloads_menu=menu
    UIManager:show(menu)
end

function Plugin:downloaded_chapters_menu(book_id)
    self.store:reload()
    local b=self.store:book(book_id)
    if not b then self:toast("下载记录已不存在"); self:show_downloads(); return end
    local order={}
    for index,ch in ipairs(b.catalog or {}) do
        order[tostring(ch.uid or ch.chapterUid or ch.chapter_uid or "")]=index
    end
    local rows={}
    for uid,row in pairs(b.chapters or {}) do
        local labels={}
        local title
        for _,kind in ipairs({"clean","notes","range_clean","range_notes","preview_clean","preview_notes"}) do
            local r=row and row[kind]
            if r and r.file and U.file_exists(r.file) then
                labels[#labels+1]=DownloadResult.variant_label(self:_variant_label(kind),r)
                title=title or r.title
            end
        end
        if #labels>0 then
            rows[#rows+1]={uid=tostring(uid),title=tostring(title or uid),labels=labels,index=order[tostring(uid)] or 999999}
        end
    end
    table.sort(rows,function(a,c)
        if a.index~=c.index then return a.index<c.index end
        return a.uid<c.uid
    end)
    local items={}
    local book={bookId=book_id,title=b.title,author=b.author,cover=b.cover}
    for _,entry in ipairs(rows) do
        local chapter={chapterUid=entry.uid,title=entry.title}
        items[#items+1]={text=entry.title,post_text=table.concat(entry.labels," · "),callback=function() self:chapter_menu(book,chapter) end}
    end
    self:list("单章文件 · "..tostring(b.title or book_id),items,"没有单章文件")
end

function Plugin:downloaded_book_menu(book_ref)
    local book_id=type(book_ref)=="table" and tostring(book_ref.book_id or book_ref.bookId) or tostring(book_ref)
    self.store:reload(); self.store:prune_missing_files()
    local b=self.store:book(book_id)
    if not b then self:toast("下载记录已不存在"); self:show_downloads(); return end
    local items={}
    local variants={}
    for _,kind in ipairs({"clean","notes","range_clean","range_notes","preview_clean","preview_notes"}) do
        local r=b.variants and b.variants[kind]
        if r and r.file and U.file_exists(r.file) then
            local label=DownloadResult.variant_label(self:_variant_label(kind),r)
            variants[#variants+1]={kind=kind,file=r.file,label=label,record=r}
        end
    end
    if #variants>0 then
        items[#items+1]={text="可阅读版本",enabled=false}
        for _,variant in ipairs(variants) do
            local kind_key=variant.kind; local file=variant.file; local label=variant.label; local record=variant.record
            items[#items+1]={text="阅读"..label,post_text="EPUB",callback=function() self:open_file(file) end}
            items[#items+1]={text="删除"..label,post_text="仅删除该版本",callback=function() self:_confirm_delete_variant(book_id,kind_key,b.title) end}
        end
    end
    local _,chapter_count=self:_download_book_labels(U.merge(b,{book_id=book_id}))
    local has_partial=self.store:book_has_partial_cache(book_id)
    if chapter_count>0 or has_partial then
        items[#items+1]={text="单章与断点",enabled=false}
        if chapter_count>0 then
            items[#items+1]={text="单章文件",post_text=tostring(chapter_count).." 个",callback=function() self:downloaded_chapters_menu(book_id) end}
        end
        if has_partial then
            items[#items+1]={text="清理未完成下载缓存",post_text="保留已生成 EPUB",callback=function() self:_confirm_clear_partial_cache(book_id,b.title) end}
        end
    end
    if #variants>0 or chapter_count>0 or has_partial then
        items[#items+1]={text="本书管理",enabled=false}
        items[#items+1]={text="删除这本书",post_text="同时删除本机想法、评论与记录",callback=function() self:_confirm_delete_book_downloads(book_id,b.title) end}
    end
    if #items==0 then self:toast("本书没有可管理的下载内容"); self:show_downloads(); return end
    if self._download_book_menu then pcall(function() UIManager:close(self._download_book_menu) end) end
    local menu=Menu:new{title=b.title or book_id,item_table=items,is_borderless=true,title_bar_fm_style=true}
    self._download_book_menu=menu
    UIManager:show(menu)
end
function Plugin:progress_sync_label()
    local prefs=self.store:preferences().sync or {}
    if prefs.progress_enabled==false then return "已关闭" end
    local r=self.sync:record()
    local session=r and self.store:session(r.book.book_id) or {}
    local state=session and session.progress_sync_state or nil
    local labels={checking="正在检查",retrying="正在重试",mapping_pending="等待章节换算",aligned="已同步",local_selected="使用本机位置",local_uploaded="已上传并确认",uploading="正在上传",verifying_upload="正在确认",upload_failed="上传失败",upload_unconfirmed="云端未确认",source_conflict="云端来源冲突",remote_selected="已采用云端位置",different="等待选择",deferred="本次暂不处理",remote_unavailable="等待重新检查",remote_jump_unconfirmed="跳转待确认"}
    return labels[state] or "已开启"
end

function Plugin:_sync_success_notice_enabled()
    return (self.store:preferences().sync or {}).success_notice_enabled~=false
end
function Plugin:toggle_sync_success_notice()
    local p=self.store:preferences(); p.sync=p.sync or {}
    p.sync.success_notice_enabled=not (p.sync.success_notice_enabled~=false)
    self.store:save_preferences(p)
    self:status_toast("同步成功提醒",p.sync.success_notice_enabled and "已开启" or "已关闭",3)
end
function Plugin:_show_auto_sync_success(text)
    if self._sync_success_notified==true or not self:_sync_success_notice_enabled() then return end
    self._sync_success_notified=true
    self:status_toast("同步完成",text or "已成功上传",3)
end
function Plugin:sync_diagnostics_menu()
    return {
        {text="检查当前书籍识别",callback=function()
            local r=self.sync:record()
            if not r or not r.book then self:info("当前文件未被识别为觅阅书籍。") return end
            self:info("当前书籍已识别\n\n书名："..tostring(r.book.title or "未命名")
                .."\n书籍 ID："..tostring(r.book.book_id or "")
                .."\n文件："..tostring(r.path or ""))
        end},
        {text="检查登录状态",callback=function() self:show_account_status() end},
        {text="测试云端进度读取",callback=function() self:manual_sync() end},
        {text="测试当前进度上传",callback=function() self:upload_local_progress(true) end},
        {text="测试上传 30 秒阅读时间",callback=function()
            if not self.sync:record() then self:info("请先打开一本觅阅下载的书籍。") return end
            self:status_toast("阅读时间测试","正在上传 30 秒……",3)
            self.sync:test_upload(function(ok,result)
                if ok then self:status_toast("阅读时间测试","30 秒已成功上传",4)
                else self:info("阅读时间测试失败\n\n"..tostring(result or "未知错误")) end
            end)
        end},
        {text="查看详细错误",callback=function() self:show_sync_status(true) end},
        {text="重置当前书籍同步状态",callback=function()
            local r=self.sync:record()
            if not r or not r.book then self:info("请先打开一本觅阅下载的书籍。") return end
            local id=tostring(r.book.book_id)
            UIManager:show(ConfirmBox:new{text="重置当前书籍的临时同步状态？\n\n不会删除书籍、本机阅读位置、划线、想法或账号。",ok_callback=function()
                self.sync:stop("manual_reset",0)
                local sessions=self.store:get("sessions",{})
                local session=sessions[id] or {}
                for _,key in ipairs({
                    "legacy_report_context","report_context","last_error","last_response_summary",
                    "last_http_code","last_http_length","last_payload_public","last_path","last_stage",
                    "progress_sync_state","progress_sync_message","progress_upload_state","progress_upload_error",
                    "consecutive_failures"
                }) do session[key]=nil end
                session.pending_report_seconds=0
                sessions[id]=session
                self.store:set("sessions",sessions)
                self.sync:clear_verified("manual_reset")
                self.sync.last_error=nil
                self.sync.consecutive_failures=0
                self._sync_success_notified=false
                self:status_toast("阅读同步","临时状态已重置",3)
                UIManager:scheduleIn(.5,function()
                    if not self.ui or not self.ui.document then return end
                    local prefs=self.store:preferences().sync or {}
                    if prefs.progress_enabled~=false then self:ensure_read_report_progress("manual_reset",true)
                    elseif prefs.time_enabled==true then self.sync:start("manual_reset") end
                end)
            end})
        end},
    }
end

function Plugin:sync_menu()
    return {
        {text="同步状态",callback=function() self:show_sync_status(false) end},
        {text="自动同步阅读进度",checked_func=function() return self.store:preferences().sync.progress_enabled~=false end,keep_menu_open=true,callback=function() self:toggle_progress_sync() end},
        {text="自动同步阅读时间",checked_func=function() return self.store:preferences().sync.time_enabled==true end,keep_menu_open=true,callback=function() self:toggle_time_sync() end},
        {text="同步成功提醒",checked_func=function() return self:_sync_success_notice_enabled() end,keep_menu_open=true,callback=function() self:toggle_sync_success_notice() end},
        {text="立即上传当前进度",callback=function() self:upload_local_progress(true) end},
        {text="重新读取云端进度",callback=function() self:manual_sync() end},
        {text="同步诊断",sub_item_table_func=function() return self:sync_diagnostics_menu() end},
    }
end

function Plugin:toggle_time_sync(confirmed)
    local current=self.store:preferences()
    if current.sync.time_enabled==true and confirmed~=true then
        UIManager:show(ConfirmBox:new{
            text="关闭后，觅阅不会上传后续阅读时长，其他设备上的阅读统计可能不完整。",
            ok_text="关闭时间同步",cancel_text="保持开启",ok_callback=function() self:toggle_time_sync(true) end,
        })
        return
    end
    local p=self.store:preferences(); p.sync.time_enabled=not p.sync.time_enabled; self.store:save_preferences(p)
    if p.sync.time_enabled then
        local record=self.sync:record()
        if record and p.sync.progress_enabled~=false and not self.sync:is_current_verified() then
            self:ensure_read_report_progress("time_sync_enabled",false)
        else
            self.sync:start("enabled")
        end
        if self:_original_weread_plugin_present() then
            self:info("阅读时间同步已开启。\n\n检测到原作者 WeRead 插件目录（weread.koplugin）。它与觅阅是两个独立插件；若两边都开启阅读时间同步，可能重复上报。可按自己的需要在插件管理中关闭其中一边。")
        else
            self:status_toast("阅读时间同步","已开启",3)
        end
    else
        self.sync:stop("disabled")
        self:status_toast("阅读时间同步","已关闭",3)
    end
end





function Plugin:_show_progress_success(_text)
    local prefs=self.store:preferences().sync or {}
    -- When reading-time sync is active, its first accepted report contains the
    -- current position too, so one combined notice is enough.
    if prefs.time_enabled==true then return end
    self:_show_auto_sync_success("阅读进度已上传")
end
function Plugin:toggle_progress_sync(confirmed)
    local current=self.store:preferences()
    if current.sync.progress_enabled~=false and confirmed~=true then
        UIManager:show(ConfirmBox:new{
            text="关闭后，其他设备将无法自动接续本书的阅读位置。本机阅读位置不会被删除。",
            ok_text="关闭进度同步",cancel_text="保持开启",ok_callback=function() self:toggle_progress_sync(true) end,
        })
        return
    end
    local p=self.store:preferences(); p.sync.progress_enabled=not (p.sync.progress_enabled~=false); p.sync.pull_on_open=p.sync.progress_enabled; self.store:save_preferences(p)
    local r=self.sync:record()
    if p.sync.progress_enabled then
        self.sync:clear_verified("progress_sync_enabled")
        self:toast("阅读进度同步已开启",3)
        if r then UIManager:scheduleIn(.1,function() self:ensure_read_report_progress("enabled",false) end) end
    else
        if r then self.store:save_session(r.book.book_id,{progress_sync_state="disabled",progress_sync_message="阅读进度同步已关闭"}) end
        self.sync.progress_hold=false
        self.sync:start("progress_disabled")
        self:toast("阅读进度同步已关闭",3)
    end
end

function Plugin:_save_progress_state(id,state,message,localp,remotep)
    self.store:save_session(id,{
        progress_sync_state=state,
        progress_sync_message=message,
        progress_local_percent=localp,
        progress_remote_percent=remotep,
        progress_decided_at=os.time(),
    })
end
function Plugin:ensure_read_report_progress(reason,automatic)
    local prefs=self.store:preferences().sync or {}
    if prefs.progress_enabled==false then
        if not automatic then self:info("阅读进度同步已关闭。") end
        self.sync:start("progress_disabled")
        return false
    end
    local r=self.sync:record()
    if not r then
        if not automatic then self:info(_("No matching MiuRead book is open.")) end
        return false
    end
    local id=tostring(r.book.book_id)
    if not self:is_online() then
        self:_save_progress_state(id,"waiting_network","等待 Wi-Fi 恢复后读取云端位置",nil,nil)
        self.sync:end_progress_sync("等待网络恢复")
        if automatic then
            self:_wait_for_network("progress-"..id,function(ready)
                if ready and self.ui and self.ui.document then
                    self:ensure_read_report_progress("network_ready",true)
                end
            end,{minimum_delay=2,max_wait=90,interval=3})
        else
            self:info("Wi-Fi 尚未恢复。\n\n本地阅读时间和位置已保留，联网后会重新确认并补传。")
        end
        return false
    end
    if self._progress_check_running then
        if not automatic then self:toast("正在读取云端位置……",2) end
        return false
    end
    self._progress_check_running=true
    local local_position=self.sync:local_position()
    if not local_position or local_position.safe~=true or local_position.progress==nil then
        local chapter_percent=local_position and local_position.chapter_percent
            or math.floor((self.sync:local_ratio() or 0)*100+.5)
        self:_save_progress_state(id,"mapping_pending","正在取得完整目录以换算单章进度",chapter_percent,nil)
        self._progress_check_running=false
        self.sync:end_progress_sync("单章位置等待完整目录")
        if not automatic then
            self:info("当前打开的是单章文件。\n\n正在等待完整目录用于换算整书进度；在换算完成前，不会把本章百分比直接上传成整书百分比。")
        end
        return false
    end
    local localp=math.floor((tonumber(local_position.progress) or 0)+.5)
    self:_save_progress_state(id,"checking","正在读取云端位置",localp,nil)
    self.sync:begin_progress_sync(reason or "读取云端进度")
    self.sync:remote(id,function(remote,remote_err)
        self._progress_check_running=false
        self._progress_remote_retries=self._progress_remote_retries or {}
        if not remote then
            local retries=tonumber(self._progress_remote_retries[id] or 0) or 0
            if automatic and retries<1 and self.ui and self.ui.document then
                self._progress_remote_retries[id]=retries+1
                self:_save_progress_state(id,"retrying","云端位置读取失败，准备重试",localp,nil)
                self.sync:end_progress_sync("云端位置读取失败，等待重试")
                UIManager:scheduleIn(2.5,function()
                    if self.ui and self.ui.document then
                        self:ensure_read_report_progress("remote_progress_retry",true)
                    end
                end)
                return
            end
            self:_save_progress_state(id,"remote_unavailable","暂时无法读取云端位置",localp,nil)
            self.sync:end_progress_sync("云端位置暂时不可用，阅读时间等待确认")
            if not automatic then
                self:info("暂时无法读取云端位置。\n\n为了避免覆盖其他设备上的位置，本次阅读时间会等待位置确认后再上传。")
            end
            logger.warn("[MiuRead][Sync] remote position unavailable", tostring(remote_err or "unknown"))
            return
        end
        self._progress_remote_retries[id]=0
        if remote.conflict then
            local webp=remote.web and math.floor((tonumber(remote.web.percent) or 0)+.5) or nil
            local agentp=remote.agent and math.floor((tonumber(remote.agent.percent) or 0)+.5) or nil
            self:_save_progress_state(id,"source_conflict","云端两个来源的位置不一致",localp,webp or agentp)
            self.sync.state="verification_required"
            self.sync.last_stage="等待选择云端位置来源"
            self:on_remote_source_conflict(id,localp,remote,automatic==true)
            return
        end
        local remotep=math.floor((tonumber(remote.percent) or 0)+.5)
        local cmp=self.sync:compare(localp,remote)
        if cmp=="same" then
            self.sync:mark_verified(id,"positions_aligned",localp,remotep)
            self:_save_progress_state(id,"aligned","本机与云端位置接近",localp,remotep)
            self.sync:end_progress_sync("位置接近，阅读时间开始同步")
            if not automatic then self:info("本机位置："..localp.."%\n云端位置："..remotep.."%\n\n位置接近，无需处理。") end
            return
        end
        self:_save_progress_state(id,"different","检测到本机与云端位置不同",localp,remotep)
        self.sync.state="verification_required"
        self.sync.last_stage="等待选择本机或云端位置"
        self:on_remote_progress(id,localp,remote,automatic==true)
    end)
    return true
end

function Plugin:manual_sync()
    return self:ensure_read_report_progress("manual_progress_sync",false)
end

function Plugin:_remote_matches(remote,target)
    local threshold=tonumber(self.store:preferences().sync.threshold) or 2
    target=tonumber(target)
    if not target or not remote then return false,nil,nil end
    local function match(candidate)
        local percent=candidate and tonumber(candidate.percent)
        return percent and math.abs(percent-target)<=threshold,percent,candidate and candidate.source
    end
    if remote.conflict then
        local ok,p,source=match(remote.web); if ok then return true,p,source end
        ok,p,source=match(remote.agent); if ok then return true,p,source end
        return false,nil,nil
    end
    return match(remote)
end

function Plugin:upload_local_progress(manual,callback)
    local r=self.sync:record()
    if not r then
        if manual then self:info("请先打开一本觅阅下载的书籍。") end
        if callback then callback(false,"未识别当前书籍") end
        return false
    end
    local position=self.sync:local_position()
    if not position or position.safe~=true or position.progress==nil then
        local err="当前文件暂时无法安全换算整书进度。"
        if manual then self:info(err) end
        if callback then callback(false,err) end
        return false
    end
    local id=tostring(r.book.book_id)
    local target=math.floor((tonumber(position.progress) or 0)+.5)
    self.sync:begin_progress_sync("主动上传本机阅读进度")
    self:_save_progress_state(id,"uploading","正在上传本机阅读进度",target,nil)
    if manual then self:status_toast("阅读进度同步","正在上传 "..target.."%……",3) end
    local started=self.sync:upload_progress(function(ok,result,submitted)
        if not ok then
            self:_save_progress_state(id,"upload_failed","阅读进度上传失败",target,nil)
            self.sync:end_progress_sync("阅读进度上传失败")
            if manual then self:info("阅读进度上传失败\n\n"..tostring(result or "未知错误")) end
            if callback then callback(false,result) end
            return
        end
        target=math.floor((tonumber(submitted and submitted.progress) or target)+.5)
        self:_save_progress_state(id,"verifying_upload","请求已接收，正在确认云端位置",target,nil)
        local function verify(attempt)
            UIManager:scheduleIn(attempt==1 and 1.5 or 2.5,function()
                if not self.ui or not self.ui.document then return end
                self.sync:remote(id,function(remote,remote_err)
                    local matched,actual,source=self:_remote_matches(remote,target)
                    if matched then
                        actual=math.floor((tonumber(actual) or target)+.5)
                        self.sync:mark_verified(id,"local_progress_uploaded",target,actual)
                        self:_save_progress_state(id,"local_uploaded","本机进度已上传并确认",target,actual)
                        self.store:save_session(id,{progress_upload_state="verified",progress_upload_verified_at=os.time(),progress_upload_source=source})
                        self.sync:end_progress_sync("本机阅读进度已上传并确认")
                        if manual then
                            self:status_toast("阅读进度同步","已上传并确认："..target.."%",4)
                        else
                            self:_show_progress_success("已同步："..target.."%")
                        end
                        if callback then callback(true,remote) end
                    elseif attempt<2 then
                        verify(attempt+1)
                    else
                        self:_save_progress_state(id,"upload_unconfirmed","请求已发送，但云端位置尚未更新",target,remote and remote.percent)
                        self.store:save_session(id,{progress_upload_state="unconfirmed",progress_upload_error=remote_err})
                        self.sync:end_progress_sync("进度请求已发送，云端尚未确认")
                        if manual then self:info("上传请求已发送，但云端位置尚未更新。\n\n本机位置："..target.."%") end
                        if callback then callback(false,remote_err or "云端位置尚未更新") end
                    end
                end,{force=true})
            end)
        end
        verify(1)
    end)
    if not started then
        self.sync:end_progress_sync("无法启动阅读进度上传")
        if manual then self:info("无法启动阅读进度上传：同步任务正在运行。") end
        if callback then callback(false,"同步任务正在运行") end
        return false
    end
    return true
end

function Plugin:_use_remote_position(id,localp,remote)
    local remotep=math.floor((tonumber(remote and remote.percent) or 0)+.5)
    local jumped,jump_error=self.sync:jump_remote(remote)
    if not jumped then
        self:_save_progress_state(id,"remote_jump_unconfirmed","无法跳转到云端位置",localp,remotep)
        self.sync:end_progress_sync("云端位置跳转失败，阅读时间暂缓上传")
        self:info(tostring(jump_error or "无法跳转到云端位置。").."\n\n当前位置未确认，因此暂不上传阅读时间。")
        return false
    end
    UIManager:scheduleIn(1.2,function()
        local actual_position=self.sync:local_position()
        local actual=actual_position and actual_position.progress and math.floor(actual_position.progress+.5) or localp
        local threshold=tonumber(self.store:preferences().sync.threshold) or 2
        if math.abs(actual-remotep)<=threshold then
            self.sync:mark_verified(id,"remote_position_selected",actual,remotep)
            self:_save_progress_state(id,"remote_selected","已采用云端位置",actual,remotep)
            self.sync:end_progress_sync("已采用云端位置，阅读时间开始同步")
            self:status_toast("阅读进度同步","已切换到云端进度："..remotep.."%",4)
        else
            self:_save_progress_state(id,"remote_jump_unconfirmed","已请求跳转，位置仍待确认",actual,remotep)
            self.sync:end_progress_sync("云端位置仍待确认，阅读时间暂缓上传")
            self:info("已请求跳到云端位置，但当前显示位置为 "..actual.."%。\n\n为避免覆盖云端位置，暂不上传阅读时间。")
        end
    end)
    return true
end

function Plugin:on_remote_source_conflict(id,localp,remote,automatic)
    if automatic and self._progress_prompted_book_id==tostring(id) then
        self.sync:end_progress_sync("云端来源冲突等待用户处理")
        return
    end
    self._progress_prompted_book_id=tostring(id)
    local webp=remote.web and math.floor((tonumber(remote.web.percent) or 0)+.5) or nil
    local agentp=remote.agent and math.floor((tonumber(remote.agent.percent) or 0)+.5) or nil
    local title="云端阅读位置来源不一致\n\n本机："..localp.."%"
        .."\n微信读书网页："..tostring(webp or "未获取").."%"
        .."\n官方接口："..tostring(agentp or "未获取").."%"
    local dialog,closing_for_action
    local function defer()
        self:_save_progress_state(id,"deferred","云端来源不一致，本次暂不处理",localp,webp or agentp)
        self.sync:end_progress_sync("云端来源冲突尚未确认")
    end
    local buttons={}
    if remote.web then buttons[#buttons+1]={{text="使用网页云端 "..webp.."%",callback=function()
        closing_for_action=true; UIManager:close(dialog); self:_use_remote_position(id,localp,remote.web)
    end}} end
    if remote.agent then buttons[#buttons+1]={{text="使用官方云端 "..agentp.."%",callback=function()
        closing_for_action=true; UIManager:close(dialog); self:_use_remote_position(id,localp,remote.agent)
    end}} end
    buttons[#buttons+1]={{text="使用本机并上传 "..localp.."%",callback=function()
        closing_for_action=true; UIManager:close(dialog); self:upload_local_progress(true)
    end}}
    buttons[#buttons+1]={{text="本次暂不处理",callback=function()
        closing_for_action=true; UIManager:close(dialog); defer()
    end}}
    dialog=ButtonDialog:new{title=title,title_align="center",close_callback=function()
        if not closing_for_action then defer() end
    end,buttons=buttons}
    UIManager:show(dialog)
end

function Plugin:on_remote_progress(id,localp,remote,automatic)
    local remotep=math.floor((tonumber(remote.percent) or 0)+.5)
    if automatic and self._progress_prompted_book_id==tostring(id) then
        self.sync:end_progress_sync("已提示位置差异，等待用户选择")
        return
    end
    self._progress_prompted_book_id=tostring(id)
    local source=remote.source=="web_cookie" and "网页云端" or (remote.source=="agent_gateway" and "官方云端" or "云端")
    local text="检测到阅读位置不同\n\n本机位置："..localp.."%\n"..source.."位置："..remotep.."%"
    local dialog,closing_for_action
    local function defer()
        self:_save_progress_state(id,"deferred","本次暂不处理位置差异",localp,remotep)
        self.sync:end_progress_sync("位置差异尚未确认，阅读时间暂缓上传")
    end
    dialog=ButtonDialog:new{title=text,title_align="center",close_callback=function()
        if not closing_for_action then defer() end
    end,buttons={
        {{text="使用云端位置",callback=function()
            closing_for_action=true; UIManager:close(dialog); self:_use_remote_position(id,localp,remote)
        end}},
        {{text="使用本机位置并上传",callback=function()
            closing_for_action=true; UIManager:close(dialog); self:upload_local_progress(true)
        end}},
        {{text="本次暂不同步位置",callback=function()
            closing_for_action=true; UIManager:close(dialog); defer()
        end}},
    }}
    UIManager:show(dialog)
end

function Plugin:_relative_time(ts)
    ts=tonumber(ts or 0) or 0
    if ts<=0 then return "尚未同步" end
    local delta=math.max(0,os.time()-ts)
    if delta<10 then return "刚刚" end
    if delta<60 then return tostring(delta).."秒前" end
    if delta<3600 then return tostring(math.floor(delta/60)).."分钟前" end
    if delta<86400 then return tostring(math.floor(delta/3600)).."小时前" end
    return U.now_text(ts)
end
function Plugin:show_sync_status(detail)
    local s=self.sync:status()
    local remote=s.remote and math.floor((s.remote.percent or 0)+.5) or nil
    local local_text=s.local_percent~=nil and (tostring(s.local_percent).."%")
        or (s.local_chapter_percent~=nil and ("本章 "..tostring(s.local_chapter_percent).."%") or "—")
    local time_text
    if not s.time_enabled then time_text="已关闭"
    elseif not s.record or s.state=="stopped" then time_text="未运行"
    elseif s.state=="verification_required" or s.state=="fetching_remote" or s.state=="progress_sync" then time_text="等待位置确认"
    elseif s.state=="paused" then time_text="暂时失败，稍后重新计时"
    elseif type(s.last_error)=="string" and (tonumber(s.consecutive_failures) or 0)>=2 then time_text="暂时失败，稍后重试"
    elseif s.state=="uploading" then time_text="正在同步"
    else time_text="运行中" end
    local lines={"阅读同步","","阅读时间："..time_text,"阅读进度："..self:progress_sync_label(),"当前位置："..local_text}
    if remote then lines[#lines+1]="云端位置："..remote.."%" end
    lines[#lines+1]="上次同步："..self:_relative_time(s.last_upload)
    if detail then
        lines[#lines+1]=""
        lines[#lines+1]="详细信息"
        lines[#lines+1]="单次阅读时间上限：30 秒"
        lines[#lines+1]="后台服务版本："..tostring(s.service_version or "—")
        if s.last_elapsed then lines[#lines+1]="上次提交时长："..tostring(s.last_elapsed).." 秒" end
        if s.last_stage then lines[#lines+1]="当前阶段："..U.first_line(s.last_stage,160) end
        if s.last_error then lines[#lines+1]="最近错误："..U.first_line(s.last_error,200) end
        if s.last_response_summary then lines[#lines+1]="响应摘要："..U.first_line(s.last_response_summary,200) end
        if s.last_http_code then lines[#lines+1]="HTTP："..tostring(s.last_http_code) end
        if s.last_path then lines[#lines+1]="上传路径："..tostring(s.last_path) end
    end
    self:info(table.concat(lines,"\n"))
end

function Plugin:on_auth_required(channel,err)
    local notify=tostring(channel or "")~="read_report"
    local marked=self:_mark_auth_problem(channel,err,notify)
    if marked and not notify then
        self:status_toast("阅读时间上传","登录验证暂时失败，本次时间不补传；下载不受影响",5)
    end
    return marked
end
function Plugin:on_auth_channel_ok(channel)
    self:_mark_auth_channel_ok(channel)
end

function Plugin:on_read_report_ready()
    -- Background sync starts silently.
end
function Plugin:on_read_report_success(path)
    local r=self.sync:record()
    local session=r and self.store:session(r.book.book_id) or {}
    if r and session.progress_sync_state=="mapping_pending"
        and self.store:preferences().sync.progress_enabled~=false then
        UIManager:scheduleIn(.5,function()
            if self.ui and self.ui.document then self:ensure_read_report_progress("catalog_ready",true) end
        end)
    elseif r and self.store:preferences().sync.progress_enabled~=false then
        -- Automatic background reports already carry the latest position. Do not
        -- immediately query the cloud again: the extra read caused avoidable I/O
        -- and UI stalls on slower devices. Manual uploads still perform full
        -- confirmation through upload_local_progress().
        local position=self.sync:local_position()
        if position and position.safe==true and position.progress~=nil then
            local target=math.floor((tonumber(position.progress) or 0)+.5)
            self.store:save_session(r.book.book_id,{
                progress_upload_state="submitted",
                progress_upload_at=os.time(),
                progress_upload_percent=target,
            })
        end
    end
end
function Plugin:on_read_report_interval_success(status)
    if status and (status.recovery_probe==true or tonumber(status.elapsed_seconds or 0)<=0) then return end
    local prefs=self.store:preferences().sync or {}
    if prefs.time_enabled~=true then return end
    if prefs.progress_enabled~=false then
        self:_show_auto_sync_success("阅读进度和阅读时间已上传")
    else
        self:_show_auto_sync_success("阅读时间已上传")
    end
end
function Plugin:on_read_report_failure(err)
    if Http.is_auth_error(err) then
        self:_mark_auth_problem("read_report",err,false)
        self:status_toast("阅读同步","登录验证暂时失败，本次时间不补传；稍后重新计时",5)
        return
    end
    self:status_toast("阅读同步","连续同步失败，本次时间不补传；稍后重试",5)
end
function Plugin:_current_book_record()
    self.store:reload()
    local r=self.sync:record()
    if r then return r end
    local doc=self.ui and self.ui.document
    local path=doc and (doc.file or (doc.getFilePath and doc:getFilePath()))
    local b,rec,variant=self.store:file_record(path)
    if b then return {book=b,record=rec,variant=variant,path=path} end
    local raw=path and U.read_file(path,true)
    local id=raw and (raw:match('"book_id"%s*:%s*"([^"]+)"') or raw:match('miuread://book/([^<"]+)'))
    local fallback=id and self.store:book(id)
    if fallback then return {book=fallback,record=fallback.variants and (fallback.variants.notes or fallback.variants.clean or fallback.variants.range_notes or fallback.variants.range_clean or fallback.variants.preview_notes or fallback.variants.preview_clean),variant=nil,path=path} end
end

function Plugin:redownload_current()
    local r=self:_current_book_record()
    if not r or not r.book then self:info(_("No matching MiuRead book is open.")); return end
    local b={bookId=r.book.book_id,title=r.book.title,author=r.book.author,cover=r.book.cover}
    local dialog
    local buttons={}
    buttons[#buttons+1]={{text="生成纯净版",callback=function() UIManager:close(dialog); self:choose_download_mode(b,{annotations=false},false) end}}
    buttons[#buttons+1]={{text="生成划线与想法版",callback=function() UIManager:close(dialog); self:choose_download_mode(b,{annotations=true},false) end}}
    buttons[#buttons+1]={{text="关闭",callback=function() UIManager:close(dialog) end}}
    dialog=ButtonDialog:new{title="重新生成《"..tostring(b.title or "本书").."》",title_align="center",buttons=buttons}
    UIManager:show(dialog)
end
function Plugin:_repair_preferences()
    local preferences=self.store:preferences()
    preferences.repair=type(preferences.repair)=="table" and preferences.repair or {}
    if preferences.repair.auto_check==nil then preferences.repair.auto_check=true end
    return preferences.repair,preferences
end

function Plugin:_repair_context(current)
    if type(current)=="table" and current.book then
        return {
            book=current.book,
            record=current.record or {},
            variant=current.variant,
            path=current.path,
            title=current.book and current.book.title,
        }
    end
    local row=self:_current_book_record()
    if not row then return nil end
    return {
        book=row.book,
        record=row.record or {},
        variant=row.variant,
        path=row.path,
        title=row.book and row.book.title,
    }
end

function Plugin:_repair_state()
    local state=self.store:get("book_repair_state",{})
    return type(state)=="table" and state or {}
end

function Plugin:_save_repair_state(book_id,row)
    local state=self:_repair_state()
    state[tostring(book_id or "")]=row
    self.store:set("book_repair_state",state)
end

function Plugin:_record_repair_history(result,status)
    local history=self.store:get("book_repair_history",{})
    if type(history)~="table" then history={} end
    table.insert(history,1,{
        at=os.time(),
        title=tostring(result and result.title or "书籍"),
        book_id=tostring(result and result.book_id or ""),
        status=tostring(status or ((result and result.ok) and "已完成" or "失败")),
    })
    while #history>20 do table.remove(history) end
    self.store:set("book_repair_history",history)
end

function Plugin:_repair_message(report)
    local lines={"发现书籍数据需要修复。"}
    for _,issue in ipairs((report and report.issues) or {}) do
        lines[#lines+1]=""
        lines[#lines+1]=tostring(issue.detail or issue.title or "书籍数据异常")
    end
    lines[#lines+1]=""
    lines[#lines+1]="修复只处理本地数据，不会重新下载整本书。"
    return table.concat(lines,"\n")
end

function Plugin:_run_book_repair(context,report,force)
    context=context or self:_repair_context()
    if not context or not context.book then self:info("当前没有可修复的觅阅书籍"); return false end
    if self.repair_async and self.repair_async:busy() then self:toast("已有修复任务正在进行"); return false end
    local title=tostring((context.book or {}).title or context.title or "当前书籍")
    self:toast("正在修复《"..title.."》",2)
    local repair=self.book_repair
    local started,err=self.repair_async:run("book-repair",function()
        return repair:repair(context,report,force==true)
    end,function(result)
        if not result or result.ok~=true or type(result.value)~="table" then
            local message=tostring(result and result.error or "修复任务未完成")
            self:_record_repair_history({title=title,book_id=(context.book or {}).book_id},"失败")
            self:info("修复失败：\n"..message)
            return
        end
        local value=result.value
        self:_record_repair_history(value,value.ok and "已完成" or "部分失败")
        self:_save_repair_state(value.book_id,{
            signature=value.signature,
            status=value.ok and "fixed" or "failed",
            checked_at=os.time(),
        })
        if value.ok then
            self:info("修复完成，可以继续阅读。")
        else
            self:info("部分内容没有修复成功，请在“修复记录”中查看后重试。")
        end
    end,180)
    if not started then self:info("无法开始修复：\n"..tostring(err or "未知原因")); return false end
    return true
end

function Plugin:_show_book_repair_prompt(context,report)
    if self._repair_prompt_open then return end
    self._repair_prompt_open=true
    local book_id=tostring(report and report.book_id or ((context.book or {}).book_id or ""))
    local signature=tostring(report and report.signature or self.book_repair:signature(context))
    UIManager:show(ConfirmBox:new{
        text=self:_repair_message(report),
        ok_text="一键修复",
        cancel_text="暂不处理",
        ok_callback=function()
            self._repair_prompt_open=false
            self:_run_book_repair(context,report,false)
        end,
        cancel_callback=function()
            self._repair_prompt_open=false
            self:_save_repair_state(book_id,{signature=signature,status="ignored",checked_at=os.time()})
        end,
    })
end

function Plugin:_schedule_current_book_repair_check(current,urgent)
    local prefs=self:_repair_preferences()
    if prefs.auto_check==false then return false end
    local context=self:_repair_context(current)
    if not context or not context.book then return false end
    local book_id=tostring((context.book or {}).book_id or (context.book or {}).bookId or "")
    if book_id=="" then return false end
    local signature=self.book_repair:signature(context)
    local previous=self:_repair_state()[book_id]
    if urgent~=true and type(previous)=="table" and tostring(previous.signature or "")==signature
        and (previous.status=="ok" or previous.status=="fixed" or previous.status=="ignored") then
        return false
    end
    if self.repair_async and self.repair_async:busy() then return false end
    local repair=self.book_repair
    local delay=urgent==true and .05 or 1.4
    UIManager:scheduleIn(delay,function()
        local active=self:_current_document_path()
        if tostring(active or "")~=tostring(context.path or "") then return end
        if self.repair_async:busy() then return end
        local started=self.repair_async:run("book-repair-check",function()
            return repair:inspect(context)
        end,function(result)
            if not result or result.ok~=true or type(result.value)~="table" then return end
            local report=result.value
            if tostring(self:_current_document_path() or "")~=tostring(context.path or "") then return end
            if #(report.issues or {})==0 then
                self:_save_repair_state(book_id,{signature=report.signature,status="ok",checked_at=os.time()})
                return
            end
            local row=self:_repair_state()[book_id]
            if urgent~=true and type(row)=="table" and tostring(row.signature or "")==tostring(report.signature or "")
                and row.status=="ignored" then return end
            self:_show_book_repair_prompt(context,report)
        end,90)
        if not started then logger.dbg("[MiuRead][Repair] check deferred") end
    end)
    return true
end

function Plugin:repair_current_book(confirmed)
    local context=self:_repair_context()
    if not context then self:info("请先打开一本觅阅书籍"); return end
    if confirmed~=true and self:_active_reader_ui() and self:_notice_enabled("repair_while_reading") then
        local dialog
        dialog=ButtonDialog:new{title="修复会重新检查当前书籍，期间评论、菜单或翻页可能暂时变慢。",title_align="center",buttons={
            {{text="继续修复",callback=function() UIManager:close(dialog); self:repair_current_book(true) end}},
            {{text="继续并不再提示",callback=function() UIManager:close(dialog); self:_set_notice_enabled("repair_while_reading",false); self:repair_current_book(true) end}},
            {{text="稍后处理",callback=function() UIManager:close(dialog) end}},
        }}
        UIManager:show(dialog)
        return
    end
    self:_run_book_repair(context,nil,true)
end

function Plugin:scan_downloaded_books_for_repair(confirmed)
    if confirmed~=true and self:_notice_enabled("library_scan") then
        self:_confirm_library_scan(function() self:scan_downloaded_books_for_repair(true) end)
        return
    end
    if self.repair_async:busy() then self:toast("已有检查或修复任务正在进行"); return end
    self:toast("正在检查已下载书籍",2)
    local repair=self.book_repair
    local started,err=self.repair_async:run("scan-book-repair",function()
        return repair:scan_downloaded()
    end,function(result)
        if not result or result.ok~=true or type(result.value)~="table" then
            self:info("检查失败：\n"..tostring(result and result.error or "未知原因")); return
        end
        local scan=result.value
        if tonumber(scan.affected or 0)==0 then
            self:info("检查完成，没有发现需要修复的已下载书籍。")
            return
        end
        UIManager:show(ConfirmBox:new{
            text="发现 "..tostring(scan.affected).." 本书需要修复。\n\n是否一键修复？",
            ok_text="全部修复",
            cancel_text="暂不处理",
            ok_callback=function()
                if self.repair_async:busy() then self:toast("已有修复任务正在进行"); return end
                local ok_start,error_start=self.repair_async:run("repair-downloaded-books",function()
                    return repair:repair_scan(scan)
                end,function(fixed)
                    if not fixed or fixed.ok~=true or type(fixed.value)~="table" then
                        self:info("批量修复失败：\n"..tostring(fixed and fixed.error or "未知原因")); return
                    end
                    local value=fixed.value
                    self:_record_repair_history({title="批量修复",book_id=""},value.ok and "已完成" or "部分失败")
                    self:info(value.ok and "修复完成。" or "部分书籍修复失败，请稍后重试。")
                end,300)
                if not ok_start then self:info("无法开始批量修复：\n"..tostring(error_start or "未知原因")) end
            end,
        })
    end,180)
    if not started then self:info("无法开始检查：\n"..tostring(err or "未知原因")) end
end

function Plugin:clear_invalid_comment_indexes()
    if self.repair_async:busy() then self:toast("已有检查或修复任务正在进行"); return end
    local repair=self.book_repair
    local started,err=self.repair_async:run("clear-invalid-comment-indexes",function()
        return repair:clear_invalid_downloaded_indexes()
    end,function(result)
        if result and result.ok==true then
            Thoughts.clear_memory_cache()
            self:info("已清理失效的评论索引。需要时会自动重新建立。")
        else
            self:info("清理失败：\n"..tostring(result and result.error or "未知原因"))
        end
    end,120)
    if not started then self:info("无法开始清理：\n"..tostring(err or "未知原因")) end
end

function Plugin:show_repair_history()
    local history=self.store:get("book_repair_history",{})
    local items={}
    for _,row in ipairs(type(history)=="table" and history or {}) do
        items[#items+1]={
            text=tostring(row.title or "书籍"),
            post_text=os.date("%m-%d %H:%M",tonumber(row.at) or os.time()).." · "..tostring(row.status or ""),
            enabled=false,
        }
    end
    if #items==0 then items[1]={text="还没有修复记录",enabled=false} end
    self:list("修复记录",items)
end

function Plugin:_confirm_library_scan(callback)
    if not self:_notice_enabled("library_scan") then callback(); return true end
    local dialog
    dialog=ButtonDialog:new{title="扫描大量本地书籍可能暂时增加耗电，并使主页响应变慢。",title_align="center",buttons={
        {{text="开始扫描",callback=function() UIManager:close(dialog); callback() end}},
        {{text="开始并不再提示",callback=function() UIManager:close(dialog); self:_set_notice_enabled("library_scan",false); callback() end}},
        {{text="取消",callback=function() UIManager:close(dialog) end}},
    }}
    UIManager:show(dialog)
    return true
end

function Plugin:book_repair_settings_menu()
    return {
        {text="自动检查书籍问题",checked_func=function()
            return (self.store:preferences().repair or {}).auto_check~=false
        end,keep_menu_open=true,callback=function()
            local p=self.store:preferences(); p.repair=p.repair or {}
            p.repair.auto_check=p.repair.auto_check==false
            self.store:save_preferences(p)
        end},
        {text="修复当前书籍",callback=function() self:repair_current_book() end},
        {text="扫描已下载书籍",callback=function() self:scan_downloaded_books_for_repair() end},
        {text="重新扫描本地书籍与封面",callback=function() self:show_miuread_home(true) end},
        {text="清理失效评论索引",callback=function() self:clear_invalid_comment_indexes() end},
        {text="修复记录",callback=function() self:show_repair_history() end},
        {text="重置检查结果",callback=function()
            self.store:set("book_repair_state",{})
            self:toast("已重置书籍检查结果")
        end},
    }
end

function Plugin:_toggle_preference(key)
    local p=self.store:preferences(); p[key]=not p[key]; self.store:save_preferences(p)
end




function Plugin:_thought_display_label()
    return "轻量列表 · 点击翻页"
end

function Plugin:display_settings_menu()
    return {
        {text="页面布局",post_text=(self:_home_preferences().layout_style=="compact" and "紧凑布局" or "标准布局"),sub_item_table_func=function() return self:home_layout_settings_menu() end},
        {text="首页书架来源",post_text="选择显示项目",sub_item_table_func=function() return self:home_source_settings_menu() end},
        {text="首页快捷面板",post_text="选择项目与顺序",sub_item_table_func=function() return self:home_quick_panel_settings_menu() end},
        {text="主页锁屏显示最近阅读封面",checked_func=function() return self:_home_preferences().lockscreen_recent~=false end,keep_menu_open=true,callback=function() self:_toggle_home_lockscreen() end},
        {text="刷新本地书库与封面",callback=function() self:_confirm_library_scan(function() self:show_miuread_home(true) end) end},
        {text="显示书架封面",checked_func=function() return self.store:preferences().shelf_covers~=false end,keep_menu_open=true,callback=function() self:_toggle_preference("shelf_covers") end},
    }
end
function Plugin:_memory_mode_label()
    local status=self.memory_mode:status()
    if not status.available then return status.enabled and "配置异常" or "不可用" end
    if status.enabled then return status.matches and "已开启" or "配置异常" end
    if status.residual then return "外部或残留设置" end
    return "关闭"
end

function Plugin:_set_memory_mode(enabled)
    local ok,result_or_error=self.memory_mode:set_enabled(enabled)
    if not ok then
        self:info("无法修改低内存模式：\n"..tostring(result_or_error))
        return
    end
    local result=result_or_error or {}
    if enabled then
        self:info("低内存模式已开启。\n\n完整退出并重新启动 KOReader 后生效。PDF、漫画和快速跳页可能稍慢。")
    elseif result.external_change then
        self:info("低内存模式已关闭。\n\n检测到缓存设置已被其他配置修改，因此没有覆盖当前值。完整重启 KOReader 后生效。")
    else
        self:info("低内存模式已关闭，原有缓存设置已恢复。\n\n完整退出并重新启动 KOReader 后生效。")
    end
end


function Plugin:restore_memory_mode()
    local status=self.memory_mode:status()
    if not status.enabled and not status.residual then
        self:info("当前没有检测到低内存设置，无需恢复。")
        return
    end
    local text
    if status.enabled then
        text="恢复开启低内存模式前的缓存设置？\n\n恢复后需要完整重启 KOReader。卸载觅阅前建议先执行恢复。"
    else
        text="检测到外部或旧版本遗留的低内存设置。是否恢复缓存策略？\n\n无法确认它是否由觅阅写入；恢复后需要完整重启 KOReader。"
    end
    UIManager:show(ConfirmBox:new{
        text=text,ok_text="恢复",ok_callback=function()
            if status.enabled then self:_set_memory_mode(false); return end
            local ok,result_or_error=self.memory_mode:restore_detected()
            if not ok then self:info("无法恢复缓存设置：\n"..tostring(result_or_error)); return end
            local result=result_or_error or {}
            self:info(result.used_default and "低内存设置已清除，将恢复 KOReader 默认缓存策略。\n\n完整重启 KOReader 后生效。"
                or "低内存设置已恢复。\n\n完整重启 KOReader 后生效。")
        end,
    })
end

function Plugin:toggle_memory_mode()
    local status=self.memory_mode:status()
    local state=(self.store:preferences().memory_mode or {}).enabled==true
    if state then
        self:_set_memory_mode(false)
        return
    end
    if status.residual then
        self:info("检测到外部或旧版本遗留的低内存设置。请先使用“恢复缓存设置”，再由觅阅重新开启。")
        return
    end
    UIManager:show(ConfirmBox:new{
        text="低内存模式适合下载大书时容易闪退或卡死的设备。\n\n开启后会减少 KOReader 页面缓存，PDF、漫画和快速跳页可能稍慢。需要完整重启 KOReader 后生效。",
        ok_text="开启",
        ok_callback=function() self:_set_memory_mode(true) end,
    })
end

function Plugin:download_settings_menu()
    local memory_status=self.memory_mode:status()
    local policy=tostring(self.store:preferences().download_reader_policy or "ask")
    local policy_label=policy=="allow" and "允许后台下载" or (policy=="after_reading" and "退出阅读后下载" or "每次询问")
    local items={
        {text="阅读时下载策略",post_text=policy_label,sub_item_table_func=function() return self:download_reader_policy_menu() end},
        {text="下载关键进度提示",checked_func=function() return self.store:preferences().download_notice_enabled~=false end,keep_menu_open=true,callback=function() self:_toggle_preference("download_notice_enabled") end},
        {text="下载完成提醒",checked_func=function() return self.store:preferences().download_complete_notice~=false end,keep_menu_open=true,callback=function() self:_toggle_preference("download_complete_notice") end},
        {text="低内存模式",post_text=self:_memory_mode_label(),checked_func=function() return (self.store:preferences().memory_mode or {}).enabled==true end,callback=function() self:toggle_memory_mode() end},
    }
    if memory_status.enabled or memory_status.residual then
        items[#items+1]={text="恢复缓存设置",callback=function() self:restore_memory_mode() end}
    end
    items[#items+1]={text="下载目录",post_text=self:_download_dir_label(),callback=function() self:directory_dialog() end}
    items[#items+1]={text="下载管理与清理",callback=function() self:show_downloads() end}
    return items
end
function Plugin:mp_settings_menu()
    return {
        {text="下载文章图片",checked_func=function() return self.store:preferences().mp_images==true end,keep_menu_open=true,callback=function() self:_toggle_preference("mp_images") end},
        {text="公众号缓存管理",sub_item_table_func=function() return self:mp_global_cache_menu() end},
    }
end
function Plugin:account_sync_settings_menu()
    local rows={
        {text="账号状态",post_text=self:_account_status_label(),callback=function() self:show_account_status() end},
        {text=self:logged_in() and "重新扫码登录" or "扫码登录",callback=function() self.auth_flow:start() end},
    }
    if self:logged_in() then rows[#rows+1]={text="退出登录",callback=function() self:confirm_logout() end} end
    for _,row in ipairs(self:sync_menu()) do rows[#rows+1]=row end
    return rows
end

function Plugin:more_settings_menu()
    return {
        {text="提醒与确认",sub_item_table_func=function() return self:notice_settings_menu() end},
        {text="书籍检查与修复",sub_item_table_func=function() return self:book_repair_settings_menu() end},
        {text="更新设置",sub_item_table_func=function() return self:update_settings_menu() end},
        {text="关于觅阅",callback=self:safe("about",function() self:show_about() end)},
    }
end

function Plugin:_download_settings_summary()
    local state=self:_download_state()
    local queue=self.store:download_queue()
    if state.status=="active" then return tostring(self:_download_percent(state)).."%" end
    if self:_has_download_status() then return self:_download_status_label():gsub("^后台下载%s*[·：]?%s*","") end
    if #queue>0 then return tostring(#queue).." 项等待" end
    return nil
end

function Plugin:settings_menu()
    return {
        {text="运行模式",post_text=self:_home_mode_label(),sub_item_table_func=function() return self:home_mode_menu() end},
        {text="首页与书架",post_text="布局、来源与快捷面板",sub_item_table_func=function() return self:display_settings_menu() end},
        {text="阅读界面",post_text="快捷面板与阅读状态",sub_item_table_func=function() return self:reader_quick_panel_settings_menu() end},
        {text="评论与标注",post_text=self:_thought_display_label(),sub_item_table_func=function() return self:thought_font_settings_menu() end},
        {text="账号与同步",post_text=self:progress_sync_label(),sub_item_table_func=function() return self:account_sync_settings_menu() end},
        {text="下载与存储",post_text=self:_download_settings_summary(),sub_item_table_func=function() return self:download_settings_menu() end},
        {text="公众号阅读",sub_item_table_func=function() return self:mp_settings_menu() end},
        {text="更多设置",sub_item_table_func=function() return self:more_settings_menu() end},
    }
end

function Plugin:thought_font_settings_menu()
    local prefs=self.store:preferences().thoughts or {}
    return {
        {text="评论字体跟随正文",checked_func=function()
            return (self.store:preferences().thoughts or {}).follow_body_font==true
        end,keep_menu_open=true,callback=function()
            local p=self.store:preferences(); p.thoughts=p.thoughts or {}
            p.thoughts.follow_body_font=p.thoughts.follow_body_font~=true
            self.store:save_preferences(p)
            if p.thoughts.follow_body_font then
                self:toast("评论字体将跟随正文")
            else
                self:toast("评论字体已改为固定字体")
            end
        end},
        {text="固定字体",post_text=self:_thought_font_face_label(prefs),enabled_func=function()
            return (self.store:preferences().thoughts or {}).follow_body_font~=true
        end,sub_item_table_func=function() return self:thought_font_face_menu() end},
        {text="字体大小",sub_item_table_func=function() return self:thought_font_menu() end},
    }
end

function Plugin:_thought_font_face_label(prefs)
    prefs=prefs or (self.store:preferences().thoughts or {})
    local name=U.trim(tostring(prefs.font_face or ""))
    return name~="" and name or "KOReader 默认"
end
function Plugin:thought_font_face_menu()
    local rows={
        {text="KOReader 默认字体（最快）",radio=true,menu_item_id="__default__",checked_func=function()
            return U.trim(tostring((self.store:preferences().thoughts or {}).font_face or ""))==""
        end,callback=function()
            local p=self.store:preferences(); p.thoughts=p.thoughts or {}
            p.thoughts.font_face=""; p.thoughts.follow_body_font=false
            self.store:save_preferences(p); self:toast("评论字体已设为 KOReader 默认字体")
        end},
    }
    local ok,faces=pcall(function()
        local cre=require("document/credocument"):engineInit()
        return cre and cre.getFontFaces and cre.getFontFaces() or {}
    end)
    if not ok or type(faces)~="table" then
        rows[#rows+1]={text="无法读取设备字体列表",enabled=false}
        return rows
    end
    local unique,list={},{}
    for _,face in ipairs(faces) do
        face=U.trim(tostring(face or ""))
        if face~="" and not unique[face] then unique[face]=true; list[#list+1]=face end
    end
    table.sort(list,function(a,b) return a:lower()<b:lower() end)
    for _,face in ipairs(list) do
        local selected=face
        rows[#rows+1]={text=selected,radio=true,menu_item_id=selected,checked_func=function()
            return tostring((self.store:preferences().thoughts or {}).font_face or "")==selected
        end,callback=function()
            local p=self.store:preferences(); p.thoughts=p.thoughts or {}
            p.thoughts.font_face=selected; p.thoughts.follow_body_font=false
            self.store:save_preferences(p); self:toast("评论字体已设为："..selected)
        end}
    end
    rows.max_per_page=7
    rows.open_on_menu_item_id_func=function()
        local face=U.trim(tostring((self.store:preferences().thoughts or {}).font_face or ""))
        return face~="" and face or "__default__"
    end
    return rows
end
function Plugin:thought_font_menu()
    local choices={{"standard","较小（默认）"},{"large","适中"},{"xlarge","接近正文"}}
    local rows={}
    for _,choice in ipairs(choices) do
        local key,label=choice[1],choice[2]
        rows[#rows+1]={text=label,radio=true,checked_func=function() return (self.store:preferences().thoughts or {}).font==key end,callback=function()
            local p=self.store:preferences(); p.thoughts=p.thoughts or {}; p.thoughts.font=key; self.store:save_preferences(p); self:toast("评论字体大小已设为："..label)
        end}
    end
    return rows
end
function Plugin:_download_dir_path()
    local custom=U.trim((self.store:preferences() or {}).download_dir or "")
    if custom~="" then return custom end
    return self.store.default_books_dir
end
function Plugin:_download_dir_label()
    local path=self:_download_dir_path()
    if path==self.store.default_books_dir then return "默认 · "..tostring(path) end
    return tostring(path)
end
function Plugin:_validate_download_dir(path)
    path=U.trim(path)
    if path=="" or path:sub(1,1)~="/" then return nil,"路径无效" end
    local attr=lfs.attributes(path)
    if not attr or attr.mode~="directory" then return nil,"文件夹不存在" end
    local probe=path.."/.miuread-write-test-"..tostring(os.time()).."-"..tostring(math.random(1000,9999))
    local f=io.open(probe,"wb")
    if not f then return nil,"该文件夹不可写" end
    f:write("ok"); f:close(); os.remove(probe)
    return true
end
function Plugin:directory_dialog()
    local current=self:_download_dir_path()
    if lfs.attributes(current,"mode")~="directory" then
        if lfs.attributes("/mnt/us/documents","mode")=="directory" then current="/mnt/us/documents"
        elseif lfs.attributes("/mnt/us","mode")=="directory" then current="/mnt/us"
        else current="/" end
    end
    local chooser=PathChooser:new{
        title="选择下载文件夹",
        select_directory=true,
        select_file=false,
        show_files=false,
        path=current,
        onConfirm=function(path)
            local ok,err=self:_validate_download_dir(path)
            if not ok then self:info("无法使用此文件夹：\n"..tostring(err)); return end
            local old=self:_download_dir_path()
            local p=self.store:preferences(); p.download_dir=path; self.store:save_preferences(p)
            local note="下载目录已设置为：\n"..tostring(path)
            if old~=path then note=note.."\n\n只影响以后下载的书籍；已下载内容保留在原位置。" end
            self:info(note)
        end,
    }
    UIManager:show(chooser)
end

function Plugin:_update_preferences()
    local p=self.store:preferences()
    p.update=U.merge({manifest=Config.UPDATE_MANIFEST,auto_check=true,interval=Config.AUTO_UPDATE_INTERVAL,
        last_attempt_at=0,last_success_at=0,last_prompted_version="",restart_mode="ask"},p.update or {})
    return p,p.update
end
function Plugin:_save_update_preferences(update)
    local p=self.store:preferences(); p.update=U.merge(p.update or {},update or {}); self.store:save_preferences(p)
end
function Plugin:_update_interval_label(seconds)
    seconds=tonumber(seconds) or Config.AUTO_UPDATE_INTERVAL
    if seconds<=86400 then return "每天" end
    if seconds<=3*86400 then return "每 3 天" end
    return "每 7 天"
end
function Plugin:update_frequency_menu()
    local values={{86400,"每天"},{3*86400,"每 3 天"},{7*86400,"每 7 天"}}
    local rows={}
    for _,entry in ipairs(values) do
        local seconds,label=entry[1],entry[2]
        rows[#rows+1]={text=label,radio=true,checked_func=function()
            local _,u=self:_update_preferences(); return tonumber(u.interval)==seconds
        end,callback=function()
            local _,u=self:_update_preferences(); u.interval=seconds; self:_save_update_preferences(u); self:toast("更新检查频率已设为"..label)
        end}
    end
    return rows
end
function Plugin:update_restart_menu()
    local choices={{"ask","安装后询问（推荐）"},{"auto","安装后自动重启"},{"never","稍后手动重启"}}
    local rows={}
    for _,choice in ipairs(choices) do
        local key,label=choice[1],choice[2]
        rows[#rows+1]={text=label,radio=true,checked_func=function()
            local _,u=self:_update_preferences(); return tostring(u.restart_mode)==key
        end,callback=function()
            local _,u=self:_update_preferences(); u.restart_mode=key; self:_save_update_preferences(u); self:toast("更新完成后："..label)
        end}
    end
    return rows
end
function Plugin:update_settings_menu()
    local _,update=self:_update_preferences()
    return {
        {text="自动检查更新",checked_func=function()
            local _,u=self:_update_preferences(); return u.auto_check~=false
        end,keep_menu_open=true,callback=function()
            local _,u=self:_update_preferences(); u.auto_check=u.auto_check==false; self:_save_update_preferences(u)
        end},
        {text="检查频率 · "..self:_update_interval_label(update.interval),sub_item_table_func=function() return self:update_frequency_menu() end},
        {text="安装完成后 · "..(update.restart_mode=="auto" and "自动重启" or (update.restart_mode=="never" and "稍后手动重启" or "询问是否重启")),sub_item_table_func=function() return self:update_restart_menu() end},
        {text="检查"..tostring(Config.UPDATE_CHANNEL_LABEL).."更新",callback=self:safe("update",function() self:check_update(false) end)},
        {text="当前运行版本 · "..tostring(self.version),enabled=false},
        {text="更新通道 · "..tostring(Config.UPDATE_CHANNEL_LABEL),enabled=false},
    }
end
function Plugin:_restart_koreader()
    if (self.download_task and self.download_task:busy()) or self._download_runtime~=nil then
        self:info("当前任务尚未完成，暂不重启。\n\n请等待任务结束，或先在下载管理中取消任务。")
        return false
    end
    if #self.store:download_queue()>0 then
        self:info("当前还有一个排队任务，暂不重启。\n\n请先取消排队任务或等待它完成。")
        return false
    end
    if self.cache_cleanup_task and self.cache_cleanup_task:busy() then
        self:info("缓存任务尚未完成，暂不重启。")
        return false
    end
    if Device and Device.isAndroid and Device:isAndroid() then
        self:info("Android 版 KOReader 无法保证由插件自动重新启动。\n\n请关闭并重新打开 KOReader。")
        return false
    end
    local function restart()
        self:_begin_koreader_exit("restart")
        if Device and Device.saveSettings then pcall(Device.saveSettings,Device) end
        UIManager:nextTick(function() UIManager:broadcastEvent(Event:new("Restart")) end)
    end
    local menu=self.ui and self.ui.menu
    if menu and type(menu.exitOrRestart)=="function" then
        menu:exitOrRestart(restart)
    else
        restart()
    end
    return true
end
function Plugin:_after_update_installed(manifest)
    local _,update=self:_update_preferences()
    local version=tostring(manifest and manifest.version or "新版本")
    if update.restart_mode=="never" then
        self:info("觅阅已更新至 "..version.."。\n\n请稍后手动重启 KOReader。")
    elseif update.restart_mode=="auto" then
        self:status_toast("更新完成","正在重启 KOReader",3)
        UIManager:scheduleIn(.8,function() self:_restart_koreader() end)
    else
        UIManager:show(ConfirmBox:new{
            text="更新文件已安装："..version.."。\n\n当前仍在运行 "..tostring(self.version).."，重启 KOReader 后才会切换到新版本。",
            ok_text="立即重启",cancel_text="稍后重启",ok_callback=function() self:_restart_koreader() end,
        })
    end
end
function Plugin:_present_update(manifest,automatic)
    if manifest.current then
        if not automatic then self:info("当前已是最新版本\n\n当前版本："..tostring(self.version)) end
        return
    end
    local _,update=self:_update_preferences()
    if automatic and tostring(update.last_prompted_version or "")==tostring(manifest.version or "") then return end
    update.last_prompted_version=tostring(manifest.version or "")
    self:_save_update_preferences(update)
    local text="发现"..tostring(Config.UPDATE_CHANNEL_LABEL).."版本 "..tostring(manifest.version)
    local notes=tostring(manifest.summary or "")
    if notes=="" then notes=tostring(manifest.notes or "") end
    if notes~="" then
        text=text.."\n\n更新内容\n"..notes
    end
    text=text.."\n\n是否下载并安装"
    UIManager:show(ConfirmBox:new{text=text,ok_text="下载并安装",ok_callback=function()
        self:online("install",function()
            local path=self.updater:download(manifest)
            local ok,err=self.updater:install(path,manifest)
            if ok then self:_after_update_installed(manifest)
            else self:info("更新失败：\n"..tostring(err)) end
        end)
    end})
end
function Plugin:maybe_auto_check_update(force)
    local _,update=self:_update_preferences()
    if not force and update.auto_check==false then return false end
    if self._auto_update_check_running then return false end
    local now=os.time()
    local interval=math.max(21600,tonumber(update.interval) or Config.AUTO_UPDATE_INTERVAL)
    local last=tonumber(update.last_attempt_at) or 0
    if not force and now-last<interval then return false end
    if not self:is_online() then return false end
    self._auto_update_check_running=true
    update.last_attempt_at=now
    self:_save_update_preferences(update)
    UIManager:scheduleIn(.05,self:safe("auto-update",function()
        local ok,manifest,err=pcall(self.updater.check,self.updater)
        self._auto_update_check_running=false
        if not ok then err=manifest; manifest=nil end
        local _,fresh=self:_update_preferences()
        if manifest then
            fresh.last_success_at=os.time()
            self:_save_update_preferences(fresh)
            self:_present_update(manifest,true)
        else
            logger.warn("[MiuRead][Updater] passive check failed",tostring(err))
            fresh.last_attempt_at=os.time()-math.max(0,interval-(Config.AUTO_UPDATE_RETRY_INTERVAL or 21600))
            self:_save_update_preferences(fresh)
        end
    end))
    return true
end
function Plugin:check_update(automatic)
    if automatic then return self:maybe_auto_check_update(true) end
    self:online("update",function()
        self:status_toast("更新","正在检查"..tostring(Config.UPDATE_CHANNEL_LABEL).."版本……",3)
        local ok,manifest,err=pcall(self.updater.check,self.updater)
        if not ok then err=manifest; manifest=nil end
        local _,update=self:_update_preferences()
        update.last_attempt_at=os.time()
        if manifest then update.last_success_at=os.time() end
        self:_save_update_preferences(update)
        if not manifest then self:info("检查更新失败：\n"..tostring(err)); return end
        self:_present_update(manifest,false)
    end)
end
function Plugin:show_about()
    local memory_note=""
    local memory_status=self.memory_mode:status()
    if memory_status.enabled then
        memory_note="\n\n低内存模式当前已开启。卸载觅阅前，请在“下载与存储”中恢复缓存设置。"
    elseif memory_status.residual then
        memory_note="\n\n检测到外部或遗留的低内存设置，可在“下载与存储”中检查并恢复。"
    end
    self:info(Config.NAME.." "..self.version
        .."\n\n微信读书内容下载、书架管理与阅读同步。"
        .."\n\n已下载书籍作为本地 EPUB 直接打开，不进行联网权限验证或锁定。"
        ..memory_note
        .."\n\n".._("Unofficial client"))
end
function Plugin:onExit()
    if not HOME_EXITING then self:_begin_koreader_exit("external exit") end
    return false
end
function Plugin:onRestart()
    if not HOME_EXITING then self:_begin_koreader_exit("external restart") end
    return false
end
function Plugin:onShowMiuRead()
    if self:_home_enabled() then return self:return_to_miuread_home() end
    self:show_shelf(false,false,"account")
end
function Plugin:onMiuReadReturnHome()
    if self:_home_enabled() then return self:return_to_miuread_home() end
    self:show_shelf(false,false,"account")
    return true
end
function Plugin:onToggleMiuReadProgressSync()
    if self:require_login() then self:toggle_progress_sync() end
    return true
end
function Plugin:onToggleMiuReadTimeSync()
    self:toggle_time_sync()
    return true
end
function Plugin:onShowMiuReadDownloads()
    self:show_downloads()
    return true
end
function Plugin:onShowMiuReadSyncStatus()
    self:show_sync_status(false)
    return true
end
function Plugin:onMiuReadQRLogin()
    if self:logged_in() then self:show_account_status() else self.auth_flow:start() end
    return true
end
function Plugin:onMiuReadLogout()
    self:confirm_logout()
    return true
end
function Plugin:onMiuReadReaderPanel()
    self:show_reader_quick_panel()
    return true
end
function Plugin:onMiuReadReaderFont()
    self:_show_reader_font_panel()
    return true
end
function Plugin:onMiuReadReaderTypeset()
    self:_show_reader_typeset_menu()
    return true
end
function Plugin:onMiuReadReaderProgress()
    self:_show_reader_progress_control()
    return true
end
function Plugin:onMiuReadUploadProgress()
    self:upload_local_progress(true)
    return true
end
function Plugin:onMiuReadPullProgress()
    self:manual_sync()
    return true
end
function Plugin:onMiuReadCurrentBook()
    self:_show_reader_current_book_panel()
    return true
end
function Plugin:onMiuReadCloseBook()
    if self:_home_enabled() then return self:return_to_miuread_home() end
    local ReaderUI=require("apps/reader/readerui")
    if ReaderUI and ReaderUI.instance and ReaderUI.instance.document then
        local readerui=ReaderUI.instance
        local file=readerui.document.file
        UIManager:nextTick(function()
            readerui:onClose()
            if file then readerui:showFileManager(file) end
        end)
    end
    return true
end
local function extract_thought_href(value,seen,depth)
    if depth>4 or value==nil then return nil end
    if type(value)=="string" then return value:match("(#?miuthought%-[%x%.]+)") end
    if type(value)~="table" then return nil end
    seen=seen or {}; if seen[value] then return nil end; seen[value]=true
    for _,key in ipairs({"href","url","target","link","uri","dest","destination"}) do local found=extract_thought_href(value[key],seen,depth+1); if found then return found end end
    for _,child in pairs(value) do local found=extract_thought_href(child,seen,depth+1); if found then return found end end
end
function Plugin:_start_thought_index_maintenance()
    if not self.thought_index_async or not self.ui or self.ui.document then return false end
    if self:_home_enabled() and not HomeView.is_shown() then return false end
    local now=os.time()
    if THOUGHT_MAINTENANCE.running==true or now-(tonumber(THOUGHT_MAINTENANCE.last_at) or 0)<120 then return false end
    if self.download_task and self.download_task:busy() then
        UIManager:scheduleIn(10,function() self:_start_thought_index_maintenance() end)
        return false
    end
    if self.thought_index_async:busy() or not self.thought_index_async:available() then return false end
    local data_dir=self.store.data_dir
    local pause_path=self._thought_index_pause_path
    os.remove(pause_path)
    THOUGHT_MAINTENANCE.running=true
    THOUGHT_MAINTENANCE.last_at=now
    local started,err=self.thought_index_async:run("thought-index-maintenance",function()
        local ok,ffi=pcall(require,"ffi")
        if ok and ffi then
            pcall(ffi.cdef,"int setpriority(int which, int who, int prio);")
            pcall(function() ffi.C.setpriority(0,0,15) end)
        end
        return Thoughts.build_missing_indexes(data_dir,pause_path,100000)
    end,function(result)
        THOUGHT_MAINTENANCE.running=false
        THOUGHT_MAINTENANCE.last_at=os.time()
        if not result or result.ok~=true or type(result.value)~="table" then
            logger.warn("[MiuRead][Thoughts] background index maintenance failed",
                tostring(result and result.error or "unknown"))
            return
        end
        local value=result.value
        logger.info("[MiuRead][Thoughts] background index maintenance",
            "checked=",tostring(value.checked or 0),"built=",tostring(value.built or 0),
            "failed=",tostring(value.failed or 0),"paused=",tostring(value.paused==true))
    end,900)
    if not started then
        THOUGHT_MAINTENANCE.running=false
        logger.dbg("[MiuRead][Thoughts] index maintenance deferred",tostring(err))
    end
    return started==true
end

function Plugin:_teardown_thought_tap()
    if self._thought_tap_setup and self.ui and self.ui.unRegisterTouchZones then pcall(function() self.ui:unRegisterTouchZones({{id="miuread_thought_popup",overrides={"tap_link"}}}) end) end
    self._thought_tap_setup=nil
end
function Plugin:_thought_font_size(level)
    local nominal={standard=12,large=14,xlarge=16}
    local value=nominal[tostring(level or "standard")] or nominal.standard
    return math.max(10,math.min(17,Device.screen:scaleBySize(value)))
end
local function usable_font_name(value)
    if type(value)~="string" then return nil end
    value=value:match("^%s*(.-)%s*$")
    if value=="" then return nil end
    return value
end
function Plugin:_thought_font_name(prefs)
    prefs=prefs or (self.store:preferences().thoughts or {})
    if prefs.follow_body_font~=true then
        return usable_font_name(prefs.font_face)
    end
    local name=usable_font_name(self.ui and self.ui.font and self.ui.font.font_face)
    if name then return name end

    local doc=self.ui and self.ui.document
    if doc and type(doc.getFontFace)=="function" then
        local ok,value=pcall(doc.getFontFace,doc)
        if ok then
            name=usable_font_name(value)
            if name then return name end
        end
    end

    if _G.G_reader_settings and type(_G.G_reader_settings.readSetting)=="function" then
        local ok,value=pcall(_G.G_reader_settings.readSetting,_G.G_reader_settings,"cre_font")
        if ok then return usable_font_name(value) end
    end
    return nil
end
function Plugin:_write_thought_popup_marker(stage, info, extra)
    local path=tostring(self._thought_popup_marker_path or "")
    if path=="" then return false end
    local payload={
        version=tostring(self.version or Config.VERSION),
        stage=tostring(stage or "unknown"),
        timestamp=os.time(),
        book_id=info and tostring(info.book_id or "") or nil,
        chapter_uid=info and tostring(info.chapter_uid or "") or nil,
        range=info and tostring(info.range or "") or nil,
    }
    for key,value in pairs(type(extra)=="table" and extra or {}) do payload[key]=value end
    local ok,encoded=pcall(Json.encode,payload)
    if not ok then return false end
    return U.atomic_write(path,encoded,true)==true
end

function Plugin:_clear_thought_popup_marker()
    local path=tostring(self._thought_popup_marker_path or "")
    if path~="" then os.remove(path) end
end

function Plugin:_flush_reader_checkpoint(reason, force)
    if not (self.ui and self.ui.document) then return false end
    -- KOReader already saves the current reading position during its own
    -- suspend/close lifecycle. MiuRead only needs an additional full settings
    -- flush when annotations or document settings actually changed. Avoiding a
    -- redundant save removes the most visible lock/close pause.
    if self._reader_checkpoint_dirty~=true and force~=true then
        logger.dbg("[MiuRead][ReaderCheckpoint] clean; extra save skipped","reason=",tostring(reason or "unspecified"))
        return true
    end
    local now=os.time()
    if force~=true and now-(tonumber(self._reader_checkpoint_last) or 0)<1 then return true end
    local ok,err=xpcall(function()
        if type(self.ui.saveSettings)=="function" then
            self.ui:saveSettings()
        elseif type(self.ui.handleEvent)=="function" then
            self.ui:handleEvent(Event:new("SaveSettings"))
            if self.ui.doc_settings and type(self.ui.doc_settings.flush)=="function" then
                self.ui.doc_settings:flush()
            end
        end
    end,debug.traceback)
    if ok then
        self._reader_checkpoint_last=now
        self._reader_checkpoint_dirty=false
        logger.info("[MiuRead][ReaderCheckpoint] saved","reason=",tostring(reason or "unspecified"))
        return true
    end
    logger.warn("[MiuRead][ReaderCheckpoint] save failed","reason=",tostring(reason or "unspecified"),tostring(err))
    return false
end

function Plugin:_schedule_reader_checkpoint(reason, delay)
    if not (self.ui and self.ui.document) then return false end
    if self._reader_checkpoint_task then
        UIManager:unschedule(self._reader_checkpoint_task)
        self._reader_checkpoint_task=nil
    end
    local task
    task=function()
        if self._reader_checkpoint_task~=task then return end
        self._reader_checkpoint_task=nil
        self:_flush_reader_checkpoint(reason,false)
    end
    self._reader_checkpoint_task=task
    UIManager:scheduleIn(math.max(.2,tonumber(delay) or 2.0),task)
    return true
end

function Plugin:_finish_thought_popup(generation)
    if generation and generation~=self._thought_popup_generation then return end
    self._thought_popup=nil
    self._thought_popup_busy=false
    self:_clear_thought_popup_marker()
    self:_mark_reader_busy(2)
    UIManager:scheduleIn(1.2,function() collectgarbage("step",48) end)
end

function Plugin:_close_active_thought_popup(reason)
    local popup=self._thought_popup
    self._thought_popup_generation=(tonumber(self._thought_popup_generation) or 0)+1
    self._thought_popup=nil
    self._thought_popup_busy=false
    self:_clear_thought_popup_marker()
    if popup and popup~=true then
        pcall(UIManager.close,UIManager,popup)
        logger.info("[MiuRead][ThoughtPopup] closed","reason=",tostring(reason or "forced"))
    end
end

function Plugin:_open_thought_info(info,generation)
    if generation~=self._thought_popup_generation or not (self.ui and self.ui.document) then
        self:_finish_thought_popup(generation)
        return
    end
    local started=os.clock()
    local popup,notice
    local ok,unexpected=xpcall(function()
        self:_write_thought_popup_marker("lookup",info)
        local group,err,token=Thoughts.find(self.store,info.book_id,info.chapter_uid,info.range)
        if not group then notice=tostring(err or "没有想法内容"); return end
        local prefs=self.store:preferences().thoughts or {}
        local function on_close() self:_finish_thought_popup(generation) end
        self:_write_thought_popup_marker("build",info,{mode="native_rounded_layered"})
        local source,comments,count,native_cache_hit=Thoughts.native_parts_cached(
            self.store,info.book_id,info.chapter_uid,info.range,group,token
        )
        if tostring(source or "")=="" and #(comments or {})==0 then notice="没有想法内容"; return end
        popup=ThoughtNativePopup.show{
            source_text=source,
            comments=comments,
            font_size=self:_thought_font_size(prefs.font),
            font_name=self:_thought_font_name(prefs),
            width_ratio=tonumber(prefs.width_ratio) or 0.91,
            height_ratio=tonumber(prefs.height_ratio) or 0.55,
            on_close=on_close,
            on_interact=function() self:_mark_reader_busy(30) end,
            on_error=function()
                self:info("评论显示失败，窗口已安全关闭。当前阅读位置不会丢失。")
            end,
        }
        logger.info("[MiuRead][ThoughtPopup] opened",
            "mode=","native_rounded_layered",
            "book=",tostring(info.book_id),"chapter=",tostring(info.chapter_uid),
            "comments=",tostring(count or 0),
            "source=",token and token.index_hit and "compact_index" or "chapter_cache",
            "cache=",token and token.cache_hit and "hit" or "miss",
            "native_cache=",native_cache_hit and "hit" or "miss",
            "elapsed_ms=",tostring(math.floor((os.clock()-started)*1000+.5)))
        if not popup then error("评论窗口未能加入界面") end
        self._thought_popup=popup
        self:_write_thought_popup_marker("visible",info,{elapsed_ms=math.floor((os.clock()-started)*1000+.5)})
        if token and token.index_hit~=true then
            UIManager:scheduleIn(.2,function() self:_schedule_current_book_repair_check(nil,true) end)
        end
    end,debug.traceback)
    if not ok then
        logger.err("[MiuRead][ThoughtPopup] open failed",tostring(unexpected))
        self:_finish_thought_popup(generation)
        self:info("评论暂时无法显示。当前阅读批注已先保存，请稍后重试。")
    elseif not popup then
        self:_finish_thought_popup(generation)
        if notice then self:info(notice) end
    end
end

function Plugin:_show_thought_href(href)
    local info=Thoughts.parse_href(href); if not info then return false end
    if self._thought_popup_busy or self._thought_popup then return true end
    local runtime=self._download_runtime
    if runtime and self.download_task and self.download_task:busy() and runtime.comment_slow_notice~=true then
        runtime.comment_slow_notice=true
        self:status_toast("后台正在下载","评论打开和翻页可能稍慢",3)
    end
    self._thought_popup_generation=(tonumber(self._thought_popup_generation) or 0)+1
    local generation=self._thought_popup_generation
    self._thought_popup_busy=true
    self:_write_thought_popup_marker("tap",info)
    self:_mark_reader_busy(30)
    -- Only write document metadata here when annotations really changed.
    -- Repeatedly opening comments must not force a storage flush every time.
    if self._reader_checkpoint_dirty and os.time()-(tonumber(self._reader_checkpoint_last) or 0)>=5 then
        self:_flush_reader_checkpoint("before_thought_popup",false)
    end
    UIManager:nextTick(function()
        self:_open_thought_info(info,generation)
    end)
    return true
end

function Plugin:_on_thought_tap(ges)
    if not self.ui or not self.ui.link or not self.ui.link.getLinkFromGes then return false end
    local ok,link=pcall(self.ui.link.getLinkFromGes,self.ui.link,ges); if not ok or not link then return false end
    local href=extract_thought_href(link,{},0); if not href then return false end
    return self:_show_thought_href(href)
end
function Plugin:_setup_thought_tap()
    if self._thought_tap_setup or not self.ui or not self.ui.registerTouchZones then return end
    local ok,Device=pcall(require,"device"); if ok and Device.isTouchDevice and not Device:isTouchDevice() then return end
    self.ui:registerTouchZones({{id="miuread_thought_popup",ges="tap",screen_zone={ratio_x=0,ratio_y=0,ratio_w=1,ratio_h=1},overrides={"tap_link"},handler=function(ges) return self:_on_thought_tap(ges) end}})
    self._thought_tap_setup=true
end

function Plugin:on_sync_record_ready(current)
    self:_teardown_thought_tap()
    if current and current.book then
        local book_id,path=tostring(current.book.book_id),current.path
        local record=current.record or {}
        local variant=tostring(current.variant or record.variant or "")
        if record.annotation_requested==true or variant:find("notes",1,true) then
            self:_setup_thought_tap()
        end
        UIManager:scheduleIn(1.0,function()
            local active=self.sync and self.sync.current
            if self.ui and self.ui.document and active and tostring(active.book.book_id)==book_id then
                self.store:mark_last_read(book_id,path)
            end
        end)
        self:_schedule_current_book_repair_check(current,false)
    end
    if self.store:preferences().sync.progress_enabled~=false then
        self:_wait_for_network("reader-ready-progress",function(ready)
            if ready and self.ui and self.ui.document then
                self:ensure_read_report_progress("reader_ready",true)
            elseif self.ui and self.ui.document then
                self:_save_progress_state(tostring(current.book.book_id),"waiting_network",
                    "等待 Wi-Fi 恢复后读取云端位置",nil,nil)
            end
        end,{minimum_delay=4.0,max_wait=60,interval=2.5})
    end
end
function Plugin:on_sync_record_missing()
    logger.dbg("[MiuRead][Sync] external EPUB ignored")
end
function Plugin:onReaderReady()
    self._home_reader_transition=false
    if self._reader_active_path then U.atomic_write(self._reader_active_path,"1",true) end
    -- Give EPUB opening and the first visible page priority over a background
    -- book generation task. The worker resumes automatically after this window.
    self:_mark_reader_busy(8)
    logger.info("[MiuRead][Sync] reader ready")
    UIManager:scheduleIn(.05,function()
        if not (self.ui and self.ui.document) then return end
        self:_install_reader_menu_bridge()
        self:_install_reader_quick_panel_zone()
        HOME_SESSION.opening_file=nil
        HOME_SESSION.opening_at=0
        local path=self:_current_document_path()
        local record,variant
        if path then
            local _book
            _book,record,variant=self.store:identify_file(path,false)
        end
        if record and (record.annotation_requested==true or tostring(variant or record.variant or ""):find("notes",1,true)) then
            self:_setup_thought_tap()
            logger.info("[MiuRead][ThoughtPopup] local tap ready before cloud sync")
        end
    end)
    if self._thought_index_pause_path then U.atomic_write(self._thought_index_pause_path,"1",true) end
    self:_teardown_thought_tap()
    self._progress_prompted_book_id=nil
    self._progress_check_running=false
    self._progress_remote_retries={}
    self._sync_success_notified=false
    self._last_progress_submit_notice=nil
    if self._reader_sync_ready_task then
        UIManager:unschedule(self._reader_sync_ready_task)
        self._reader_sync_ready_task=nil
    end
    local task
    task=function()
        if self._reader_sync_ready_task~=task then return end
        self._reader_sync_ready_task=nil
        if self.ui and self.ui.document then self.sync:on_reader_ready() end
    end
    self._reader_sync_ready_task=task
    -- Let KOReader paint the first page and restore input before identity and
    -- cloud-progress work begins. Local comment taps are already installed by
    -- the next-tick block above, so this does not delay reading interaction.
    UIManager:scheduleIn(.35,task)
end
function Plugin:onSetDimensions()
    if self.ui and self.ui.document then
        UIManager:nextTick(function()
            if self.ui and self.ui.document then
                self:_install_reader_menu_bridge()
                self:_install_reader_quick_panel_zone()
            end
        end)
    end
end
function Plugin:onPageUpdate(page)
    self:_mark_reader_busy(3)
    self.sync:on_page(page)
end
function Plugin:onAnnotationsModified()
    self._reader_checkpoint_dirty=true
    -- KOReader emits this for new, edited and deleted highlights/notes. Save
    -- once after a short quiet period so a later crash cannot discard a whole
    -- reading session, without writing on every pen movement.
    self:_schedule_reader_checkpoint("annotations_modified",2.0)
end
function Plugin:onSuspend()
    if self._reader_checkpoint_dirty==true then
        self:_flush_reader_checkpoint("suspend",true)
    end
    -- Do not let an active download take the CPU while KOReader is preparing
    -- the lock screen. No network request is awaited here.
    self:_mark_reader_busy(10)
    self._suspended_at=os.time()
    self.sync:on_suspend()
end
function Plugin:onResume()
    if self._reader_active_path then U.atomic_write(self._reader_active_path,"1",true) end
    self:_mark_reader_busy(5)
    if self.ui and self.ui.document then
        UIManager:nextTick(function()
            if self.ui and self.ui.document then
                self:_install_reader_menu_bridge()
                self:_install_reader_quick_panel_zone()
            end
        end)
    end
    local slept=self._suspended_at and os.time()-self._suspended_at or 0
    self._suspended_at=nil
    local prefs=self.store:preferences().sync or {}
    local recheck=prefs.progress_enabled~=false and slept>=math.max(60,tonumber(prefs.resume_after) or 300)
    if recheck then
        self._progress_prompted_book_id=nil
        self.sync:clear_verified("resume_recheck")
    end
    self.sync:on_resume(slept)
    if recheck then
        self:_wait_for_network("resume-progress",function(ready)
            if ready and self.ui and self.ui.document then
                self:ensure_read_report_progress("resume_recheck",true)
            elseif self.ui and self.ui.document then
                local r=self.sync:record()
                if r then self:_save_progress_state(tostring(r.book.book_id),"waiting_network",
                    "设备已唤醒，等待 Wi-Fi 完全恢复",nil,nil) end
            end
        end,{minimum_delay=6,max_wait=75,interval=3})
    end
end
function Plugin:_run_post_reader_work(generation)
    if generation~=self._post_reader_work_generation then return false end
    self._post_reader_work_task=nil
    local phase=tostring(HOME_SESSION.post_reader_work_phase or "")
    if phase=="" then return true end
    if self:_active_reader_ui() then
        logger.info("[MiuRead][Download] post-reader work deferred",phase)
        return false
    end
    if phase=="install" then
        local ok,err=pcall(self._install_pending_downloads,self,true)
        if not ok then logger.warn("[MiuRead][Download] pending install failed",tostring(err)) end
        HOME_SESSION.post_reader_work_phase="queue"
        local task
        task=function()
            if self._post_reader_work_task~=task then return end
            self._post_reader_work_task=nil
            self:_run_post_reader_work(generation)
        end
        self._post_reader_work_task=task
        UIManager:scheduleIn(.5,task)
        return true
    end
    if phase=="queue" then
        local ok,err=pcall(self._start_next_queued_download,self)
        if not ok then logger.warn("[MiuRead][Download] queued start failed",tostring(err)) end
        HOME_SESSION.post_reader_work_phase=nil
        return true
    end
    HOME_SESSION.post_reader_work_phase=nil
    return true
end

function Plugin:_schedule_post_reader_work(reason,delay)
    if not HOME_SESSION.post_reader_work_phase then
        HOME_SESSION.post_reader_work_phase="install"
    end
    self._post_reader_work_generation=(tonumber(self._post_reader_work_generation) or 0)+1
    local generation=self._post_reader_work_generation
    if self._post_reader_work_task then
        UIManager:unschedule(self._post_reader_work_task)
        self._post_reader_work_task=nil
    end
    local task
    task=function()
        if self._post_reader_work_task~=task then return end
        self._post_reader_work_task=nil
        self:_run_post_reader_work(generation)
    end
    self._post_reader_work_task=task
    UIManager:scheduleIn(math.max(0,tonumber(delay) or .8),task)
    logger.info("[MiuRead][Download] post-reader work scheduled",tostring(reason or "close"),tostring(HOME_SESSION.post_reader_work_phase))
    return true
end

function Plugin:onCloseDocument()
    if self._reader_checkpoint_dirty==true then
        self:_flush_reader_checkpoint("close_document",true)
    end
    self:_mark_reader_busy(6)
    self:_close_active_thought_popup("document closed")
    if self._reader_checkpoint_task then
        UIManager:unschedule(self._reader_checkpoint_task)
        self._reader_checkpoint_task=nil
    end
    if not self._reader_returning then self._home_reader_transition=false end
    local closing_path=tostring(self:_current_document_path() or "")
    local opening_path=tostring(HOME_SESSION.opening_file or "")
    -- During switchDocument the old ReaderUI closes while the target book is
    -- still opening. Keep that target guard until the new ReaderReady event.
    if opening_path=="" or opening_path==closing_path then
        HOME_SESSION.opening_file=nil
        HOME_SESSION.opening_at=0
    end
    self:_cancel_network_waits()
    if self.repair_async and self.repair_async.job and self.repair_async.job.label=="book-repair-check" then
        self.repair_async:cancel("document closed")
    end
    self._repair_prompt_open=false
    if self._thought_index_pause_path then os.remove(self._thought_index_pause_path) end
    if self._reader_active_path then os.remove(self._reader_active_path) end
    -- Keep the worker paused just long enough for the bookshelf to become
    -- responsive, then release the marker. Uploading the final reading tail is
    -- already delegated to the lightweight service and never awaited here.
    if self._reader_busy_path then
        local busy_path=self._reader_busy_path
        UIManager:scheduleIn(4,function() os.remove(busy_path) end)
    end
    if self._reader_sync_ready_task then
        UIManager:unschedule(self._reader_sync_ready_task)
        self._reader_sync_ready_task=nil
    end
    self:_teardown_thought_tap(); self._progress_prompted_book_id=nil; self._progress_check_running=false; self.sync:on_close()
    -- Keep post-close work pending until a non-reading surface is available.
    -- Opening another book quickly no longer drops installation or queue work.
    self:_schedule_post_reader_work("document closed",.8)
    sync_home_session()
    if self:_home_enabled() and HOME_READER_ORIGIN and not HOME_SESSION_SUPPRESSED
        and not HOME_NATIVE_VISIT and not HOME_EXITING then
        local delay=self._miuread_return_requested and .02 or .12
        self._miuread_return_requested=false
        local generation=self._reader_return_generation
        if not self._reader_returning then
            generation=self:_begin_reader_return("close document",closing_path)
        end
        UIManager:scheduleIn(delay,function()
            pcall(function()
                self:_schedule_reader_return_finish(generation,0,"close document")
            end)
        end)
    end
end
function Plugin:onFlushSettings()
    if self._reader_checkpoint_task then
        UIManager:unschedule(self._reader_checkpoint_task)
        self._reader_checkpoint_task=nil
    end
    self:_flush_reader_checkpoint("flush_settings",true)
    self:_flush_cover_index()
    self.store:flush()
end
return Plugin
