local DataStorage=require("datastorage")
local lfs=require("libs/libkoreader-lfs")
local LuaSettings=require("luasettings")
local Config=require("miuread.config")
local Json=require("miuread.json")
local U=require("miuread.util")
local Store={}; Store.__index=Store
local defaults={
 schema=Config.SCHEMA,
 auth={api_key="",cookies={},wr_ticket="",wr_wrpa="",ticket_updated_at=0,
     account={name="",vid="",logged_at=0}},
 preferences={images=true,mp_images=false,shelf_covers=true,download_keep_awake=true,download_notice_enabled=false,download_complete_notice=true,download_dir="",shelf_section="account",account_shelf_kind="books",thoughts={font="standard",font_face="",follow_body_font=false,width_ratio=0.91,height_ratio=0.60},update={manifest=Config.UPDATE_MANIFEST},sync={time_enabled=false,time_notice_enabled=false,progress_enabled=true,progress_notice_mode="off",manual_only=false,auto_upload=false,pull_on_open=true,check_resume=false,require_verified=false,interval=Config.READ_INTERVAL,idle_timeout=Config.IDLE_TIMEOUT,threshold=Config.REMOTE_THRESHOLD,resume_after=300}},
 library={},sessions={},shelf_cache={books={},mp={},updated_at=0},cover_index={},cover_guard={active=false,started_at=0,stage="",version=""},update_state={},download_queue={},
 pending_installs={},last_cleanup_result={},read_report_consumed={},
}
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
    local o=setmetatable({
        data_dir=data,
        cache_books_dir=data.."/books",
        mp_dir=data.."/mp",
        default_books_dir=public_documents_root(data),
        covers_dir=data.."/covers",
        temp_dir=data.."/temp",
        updates_dir=data.."/updates",
        settings_path=options.settings_path or (DataStorage:getSettingsDir().."/miuread.lua"),
        download_state_path=data.."/download-state.json",
        isolated=options.isolated==true,
    },self)
    o.db=LuaSettings:open(o.settings_path)
    for k,v in pairs(defaults) do if o.db:readSetting(k,nil)==nil then o.db:saveSetting(k,U.copy(v)) end end
    o:migrate()
    -- v1.1.45 intentionally disables automatic legacy EPUB relocation. File
    -- moves must never run during every reader/file-manager transition.
    o.db:flush()
    return o
end
function Store:migrate()
    local schema=tonumber(self.db:readSetting("schema",1)) or 1
    if schema<Config.SCHEMA then
        local previous=self.db:readSetting("preferences",{}) or {}
        local p=U.merge(defaults.preferences,previous)
        if schema<10 then
            p.annotation_mode="all"
            p.show_annotations=true
            p.sync=p.sync or {}
            p.sync.manual_only=true
            p.sync.auto_upload=false
            p.sync.pull_on_open=false
            p.sync.check_resume=false
            p.sync.require_verified=false
        end
        if schema<11 and previous.download_keep_awake==nil then
            p.download_keep_awake=true
        end
        -- Schema 12 keeps private checkpoints/comments in koreader/miuread while
        -- final EPUB files default to the normal KOReader documents directory.
        if schema<13 then
            local sessions=self.db:readSetting("sessions",{}) or {}
            for _,session in pairs(sessions) do
                if type(session)=="table" then
                    session.report_context=nil
                    session.psvts=nil; session.pclts=nil; session.token=nil
                    session.reader_url=nil; session.context_updated_at=nil
                    session.last_path=nil; session.last_attempts=nil; session.last_stage=nil
                    session.last_response_summary=nil; session.last_http_code=nil
                    session.last_http_length=nil; session.last_payload_public=nil
                    session.last_error=nil; session.consecutive_failures=0
                    session.read_context_version=2
                end
            end
            self.db:saveSetting("sessions",sessions)
        end
        if schema<15 then
            p.sync=p.sync or {}
            if previous.sync==nil or previous.sync.progress_enabled==nil then p.sync.progress_enabled=true end
            p.sync.pull_on_open=p.sync.progress_enabled~=false
            p.sync.require_verified=false
            p.sync.manual_only=false
        end
        if schema<16 then
            -- Public builds use one fixed OTA manifest. Legacy channel/URL
            -- preferences are ignored and replaced by the repository address.
            p.update={manifest=Config.UPDATE_MANIFEST}
        end
        if schema<18 then
            -- Replace the legacy centered comment card with the compact
            -- bottom-sheet layout. These dimensions were never user-facing,
            -- so migrate existing installations instead of preserving the
            -- oversized saved values.
            p.thoughts=p.thoughts or {}
            p.thoughts.width_ratio=0.92
            p.thoughts.height_ratio=0.42
        end
        if schema<19 then
            -- v1.0.6 treats the saved height as a maximum, not a fixed card
            -- height. Give the comments room to show several entries while
            -- allowing short content to shrink to its actual rendered size.
            p.thoughts=p.thoughts or {}
            p.thoughts.width_ratio=0.94
            p.thoughts.height_ratio=0.60
        end
        if schema<20 then
            -- v1.0.7 uses a near-full-width comments sheet with compact outer
            -- and inner spacing. Migrate old saved dimensions so existing
            -- installations receive the same layout without clearing data.
            p.thoughts=p.thoughts or {}
            p.thoughts.width_ratio=0.985
            p.thoughts.height_ratio=0.60
        end
        if schema<21 then
            -- v1.0.8 returns to a centered dialog and reallocates interior
            -- space to the selected text and comments instead of leaving
            -- large blank areas. Existing installs are migrated directly.
            p.thoughts=p.thoughts or {}
            p.thoughts.width_ratio=0.94
            p.thoughts.height_ratio=0.68
        end
        if schema<22 then
            -- v1.0.9 removes MuPDF's internal page margins and sizes short
            -- comment dialogs from the actual rendered content height.
            p.thoughts=p.thoughts or {}
            p.thoughts.width_ratio=0.94
            p.thoughts.height_ratio=0.68
        end
        if schema<23 then
            -- v1.0.10 combines the lighter card proportions with the denser
            -- comment list: slightly smaller dialog, balanced inner spacing,
            -- framed source quote and compact inline like counts.
            p.thoughts=p.thoughts or {}
            p.thoughts.width_ratio=0.91
            p.thoughts.height_ratio=0.60
        end
        if schema<24 then
            -- v1.1.0 adds the combined local/cloud shelf, two-column cover
            -- view, compact list, local shelf search and single-scope filters.
            if previous.shelf_view==nil then p.shelf_view="grid" end
            if previous.shelf_scope==nil then
                local old=previous.shelf_filters or {}
                if old.downloaded then p.shelf_scope="downloaded"
                elseif old.reading then p.shelf_scope="reading"
                elseif old.finished then p.shelf_scope="finished"
                else p.shelf_scope="all" end
                p.shelf_filters={}
            end
            if previous.shelf_sort==nil then p.shelf_sort="read" end
        end
        if schema<25 then
            -- v1.1.1 removes the unstable custom two-column Menu layout and
            -- returns every device to the proven one-column compact shelf.
            p.shelf_view="compact"
        end
        if schema<26 then
            -- v1.1.25 adds a user-facing switch for the automatic reading-time
            -- status notice. Existing users keep the current visible behavior.
            p.sync=p.sync or {}
            if previous.sync==nil or previous.sync.time_notice_enabled==nil then
                p.sync.time_notice_enabled=true
            end
        end
        if schema<28 then
            -- v1.1.34 records only the short-lived shelf-cover render guard.
            -- If KOReader exits while a cover page is being built, the next
            -- launch can open the shelf once without covers and avoid a loop.
            self.db:saveSetting("cover_guard",U.copy(defaults.cover_guard))
        end
        if schema<29 then
            -- Reset position confirmation for the new two-way sync rule and
            -- neutralize old diagnostic labels kept in user settings.
            local sessions=self.db:readSetting("sessions",{}) or {}
            local function neutral(value)
                if type(value)~="string" then return value end
                value=value:gsub("legacy_[%d%.]+_","compat_read_report_")
                value=value:gsub("[%d]+%.[%d]+%.[%d]+%s*原版","兼容")
                value=value:gsub("%s+"," ")
                return value
            end
            for _,session in pairs(sessions) do
                if type(session)=="table" then
                    session.remote_verified=false
                    session.verified_at=nil
                    session.verified_reason=nil
                    session.last_path=neutral(session.last_path)
                    session.last_stage=neutral(session.last_stage)
                    session.last_response_summary=neutral(session.last_response_summary)
                end
            end
            self.db:saveSetting("sessions",sessions)
        end

        if schema<30 then
            -- v1.1.36 keeps the cloud shelf order by default and separates
            -- progress-success notices from reading-time notices.
            p.sync=p.sync or {}
            if previous.sync==nil or previous.sync.progress_notice_mode==nil then
                p.sync.progress_notice_mode="first"
            end
            if tostring(previous.shelf_sort or "read")=="read" then
                p.shelf_sort="cloud"
            end
        end

        if schema<31 then
            -- v1.1.37 simplifies the menus and persists the single-download queue.
            -- Existing download/image preferences are retained internally for
            -- compatibility, but they are no longer exposed as routine toggles.
            self.db:saveSetting("download_queue", self.db:readSetting("download_queue", {}) or {})
        end
        if schema<32 then
            -- v1.1.38 separates the current account shelf from EPUB files
            -- generated by MiuRead. The old mixed shelf settings are kept only
            -- as migration input so local files can no longer disturb the
            -- account shelf's default ordering.
            p.shelf_section=tostring(previous.shelf_section or "account")
            if p.shelf_section~="generated" then p.shelf_section="account" end
            p.account_shelf_kind=tostring(previous.account_shelf_kind or "books")
            if p.account_shelf_kind~="mp" then p.account_shelf_kind="books" end
            local old_sort=tostring(previous.account_shelf_sort or previous.shelf_sort or "cloud")
            local account_sort_map={cloud="default",default="default",read="read",update="update",progress="progress",title="title",author="author"}
            p.account_shelf_sort=account_sort_map[old_sort] or "default"
            local old_scope=tostring(previous.account_shelf_scope or previous.shelf_scope or "all")
            local account_scope_map={all="all",downloaded="generated",generated="generated",ungenerated="ungenerated",top="top",archive="archive"}
            p.account_shelf_scope=account_scope_map[old_scope] or "all"
            p.generated_shelf_sort=tostring(previous.generated_shelf_sort or "opened")
            if not ({opened=true,generated=true,title=true,author=true,size=true})[p.generated_shelf_sort] then p.generated_shelf_sort="opened" end
            p.generated_shelf_scope=tostring(previous.generated_shelf_scope or "all")
            if not ({all=true,in_account=true,removed=true,clean=true,notes=true})[p.generated_shelf_scope] then p.generated_shelf_scope="all" end
        end
        if schema<33 then
            -- v1.1.39 restores the shelf ordering that most closely matches
            -- the mobile client: cloud readUpdateTime descending. Old labels
            -- such as default/cloud represented interface-array order and are
            -- migrated automatically; explicit user choices are preserved.
            local old_sort=tostring(previous.account_shelf_sort or previous.shelf_sort or p.account_shelf_sort or "read")
            local account_sort_map={
                cloud="read",default="read",cloud_order="read",interface="read",read="read",
                update="update",progress="progress",title="title",author="author",
            }
            p.account_shelf_sort=account_sort_map[old_sort] or "read"
            p.shelf_sort="read"
        end
        if schema<36 then
            -- Rebuild the small pending-install index once. This replaces the
            -- old full-library scan on every document close.
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
            self.db:saveSetting("last_cleanup_result",{})
        end
        if schema<37 then
            -- Add a non-destructive access state to existing generated books.
            -- Old files remain readable until their first explicit verification;
            -- no migration-time file move or lock is performed.
            local library=self.db:readSetting("library",{}) or {}
            for _,book in pairs(library) do
                if type(book)=="table" and type(book.access)~="table" then
                    book.access={
                        ownership="unknown",access_scope="unknown",status="unverified",
                        verified_at=0,valid_until=0,shelf_present=nil,
                    }
                end
            end
            self.db:saveSetting("library",library)
        end
        if schema<39 then
            -- beta.2 replaces the old five-day absolute deadlines with the
            -- current beta policy. Old EPUB metadata must not restore those
            -- deadlines after the library has migrated.
            p.low_resource=nil
            p.annotation_mode=nil
            p.show_annotations=nil
            local library=self.db:readSetting("library",{}) or {}
            local now=os.time()
            local ttl=tonumber(Config.ACCESS_VERIFY_TTL) or 10*60
            local policy=tonumber(Config.ACCESS_POLICY_VERSION) or 2
            local function migrate_record(record,access)
                if type(record)~="table" then return end
                record.access_policy_version=policy
                record.ownership=record.ownership or access.ownership
                record.verified_at=tonumber(record.verified_at) or tonumber(access.verified_at) or 0
                if access.ownership=="purchased" or access.ownership=="personal_upload" then
                    record.valid_until=0
                else
                    record.valid_until=tonumber(access.valid_until) or 0
                end
            end
            for _,book in pairs(library) do
                if type(book)=="table" then
                    local access=type(book.access)=="table" and book.access or {
                        ownership="unknown",access_scope="unknown",status="unverified",
                        verified_at=0,valid_until=0,shelf_present=nil,
                    }
                    local ownership=tostring(access.ownership or "unknown")
                    local verified=tonumber(access.verified_at) or 0
                    access.policy_version=policy
                    if ownership=="purchased" or ownership=="personal_upload" then
                        access.valid_until=0
                        access.status="allowed"
                        access.lock_reason=""
                    else
                        local deadline=verified>0 and (verified+ttl) or 0
                        access.valid_until=deadline>now and deadline or 0
                        if access.status~="blocked" and access.status~="restricted" then
                            access.status=access.valid_until>0 and "allowed" or "expired"
                        end
                    end
                    book.access=access
                    for _,record in pairs(book.variants or {}) do migrate_record(record,access) end
                    for _,row in pairs(book.chapters or {}) do
                        for _,record in pairs(row or {}) do migrate_record(record,access) end
                    end
                end
            end
            self.db:saveSetting("library",library)
        end
        if schema<40 then
            -- beta.3 removes developer-only controls and reapplies the current
            -- access policy without rewriting EPUB or reader sidecar files.
            p.low_resource=nil
            p.annotation_mode=nil
            p.show_annotations=nil
            p.download_notice_enabled=false
            p.sync=p.sync or {}
            p.sync.time_notice_enabled=false
            p.sync.progress_notice_mode="off"
            local library=self.db:readSetting("library",{}) or {}
            local now=os.time()
            local ttl=tonumber(Config.ACCESS_VERIFY_TTL) or 10*60
            local policy=tonumber(Config.ACCESS_POLICY_VERSION) or 3
            local function apply_record(record,access)
                if type(record)~="table" then return end
                record.access_policy_version=policy
                record.ownership=access.ownership
                record.verified_at=tonumber(access.verified_at) or 0
                record.valid_until=tonumber(access.valid_until) or 0
            end
            for _,book in pairs(library) do
                if type(book)=="table" then
                    local access=type(book.access)=="table" and book.access or {}
                    access.policy_version=policy
                    local ownership=tostring(access.ownership or "unknown")
                    if ownership=="purchased" or ownership=="personal_upload" then
                        access.status="allowed"; access.valid_until=0; access.lock_reason=""
                    else
                        local verified=tonumber(access.verified_at) or 0
                        local deadline=verified>0 and verified+ttl or 0
                        access.valid_until=deadline>now and deadline or 0
                        if access.status~="blocked" and access.status~="restricted" then
                            access.status=access.valid_until>0 and "allowed" or "expired"
                        end
                    end
                    book.access=access
                    for _,record in pairs(book.variants or {}) do apply_record(record,access) end
                    for _,row in pairs(book.chapters or {}) do
                        for _,record in pairs(row or {}) do apply_record(record,access) end
                    end
                end
            end
            self.db:saveSetting("library",library)
        end
        if schema<42 then
            -- 2.0.0-beta.1 removes obsolete shelf sort/filter settings and repairs
            -- access data written by 1.1.49-beta.1. Permanent rights are restored
            -- from surviving book or file records; temporary books keep their
            -- files and are rechecked only when needed.
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

            local library=self.db:readSetting("library",{}) or {}
            local now=os.time()
            local ttl=tonumber(Config.ACCESS_VERIFY_TTL) or 3*24*60*60
            local policy=tonumber(Config.ACCESS_POLICY_VERSION) or 5
            local lock_suffix=".miuread-locked"

            local function permanent_kind(book)
                local access=type(book.access)=="table" and book.access or {}
                local own=tostring(access.ownership or "")
                if own=="purchased" or own=="personal_upload" then return own end
                local found
                local function scan(record)
                    if found or type(record)~="table" then return end
                    local value=tostring(record.ownership or record.access_ownership or "")
                    if value=="purchased" or value=="personal_upload" then found=value end
                end
                for _,record in pairs(book.variants or {}) do scan(record) end
                for _,row in pairs(book.chapters or {}) do for _,record in pairs(row or {}) do scan(record) end end
                return found
            end

            local function record_scope(kind,record)
                local scope=tostring(record and record.access_scope or "")
                if scope=="preview" or scope=="full" then return scope end
                return tostring(kind or ""):sub(1,8)=="preview_" and "preview" or "full"
            end

            local function unlock_record(record)
                if type(record)~="table" then return end
                local path=tostring(record.file or "")
                local target=tostring(record.original_file or path:gsub("%.miuread%-locked$", ""))
                if path:sub(-#lock_suffix)==lock_suffix and target~="" then
                    if U.file_exists(target) then
                        record.file=target
                        if path~=target and U.file_exists(path) then os.remove(path) end
                    elseif U.file_exists(path) then
                        local ok=os.rename(path,target)
                        if ok then record.file=target end
                    end
                end
                record.locked=nil
                record.lock_reason=nil
                record.locked_at=nil
                record.original_file=nil
                record.access_status="allowed"
            end

            for _,book in pairs(library) do
                if type(book)=="table" then
                    local access=type(book.access)=="table" and book.access or {}
                    local permanent=permanent_kind(book)
                    access.policy_version=policy
                    access.stale=nil
                    if permanent then
                        access.ownership=permanent
                        access.status="allowed"
                        access.access_scope="full"
                        access.valid_until=0
                        access.lock_reason=""
                    else
                        if tostring(access.ownership or "")=="purchased" or tostring(access.ownership or "")=="personal_upload" then
                            -- A permanent marker without surviving file evidence is
                            -- still preserved; this path mostly covers old clean installs.
                        elseif tostring(access.ownership_source or "")=="official_shelf_policy" then
                            access.ownership="temporary"
                            access.ownership_source="migration_from_1.1.49"
                        elseif tostring(access.ownership or "")=="" then
                            access.ownership="unknown"
                        end
                        local verified=tonumber(access.verified_at) or 0
                        if access.status~="blocked" and access.status~="restricted" then
                            local deadline=verified>0 and verified+ttl or 0
                            access.valid_until=deadline>now and deadline or 0
                            access.status=access.valid_until>0 and "allowed" or "expired"
                        end
                    end
                    book.access=access

                    local function migrate_record(kind,record)
                        if type(record)~="table" then return end
                        record.access_policy_version=policy
                        record.access_scope=record_scope(kind,record)
                        if permanent then
                            record.ownership=permanent
                            record.valid_until=0
                            unlock_record(record)
                        else
                            record.ownership=record.ownership or access.ownership
                            local path=tostring(record.file or "")
                            if path:sub(-#lock_suffix)==lock_suffix then record.locked=true end
                            if record.locked==true then
                                record.access_status="blocked"
                            elseif access.status=="allowed" then
                                record.access_status="allowed"
                            end
                        end
                    end
                    for kind,record in pairs(book.variants or {}) do migrate_record(kind,record) end
                    for _,row in pairs(book.chapters or {}) do
                        for kind,record in pairs(row or {}) do migrate_record(kind,record) end
                    end
                end
            end
            self.db:saveSetting("library",library)
        end
        if schema<43 then
            -- 2.0.0-beta.2 removes local reading-rights validation completely.
            -- Restore every file renamed by earlier beta builds and discard all
            -- access/expiry/lock fields. Download, login and sync remain online
            -- features, but existing EPUB files are ordinary local documents.
            p.low_resource=nil
            p.annotation_mode=nil
            p.show_annotations=nil
            local library=self.db:readSetting("library",{}) or {}
            local suffix=".miuread-locked"

            local function clear_record(record)
                if type(record)~="table" then return end
                local path=tostring(record.file or "")
                local target=tostring(record.original_file or "")
                if target=="" and path:sub(-#suffix)==suffix then
                    target=path:sub(1,#path-#suffix)
                end
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

            -- Recover orphaned locked EPUB files even when an old record was lost.
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
        if schema<44 then
            -- 2.0.0-beta.3 restores the WeRead app shelf order. beta.2 cached
            -- the raw API array order, so discard that cache once and remove
            -- obsolete user-sort fields before the next shelf load.
            p.shelf_sort=nil; p.shelf_scope=nil; p.shelf_filters=nil
            p.account_shelf_sort=nil; p.account_shelf_scope=nil
            p.generated_shelf_sort=nil; p.generated_shelf_scope=nil
            self.db:saveSetting("shelf_cache",U.copy(defaults.shelf_cache))
        end
        if schema<45 then
            -- 2.0.0-beta.5 stores public-account lists and articles outside the
            -- global settings file. Existing books, checkpoints and EPUB files
            -- are intentionally left untouched.
            local auth=self.db:readSetting("auth",{}) or {}
            if auth.wr_ticket==nil then auth.wr_ticket="" end
            if auth.wr_wrpa==nil then auth.wr_wrpa="" end
            if auth.ticket_updated_at==nil then auth.ticket_updated_at=0 end
            self.db:saveSetting("auth",U.merge(defaults.auth,auth))
        end
        if schema<48 then
            -- 2.0.0-beta.5.8 replaces the old browser-authorized public-account
            -- implementation with QR-login + MP_WXS article reading. Existing
            -- article HTML caches remain on disk, but obsolete collection records
            -- and queued collection downloads are detached so they cannot return.
            local auth=self.db:readSetting("auth",{}) or {}
            auth.mp_cookie_header=nil
            auth.mp_extra_headers=nil
            auth.mp_referer=nil
            auth.mp_auth_source=nil
            auth.mp_authorized_at=nil
            self.db:saveSetting("auth",U.merge(defaults.auth,auth))

            local function is_mp_id(id)
                id=tostring(id or "")
                return id:sub(1,7)=="MP_WXS_" or id:lower()=="mpbook"
            end

            local library=self.db:readSetting("library",{}) or {}
            local sessions=self.db:readSetting("sessions",{}) or {}
            local library_changed,sessions_changed=false,false
            for id,row in pairs(library) do
                if is_mp_id(id) or (type(row)=="table" and tostring(row.content_type or "")=="mp_collection") then
                    library[id]=nil
                    library_changed=true
                    if sessions[tostring(id)]~=nil then sessions[tostring(id)]=nil; sessions_changed=true end
                end
            end
            if library_changed then self.db:saveSetting("library",library) end
            if sessions_changed then self.db:saveSetting("sessions",sessions) end

            local kept_queue={}
            for _,job in ipairs(self.db:readSetting("download_queue",{}) or {}) do
                local book=type(job.book)=="table" and job.book or {}
                local options=type(job.options)=="table" and job.options or {}
                local id=book.bookId or book.book_id
                local obsolete=is_mp_id(id) or options.mp_collection==true
                    or tostring(options.content_type or "")=="mp_collection"
                    or tostring(book.content_type or "")=="mp_collection"
                if not obsolete then kept_queue[#kept_queue+1]=job end
            end
            self.db:saveSetting("download_queue",kept_queue)

            local shelf=self.db:readSetting("shelf_cache",{}) or {}
            shelf.mp={}
            self.db:saveSetting("shelf_cache",U.merge(defaults.shelf_cache,shelf))

            local state=self:download_state()
            local state_book=type(state.book)=="table" and state.book or {}
            local state_options=type(state.options)=="table" and state.options or {}
            if is_mp_id(state.book_id or state_book.bookId or state_book.book_id)
                or state_options.mp_collection==true
                or tostring(state_options.content_type or "")=="mp_collection" then
                self:clear_download_state()
            end
        end
        if schema<50 then
            -- beta.6.1 removes beta.6.0's persistent external-EPUB negative cache.
            -- A temporary identification failure must not hide an existing book.
            self.db:saveSetting("external_epub_cache",{})
        end
        if schema<51 then
            -- beta.6.4 gives comments their own fixed font by default. Following
            -- the current book font remains optional because resolving and
            -- embedding a changing book font can delay older devices.
            p.thoughts=p.thoughts or {}
            if p.thoughts.follow_body_font==nil then p.thoughts.follow_body_font=false end
            if p.thoughts.font_face==nil then p.thoughts.font_face="" end
        end
        self.db:saveSetting("preferences",p)
        self.db:saveSetting("schema",Config.SCHEMA)
    end
end
function Store:get(k,d) local v=self.db:readSetting(k,nil); return v==nil and U.copy(d) or v end
function Store:set(k,v) self.db:saveSetting(k,v); self.db:flush() end
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
function Store:clear_auth() self:set("auth",U.copy(defaults.auth)) end
function Store:preferences() return U.merge(defaults.preferences,self:get("preferences",{})) end
function Store:save_preferences(v) self:set("preferences",U.merge(defaults.preferences,v or {})) end
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
function Store:migrate_legacy_epubs()
    local all=self.db:readSetting("library",{}) or {}
    local changed=false
    local root=self:epub_root()
    local function move_record(record)
        if type(record)~="table" or type(record.file)~="string" or record.file=="" then return end
        if not U.file_exists(record.file) then return end
        if record.file:sub(1,#root+1)==root.."/" then return end
        if record.file:sub(1,#self.cache_books_dir+1)~=self.cache_books_dir.."/" then return end
        local name=basename(record.file); if not name then return end
        local target=root.."/"..name
        if U.file_exists(target) then
            local stem,ext=name:match("^(.*)(%.epub)$")
            target=root.."/"..tostring(stem or name).." [迁移]"..tostring(ext or "")
        end
        local ok=os.rename(record.file,target)
        if not ok then ok=U.copy_file(record.file,target); if ok then os.remove(record.file) end end
        if ok then record.file=target; record.directory=root; changed=true end
    end
    for _,book in pairs(all) do
        for _,record in pairs(book.variants or {}) do move_record(record) end
        for _,row in pairs(book.chapters or {}) do for _,record in pairs(row or {}) do move_record(record) end end
        if changed then book.directory=root end
    end
    if changed then self.db:saveSetting("library",all) end
end
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
function Store:book_paths(id,include_cache)
    local b=self:book(id)
    local out,seen={},{}
    if b then
        for _,r in pairs(b.variants or {}) do add_unique_path(out,seen,r and r.file) end
        for _,row in pairs(b.chapters or {}) do for _,r in pairs(row or {}) do add_unique_path(out,seen,r and r.file) end end
    end
    if include_cache~=false then add_unique_path(out,seen,self:book_cache_path(id)) end
    return out
end
function Store:all_download_paths(include_covers)
    local out,seen={},{}
    for id,_ in pairs(self:library()) do for _,path in ipairs(self:book_paths(id,true)) do add_unique_path(out,seen,path) end end
    add_unique_path(out,seen,self.cache_books_dir)
    if include_covers then add_unique_path(out,seen,self.covers_dir) end
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
function Store:forget_chapter(id,uid,kind)
    local all=self:library(); local key=tostring(id); local b=all[key]; local row=b and b.chapters and b.chapters[tostring(uid)]
    if row then row[kind]=nil; if next(row)==nil then b.chapters[tostring(uid)]=nil end end
    if b and not book_has_records(b) and not self:book_has_partial_cache(id) then all[key]=nil end
    self:set("library",all)
end
function Store:forget_chapter_all(id,uid)
    local all=self:library(); local key=tostring(id); local b=all[key]
    if b and b.chapters then b.chapters[tostring(uid)]=nil end
    if b and not book_has_records(b) and not self:book_has_partial_cache(id) then all[key]=nil end
    self:set("library",all)
end
function Store:forget_book(id) local all=self:library(); all[tostring(id)]=nil; self:set("library",all) end
function Store:forget_all_books() self:set("library",{}) end
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
function Store:delete_variant(id,kind)
    for _,path in ipairs(self:variant_paths(id,kind)) do U.remove_tree(path) end
    self:forget_variant(id,kind)
end
function Store:delete_chapter(id,uid,kind)
    local r=self:chapter_variant(id,uid,kind); if r and r.file then U.remove_tree(r.file) end
    self:forget_chapter(id,uid,kind)
end
function Store:delete_book(id)
    for _,path in ipairs(self:book_paths(id,true)) do U.remove_tree(path) end
    self:forget_book(id)
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

function Store:epub_identity(path)
    if not path or not U.file_exists(path) or not tostring(path):lower():match("%.epub$") then return nil end
    local quoted=U.shell_quote(path)
    local identity={}
    local raw=read_pipe("unzip -p "..quoted.." OEBPS/miuread.json 2>/dev/null")
    if raw then
        local ok,value=pcall(Json.decode,raw)
        if ok and type(value)=="table" then identity=U.copy(value) end
    end
    local opf=read_pipe("unzip -p "..quoted.." OEBPS/package.opf 2>/dev/null")
    if opf then
        identity.book_id=identity.book_id
            or opf:match("miuread://book/([^<%s]+)")
            or opf:match("miuread%-([^<%s]+)")
        identity.title=identity.title or xml_unescape(opf:match("<dc:title[^>]*>(.-)</dc:title>"))
        identity.author=identity.author or xml_unescape(opf:match("<dc:creator[^>]*>(.-)</dc:creator>"))
    end
    if tostring(identity.book_id or "")~="" then return identity end

    -- MiuRead-generated EPUB entries are stored without compression. If a
    -- device lacks a usable unzip -p, inspect only the tail instead of loading
    -- a large book into memory.
    local file=io.open(path,"rb")
    if file then
        local size=file:seek("end") or 0
        file:seek("set",math.max(0,size-1024*1024))
        local tail=file:read("*a") or ""
        file:close()
        local id=tail:match('"book_id"%s*:%s*"([^"]+)"') or tail:match("miuread://book/([^<%s]+)")
        if id then
            return {
                book_id=id,
                variant=tail:match('"variant"%s*:%s*"([^"]+)"'),
                content_type=tail:match('"content_type"%s*:%s*"([^"]+)"'),
                standalone=tail:match('"standalone"%s*:%s*true')~=nil,
            }
        end
    end
    return nil
end

local function access_from_epub_meta(_meta)
    return nil
end

function Store:identify_file(path,relink)
    if not path then return nil end
    local normalized=normalize_path(path)
    local current_size=U.file_size(path)
    local all=self:library()
    local function match_record(record)
        return type(record)=="table" and record.file and normalize_path(record.file)==normalized
    end
    local function relink_record(book,record)
        if not relink or type(record)~="table" then return end
        if record.file~=path then
            record.file=path
            record.directory=path:match("^(.*)/[^/]+$")
        end
        record.file_size=current_size or record.file_size
        book.directory=record.directory or book.directory
        self:set("library",all)
    end
    for _,b in pairs(all) do
        for kind,r in pairs(b.variants or {}) do
            if match_record(r) then relink_record(b,r); return b,r,kind end
        end
        for uid,row in pairs(b.chapters or {}) do
            for kind,r in pairs(row or {}) do
                if match_record(r) then
                    r.chapter_uid=uid
                    relink_record(b,r)
                    return b,r,kind
                end
            end
        end
    end

    local meta=self:epub_identity(path)
    -- For older files without embedded identity, a harmless spacing-only rename
    -- can still be repaired. Relink only one unambiguous filename candidate.
    local wanted_name=filename_key(path)
    if not meta and wanted_name~="" then
        local matches={}
        for _,b in pairs(all) do
            for kind,r in pairs(b.variants or {}) do
                if type(r)=="table" and filename_key(r.file)==wanted_name then
                    matches[#matches+1]={book=b,record=r,kind=kind}
                end
            end
            for uid,row in pairs(b.chapters or {}) do
                for kind,r in pairs(row or {}) do
                    if type(r)=="table" and filename_key(r.file)==wanted_name then
                        matches[#matches+1]={book=b,record=r,kind=kind,uid=uid}
                    end
                end
            end
        end
        if #matches==1 then
            local found=matches[1]
            if found.uid then found.record.chapter_uid=found.uid end
            relink_record(found.book,found.record)
            return found.book,found.record,found.kind
        end
    end

    local id=meta and tostring(meta.book_id or "") or ""
    if id=="" then return nil end
    local kind=tostring(meta.variant or "")
    if kind=="" then kind="notes" end
    local b=all[id]
    local chapters=type(meta.chapters)=="table" and meta.chapters or {}
    local standalone=meta.standalone==true
    local uid=tostring(meta.chapter_uid or ((chapters[1] and (chapters[1].uid or chapters[1].chapter_uid)) or ""))
    local record

    if b then
        if standalone then
            local row=uid~="" and b.chapters and b.chapters[uid] or nil
            record=row and (row[kind] or row.notes or row.clean)
            if record then record.chapter_uid=uid end
        else
            record=b.variants and (b.variants[kind] or b.variants.notes or b.variants.clean)
        end
        -- Metadata proves the book identity. If its old library row is missing,
        -- recover a minimal row instead of treating the EPUB as an external book.
        if not record then
            record={
                book_id=id,title=meta.title or b.title or basename(path),author=meta.author or b.author or "",
                file=path,directory=path:match("^(.*)/[^/]+$"),variant=kind,
                content_type=meta.content_type,sync_enabled=meta.sync_enabled,read_report_enabled=meta.read_report_enabled,
                downloaded_at=tonumber(meta.generated_at) or os.time(),chapter_map=chapters,
                chapter_count=#chapters,complete=meta.complete~=false,file_size=current_size,
            }
            if standalone and uid~="" then
                record.chapter_uid=uid
                b.chapters=b.chapters or {}; b.chapters[uid]=b.chapters[uid] or {}; b.chapters[uid][kind]=record
            else
                b.variants=b.variants or {}; b.variants[kind]=record
            end
        end
    else
        b={
            book_id=id,title=meta.title or tostring(basename(path) or id):gsub("%.epub$",""),
            author=meta.author or "",variants={},chapters={},catalog=chapters,
            content_type=meta.content_type,
            directory=path:match("^(.*)/[^/]+$"),updated_at=os.time(),recovered=true,
        }
        record={
            book_id=id,title=b.title,author=b.author,file=path,directory=b.directory,
            variant=kind,content_type=meta.content_type,
            sync_enabled=meta.sync_enabled,read_report_enabled=meta.read_report_enabled,
            downloaded_at=tonumber(meta.generated_at) or os.time(),
            chapter_map=chapters,chapter_count=#chapters,complete=meta.complete~=false,
            file_size=current_size,recovered=true,
        }
        if standalone and uid~="" then
            record.chapter_uid=uid; b.chapters[uid]={[kind]=record}
        else
            b.variants[kind]=record
        end
        all[id]=b
    end

    if record and relink then relink_record(b,record) end
    return b,record,kind
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
function Store:session(id) return self:get("sessions",{})[tostring(id)] end
function Store:save_session(id,patch) local a=self:get("sessions",{}); local k=tostring(id); a[k]=U.merge(a[k] or {},patch or {}); self:set("sessions",a); return a[k] end
function Store:clear_session(id) local a=self:get("sessions",{}); a[tostring(id)]=nil; self:set("sessions",a) end
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
function Store:download_queue() return self:get("download_queue",{}) end
function Store:save_download_queue(queue) self:set("download_queue",type(queue)=="table" and queue or {}) end
function Store:enqueue_download(job)
    local queue=self:download_queue(); queue[#queue+1]=U.copy(job or {}); self:save_download_queue(queue); return #queue
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
function Store:last_cleanup_result() return self:get("last_cleanup_result",{}) end
function Store:save_cleanup_result(result) self:set("last_cleanup_result",type(result)=="table" and result or {}) end
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
function Store:flush() self.db:flush() end
function Store:reload()
    self.db = LuaSettings:open(self.settings_path)
    return self
end
return Store
