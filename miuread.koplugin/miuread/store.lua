local DataStorage=require("datastorage")
local lfs=require("libs/libkoreader-lfs")
local LuaSettings=require("luasettings")
local Config=require("miuread.config")
local Json=require("miuread.json")
local U=require("miuread.util")
local logger=require("logger")
local Store={}; Store.__index=Store
local function generate_login_session_id()
    return tostring(os.time()).."-"..tostring(math.random(100000,999999))
end
local defaults={
 schema=Config.SCHEMA,
 auth={login_session_id="",api_key="",cookies={},wr_ticket="",wr_wrpa="",ticket_updated_at=0,
     account={name="",vid="",logged_at=0},
     health={state="unknown",last_checked_at=0,last_ok_at=0,last_error_at=0,
         last_error_code="",last_error_message="",last_error_channel="",notice_pending=false,
         channels={
             shelf={state="unknown",checked_at=0,error="",code="",failures=0,retry_at=0},
             progress={state="unknown",checked_at=0,error="",code="",failures=0,retry_at=0},
             download={state="unknown",checked_at=0,error="",code="",failures=0,retry_at=0},
             annotations={state="unknown",checked_at=0,error="",code="",failures=0,retry_at=0},
             read_report={state="unknown",checked_at=0,error="",code="",failures=0,retry_at=0},
         }}},
 preferences={images=true,mp_images=false,shelf_covers=true,download_keep_awake=true,download_notice_enabled=false,download_complete_notice=true,download_reader_policy="ask",download_dir="",shelf_section="account",account_shelf_kind="books",home_ui={enabled=true,layout_style="desk",local_root="",local_roots={},local_library_mode="direct",auto_scan=false,local_check_on_open=true,page_by_section={},source_order={"account","generated","local","mp"},action_items={refresh=true,search=true,downloads=true,sync=true,frontlight=true,miuread_settings=true,all_books=false,history=false,file_manager=false,screenshot=false},action_order={"refresh","search","downloads","sync","frontlight","miuread_settings","all_books","history","file_manager","screenshot"},action_layout_version=1,panel_items={wifi=true,rotate=true,screenshot=true,koreader_settings=true,return_koreader=true,quit=true,frontlight=false,sync=false,miuread_settings=false,downloads=false,restart=false,sleep=false,full_refresh=false},panel_order={"wifi","rotate","screenshot","koreader_settings","return_koreader","quit","frontlight","sync","miuread_settings","downloads","restart","sleep","full_refresh"},panel_layout_version=1,more_expanded=false,network_metadata=false,background_thought_index=false},reader_ui={enabled=true,plugin_mode_enabled=false,show_title=true,show_status=true,show_recent=true,recent_actions={},quick_layout_version=7,quick_items={toc=true,progress=true,font=true,frontlight=true,sync=true,comment_font=true,page_display=false,typeset=false,current_book=false,downloads=false,full_refresh=false,koreader_menu=false,sleep=false},quick_order={"toc","progress","font","frontlight","sync","comment_font","page_display","typeset","current_book","downloads","full_refresh","koreader_menu","sleep"}},notices={reader_download=true,low_battery=true,low_storage=true,full_refresh=true,lockscreen=true,library_scan=true,repair_while_reading=true,mode_switch=true},memory_mode={enabled=false,previous_known=false,previous_ratio=false},thoughts={font="standard",font_face="",follow_body_font=false},repair={auto_check=true},update={manifest=Config.UPDATE_MANIFEST,auto_check=true,interval=Config.AUTO_UPDATE_INTERVAL,last_attempt_at=0,last_success_at=0,last_prompted_version="",restart_mode="ask"},sync={time_enabled=false,progress_enabled=true,success_notice_enabled=true,interval=Config.READ_INTERVAL,idle_timeout=Config.IDLE_TIMEOUT,threshold=Config.REMOTE_THRESHOLD,resume_after=300}},
 library={},sessions={},shelf_cache={books={},mp={},updated_at=0},cover_index={},cover_guard={active=false,started_at=0,stage="",version=""},update_state={},download_queue={},
 pending_installs={},read_report_consumed={},
}
local function invalidate_report_contexts_table(sessions)
    sessions=type(sessions)=="table" and sessions or {}
    local changed=0
    local clear_keys={
        "legacy_report_context","report_context","psvts","pclts","token","reader_url",
        "context_updated_at","report_login_session_id","verification_login_session_id",
        "remote","remote_sources","remote_checked_at","remote_web_error","remote_agent_error",
        "remote_verified","verified_at","verified_reason","verified_local_percent","verified_remote_percent",
        "progress_sync_state","progress_sync_message","progress_upload_state","progress_upload_error",
        "progress_upload_verified_at","progress_upload_source","progress_upload_at","progress_upload_percent",
        "last_response_summary","last_http_code","last_http_length","last_payload_public","last_path",
        "last_stage","last_error","last_attempts",
    }
    for _,session in pairs(sessions) do
        if type(session)=="table" then
            for _,key in ipairs(clear_keys) do
                if session[key]~=nil then session[key]=nil; changed=changed+1 end
            end
            if tonumber(session.consecutive_failures or 0)~=0 then session.consecutive_failures=0; changed=changed+1 end
            if tonumber(session.pending_report_seconds or 0)~=0 then session.pending_report_seconds=0; changed=changed+1 end
        end
    end
    return sessions,changed
end
local function invalidate_upload_health_table(auth)
    auth=U.merge(defaults.auth,auth or {})
    auth.health.notice_pending=false
    auth.health.last_error_channel=""
    if tostring(auth.api_key or "")~="" and next(auth.cookies or {})~=nil then
        auth.health.state="unknown"
        for _,channel in ipairs({"progress","read_report"}) do
            local row=auth.health.channels[channel] or {}
            auth.health.channels[channel]={
                state="unknown",checked_at=0,error="",code="",failures=0,retry_at=0,
                last_ok_at=tonumber(row.last_ok_at or 0) or 0,
            }
        end
    end
    return auth
end
local function settings_file_valid(path)
    if not path or lfs.attributes(path,"mode")~="file" then return false,"missing" end
    local size=U.file_size(path) or 0
    if size<=0 then return false,"empty" end
    local loader,err=loadfile(path)
    return loader~=nil,err
end

local function restore_settings_file(path,backup_path)
    if not path then return false end
    local exists=lfs.attributes(path,"mode")=="file"
    local valid,reason=settings_file_valid(path)
    if valid then return false end
    local candidates={path..".previous",backup_path,path..".old"}
    for _,candidate in ipairs(candidates) do
        local backup_ok=settings_file_valid(candidate)
        if backup_ok then
            local restored,restore_error=U.copy_file(candidate,path)
            if restored then
                logger.warn("[MiuRead][Store] damaged settings restored",
                    "source=",tostring(candidate),"reason=",tostring(reason))
                return true,candidate
            end
            logger.warn("[MiuRead][Store] settings restore failed",tostring(restore_error))
        end
    end
    if exists then
        local corrupt=path..".corrupt-"..tostring(os.time())
        local moved=os.rename(path,corrupt)
        logger.warn("[MiuRead][Store] damaged settings isolated",
            "file=",tostring(moved and corrupt or path),"reason=",tostring(reason))
    else
        logger.warn("[MiuRead][Store] settings missing and no valid backup","file=",tostring(path))
    end
    return true,nil
end

local function refresh_settings_backup(path,backup_path)
    local source=lfs.attributes(path)
    local backup=lfs.attributes(backup_path)
    if type(source)~="table" then return false end
    local needed=type(backup)~="table"
        or tonumber(source.size or -1)~=tonumber(backup.size or -2)
        or (tonumber(source.modification or 0)-tonumber(backup.modification or 0))>=300
    if not needed then return false end
    local copied,copy_error=U.copy_file(path,backup_path)
    if not copied then logger.warn("[MiuRead][Store] settings backup failed",tostring(copy_error)) end
    return copied==true
end

local function public_documents_root(data_dir)
    local kindle_documents = "/mnt/us/documents"
    if lfs.attributes(kindle_documents,"mode")=="directory" then
        return kindle_documents .. "/MiuRead"
    end
    local ok, home = pcall(function() return DataStorage:getDataDir() end)
    if ok and type(home)=="string" and home~="" then
        return home .. "/MiuRead"
    end
    return data_dir .. "/books"
end

function Store:new(options)
    options=options or {}
    local data=options.data_dir or (DataStorage:getFullDataDir().."/"..Config.DATA_DIR)
    U.mkdir(data); U.mkdir(data.."/books"); U.mkdir(data.."/mp"); U.mkdir(data.."/covers"); U.mkdir(data.."/temp"); U.mkdir(data.."/updates")
    local settings_path=options.settings_path or (DataStorage:getSettingsDir().."/miuread.lua")
    local settings_backup_path=settings_path..".miuread-backup"
    if options.isolated~=true then restore_settings_file(settings_path,settings_backup_path) end
    local o=setmetatable({
        data_dir=data,
        cache_books_dir=data.."/books",
        mp_dir=data.."/mp",
        default_books_dir=public_documents_root(data),
        covers_dir=data.."/covers",
        temp_dir=data.."/temp",
        updates_dir=data.."/updates",
        settings_path=settings_path,
        settings_backup_path=settings_backup_path,
        download_state_path=data.."/download-state.json",
        isolated=options.isolated==true,
    },self)
    o.db=LuaSettings:open(o.settings_path)
    for k,v in pairs(defaults) do if o.db:readSetting(k,nil)==nil then o.db:saveSetting(k,U.copy(v)) end end
    o:migrate()
    o.db:flush()
    if not o.isolated then
        local valid=settings_file_valid(o.settings_path)
        if valid then refresh_settings_backup(o.settings_path,o.settings_backup_path) end
    end
    return o
end
function Store:migrate()
    local schema=tonumber(self.db:readSetting("schema",1)) or 1
    if schema>=Config.SCHEMA then return end

    local previous=self.db:readSetting("preferences",{}) or {}
    local previous_home=type(previous.home_ui)=="table" and previous.home_ui or {}
    local p=U.merge(defaults.preferences,previous)

    -- Keep only preferences that still have a live reader or menu path.
    p.low_resource=nil
    p.annotation_mode=nil
    p.show_annotations=nil
    p.shelf_sort=nil
    p.shelf_scope=nil
    p.shelf_view=nil
    p.shelf_filters=nil
    p.account_shelf_sort=nil
    p.account_shelf_scope=nil
    p.generated_shelf_sort=nil
    p.generated_shelf_scope=nil

    p.shelf_section=tostring(p.shelf_section or "account")
    if p.shelf_section~="generated" then p.shelf_section="account" end
    p.account_shelf_kind=tostring(p.account_shelf_kind or "books")
    if p.account_shelf_kind~="mp" then p.account_shelf_kind="books" end

    p.sync=U.merge(defaults.preferences.sync,p.sync or {})
    if schema<15 then p.sync.progress_enabled=true end
    if schema<60 then p.sync.success_notice_enabled=true end
    p.sync.time_notice_enabled=nil
    p.sync.progress_notice_mode=nil
    p.sync.manual_only=nil
    p.sync.auto_upload=nil
    p.sync.check_resume=nil
    p.sync.require_verified=nil
    p.sync.pull_on_open=nil

    p.update=U.merge(defaults.preferences.update,p.update or {})
    p.update.manifest=Config.UPDATE_MANIFEST
    if not tonumber(p.update.interval) or tonumber(p.update.interval)<21600 then
        p.update.interval=Config.AUTO_UPDATE_INTERVAL
    end
    if p.update.restart_mode~="auto" and p.update.restart_mode~="never" then
        p.update.restart_mode="ask"
    end

    p.thoughts=U.merge(defaults.preferences.thoughts,p.thoughts or {})
    if schema<81 then
        p.thoughts.font="standard"
        p.thoughts.font_face=""
        p.thoughts.follow_body_font=false
    end
    if not ({small=true,standard=true,large=true,xlarge=true})[tostring(p.thoughts.font or "")] then
        p.thoughts.font="standard"
    end
    p.thoughts.font_face=tostring(p.thoughts.font_face or "")
    p.thoughts.follow_body_font=p.thoughts.follow_body_font==true
    p.thoughts.width_ratio=nil
    p.thoughts.height_ratio=nil
    p.thoughts.display_mode=nil
    p.thoughts.comments_per_page=nil

    p.home_ui=U.merge(defaults.preferences.home_ui,p.home_ui or {})
    p.home_ui.layout_version=nil
    p.home_ui.layout_style=p.home_ui.layout_style=="compact" and "compact" or "desk"
    p.home_ui.widgets=nil
    p.home_ui.preset=nil
    p.home_ui.goal_minutes=nil
    p.home_ui.swipe_quick=nil
    p.home_ui.initial_page=nil
    p.home_ui.quick_items=nil
    p.home_ui.quick_order=nil
    if (tonumber(previous_home.performance_defaults_version) or 0)<1 then
        p.home_ui.auto_scan=false
        p.home_ui.network_metadata=false
        p.home_ui.background_thought_index=false
    end
    p.home_ui.performance_defaults_version=nil
    if schema<93 and previous_home.local_library_mode==nil then
        local legacy=self.db:readSetting("home_local_index",{}) or {}
        local had_index=type(legacy)=="table" and type(legacy.books)=="table" and #legacy.books>0
        p.home_ui.local_library_mode=had_index and "manual" or "direct"
    end
    local mode=tostring(p.home_ui.local_library_mode or "direct")
    if mode~="auto" and mode~="manual" and mode~="direct" then mode="direct" end
    p.home_ui.local_library_mode=mode
    p.home_ui.auto_scan=mode=="auto"
    p.reader_ui=U.merge(defaults.preferences.reader_ui,p.reader_ui or {})
    p.notices=U.merge(defaults.preferences.notices,p.notices or {})
    if schema<96 and previous.download_reader_warning==false then
        p.notices.reader_download=false
    end
    p.download_reader_warning=nil
    p.repair=U.merge(defaults.preferences.repair,p.repair or {})

    if schema<40 then p.download_notice_enabled=false end
    if p.download_reader_policy~="allow" and p.download_reader_policy~="after_reading" then
        p.download_reader_policy="ask"
    end

    -- Rebuild the compact pending-install index used by document-close cleanup.
    if schema<36 then
        local pending={}
        local library=self.db:readSetting("library",{}) or {}
        local function add_pending(book_id,kind,chapter_uid,record)
            if type(record)~="table" or record.pending_install~=true
                or tostring(record.pending_file or "")=="" then return end
            local key=table.concat({tostring(book_id),tostring(chapter_uid or "full"),tostring(kind or "")},":")
            pending[#pending+1]={key=key,book_id=tostring(book_id),kind=tostring(kind or ""),
                chapter_uid=chapter_uid and tostring(chapter_uid) or nil,file=record.file,
                pending_file=record.pending_file,created_at=tonumber(record.downloaded_at) or os.time()}
        end
        for book_id,book in pairs(library) do
            for kind,record in pairs(book.variants or {}) do add_pending(book_id,kind,nil,record) end
            for uid,row in pairs(book.chapters or {}) do
                for kind,record in pairs(row or {}) do add_pending(book_id,kind,uid,record) end
            end
        end
        self.db:saveSetting("pending_installs",pending)
    end

    -- One discontinued beta renamed local EPUBs while checking reading rights.
    -- Restore those files directly and remove all retired access metadata.
    if schema<43 then
        local library=self.db:readSetting("library",{}) or {}
        local suffix=".miuread-locked"
        local function clear_record(record)
            if type(record)~="table" then return end
            local path=tostring(record.file or "")
            local target=tostring(record.original_file or "")
            if target=="" and path:sub(-#suffix)==suffix then target=path:sub(1,#path-#suffix) end
            if target~="" and path~="" and path~=target then
                if U.file_exists(target) then
                    if U.file_exists(path) and path:sub(-#suffix)==suffix then os.remove(path) end
                    record.file=target
                elseif U.file_exists(path) then
                    local ok=os.rename(path,target)
                    if ok then record.file=target end
                end
            end
            record.locked=nil; record.lock_reason=nil; record.locked_at=nil; record.original_file=nil
            record.access_status=nil; record.access_policy_version=nil
            record.ownership=nil; record.ownership_source=nil
            record.access_ownership=nil; record.access_ownership_source=nil
            record.account_vid=nil; record.verified_at=nil; record.valid_until=nil
            record.last_access_check=nil
        end
        for _,book in pairs(library) do
            if type(book)=="table" then
                book.access=nil
                for _,record in pairs(book.variants or {}) do clear_record(record) end
                for _,row in pairs(book.chapters or {}) do
                    for _,record in pairs(row or {}) do clear_record(record) end
                end
            end
        end
        local roots={}
        local chosen=U.trim(tostring(p.download_dir or ""))
        roots[#roots+1]=chosen~="" and chosen or self.default_books_dir
        roots[#roots+1]=self.cache_books_dir
        local seen={}
        for _,root in ipairs(roots) do
            if root and root~="" and not seen[root] then
                seen[root]=true
                for _,path in ipairs(U.list(root)) do
                    if tostring(path):sub(-#suffix)==suffix and U.file_exists(path) then
                        local target=tostring(path):sub(1,#path-#suffix)
                        if U.file_exists(target) then os.remove(path) else os.rename(path,target) end
                    end
                end
            end
        end
        self.db:saveSetting("library",library)
    end

    if schema<44 then self.db:saveSetting("shelf_cache",U.copy(defaults.shelf_cache)) end

    -- Remove the retired public-account collection format and its queued jobs.
    if schema<48 then
        local function is_old_mp_id(id)
            id=tostring(id or "")
            return id:sub(1,7)=="MP_WXS_" or id:lower()=="mpbook"
        end
        local library=self.db:readSetting("library",{}) or {}
        local sessions=self.db:readSetting("sessions",{}) or {}
        local library_changed,sessions_changed=false,false
        for id,row in pairs(library) do
            if is_old_mp_id(id) or (type(row)=="table" and tostring(row.content_type or "")=="mp_collection") then
                library[id]=nil; library_changed=true
                if sessions[tostring(id)]~=nil then sessions[tostring(id)]=nil; sessions_changed=true end
            end
        end
        if library_changed then self.db:saveSetting("library",library) end
        if sessions_changed then self.db:saveSetting("sessions",sessions) end
        local kept={}
        for _,job in ipairs(self.db:readSetting("download_queue",{}) or {}) do
            local book=type(job.book)=="table" and job.book or {}
            local options=type(job.options)=="table" and job.options or {}
            local obsolete=is_old_mp_id(book.bookId or book.book_id)
                or options.mp_collection==true
                or tostring(options.content_type or "")=="mp_collection"
                or tostring(book.content_type or "")=="mp_collection"
            if not obsolete then kept[#kept+1]=job end
        end
        self.db:saveSetting("download_queue",kept)
        local shelf=self.db:readSetting("shelf_cache",{}) or {}
        shelf.mp={}
        self.db:saveSetting("shelf_cache",U.merge(defaults.shelf_cache,shelf))
        local state=self:download_state()
        local state_book=type(state.book)=="table" and state.book or {}
        local state_options=type(state.options)=="table" and state.options or {}
        if is_old_mp_id(state.book_id or state_book.bookId or state_book.book_id)
            or state_options.mp_collection==true
            or tostring(state_options.content_type or "")=="mp_collection" then
            self:clear_download_state()
        end
    end

    if schema<82 then
        local queue=self.db:readSetting("download_queue",{}) or {}
        if #queue>1 then self.db:saveSetting("download_queue",{queue[1]}) end
    end

    local auth=U.merge(defaults.auth,self.db:readSetting("auth",{}) or {})
    auth.mp_cookie_header=nil
    auth.mp_extra_headers=nil
    auth.mp_referer=nil
    auth.mp_auth_source=nil
    auth.mp_authorized_at=nil
    local has_local=tostring(auth.api_key or "")~="" and next(auth.cookies or {})~=nil
    if schema<61 then
        auth.health=U.merge(defaults.auth.health,auth.health or {})
        auth.health.notice_pending=false
        auth.health.last_error_channel=""
        auth.health.state=has_local and "unknown" or "logged_out"
        for _,channel in ipairs({"shelf","progress","download","annotations","read_report"}) do
            local row=(auth.health.channels or {})[channel] or {}
            auth.health.channels[channel]={state="unknown",checked_at=0,error="",code="",failures=0,retry_at=0,
                last_ok_at=tonumber(row.last_ok_at or 0) or 0}
        end
    elseif schema<90 then
        auth=invalidate_upload_health_table(auth)
    end
    if not has_local then auth.health.state="logged_out" end
    local account=type(auth.account)=="table" and auth.account or {}
    if schema<90 and tostring(auth.login_session_id or "")==""
        and tostring(account.vid or "")~="" and has_local then
        auth.login_session_id=generate_login_session_id()
    end
    self.db:saveSetting("auth",auth)

    if schema<90 then
        local sessions=self.db:readSetting("sessions",{}) or {}
        local cleaned,changed=invalidate_report_contexts_table(sessions)
        if changed>0 then self.db:saveSetting("sessions",cleaned) end
    end

    self.db:saveSetting("preferences",p)
    if type(self.db.delSetting)=="function" then
        self.db:delSetting("external_epub_cache")
        self.db:delSetting("download_state")
        self.db:delSetting("last_cleanup_result")
    else
        self.db:saveSetting("external_epub_cache",nil)
        self.db:saveSetting("download_state",nil)
        self.db:saveSetting("last_cleanup_result",nil)
    end
    self.db:saveSetting("schema",Config.SCHEMA)
end

function Store:get(k,d) local v=self.db:readSetting(k,nil); return v==nil and U.copy(d) or v end
function Store:set(k,v) self.db:saveSetting(k,v); self:flush() end
function Store:set_deferred(k,v) self.db:saveSetting(k,v) end
local function sanitized_auth(value)
    local auth=U.merge(defaults.auth,value or {})
    auth.mp_cookie_header=nil
    auth.mp_extra_headers=nil
    auth.mp_referer=nil
    auth.mp_auth_source=nil
    auth.mp_authorized_at=nil
    return auth
end
function Store:auth() return sanitized_auth(self:get("auth",{})) end
function Store:save_auth(v) self:set("auth",sanitized_auth(v)) end
function Store:generate_login_session_id() return generate_login_session_id() end
function Store:ensure_login_session_id()
    local auth=self:auth()
    local account=type(auth.account)=="table" and auth.account or {}
    if tostring(auth.login_session_id or "")=="" and tostring(account.vid or "")~=""
        and tostring(auth.api_key or "")~="" and next(auth.cookies or {})~=nil then
        auth.login_session_id=generate_login_session_id()
        self:save_auth(auth)
    end
    return tostring(auth.login_session_id or "")
end
function Store:auth_health()
    local auth=self:auth()
    return U.merge(defaults.auth.health,auth.health or {})
end
function Store:clear_auth() self:set("auth",U.copy(defaults.auth)) end
function Store:clear_account_shelf_cache()
    local cache=self:shelf_cache()
    cache.books={}; cache.mp={}; cache.updated_at=0
    self:save_shelf_cache(cache)
end
function Store:preferences() return U.merge(defaults.preferences,self:get("preferences",{})) end
function Store:save_preferences(v) self:set("preferences",U.merge(defaults.preferences,v or {})) end
function Store:save_preferences_deferred(v) self:set_deferred("preferences",U.merge(defaults.preferences,v or {})) end
function Store:books_root() local p=self:preferences().download_dir; if p=="" then p=self.default_books_dir end; U.mkdir(p); return p end
function Store:epub_root() return self:books_root() end
function Store:book_cache_path(id) return self.cache_books_dir.."/"..U.id_name(id) end
function Store:mp_account_dir(id)
    local path=self.mp_dir.."/"..U.id_name(id)
    U.mkdir(self.mp_dir); U.mkdir(path)
    return path
end
function Store:mp_root() U.mkdir(self.mp_dir); return self.mp_dir end
function Store:book_dir(id) local p=self:book_cache_path(id); U.mkdir(p); return p end
function Store:epub_path(filename) local p=self:epub_root().."/"..tostring(filename); U.mkdir(self:epub_root()); return p end

local function basename(path) return tostring(path or ""):match("([^/]+)$") end
function Store:library() return self:get("library",{}) end
function Store:book(id) return self:library()[tostring(id)] end
function Store:save_book(id,patch)
    local all=self:library(); local key=tostring(id); all[key]=U.merge(all[key] or {book_id=key,variants={},chapters={}},patch or {}); self:set("library",all); return all[key]
end
function Store:clear_book_access(id)
    local all=self:library(); local key=tostring(id)
    if type(all[key])=="table" and all[key].access~=nil then
        all[key].access=nil
        self:set("library",all)
    end
    return all[key]
end
function Store:save_variant(id,kind,record)
    local b=self:book(id) or {book_id=tostring(id),variants={},chapters={}}; b.variants=b.variants or {}; b.variants[kind]=U.copy(record); return self:save_book(id,b)
end
function Store:save_chapter_variant(id,uid,kind,record)
    local b=self:book(id) or {book_id=tostring(id),variants={},chapters={}}; b.chapters=b.chapters or {}; local key=tostring(uid); b.chapters[key]=b.chapters[key] or {}; b.chapters[key][kind]=U.copy(record); return self:save_book(id,b)
end
function Store:variant(id,kind) local b=self:book(id); return b and b.variants and b.variants[kind] end
function Store:chapter_variant(id,uid,kind) local b=self:book(id); return b and b.chapters and b.chapters[tostring(uid)] and b.chapters[tostring(uid)][kind] end
local function add_unique_path(out,seen,path)
    path=tostring(path or "")
    if path~="" and not seen[path] then seen[path]=true; out[#out+1]=path end
end
function Store:partial_cache_paths(id)
    local root=self:book_cache_path(id)
    local out={}
    if lfs.attributes(root,"mode")~="directory" then return out end
    local ok,iter,state=pcall(lfs.dir,root)
    if not ok or type(iter)~="function" then return out end
    for name in iter,state do
        if name~="." and name~=".." and tostring(name):match("^%.miuread%-partial%-") then out[#out+1]=root.."/"..name end
    end
    table.sort(out)
    return out
end
function Store:book_has_partial_cache(id) return #self:partial_cache_paths(id)>0 end
function Store:variant_paths(id,kind)
    local r=self:variant(id,kind)
    return r and r.file and {r.file} or {}
end
function Store:chapter_paths(id,uid)
    local b=self:book(id); local row=b and b.chapters and b.chapters[tostring(uid)]
    local out,seen={},{}
    for _,r in pairs(row or {}) do add_unique_path(out,seen,r and r.file) end
    return out
end
local function book_has_records(book)
    if type(book)~="table" then return false end
    if next(book.variants or {}) then return true end
    for _,row in pairs(book.chapters or {}) do if next(row or {}) then return true end end
    return false
end
function Store:forget_variant(id,kind)
    local all=self:library(); local key=tostring(id); local b=all[key]; if not b then return end
    if b.variants then b.variants[kind]=nil end
    if not book_has_records(b) and not self:book_has_partial_cache(id) then all[key]=nil end
    self:set("library",all)
end
function Store:forget_chapter_all(id,uid)
    local all=self:library(); local key=tostring(id); local b=all[key]
    if b and b.chapters then b.chapters[tostring(uid)]=nil end
    if b and not book_has_records(b) and not self:book_has_partial_cache(id) then all[key]=nil end
    self:set("library",all)
end
function Store:forget_book_local_state(id)
    local key=tostring(id or "")
    if key=="" then return false end
    local all=self:library(); all[key]=nil; self:set("library",all)
    local sessions=self:get("sessions",{}); sessions[key]=nil; self:set("sessions",sessions)
    local covers=self:get("cover_index",{}); covers[key]=nil; self:set("cover_index",covers)

    local queue_out={}
    for _,job in ipairs(self:download_queue()) do
        local job_id=tostring((job.book and (job.book.bookId or job.book.book_id)) or job.book_id or "")
        if job_id~=key then queue_out[#queue_out+1]=job end
    end
    self:save_download_queue(queue_out)

    local pending_out={}
    for _,row in ipairs(self:pending_installs()) do
        if tostring(row.book_id or "")~=key then pending_out[#pending_out+1]=row end
    end
    self:save_pending_installs(pending_out)

    local repair=self:get("book_repair_state",{}); repair[key]=nil; self:set("book_repair_state",repair)
    local history_out={}
    for _,row in ipairs(self:get("book_repair_history",{})) do
        if tostring(row.book_id or "")~=key then history_out[#history_out+1]=row end
    end
    self:set("book_repair_history",history_out)

    local shelf=self:shelf_cache()
    local shelf_changed=false
    for _,group in ipairs({shelf.books or {},shelf.mp or {}}) do
        for _,row in ipairs(group) do
            if tostring(row.bookId or row.book_id or "")==key and row.cover_path~=nil then
                row.cover_path=nil; shelf_changed=true
            end
        end
    end
    if shelf_changed then self:save_shelf_cache(shelf) end

    local state=self:download_state()
    if tostring(state.book_id or (state.book and (state.book.bookId or state.book.book_id)) or "")==key then
        self:clear_download_state()
    end
    return true
end
function Store:prune_missing_files()
    local all=self:library(); local changed=false
    for id,b in pairs(all) do
        for kind,r in pairs(b.variants or {}) do if not (r and r.file and U.file_exists(r.file)) then b.variants[kind]=nil; changed=true end end
        for uid,row in pairs(b.chapters or {}) do
            for kind,r in pairs(row or {}) do if not (r and r.file and U.file_exists(r.file)) then row[kind]=nil; changed=true end end
            if next(row or {})==nil then b.chapters[uid]=nil; changed=true end
        end
        if not book_has_records(b) and not self:book_has_partial_cache(id) then all[id]=nil; changed=true end
    end
    if changed then self:set("library",all) end
    return changed
end
function Store:all_books()
    local o={}; for id,b in pairs(self:library()) do local x=U.copy(b); x.book_id=x.book_id or id; o[#o+1]=x end
    table.sort(o,function(a,b) return tonumber(a.updated_at or a.downloaded_at or 0)>tonumber(b.updated_at or b.downloaded_at or 0) end); return o
end
local function normalize_path(path)
    local value=tostring(path or ""):gsub("\\","/"):gsub("/+","/")
    value=value:gsub("/%./","/")
    while value:find("/[^/]+/%.%./") do value=value:gsub("/[^/]+/%.%./","/") end
    if #value>1 then value=value:gsub("/$","") end
    return value
end

local function read_pipe(command)
    local pipe=io.popen(command,"r")
    if not pipe then return nil end
    local data=pipe:read("*a")
    pipe:close()
    if data=="" then return nil end
    return data
end

local function xml_unescape(value)
    return tostring(value or "")
        :gsub("&lt;", "<"):gsub("&gt;", ">")
        :gsub("&quot;", '"'):gsub("&apos;", "'")
        :gsub("&amp;", "&")
end

local function filename_key(path)
    local name=tostring(basename(path) or ""):lower()
    -- Treat harmless spacing differences around the variant suffix as the same
    -- filename, but only relink when the match is unique.
    return name:gsub("[%s　]+", "")
end

local function identity_from_blob(blob,identity)
    blob=tostring(blob or "")
    identity=type(identity)=="table" and identity or {}
    identity.book_id=identity.book_id
        or blob:match('"book_id"%s*:%s*"([^"]+)"')
        or blob:match("miuread://book/([^<%s\"]+)")
    identity.variant=identity.variant or blob:match('"variant"%s*:%s*"([^"]+)"')
    identity.content_type=identity.content_type or blob:match('"content_type"%s*:%s*"([^"]+)"')
    if identity.standalone==nil and blob:match('"standalone"%s*:%s*true') then identity.standalone=true end
    identity.chapter_uid=identity.chapter_uid or blob:match('"chapter_uid"%s*:%s*"?([^",}%s]+)')
    identity.title=identity.title or xml_unescape(blob:match("<dc:title[^>]*>(.-)</dc:title>"))
    identity.author=identity.author or xml_unescape(blob:match("<dc:creator[^>]*>(.-)</dc:creator>"))
    return identity
end

function Store:epub_identity_light(path)
    if not path or not U.file_exists(path) or not tostring(path):lower():match("%.epub$") then return nil end
    local file=io.open(path,"rb")
    if not file then return nil end
    local size=file:seek("end") or 0
    file:seek("set",0)
    local head=file:read(math.min(size,768*1024)) or ""
    local tail=""
    if size>#head then
        file:seek("set",math.max(0,size-1024*1024))
        tail=file:read("*a") or ""
    end
    file:close()
    local identity=identity_from_blob(head.."\n"..tail,{})
    if tostring(identity.book_id or "")~="" or tostring(identity.title or "")~="" then return identity end
    return nil
end

function Store:epub_identity(path)
    local identity=self:epub_identity_light(path) or {}
    if tostring(identity.book_id or "")~="" then return identity end
    if not path or not U.file_exists(path) or not tostring(path):lower():match("%.epub$") then return nil end
    local quoted=U.shell_quote(path)
    local raw=read_pipe("unzip -p "..quoted.." OEBPS/miuread.json 2>/dev/null")
    if raw then
        local ok,value=pcall(Json.decode,raw)
        if ok and type(value)=="table" then identity=U.merge(identity,value) end
    end
    local opf=read_pipe("unzip -p "..quoted.." OEBPS/package.opf 2>/dev/null")
    if opf then identity=identity_from_blob(opf,identity) end
    if tostring(identity.book_id or "")~="" or tostring(identity.title or "")~="" then return identity end
    return nil
end

local function metadata_key(value)
    local text=tostring(value or ""):lower()
    text=text:gsub("%.epub$","")
    text=text:gsub("%s*%[[^%]]-%]%s*$","")
    text=text:gsub("%s*【.-】%s*$","")
    text=text:gsub("[%s%c%p　]+","")
    for _,mark in ipairs({"，","。","！","？","：","；","“","”","‘","’","《","》","〈","〉","（","）","【","】","·","—","…"}) do
        text=text:gsub(mark,"",1e6)
    end
    return text
end

local function relink_saved_record(store,all,book,record,path,current_size,relink)
    if not relink or type(record)~="table" then return end
    local changed=false
    if record.file~=path then
        record.file=path
        record.directory=path:match("^(.*)/[^/]+$")
        changed=true
    end
    if current_size and tonumber(record.file_size)~=tonumber(current_size) then
        record.file_size=current_size
        changed=true
    end
    if record.directory and book.directory~=record.directory then
        book.directory=record.directory
        changed=true
    end
    if changed then store:set("library",all) end
end

function Store:file_record_fast(path,relink)
    if not path then return nil end
    local normalized=normalize_path(path)
    local current_size
    local function file_size()
        if current_size==nil then current_size=U.file_size(path) or false end
        return current_size~=false and current_size or nil
    end
    local all=self:library()
    local function match_record(record)
        return type(record)=="table" and record.file and normalize_path(record.file)==normalized
    end
    for _,book in pairs(all) do
        for kind,record in pairs(book.variants or {}) do
            if match_record(record) then
                relink_saved_record(self,all,book,record,path,file_size(),relink)
                return book,record,kind
            end
        end
        for uid,row in pairs(book.chapters or {}) do
            for kind,record in pairs(row or {}) do
                if match_record(record) then
                    record.chapter_uid=uid
                    relink_saved_record(self,all,book,record,path,file_size(),relink)
                    return book,record,kind
                end
            end
        end
    end
    local wanted_name=filename_key(path)
    if wanted_name=="" then return nil end
    local matches={}
    for _,book in pairs(all) do
        for kind,record in pairs(book.variants or {}) do
            if type(record)=="table" and filename_key(record.file)==wanted_name then
                matches[#matches+1]={book=book,record=record,kind=kind}
            end
        end
        for uid,row in pairs(book.chapters or {}) do
            for kind,record in pairs(row or {}) do
                if type(record)=="table" and filename_key(record.file)==wanted_name then
                    matches[#matches+1]={book=book,record=record,kind=kind,uid=uid}
                end
            end
        end
    end
    if #matches==1 then
        local found=matches[1]
        if found.uid then found.record.chapter_uid=found.uid end
        relink_saved_record(self,all,found.book,found.record,path,file_size(),relink)
        return found.book,found.record,found.kind
    end
    return nil
end

function Store:file_record_from_identity(path,meta,relink)
    if not path or type(meta)~="table" then return nil end
    local current_size=U.file_size(path)
    local all=self:library()
    local id=tostring(meta.book_id or "")
    if id=="" then
        local wanted_title=metadata_key(meta.title)
        local wanted_author=metadata_key(meta.author)
        local matches={}
        if wanted_title~="" then
            for key,book in pairs(all) do
                if metadata_key(book.title)==wanted_title then
                    local author=metadata_key(book.author)
                    if wanted_author=="" or author=="" or author==wanted_author then
                        matches[#matches+1]={id=tostring(book.book_id or key),book=book}
                    end
                end
            end
        end
        if #matches==1 then
            id=matches[1].id
            meta.book_id=id
            meta.recovered_by="embedded_title"
            logger.info("[MiuRead][Store] legacy EPUB identity recovered by title","book=",id)
        else return nil end
    end
    local kind=tostring(meta.variant or "")
    if kind=="" then
        local name=tostring(basename(path) or "")
        if name:find("纯净版",1,true) then kind="clean"
        elseif name:find("划线与想法版",1,true) or name:find("想法版",1,true) then kind="notes" end
    end
    local chapters=type(meta.chapters)=="table" and meta.chapters or {}
    local standalone=meta.standalone==true
    local uid=tostring(meta.chapter_uid or ((chapters[1] and (chapters[1].uid or chapters[1].chapter_uid)) or ""))
    local book=all[id]
    if kind=="" and book then
        local available={}
        for existing_kind,existing_record in pairs(book.variants or {}) do
            if type(existing_record)=="table" then available[#available+1]=existing_kind end
        end
        kind=#available==1 and tostring(available[1]) or "recovered"
    elseif kind=="" then kind="recovered" end
    local record
    if book then
        if standalone then
            local row=uid~="" and book.chapters and book.chapters[uid] or nil
            record=row and row[kind]
            if record then record.chapter_uid=uid end
        else
            record=book.variants and book.variants[kind]
        end
        if not record then
            record={
                book_id=id,title=meta.title or book.title or basename(path),author=meta.author or book.author or "",
                file=path,directory=path:match("^(.*)/[^/]+$"),variant=kind,
                content_type=meta.content_type,sync_enabled=meta.sync_enabled,read_report_enabled=meta.read_report_enabled,
                downloaded_at=tonumber(meta.generated_at) or os.time(),chapter_map=chapters,
                chapter_count=#chapters,complete=meta.complete~=false,file_size=current_size,
                partial_range=meta.partial_range==true,range_start_index=tonumber(meta.range_start_index),
                range_end_index=tonumber(meta.range_end_index),range_start_title=meta.range_start_title,
                range_end_title=meta.range_end_title,annotation_pending=meta.annotation_pending==true or nil,
                annotation_error_kind=meta.annotation_error_kind,recovered=true,
            }
            if standalone and uid~="" then
                record.chapter_uid=uid
                book.chapters=book.chapters or {}; book.chapters[uid]=book.chapters[uid] or {}; book.chapters[uid][kind]=record
            else
                book.variants=book.variants or {}; book.variants[kind]=record
            end
        end
        if (#(book.catalog or {})==0) and #chapters>0 then book.catalog=U.copy(chapters) end
    else
        book={
            book_id=id,title=meta.title or tostring(basename(path) or id):gsub("%.epub$",""),
            author=meta.author or "",variants={},chapters={},catalog=chapters,
            content_type=meta.content_type,directory=path:match("^(.*)/[^/]+$"),updated_at=os.time(),recovered=true,
        }
        record={
            book_id=id,title=book.title,author=book.author,file=path,directory=book.directory,
            variant=kind,content_type=meta.content_type,sync_enabled=meta.sync_enabled,
            read_report_enabled=meta.read_report_enabled,downloaded_at=tonumber(meta.generated_at) or os.time(),
            chapter_map=chapters,chapter_count=#chapters,complete=meta.complete~=false,file_size=current_size,recovered=true,
            partial_range=meta.partial_range==true,range_start_index=tonumber(meta.range_start_index),
            range_end_index=tonumber(meta.range_end_index),range_start_title=meta.range_start_title,
            range_end_title=meta.range_end_title,annotation_pending=meta.annotation_pending==true or nil,
            annotation_error_kind=meta.annotation_error_kind,
        }
        if standalone and uid~="" then record.chapter_uid=uid; book.chapters[uid]={[kind]=record}
        else book.variants[kind]=record end
        all[id]=book
    end
    if record and relink then relink_saved_record(self,all,book,record,path,current_size,true) end
    return book,record,kind
end

function Store:identify_file(path,relink)
    local book,record,kind=self:file_record_fast(path,relink)
    if book then return book,record,kind end
    local meta=self:epub_identity(path)
    return self:file_record_from_identity(path,meta,relink)
end

function Store:file_record(path)
    return self:identify_file(path,true)
end

function Store:mark_last_read(id,path,progress)
    id=tostring(id or "")
    if id=="" then return end
    local patch={last_read_at=os.time()}
    if path then patch.last_read_path=path end
    if progress~=nil then patch.progress_local_percent=tonumber(progress) end
    self:save_session(id,patch)
end
function Store:clear_login_bound_sessions(reason)
    local sessions=self:get("sessions",{})
    local cleaned,changed=invalidate_report_contexts_table(sessions)
    if changed>0 then self:set("sessions",cleaned) end
    self:save_auth(invalidate_upload_health_table(self:get("auth",{})))
    logger.info("[MiuRead][Store] login-bound sessions cleared",
        "reason=",tostring(reason or "unknown"),"fields=",tostring(changed))
    return changed,reason
end
function Store:session(id) return self:get("sessions",{})[tostring(id)] end
function Store:save_session(id,patch,flush_now) local a=self:get("sessions",{}); local k=tostring(id); a[k]=U.merge(a[k] or {},patch or {}); self.db:saveSetting("sessions",a); if flush_now~=false then self:flush() end; return a[k] end
function Store:shelf_cache() return U.merge(defaults.shelf_cache,self:get("shelf_cache",{})) end
function Store:save_shelf_cache(v) self:set("shelf_cache",U.merge(defaults.shelf_cache,v or {})) end
function Store:update_cached_progress(id,percent)
    id=tostring(id or "")
    percent=tonumber(percent)
    if id=="" or percent==nil then return false end
    local cache=self:shelf_cache()
    local changed=false
    for _,group in ipairs({cache.books or {},cache.mp or {}}) do
        for _,row in ipairs(group) do
            if tostring(row.bookId or row.book_id or "")==id then
                row.progress=U.clamp(percent,0,100)
                row.finished=row.progress>=100
                changed=true
            end
        end
    end
    if changed then self:save_shelf_cache(cache) end
    return changed
end
function Store:cover_guard() return U.merge(defaults.cover_guard,self:get("cover_guard",{})) end
function Store:save_cover_guard(v) self:set("cover_guard",U.merge(defaults.cover_guard,v or {})) end
function Store:cover_path(id) return self.covers_dir.."/"..U.id_name(id)..".img" end
function Store:update_state() return self:get("update_state",{}) end
function Store:save_update_state(v) self:set("update_state",v or {}) end
function Store:download_state()
    local raw=U.read_file(self.download_state_path,true)
    if not raw or raw=="" then return {} end
    local ok,value=pcall(Json.decode,raw)
    return ok and type(value)=="table" and value or {}
end
function Store:save_download_state(value)
    local ok,encoded=pcall(Json.encode,value or {})
    if not ok then return false,encoded end
    return U.atomic_write(self.download_state_path,encoded,true)
end
function Store:clear_download_state() os.remove(self.download_state_path) end
function Store:download_queue()
    local queue=self:get("download_queue",{})
    if type(queue)~="table" then return {} end
    if #queue<=1 then return queue end
    return {queue[1]}
end
function Store:save_download_queue(queue)
    queue=type(queue)=="table" and queue or {}
    local kept={}
    if type(queue[1])=="table" then kept[1]=U.copy(queue[1]) end
    self:set("download_queue",kept)
end
function Store:enqueue_download(job)
    local queue=self:download_queue()
    if #queue>=1 then return nil,"full" end
    queue[1]=U.copy(job or {})
    self:save_download_queue(queue)
    return 1
end
function Store:dequeue_download()
    local queue=self:download_queue(); if #queue==0 then return nil end
    local job=table.remove(queue,1); self:save_download_queue(queue); return job
end
function Store:remove_queued_download(index)
    local queue=self:download_queue(); index=tonumber(index); if not index or not queue[index] then return false end
    table.remove(queue,index); self:save_download_queue(queue); return true
end
function Store:pending_installs() return self:get("pending_installs",{}) end
function Store:save_pending_installs(rows) self:set("pending_installs",type(rows)=="table" and rows or {}) end
function Store:add_pending_install(book_id,kind,chapter_uid,record)
    local rows=self:pending_installs()
    local key=table.concat({tostring(book_id or ""),tostring(chapter_uid or "full"),tostring(kind or "")},":")
    local item={key=key,book_id=tostring(book_id or ""),kind=tostring(kind or ""),
        chapter_uid=chapter_uid and tostring(chapter_uid) or nil,file=record and record.file,
        pending_file=record and record.pending_file,created_at=os.time()}
    local replaced=false
    for index,row in ipairs(rows) do
        if tostring(row.key or "")==key then rows[index]=item; replaced=true; break end
    end
    if not replaced then rows[#rows+1]=item end
    self:save_pending_installs(rows)
    return item
end
function Store:remove_pending_install(book_id,kind,chapter_uid)
    local rows,out=self:pending_installs(),{}
    local key=table.concat({tostring(book_id or ""),tostring(chapter_uid or "full"),tostring(kind or "")},":")
    local changed=false
    for _,row in ipairs(rows) do
        if tostring(row.key or "")==key then changed=true else out[#out+1]=row end
    end
    if changed then self:save_pending_installs(out) end
    return changed
end
function Store:prune_pending_installs()
    local rows,out=self:pending_installs(),{}
    local changed=false
    for _,row in ipairs(rows) do
        if row.pending_file and U.file_exists(row.pending_file) then out[#out+1]=row else changed=true end
    end
    if changed then self:save_pending_installs(out) end
    return out
end
function Store:is_read_report_consumed(stamp)
    stamp=tostring(stamp or "")
    if stamp=="" then return false end
    local rows=self:get("read_report_consumed",{})
    return rows[stamp]~=nil
end
function Store:mark_read_report_consumed(stamp)
    stamp=tostring(stamp or "")
    if stamp=="" then return end
    local rows=self:get("read_report_consumed",{})
    rows[stamp]=os.time()
    local ordered={}
    for key,at in pairs(rows) do ordered[#ordered+1]={key=key,at=tonumber(at) or 0} end
    table.sort(ordered,function(a,b) return a.at>b.at end)
    for index=#ordered,21,-1 do rows[ordered[index].key]=nil end
    self:set("read_report_consumed",rows)
end
function Store:flush()
    local previous_path=self.settings_path..".previous"
    if not self.isolated then
        local valid=settings_file_valid(self.settings_path)
        if valid then U.copy_file(self.settings_path,previous_path) end
    end
    local ok,err=xpcall(function() self.db:flush() end,debug.traceback)
    if not ok then
        if not self.isolated then restore_settings_file(self.settings_path,self.settings_backup_path) end
        error(err)
    end
    if not self.isolated then
        local valid,reason=settings_file_valid(self.settings_path)
        if valid then
            U.copy_file(self.settings_path,self.settings_backup_path)
            os.remove(previous_path)
        else
            logger.warn("[MiuRead][Store] settings flush produced invalid file","reason=",tostring(reason))
            restore_settings_file(self.settings_path,self.settings_backup_path)
            self.db=LuaSettings:open(self.settings_path)
        end
    end
    return true
end
function Store:reload()
    if not self.isolated then restore_settings_file(self.settings_path,self.settings_backup_path) end
    self.db = LuaSettings:open(self.settings_path)
    if not self.isolated then
        local valid=settings_file_valid(self.settings_path)
        if valid then U.copy_file(self.settings_path,self.settings_backup_path) end
    end
    return self
end
return Store
