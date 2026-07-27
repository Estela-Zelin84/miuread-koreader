local ButtonDialog=require("ui/widget/buttondialog")
local ConfirmBox=require("ui/widget/confirmbox")
local InfoMessage=require("ui/widget/infomessage")
local InputDialog=require("ui/widget/inputdialog")
local Menu=require("ui/widget/menu")
local PathChooser=require("ui/widget/pathchooser")
local UIManager=require("ui/uimanager")
local WidgetContainer=require("ui/widget/container/widgetcontainer")
local logger=require("logger")
local lfs=require("libs/libkoreader-lfs")
local Config=require("miuread.config")
local Text=require("miuread.text")
local U=require("miuread.util")
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
local CacheCleanupTask=require("miuread.cache_cleanup_task")
local Library=require("miuread.library")
local ShelfView=require("miuread.shelf_view")
local Async=require("miuread.async")
local Sync=require("miuread.sync")
local Updater=require("miuread.updater")
local Cookies=require("miuread.cookies")
local Thoughts=require("miuread.thoughts")
local ThoughtPopup=require("miuread.thought_popup")
local StatusToast=require("miuread.status_toast")
local Actions=require("miuread.actions")
local _=Text.tr
local unpack_args=unpack or table.unpack
local SHELF_CACHE_TTL=15*60
local SHELF_DIRECT_CACHE_TTL=6*60*60
local COVER_GUARD_WINDOW=6*60*60
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
    self.store=Store:new()
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
    self.async=Async:new(self.store)
    self.mp_async=Async:new(self.store,{poll_interval=.35,allow_android=true})
    self.search_async=Async:new(self.store,{poll_interval=.4,allow_android=true})
    self.shelf_async=Async:new(self.store,{poll_interval=.4,allow_android=true})
    self.cover_async=Async:new(self.store,{poll_interval=.30,allow_android=true})
    self.auth_flow=Auth:new(self.http,self.store,self)
    self.sync=Sync:new(self.reader,self.api,self.store,self,self.async)
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

    local recovered=self:_recover_download_state()
    if not recovered then UIManager:scheduleIn(1.0,function() self:_start_next_queued_download() end) end
    Actions.register()
    self.ui.menu:registerToMainMenu(self)
    local state=self.updater:startup()
    if state=="updated" then UIManager:scheduleIn(1,function() self:toast(_("Update installed"),3) end) end
    UIManager:scheduleIn(.8,function() if not self:_current_document_path() then self:_install_pending_downloads(false) end end)
end

function Plugin:addToMainMenu(items) items.miuread={text=Config.NAME,sorting_hint="tools",sub_item_table_func=function() return self.ui.document and self:reader_menu() or self:home_menu() end} end
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

function Plugin:list(title,items,empty) if not items or #items==0 then self:info(empty or _("No items")); return end; UIManager:show(Menu:new{title=title,item_table=items,is_borderless=true,title_bar_fm_style=true}) end
function Plugin:logged_in() local a=self.store:auth(); return a.api_key~="" and next(a.cookies or {})~=nil end
function Plugin:require_login() if not self:logged_in() then self:info(_("Not logged in")); return false end return true end
function Plugin:home_menu()
    local out={
        {text="我的书架",callback=self:safe("shelf",function() self:show_shelf(false,false,"account") end)},
        {text="搜索书籍",callback=self:safe("search",function() self:search_dialog() end)},
        {text="下载管理",callback=self:safe("downloads",function() self:show_downloads() end)},
        {text="阅读同步",sub_item_table_func=function() return self:sync_menu() end},
        {text="设置",sub_item_table_func=function() return self:settings_menu() end},
    }
    if self:_has_download_status() then
        table.insert(out,1,{text=self:_download_status_label(),callback=function() self:show_download_status() end})
    end
    return out
end

function Plugin:reader_menu()
    local current_path=self:_current_document_path()
    local mp_context=self.mp and self.mp:identify_path(current_path) or nil
    local out
    if mp_context then
        out={
            {text="返回文章列表",callback=self:safe("mp-back",function() self:open_mp_account_by_id(mp_context.bookId,mp_context.account_title) end)},
            {text="上一篇",callback=self:safe("mp-prev",function() self:open_mp_neighbor(-1) end)},
            {text="下一篇",callback=self:safe("mp-next",function() self:open_mp_neighbor(1) end)},
            {text="设置",sub_item_table_func=function() return self:settings_menu() end},
        }
    else
        out={
            {text="返回我的书架",callback=self:safe("shelf",function() self:show_shelf(false,false,"account") end)},
            {text="阅读同步",sub_item_table_func=function() return self:sync_menu() end},
            {text="生成／更新当前书籍",callback=self:safe("redownload",function() self:redownload_current() end)},
            {text="设置",sub_item_table_func=function() return self:settings_menu() end},
        }
    end
    if self:_has_download_status() then
        table.insert(out,1,{text=self:_download_status_label(),callback=function() self:show_download_status() end})
    end
    return out
end

function Plugin:account_menu()
    local out={
        {text=self:logged_in() and "重新扫码登录" or "扫码登录",callback=self:safe("login",function() self.auth_flow:start() end)},
        {text="账号状态",callback=function()
            local a=self.store:auth()
            local name=tostring((a.account or {}).name or "")
            self:info(self:logged_in() and ("已登录"..(name~="" and ("\n"..name) or "")) or "尚未登录")
        end},
    }
    if self:logged_in() then
        out[#out+1]={text="退出登录",callback=function()
            UIManager:show(ConfirmBox:new{text="退出当前微信读书账号？\n\n已下载书籍和阅读记录不会删除。",ok_callback=function()
                self.auth_flow:cancel(); self.store:clear_auth(); self:toast("已退出登录")
            end})
        end}
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
        b.download_status=nil
        if tostring(download_state.book_id or "")~="" and tostring(download_state.book_id)==tostring(b.bookId or "") then
            if download_state.status=="active" then b.download_status="生成中 "..tostring(self:_download_percent(download_state)).."%"
            elseif download_state.status=="pending_install" then b.download_status="等待关闭后更新"
            elseif download_state.status=="failed" or download_state.status=="interrupted" then b.download_status="生成未完成"
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
    local available={}
    for _,kind in ipairs({"notes","clean","preview_notes","preview_clean"}) do
        local r=self.store:variant(id,kind)
        if r and r.file and U.file_exists(r.file) then available[#available+1]=r end
    end
    if #available==1 then self:open_file(available[1].file) else self:book_menu(b) end
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
    for _,kind in ipairs({"notes","clean","preview_notes","preview_clean"}) do
        if consider(b.variants and b.variants[kind]) then return fallback end
    end
    for _,row in pairs(b.chapters or {}) do
        for _,kind in ipairs({"notes","clean","preview_notes","preview_clean"}) do
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
        {text="管理本号缓存",sub_item_table_func=function() return self:mp_cache_menu(book,articles) end},
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

function Plugin:open_or_download_mp_article(book,article,force)
    local record=self.mp:article_record(book.bookId,article)
    if record and force~=true then self:open_file(record.file); return end
    if not self:require_login() then return end
    if not self:is_online() then
        if record then self:open_file(record.file) else self:info(_("Network unavailable")) end
        return
    end
    if self.mp_async:busy() then self:info("另一项公众号任务正在进行中。") return end
    self:status_toast("公众号",tostring(article.title or "文章").."正在下载",2)
    local book_copy,article_copy=U.copy(book),U.copy(article)
    local prefs=self.store:preferences()
    local started,err=self.mp_async:run("mp-article",function()
        return self.mp:fetch_article(book_copy,article_copy,{images=prefs.mp_images==true,force=force==true})
    end,function(result)
        self.store:reload()
        if result and result.ok and type(result.value)=="table" and result.value.file then
            self:open_file(result.value.file)
        else
            local fallback=self.mp:article_record(book_copy.bookId,article_copy)
            if fallback then self:open_file(fallback.file)
            else
                logger.warn("[MiuRead][MP] article download failed",tostring(result and result.error))
                self:info("文章下载失败，请稍后重试。")
            end
        end
    end,120)
    if not started then self:info("无法启动文章下载：\n"..tostring(err)) end
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
            self.mp:clear_account(book.bookId)
            self:toast("已清理")
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
                self.mp:clear_article(book.bookId,article); self:toast("已清理")
            end})
        end},
    }
    self:list(article.title or "文章",items)
end

function Plugin:mp_global_cache_menu()
    return {
        {text="清理全部公众号缓存",callback=function()
            UIManager:show(ConfirmBox:new{text="清理全部公众号列表和单篇文章缓存？",ok_callback=function()
                U.remove_tree(self.store:mp_root())
                U.mkdir(self.store:mp_root())
                self:toast("已清理")
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
        {kind="preview_clean",label="试读版 · 纯净版"},{kind="preview_notes",label="试读版 · 划线与想法版"}}
    for _,entry in ipairs(records) do
        local record=self:_variant_exists(b.bookId,entry.kind)
        if record then
            items[#items+1]={text="打开"..entry.label,callback=function() self:open_file(record.file) end}
        end
    end
    items[#items+1]={text="生成／更新书籍",callback=function() self:choose_download(b,nil,false) end}
    items[#items+1]={text="按章节下载",callback=function() self:chapters(b) end}
    if self:_book_has_cache(b.bookId) or self.store:book_has_partial_cache(b.bookId) then
        items[#items+1]={text="管理本书文件",callback=function() self:downloaded_book_menu(tostring(b.bookId)) end}
    end
    items[#items+1]={text="书籍详情",callback=function() self:book_details(b) end}
    self:list(b.title,items)
end

function Plugin:book_details(b)
    self:online("details",function() local x=self.api:book(b.bookId); local z=normalize(x); self:info(z.title.."\n"..z.author.."\n\n"..tostring(x.intro or x.description or "")) end)
end
function Plugin:choose_download_mode(b,opt,open_after)
    local dialog
    local function start(background)
        if self._download_launch_pending or (self.download_task and self.download_task:busy()) then
            self:toast("已有下载任务正在准备或运行",2)
            return
        end
        self._download_launch_pending=true
        UIManager:close(dialog)
        self:status_toast("觅阅",tostring(b and b.title or "未命名")..
            (background and "正在准备后台下载" or "正在准备下载"),2)
        -- Close and repaint the menu before starting the child process. This
        -- avoids the Android screen looking frozen after the download button.
        UIManager:scheduleIn(.20,function()
            self._download_launch_pending=false
            if self.download_task and self.download_task:busy() then
                self:toast("已有下载任务正在运行",2)
                return
            end
            self:download(b,opt,open_after,nil,background)
        end)
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
    local lines={
        heading,
        "保存位置："..tostring(rec.file or ""),
        "打开一次后会出现在 KOReader 最近阅读中",
    }
    if preview then
        lines[#lines+1]="成功取得正文："..tostring(rec.readable_chapter_count or 0).." / "..tostring(rec.catalog_chapter_count or rec.expected_chapter_count or 0)
        if preview_mode=="info" then lines[#lines+1]="本文件只包含书籍信息和权限说明，不含试读正文。"
        elseif preview_mode=="partial" then lines[#lines+1]="未成功取得的试读章节未写入文件，可稍后重新生成。" end
    end
    if rec and rec.annotation_pending==true then
        lines[#lines+1]="划线与想法暂时无法完整获取，已生成正文完整的纯净版。"
        lines[#lines+1]="正文断点已保留；下次重新生成划线与想法版时不会重新下载正文。"
    elseif opt and opt.annotations then
        local a=rec.annotation_summary or {}
        lines[#lines+1]="划线："..tostring(a.underlines or 0)
        lines[#lines+1]="含想法的划线："..tostring(a.thoughts or 0)
    end
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
    images="处理图片",package="生成 EPUB",done="下载完成",error="下载失败",
    cancelled="下载已取消",
}
function Plugin:_on_download_progress(runtime,state)
    if self._download_runtime~=runtime then return end
    runtime.last_state=U.copy(state or {})
    runtime.task=self.download_task and self.download_task:descriptor() or runtime.task
    if runtime.dialog then runtime.dialog:set_state(state) end
    self:_write_download_state("active",self:_active_download_payload(runtime,state),false)
    if state and state.waiting_network==true then
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
            if was_background then self:status_toast("觅阅","下载已取消",3) else self:toast("下载已取消",3) end
            self:_start_next_queued_download()
            return
        end
        self:_write_download_state("failed",{
            title=b.title,book_id=b.bookId,book=U.copy(b),options=U.copy(opt),
            error=tostring(err),stage=runtime.last_state and runtime.last_state.stage,
            current=runtime.last_state and runtime.last_state.current,total=runtime.last_state and runtime.last_state.total,
            percent=runtime.last_state and runtime.last_state.percent,seen=false,
        },true)
        self:_update_open_shelf_download_status(b.bookId,"生成未完成")
        local first=U.first_line(err)
        if tostring(err):find("ANNOTATION_FORBIDDEN",1,true) then
            first="划线与想法暂时无法获取，可改为生成纯净版。已下载正文会保留。"
        end
        if was_background then self:status_toast("觅阅",tostring(b.title or "未命名").."下载未完成，进度已保留",5)
        else self:info(first) end
        self:_start_next_queued_download()
        return
    end
    local rec=self:_merge_download_result(result,b,opt)
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
    self:_update_open_shelf_download_status(b.bookId,pending and "等待关闭后更新"
        or (rec.annotation_pending==true and "正文已生成 · 批注待补" or "已生成"))
    self:_write_download_state(pending and "pending_install" or "completed",{
        title=b.title,book_id=b.bookId,book=U.copy(b),options=U.copy(opt),file=rec.file,
        pending_file=rec.pending_file,pending_install=pending or nil,seen=false,percent=1,
        current=rec.chapter_count,total=rec.expected_chapter_count,completed_at=os.time(),
        annotation_pending=rec.annotation_pending==true or nil,
        annotation_error_kind=rec.annotation_error_kind,
    },true)
    if done then done(rec,was_background); self:_start_next_queued_download(); return end
    if pending then
        local text=tostring(b.title or "未命名").."新版本已下载，关闭当前书籍后更新"
        if was_background then self:status_toast("觅阅",text,5) else self:info(text) end
    elseif was_background then
        if self.store:preferences().download_complete_notice~=false then
            self:status_toast("觅阅",tostring(b.title or "未命名")..
                (rec.annotation_pending==true and "正文下载完成，批注待补全" or "下载完成"),5)
        end
    elseif open_after and rec.file then
        self.store:clear_download_state(); self:open_file(rec.file)
    else
        self:_show_download_complete(rec,opt)
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
            function(result) self:_finish_download_runtime(runtime,result) end)
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
    if state.status=="completed" then return state.seen~=true end
    return state.status=="failed" or state.status=="interrupted" or state.status=="pending_install"
end
function Plugin:_download_status_label()
    local state=self:_download_state()
    if state.status=="active" then
        local title=tostring(state.title or "未命名")
        if #title>16 then title=title:sub(1,16).."…" end
        return "后台下载：《"..title.."》 "..tostring(self:_download_percent(state)).."%"
    end
    if state.status=="pending_install" then return "后台下载 · 等待更新" end
    if state.status=="completed" then return "后台下载 · 已完成" end
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
    local task=runtime.task or (self.download_task and self.download_task:descriptor())
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
    self.store:save_book(book.bookId,{
        book_id=tostring(book.bookId),title=book.title,author=book.author,cover=book.cover,
        directory=rec.directory,updated_at=os.time(),catalog=rec.chapter_map,access=nil,
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
function Plugin:_show_download_complete(rec,opt)
    local dialog
    dialog=ButtonDialog:new{title=self:_download_summary(rec,opt),title_align="center",buttons={
        {{text="立即阅读",callback=function() UIManager:close(dialog); self.store:clear_download_state(); self:open_file(rec.file) end}},
        {{text="关闭",callback=function() UIManager:close(dialog) end}},
    }}
    UIManager:show(dialog)
end
function Plugin:show_download_status()
    if self.download_task and self.download_task:busy() then self:_show_active_download_dialog(); return end
    local state=self.store:download_state()
    if not state.status or state.status=="" then self:info("当前没有后台下载记录。") return end
    if state.status=="completed" then state.seen=true; self.store:save_download_state(state) end
    local title=tostring(state.title or "未命名")
    local lines={}
    if state.status=="completed" then lines[#lines+1]="下载完成"
    elseif state.status=="pending_install" then lines[#lines+1]="新版本已下载完成"
    elseif state.status=="failed" then lines[#lines+1]="下载未完成"
    elseif state.status=="interrupted" then lines[#lines+1]="上次下载已中断"
    else lines[#lines+1]=tostring(state.status) end
    lines[#lines+1]="《"..title.."》"
    if state.current and state.total and tonumber(state.total)>0 then lines[#lines+1]="章节 "..tostring(state.current).." / "..tostring(state.total) end
    if state.error and state.error~="" then lines[#lines+1]="\n"..U.first_line(state.error) end
    if state.annotation_pending==true then
        lines[#lines+1]="\n正文已完整生成；划线与想法将在下次重新生成时补全。"
    end
    if state.status=="pending_install" then lines[#lines+1]="\n关闭当前书籍后会自动安装新版本。" end
    local buttons={}
    local dialog
    if state.status=="completed" and state.file and U.file_exists(state.file) then
        buttons[#buttons+1]={{text="立即阅读",callback=function() UIManager:close(dialog); self.store:clear_download_state(); self:open_file(state.file) end}}
    elseif (state.status=="failed" or state.status=="interrupted") and type(state.book)=="table" then
        buttons[#buttons+1]={{text="继续下载",callback=function() UIManager:close(dialog); self:download(state.book,state.options or {},false) end}}
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
    local backup=target..".miuread-backup"
    os.remove(backup)
    local had_previous=U.file_exists(target)
    if had_previous then
        local ok,err=os.rename(target,backup)
        if not ok then return false,"无法保护原 EPUB："..tostring(err) end
    end
    local ok,err=os.rename(pending,target)
    if not ok then
        if had_previous then os.rename(backup,target) end
        return false,"无法安装新 EPUB："..tostring(err)
    end
    if had_previous then os.remove(backup) end
    local updated=U.copy(record)
    updated.pending_file=nil; updated.pending_install=nil; updated.installed_at=os.time()
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
    local installed,last_record=0,nil
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
            if ok then installed=installed+1; last_record=value
            else logger.warn("[MiuRead][Download] pending install failed",tostring(value)) end
        end
    end
    if installed>0 then
        local remaining=self.store:prune_pending_installs()
        local state=self.store:download_state()
        if #remaining==0 then
            state.status="completed"; state.pending_install=nil; state.pending_file=nil; state.seen=false
        else
            state.status="pending_install"; state.pending_install=true
        end
        state.updated_at=os.time()
        if last_record then state.file=last_record.file end
        self.store:save_download_state(state)
        self:_refresh_local_files()
        if notify then
            self:status_toast("觅阅",installed>1 and (tostring(installed).." 个新版本已安装") or "新版本已安装",4)
        end
        return true
    end
    return false
end

function Plugin:_download_job_key(book,opt)
    opt=opt or {}
    local kind=opt.annotations and "notes" or "clean"
    return table.concat({tostring(book and book.bookId or ""),kind,tostring(opt.chapter_uid or "full"),tostring(opt.limit or "all")},":")
end
function Plugin:_queue_download(book,opt,open_after)
    local key=self:_download_job_key(book,opt)
    local runtime=self._download_runtime
    if runtime and self:_download_job_key(runtime.book,runtime.options)==key then
        self:info("这项下载已经在进行中。") return false
    end
    for _,job in ipairs(self.store:download_queue()) do
        if tostring(job.key or "")==key then self:info("这项下载已经在等待队列中。") return false end
    end
    local position=self.store:enqueue_download({key=key,book=U.copy(book or {}),options=U.copy(opt or {}),open_after=open_after==true,queued_at=os.time()})
    self:status_toast("下载队列","已加入等待队列 · 第 "..tostring(position).." 项",3)
    return true
end
function Plugin:_start_next_queued_download()
    if self.download_task and self.download_task:busy() then return false end
    if self._download_runtime then return false end
    if not self:is_online() or not self:logged_in() then return false end
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
    local items={}
    for index,job in ipairs(queue) do
        local queue_index=index
        local title=tostring(job.book and job.book.title or "未命名")
        local variant=(job.options and job.options.annotations) and "划线与想法版" or "纯净版"
        items[#items+1]={text=title,post_text=tostring(queue_index).." · "..variant,callback=function()
            UIManager:show(ConfirmBox:new{text="从等待队列移除《"..title.."》？",ok_callback=function()
                self.store:remove_queued_download(queue_index); self:toast("已移出等待队列")
            end})
        end}
    end
    self:list("等待下载",items)
end

function Plugin:download(b,opt,open_after,done,start_in_background,from_queue)
    if not self:require_login() then return end
    if not self:is_online() then self:info(_("Network unavailable")); return end
    opt=U.copy(opt or {})
    if self.download_task and self.download_task:busy() then
        if from_queue then
            self.store:enqueue_download({key=self:_download_job_key(b,opt),book=U.copy(b),options=U.copy(opt),open_after=open_after==true,queued_at=os.time()})
            return false
        end
        return self:_queue_download(b,opt,open_after)
    end
    local stored=self.store:download_state()
    if stored.status=="active" and self:_recover_download_state() then
        if from_queue then
            self.store:enqueue_download({key=self:_download_job_key(b,opt),book=U.copy(b),options=U.copy(opt),open_after=open_after==true,queued_at=os.time()})
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
    local ok,err=self.download_task:start(b,opt,
        function(state) self:_on_download_progress(runtime,state) end,
        function(result) self:_finish_download_runtime(runtime,result) end)
    if not ok then
        self._download_runtime=nil
        self.store:clear_download_state()
        if from_queue then self.store:enqueue_download({key=self:_download_job_key(b,opt),book=U.copy(b),options=U.copy(opt),open_after=open_after==true,queued_at=os.time()}) end
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



function Plugin:chapters(b)
    self:online("chapters",function()
        local _,rows=self.downloader:catalog(b.bookId)
        local items={}
        for _,ch in ipairs(rows or {}) do
            local chapter=ch
            local uid=tostring(chapter.chapterUid or chapter.uid or "")
            local clean=self.store:chapter_variant(b.bookId,uid,"clean")
            local notes=self.store:chapter_variant(b.bookId,uid,"notes")
            local states={}
            if clean and clean.file and U.file_exists(clean.file) then states[#states+1]="纯净版" end
            if notes and notes.file and U.file_exists(notes.file) then states[#states+1]="划线与想法版" end
            items[#items+1]={
                text=chapter.title or uid,
                post_text=#states>0 and table.concat(states," · ") or tostring(chapter.wordCount or ""),
                callback=function() self:chapter_menu(b,chapter) end,
            }
        end
        self:list("按章节下载 · "..tostring(b.title or "未命名"),items,"没有可用章节")
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
            items[#items+1]={text="阅读"..entry.label,callback=function() self:open_file(record.file) end}
        end
    end
    items[#items+1]={text=(clean or notes) and "更新本章" or "下载本章",callback=function() self:choose_download(b,nil,true,uid) end}
    if clean or notes then items[#items+1]={text="删除本章文件",callback=function() self:_confirm_delete_chapter_cache(b.bookId,uid,ch.title or uid) end} end
    self:list(ch.title or uid,items)
end

function Plugin:_open_file_direct(path)
    if self.ui.document then self.ui:switchDocument(path) else self.ui:openFile(path) end
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
    local base=preview and kind:sub(9) or kind
    local label=base=="notes" and "划线与想法版" or "纯净版"
    return preview and ("试读版 · "..label) or label
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
function Plugin:_confirm_delete_book_downloads(book_id,title)
    if self:_cache_action_blocked() then return end
    local paths=self.store:book_paths(book_id,true)
    if #paths==0 then self.store:forget_book(book_id); self:show_downloads(); return end
    UIManager:show(ConfirmBox:new{
        text="删除《"..tostring(title or book_id).."》的全部下载内容？\n\n将删除纯净版、划线与想法版、单章文件和下载断点，不会退出账户。",
        ok_callback=function()
            self:_run_cache_cleanup(self.store:book_paths(book_id,true),{
                progress_text="正在删除本书全部下载内容……",
                done_text="本书下载内容已删除",
                commit=function() self.store:forget_book(book_id) end,
                policy={mode="book_delete",allowed_book_cache={self.store:book_cache_path(book_id)}},operation="删除本书下载内容",
            })
        end,
    })
end
function Plugin:_download_book_labels(b)
    local labels={}
    for _,kind in ipairs({"clean","notes","preview_clean","preview_notes"}) do
        local r=b.variants and b.variants[kind]
        if r and r.file and U.file_exists(r.file) then labels[#labels+1]=self:_variant_label(kind) end
    end
    local chapter_count=0
    for _,row in pairs(b.chapters or {}) do for _,r in pairs(row or {}) do if r.file and U.file_exists(r.file) then chapter_count=chapter_count+1 end end end
    if chapter_count>0 then labels[#labels+1]="单章 "..tostring(chapter_count) end
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
    items[#items+1]={text="清理下载与缓存",callback=function() self:show_download_cleanup_dialog() end}
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
        for _,kind in ipairs({"clean","notes","preview_clean","preview_notes"}) do
            local r=row and row[kind]
            if r and r.file and U.file_exists(r.file) then
                labels[#labels+1]=self:_variant_label(kind)
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
    for _,kind in ipairs({"clean","notes","preview_clean","preview_notes"}) do
        local r=b.variants and b.variants[kind]
        if r and r.file and U.file_exists(r.file) then variants[#variants+1]={kind=kind,file=r.file,label=self:_variant_label(kind)} end
    end
    if #variants>0 then
        items[#items+1]={text="可阅读版本",enabled=false}
        for _,variant in ipairs(variants) do
            local kind_key=variant.kind; local file=variant.file; local label=variant.label
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
        items[#items+1]={text="删除本书全部下载内容",post_text="不可恢复",callback=function() self:_confirm_delete_book_downloads(book_id,b.title) end}
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

function Plugin:sync_menu()
    return {
        {text="阅读时间同步",checked_func=function() return self.store:preferences().sync.time_enabled==true end,keep_menu_open=true,callback=function() self:toggle_time_sync() end},
        {text="阅读进度同步",checked_func=function() return self.store:preferences().sync.progress_enabled~=false end,keep_menu_open=true,callback=function() self:toggle_progress_sync() end},
        {text="立即同步进度",callback=function() self:manual_sync() end},
        {text="同步状态",callback=function() self:show_sync_status(false) end},
    }
end
function Plugin:toggle_time_sync()
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
    -- Automatic success notifications stay silent to avoid unnecessary e-ink refreshes.
end
function Plugin:toggle_progress_sync()
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
function Plugin:show_sync_status(_detail)
    local s=self.sync:status()
    local remote=s.remote and math.floor((s.remote.percent or 0)+.5) or nil
    local local_text=s.local_percent~=nil and (tostring(s.local_percent).."%")
        or (s.local_chapter_percent~=nil and ("本章 "..tostring(s.local_chapter_percent).."%") or "—")
    local time_text
    if not s.time_enabled then time_text="已关闭"
    elseif not s.record or s.state=="stopped" then time_text="未运行"
    elseif s.state=="verification_required" or s.state=="fetching_remote" or s.state=="progress_sync" then time_text="等待位置确认"
    elseif type(s.last_error)=="string" and (tonumber(s.consecutive_failures) or 0)>=2 then time_text="暂时失败，稍后重试"
    elseif s.state=="uploading" then time_text="正在同步"
    else time_text="运行中" end
    local lines={"阅读同步","","阅读时间："..time_text,"阅读进度："..self:progress_sync_label(),"当前位置："..local_text}
    if remote then lines[#lines+1]="云端位置："..remote.."%" end
    lines[#lines+1]="上次同步："..self:_relative_time(s.last_upload)
    self:info(table.concat(lines,"\n"))
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
function Plugin:on_read_report_interval_success(_status)
    -- Periodic success remains silent.
end
function Plugin:on_read_report_failure(_err)
    self:status_toast("阅读同步","连续同步失败，将稍后自动重试",5)
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
    if fallback then return {book=fallback,record=fallback.variants and (fallback.variants.notes or fallback.variants.clean or fallback.variants.preview_notes or fallback.variants.preview_clean),variant=nil,path=path} end
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
function Plugin:_toggle_preference(key)
    local p=self.store:preferences(); p[key]=not p[key]; self.store:save_preferences(p)
end




function Plugin:settings_menu()
    return {
        {text="显示书架封面",checked_func=function() return self.store:preferences().shelf_covers~=false end,keep_menu_open=true,callback=function() self:_toggle_preference("shelf_covers") end},
        {text="想法字体大小",sub_item_table_func=function() return self:thought_font_menu() end},
        {text="下载公众号文章图片",checked_func=function() return self.store:preferences().mp_images==true end,keep_menu_open=true,callback=function() self:_toggle_preference("mp_images") end},
        {text="公众号缓存",sub_item_table_func=function() return self:mp_global_cache_menu() end},
        {text="下载关键进度提示",checked_func=function() return self.store:preferences().download_notice_enabled~=false end,keep_menu_open=true,callback=function() self:_toggle_preference("download_notice_enabled") end},
        {text="下载完成提醒",checked_func=function() return self.store:preferences().download_complete_notice~=false end,keep_menu_open=true,callback=function() self:_toggle_preference("download_complete_notice") end},
        {text="下载目录",post_text=self:_download_dir_label(),callback=function() self:directory_dialog() end},
        {text="账户",sub_item_table_func=function() return self:account_menu() end},
        {text="检查内测更新",callback=self:safe("update",function() self:check_update() end)},
        {text="当前版本 · "..tostring(self.version),enabled=false},
        {text="关于觅阅",callback=self:safe("about",function() self:show_about() end)},
    }
end

function Plugin:thought_font_menu()
    local choices={{"standard","较小（默认）"},{"large","适中"},{"xlarge","接近正文"}}
    local rows={}
    for _,choice in ipairs(choices) do
        local key,label=choice[1],choice[2]
        rows[#rows+1]={text=label,radio=true,checked_func=function() return (self.store:preferences().thoughts or {}).font==key end,callback=function()
            local p=self.store:preferences(); p.thoughts=p.thoughts or {}; p.thoughts.font=key; self.store:save_preferences(p); self:toast("想法字体已设为："..label)
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

function Plugin:check_update()
    self:online("update",function()
        local m,e=self.updater:check()
        if not m then self:info("检查更新失败：\n"..tostring(e)); return end
        if m.current then self:info("当前已是最新版本\n\n当前版本："..tostring(self.version)); return end
        local text="发现新版本："..tostring(m.version)
        if m.notes and tostring(m.notes)~="" then text=text.."\n\n主要更新：\n"..tostring(m.notes) end
        text=text.."\n\n是否下载并安装？"
        UIManager:show(ConfirmBox:new{text=text,ok_text="下载并安装",ok_callback=function()
            self:online("install",function()
                local path=self.updater:download(m)
                local ok,er=self.updater:install(path,m)
                if ok then self:info("更新已安装\n\n请完全退出并重新启动 KOReader。") else self:info("更新失败：\n"..tostring(er)) end
            end)
        end})
    end)
end
function Plugin:show_about()
    self:info(Config.NAME.." "..self.version
        .."\n\n微信读书内容下载、书架管理与阅读同步。"
        .."\n\n已下载书籍作为本地 EPUB 直接打开，不进行联网权限验证或锁定。"
        .."\n\n".._("Unofficial client"))
end
function Plugin:onShowMiuRead() self:show_shelf(false,false,"account") end
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
    if self:logged_in() then self:toast("已登录",2) else self.auth_flow:start() end
    return true
end
function Plugin:onMiuReadCloseBook()
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
function Plugin:_teardown_thought_tap()
    if self._thought_tap_setup and self.ui and self.ui.unRegisterTouchZones then pcall(function() self.ui:unRegisterTouchZones({{id="miuread_thought_popup",overrides={"tap_link"}}}) end) end
    self._thought_tap_setup=nil
end
function Plugin:_thought_font_size(level)
    local Device=require("device")
    local doc=self.ui and self.ui.document
    local configurable=doc and doc.configurable or {}
    local candidates={
        configurable.font_size,
        configurable.fontsize,
        self.ui and self.ui.rolling and self.ui.rolling.font_size,
    }
    local base
    for _,value in ipairs(candidates) do
        value=tonumber(value)
        if value and value>=10 and value<=80 then base=value; break end
    end
    if not base and _G.G_reader_settings and _G.G_reader_settings.readSetting then
        local ok,value=pcall(_G.G_reader_settings.readSetting,_G.G_reader_settings,"cre_font_size",22)
        if ok then base=tonumber(value) end
    end
    base=math.max(14,math.min(48,base or 22))
    local factors={standard=0.86,large=1.00,xlarge=1.15}
    local factor=factors[tostring(level or "standard")] or 1
    return Device.screen:scaleBySize(math.floor(base*factor+.5))
end
local function usable_font_name(value)
    if type(value)~="string" then return nil end
    value=value:match("^%s*(.-)%s*$")
    if value=="" then return nil end
    return value
end
function Plugin:_thought_font_name()
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
function Plugin:_show_thought_href(href)
    local info=Thoughts.parse_href(href); if not info then return false end
    if self._thought_popup_busy then return true end
    self._thought_popup_busy=true
    local started=os.clock()
    local ok,unexpected=xpcall(function()
        local group,err,token=Thoughts.find(self.store,info.book_id,info.chapter_uid,info.range)
        if not group then self:info(tostring(err or "没有想法内容")); return end
        local prefs=self.store:preferences().thoughts or {}
        local source_html,html,metrics,html_cache_hit=Thoughts.popup_parts_cached(
            self.store,info.book_id,info.chapter_uid,info.range,group,token
        )
        if html=="" then self:info("没有想法内容"); return end
        ThoughtPopup.show{
            source_html=source_html,
            html=html,
            font_size=self:_thought_font_size(prefs.font),
            font_name=self:_thought_font_name(),
            width_ratio=tonumber(prefs.width_ratio) or 0.91,
            height_ratio=tonumber(prefs.height_ratio) or 0.60,
            css=Thoughts.popup_css(),
            metrics=metrics,
        }
        logger.info("[MiuRead][ThoughtPopup] opened",
            "book=",tostring(info.book_id),"chapter=",tostring(info.chapter_uid),
            "comments=",tostring(metrics and metrics.comment_count or 0),
            "chapter_cache=",token and token.cache_hit and "hit" or "miss",
            "html_cache=",html_cache_hit and "hit" or "miss",
            "elapsed_ms=",tostring(math.floor((os.clock()-started)*1000+.5)))
    end,debug.traceback)
    self._thought_popup_busy=false
    if not ok then
        logger.err("[MiuRead][ThoughtPopup] open failed",tostring(unexpected))
        self:info("想法弹窗打开失败：\n"..U.first_line(unexpected,220))
    end
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
    if current and current.book then
        local book_id,path=tostring(current.book.book_id),current.path
        UIManager:scheduleIn(1.0,function()
            local active=self.sync and self.sync.current
            if self.ui and self.ui.document and active and tostring(active.book.book_id)==book_id then
                self.store:mark_last_read(book_id,path)
            end
        end)
    end
    if self.store:preferences().sync.progress_enabled~=false then
        UIManager:scheduleIn(1.2,function()
            if self.ui and self.ui.document then self:ensure_read_report_progress("reader_ready",true) end
        end)
    end
end
function Plugin:on_sync_record_missing()
    logger.dbg("[MiuRead][Sync] external EPUB ignored")
end
function Plugin:onReaderReady()
    logger.info("[MiuRead][Sync] reader ready")
    self:_teardown_thought_tap(); self:_setup_thought_tap()
    self._progress_prompted_book_id=nil
    self._progress_check_running=false
    self._progress_remote_retries={}
    self._progress_success_notified=false
    self._last_progress_submit_notice=nil
    self.sync:on_reader_ready()
end
function Plugin:onPageUpdate(page)
    self.sync:on_page(page)
end
function Plugin:onSuspend() self._suspended_at=os.time(); self.sync:on_suspend() end
function Plugin:onResume()
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
        UIManager:scheduleIn(.5,function()
            if self.ui and self.ui.document then self:ensure_read_report_progress("resume_recheck",true) end
        end)
    end
end
function Plugin:onCloseDocument()
    self:_teardown_thought_tap(); self._progress_prompted_book_id=nil; self._progress_check_running=false; self.sync:on_close()
    UIManager:scheduleIn(.2,function() self:_install_pending_downloads(true) end)
end
function Plugin:onFlushSettings() self:_flush_cover_index(); self.store:flush() end
return Plugin
