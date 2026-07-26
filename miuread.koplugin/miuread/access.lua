local Config = require("miuread.config")
local Http = require("miuread.http")
local U = require("miuread.util")
local logger = require("logger")

local Access = {}
Access.__index = Access

local TTL = tonumber(Config.ACCESS_VERIFY_TTL) or (3 * 24 * 60 * 60)
local LOCK_SUFFIX = ".miuread-locked"
local RETRY_GRACE = tonumber(Config.ACCESS_RETRY_GRACE) or (6 * 60 * 60)

local PERSONAL_KEYS = {
    isupload=true, isuploaded=true, uploaded=true, isprivateupload=true,
    ispersonal=true, isownbook=true, isselfuploaded=true, fromupload=true,
    personalupload=true, ispersonalupload=true, userupload=true, isuserupload=true, isimported=true, imported=true,
}
local PURCHASE_KEYS = {
    isbought=true, bought=true, ispurchased=true, purchased=true,
    isowned=true, owned=true, haspurchased=true, purchaseok=true,
    isbuy=true, hasbuy=true, hasbought=true, bookbought=true,
    isbookbought=true, isbookpurchased=true, purchasedbook=true,
}
local CLAIM_KEYS = {
    activityclaimed=true, isactivityclaimed=true, claimed=true, isclaimed=true,
    redeemed=true, isredeemed=true, received=true, isreceived=true,
    freeclaimed=true, permanentclaimed=true, exchangeowned=true,
}
local PERMANENT_KEYS = {
    ispermanent=true, permanent=true, permanentaccess=true,
    ispermanentaccess=true, permanentreadable=true,
    ispermanentreadable=true, canpermanentread=true,
    ownedforever=true, foreverreadable=true, lifetimeaccess=true,
}
local SOURCE_KEYS = {
    sourcetype=true, source=true, booksource=true, origin=true, origintype=true,
    importtype=true, ownership=true, ownershiptype=true, accesstype=true,
    rightstype=true, entitlementtype=true, acquiretype=true, acquiredtype=true,
}
local PURCHASE_STATUS_KEYS = {
    buystatus=true, purchasestatus=true, paidstatus=true, ownershipstatus=true,
    accessstatus=true, rightsstatus=true, entitlementstatus=true,
}

local function compact_text(value)
    return tostring(value or ""):lower():gsub("%s+", "")
end

local function truthy(value)
    if value == true then return true end
    if tonumber(value) == 1 then return true end
    local text = compact_text(value)
    return text == "true" or text == "yes" or text == "owned" or text == "purchased"
        or text == "bought" or text == "paid" or text == "success"
        or text == "permanent" or text == "forever"
        or text == "已购买" or text == "永久"
end

local function explicit_text_ownership(value)
    local text = compact_text(value)
    if text == "" then return nil end
    if text:find("个人上传", 1, true) or text:find("用户上传", 1, true)
        or text:find("本地导入", 1, true) or text:find("私有上传", 1, true) then
        return "personal_upload"
    end
    -- These are explicit account-rights messages rendered by the official
    -- reader. Unlike chapter `paid` flags, they mean the current account owns
    -- permanent reading rights (purchase, activity claim, redemption, etc.).
    if text:find("可永久阅读", 1, true) or text:find("永久阅读", 1, true)
        or text:find("书币购买", 1, true) or text:find("活动领取", 1, true)
        or text:find("永久领取", 1, true) or text:find("永久拥有", 1, true)
        or text:find("永久权益", 1, true) then
        return "purchased"
    end
end

local function ownership_field_text(value)
    local explicit = explicit_text_ownership(value)
    if explicit then return explicit end
    local text = compact_text(value)
    if text:find("upload", 1, true) or text:find("import", 1, true)
        or text:find("personal", 1, true) or text:find("private", 1, true) then
        return "personal_upload"
    end
    if text:find("purchased", 1, true) or text:find("bought", 1, true)
        or text:find("owned", 1, true) or text:find("permanent", 1, true)
        or text:find("forever", 1, true) or text:find("已购买", 1, true) then
        return "purchased"
    end
end

local function scan_ownership(value, depth, seen, path)
    if type(value) ~= "table" or (depth or 0) > 8 then return nil end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true
    path = tostring(path or "")

    for key, item in pairs(value) do
        local lower = type(key) == "string" and key:lower() or ""
        local field_path = path .. tostring(key)
        if PERSONAL_KEYS[lower] and truthy(item) then return "personal_upload", field_path end
        if (PURCHASE_KEYS[lower] or PERMANENT_KEYS[lower] or CLAIM_KEYS[lower]) and truthy(item) then
            return "purchased", field_path
        end
        if PURCHASE_STATUS_KEYS[lower] and (type(item)=="string" or type(item)=="number") then
            local found=ownership_field_text(item)
            if found then return found,field_path end
        end
        if SOURCE_KEYS[lower] and (type(item) == "string" or type(item) == "number") then
            local found=ownership_field_text(item)
            if found then return found,field_path end
        end
        if type(item)=="string" then
            local found=explicit_text_ownership(item)
            if found then return found,field_path end
        end
    end
    for key, item in pairs(value) do
        if type(item) == "table" then
            local found, source = scan_ownership(item, (depth or 0) + 1, seen,
                path .. tostring(key) .. ".")
            if found then return found, source end
        end
    end
end

local function find_book(rows, id)
    id = tostring(id or "")
    for _, row in ipairs(rows or {}) do
        if tostring(row.bookId or row.book_id or "") == id then return row end
    end
end

local function catalog_rows(reader, book_id)
    local catalog = reader:catalog(book_id)
    local source = catalog.updated or catalog.chapterInfos or catalog.chapters or {}
    local out, seen = {}, {}
    for _, chapter in ipairs(source or {}) do
        local uid = tostring(chapter.chapterUid or chapter.uid or "")
        if uid ~= "" and not seen[uid]
            and not reader._is_cover_chapter(chapter)
            and not reader._is_unavailable_chapter(chapter) then
            seen[uid] = true
            out[#out + 1] = chapter
        end
    end
    return catalog, out
end

local function error_kind(value)
    if Http.is_auth_error(value) then return "auth" end
    local text = tostring(value or ""):lower()
    if text:find("network request failed", 1, true) or text:find("timeout", 1, true)
        or text:find("timed out", 1, true) or text:find("http nil", 1, true)
        or text:find("transport unavailable", 1, true) or text:find("connection", 1, true)
        or text:find("network unavailable", 1, true) or text:find("网络", 1, true) then
        return "network"
    end
    return "unknown"
end

local function reason_text(reason)
    local labels = {
        not_in_shelf = "已从官方书架移除",
        no_permission = "当前无阅读权限",
        preview_only = "当前仅可试读",
        login_required = "登录已失效，请重新登录",
        network_required = "需要联网验证",
        verify_failed = "暂时无法验证书籍状态",
    }
    return labels[tostring(reason or "")] or tostring(reason or "暂时无法验证书籍状态")
end

local function is_preview_kind(kind)
    return tostring(kind or ""):sub(1, 8) == "preview_"
end

local function record_scope(record, kind)
    local scope = type(record) == "table" and tostring(record.access_scope or "") or ""
    if scope == "preview" or scope == "full" then return scope end
    if is_preview_kind(kind or (record and record.variant)) then return "preview" end
    return "full"
end

local function each_record(book, fn)
    for kind, record in pairs(book.variants or {}) do fn(record, kind, nil) end
    for uid, row in pairs(book.chapters or {}) do
        for kind, record in pairs(row or {}) do fn(record, kind, uid) end
    end
end

local function scope_matches(record, kind, wanted)
    return not wanted or wanted == "all" or record_scope(record, kind) == wanted
end

function Access:new(library, api, reader, store)
    return setmetatable({library=library, api=api, reader=reader, store=store}, self)
end

function Access:ttl() return TTL end
function Access:lock_suffix() return LOCK_SUFFIX end

local function record_locked(record)
    if type(record)~="table" then return false end
    local path=tostring(record.file or "")
    return record.locked==true or path:sub(-#LOCK_SUFFIX)==LOCK_SUFFIX
end

local function canonical_record_path(record)
    if type(record)~="table" then return "" end
    local path=tostring(record.original_file or record.file or "")
    return path:gsub("%.miuread%-locked$", "")
end

local function same_record(left,right)
    if left==right and type(left)=="table" then return true end
    if type(left)~="table" or type(right)~="table" then return false end
    local lp,rp=canonical_record_path(left),canonical_record_path(right)
    if lp~="" and rp~="" and lp==rp then return true end
    local lv,rv=tostring(left.variant or ""),tostring(right.variant or "")
    local lc,rc=tostring(left.chapter_uid or ""),tostring(right.chapter_uid or "")
    return lv~="" and lv==rv and lc~="" and lc==rc
end

local function effective_deadline(record,access)
    local record_deadline=tonumber(record and record.valid_until) or 0
    if record_deadline>0 then return record_deadline end
    return tonumber(access and access.valid_until) or 0
end

local function effective_status(record,access)
    local value=tostring(record and record.access_status or "")
    if value~="" then return value end
    return tostring(access and access.status or "unverified")
end

local function previously_verified(record,access)
    if effective_status(record,access)=="blocked" or effective_status(record,access)=="restricted" then return false end
    return (tonumber(record and record.verified_at) or 0)>0
        or (tonumber(access and access.verified_at) or 0)>0
        or effective_status(record,access)=="allowed"
        or effective_status(record,access)=="expired"
end

function Access:is_record_locked(record)
    return record_locked(record)
end

function Access:lock_record(book_id,target,reason)
    if self.store and self.store.read_only==true then return false end
    local book=self.store:book(book_id)
    if not book or type(target)~="table" then return false end
    local changed=false
    each_record(book,function(record)
        if changed or not same_record(record,target) then return end
        local path=tostring(record.file or "")
        if path=="" then return end
        record.locked=true
        record.lock_reason=reason
        record.access_status="blocked"
        record.last_access_check=os.time()
        if path:sub(-#LOCK_SUFFIX)==LOCK_SUFFIX then
            changed=true
            return
        end
        if not U.file_exists(path) or not path:lower():match("%.epub$") then
            changed=true
            return
        end
        local locked=path..LOCK_SUFFIX
        if U.file_exists(locked) then
            record.original_file=path
            record.file=locked
            record.locked_at=record.locked_at or os.time()
            changed=true
            return
        end
        local ok,err=os.rename(path,locked)
        if ok then
            record.original_file=path
            record.file=locked
            record.locked_at=os.time()
            changed=true
        else
            logger.warn("[MiuRead][Access] record lock rename failed",
                "book=",tostring(book_id),"error=",tostring(err))
        end
    end)
    if changed then self.store:save_book(book_id,book) end
    return changed
end

function Access:unlock_record(book_id,target)
    if self.store and self.store.read_only==true then return false end
    local book=self.store:book(book_id)
    if not book or type(target)~="table" then return false end
    local changed=false
    each_record(book,function(record)
        if changed or not same_record(record,target) then return end
        local path=tostring(record.file or "")
        if path=="" or not record_locked(record) then return end
        local restored=tostring(record.original_file or path:gsub("%.miuread%-locked$", ""))
        if restored=="" then return end
        if U.file_exists(restored) then
            record.file=restored
            if path~=restored and U.file_exists(path) then os.remove(path) end
        elseif U.file_exists(path) then
            local ok,err=os.rename(path,restored)
            if not ok then
                logger.warn("[MiuRead][Access] record unlock rename failed",
                    "book=",tostring(book_id),"error=",tostring(err))
                return
            end
            record.file=restored
        else
            return
        end
        record.locked=nil
        record.lock_reason=nil
        record.locked_at=nil
        record.original_file=nil
        record.access_status="allowed"
        record.last_access_check=os.time()
        changed=true
    end)
    if changed then self.store:save_book(book_id,book) end
    return changed
end

function Access:stamp_record(book_id,target,access)
    if self.store and self.store.read_only==true then return false end
    local book=self.store:book(book_id)
    if not book or type(target)~="table" then return false end
    access=type(access)=="table" and access or (book.access or {})
    local changed=false
    each_record(book,function(record)
        if changed or not same_record(record,target) then return end
        record.access_policy_version=tonumber(Config.ACCESS_POLICY_VERSION) or 5
        record.ownership=access.ownership or record.ownership
        record.verified_at=tonumber(access.verified_at) or os.time()
        record.valid_until=tonumber(access.valid_until) or 0
        record.access_status=access.status or "allowed"
        record.last_access_check=os.time()
        changed=true
    end)
    if changed then self.store:save_book(book_id,book) end
    return changed
end

function Access:is_locked(book_or_id,record)
    if record~=nil then return record_locked(record) end
    local book=type(book_or_id)=="table" and (book_or_id.local_record or book_or_id)
        or self.store:book(book_or_id)
    if type(book)~="table" then return false end
    local found=false
    each_record(book,function(item)
        if record_locked(item) then found=true end
    end)
    return found
end

function Access:first_record(book_or_id,wanted_scope,locked_only)
    local book=type(book_or_id)=="table" and (book_or_id.local_record or book_or_id)
        or self.store:book(book_or_id)
    if type(book)~="table" then return nil end
    local found
    each_record(book,function(record,kind)
        if found or type(record)~="table" then return end
        if wanted_scope and record_scope(record,kind)~=wanted_scope then return end
        if locked_only and not record_locked(record) then return end
        found=record
    end)
    return found
end

function Access:classify_ownership(...)
    for i = 1, select("#", ...) do
        local candidate = select(i, ...)
        local found, source = scan_ownership(candidate)
        if found then return found, source end
    end
    return "temporary", "no_permanent_marker"
end

function Access:_account_vid()
    local auth = self.store:auth()
    return tostring(auth.account and auth.account.vid or "")
end

function Access:_save(book_id, patch)
    local book = self.store:book(book_id) or {book_id=tostring(book_id), variants={}, chapters={}}
    local current = type(book.access) == "table" and book.access or {}
    patch = U.copy(patch or {})
    if patch.policy_version == nil then
        patch.policy_version = tonumber(Config.ACCESS_POLICY_VERSION) or 2
    end
    local access = U.merge(current, patch)
    self.store:save_book(book_id, {access=access})
    return access
end

function Access:_cached_shelf_row(book_id,max_age)
    local books,mp,updated=self.library:cached()
    local age=os.time()-(tonumber(updated) or 0)
    if age<0 or age>(tonumber(max_age) or 15*60) then return nil end
    return find_book(books,book_id) or find_book(mp,book_id)
end

function Access:_refresh_shelf_row(book_id)
    local books, mp = self.library:refresh({retries=1, timeout={7,12}})
    return find_book(books, book_id) or find_book(mp, book_id), books, mp
end

function Access:_ownership(row, detail, existing, chapter_detail, reader_context)
    local current_vid=self:_account_vid()
    local bound_vid=tostring(existing and existing.account_vid or "")
    local same_account=bound_vid=="" or current_vid=="" or bound_vid==current_vid
    if same_account and existing and (existing.ownership == "purchased" or existing.ownership == "personal_upload") then
        return existing.ownership, tostring(existing.ownership_source or "existing_record")
    end
    -- Chapter metadata contains generic paid flags and is deliberately excluded.
    return self:classify_ownership(row, row and row.raw, detail,
        reader_context and reader_context.book,
        reader_context and reader_context.source,
        reader_context)
end

function Access:prepare_download(book)
    book = U.copy(book or {})
    local id = tostring(book.bookId or book.book_id or "")
    if id == "" then return nil, {kind="unknown", message="书籍缺少 bookId"} end
    local ok, row = pcall(self._refresh_shelf_row, self, id)
    if not ok then
        local kind = error_kind(row)
        return nil, {
            kind=kind,
            message=kind == "auth" and "登录已失效，请重新登录后下载。"
                or "无法确认官方书架状态，本次未开始下载。",
        }
    end
    if not row then
        self:_save(id, {
            shelf_present=false, status="blocked", lock_reason="not_in_shelf",
            shelf_checked_at=os.time(),
        })
        return nil, {kind="blocked", message="请先将本书加入微信读书官方书架，再返回觅阅下载。"}
    end

    local detail, chapter_detail
    local detail_ok, detail_value = pcall(self.api.book, self.api, id)
    if detail_ok then detail = detail_value end
    local chapter_ok, chapter_value = pcall(self.api.chapters, self.api, id)
    if chapter_ok then chapter_detail = chapter_value end
    local reader_context
    local state_ok, state_value = pcall(self.reader.access_state, self.reader, id)
    if state_ok then reader_context = state_value
    else logger.warn("[MiuRead][Access] reader rights unavailable","book=",id,"error=",U.first_line(state_value,160)) end
    local existing = (self.store:book(id) or {}).access or {}
    local ownership, ownership_source = self:_ownership(row, detail, existing, chapter_detail, reader_context)
    local now = os.time()
    local access = self:_save(id, {
        ownership=ownership,
        ownership_source=ownership_source,
        account_vid=self:_account_vid(),
        shelf_present=true,
        shelf_checked_at=now,
        status=existing.status=="allowed" and "allowed" or "checking",
        lock_reason=existing.status=="allowed" and tostring(existing.lock_reason or "") or "",
    })
    book.bookId = id
    book.title = book.title or row.title
    book.author = book.author or row.author
    book.cover = book.cover or row.cover
    book.access_ownership = ownership
    book.access_ownership_source = ownership_source
    book.access_account_vid = access.account_vid
    return book, access
end

function Access:lock_book(book_id, reason, wanted_scope)
    if self.store and self.store.read_only==true then return false end
    local book = self.store:book(book_id)
    if not book then return false end
    local changed = false
    each_record(book, function(record, kind)
        if type(record) ~= "table" or not scope_matches(record, kind, wanted_scope) then return end
        local path = tostring(record.file or "")
        if path == "" then return end
        record.locked = true
        record.lock_reason = reason
        record.access_status = "blocked"
        record.last_access_check = os.time()
        if path:sub(-#LOCK_SUFFIX) == LOCK_SUFFIX then
            changed = true
            return
        end
        if not U.file_exists(path) or not path:lower():match("%.epub$") then
            changed = true
            return
        end
        local locked = path .. LOCK_SUFFIX
        if U.file_exists(locked) then
            record.original_file = path
            record.file = locked
            record.locked_at = record.locked_at or os.time()
            changed = true
            return
        end
        local ok, err = os.rename(path, locked)
        if ok then
            record.original_file = path
            record.file = locked
            record.locked_at = os.time()
            changed = true
        else
            logger.warn("[MiuRead][Access] lock rename failed",
                "book=", tostring(book_id), "error=", tostring(err))
        end
    end)
    if changed then self.store:save_book(book_id, book) end
    return changed
end

function Access:unlock_book(book_id, wanted_scope)
    if self.store and self.store.read_only==true then return false end
    local book = self.store:book(book_id)
    if not book then return false end
    local changed = false
    each_record(book, function(record, kind)
        if type(record) ~= "table" or not scope_matches(record, kind, wanted_scope) then return end
        local path = tostring(record.file or "")
        if path == "" or not record_locked(record) then return end
        local target = tostring(record.original_file or path:gsub("%.miuread%-locked$", ""))
        if target == "" then return end
        if U.file_exists(target) then
            record.file = target
            if path~=target and U.file_exists(path) then os.remove(path) end
        elseif U.file_exists(path) then
            local ok, err = os.rename(path, target)
            if not ok then
                logger.warn("[MiuRead][Access] unlock rename failed",
                    "book=", tostring(book_id), "error=", tostring(err))
                return
            end
            record.file = target
        else
            return
        end
        record.locked = nil
        record.lock_reason = nil
        record.locked_at = nil
        record.original_file = nil
        record.access_status = "allowed"
        record.last_access_check = os.time()
        changed = true
    end)
    if changed then self.store:save_book(book_id, book) end
    return changed
end

function Access:stamp_records(book_id,wanted_scope,access)
    if self.store and self.store.read_only==true then return false end
    local book=self.store:book(book_id)
    if not book then return false end
    access=type(access)=="table" and access or (book.access or {})
    local changed=false
    each_record(book,function(record,kind)
        if type(record)~="table" or not scope_matches(record,kind,wanted_scope) then return end
        record.access_policy_version=tonumber(Config.ACCESS_POLICY_VERSION) or 5
        record.ownership=access.ownership or record.ownership
        record.verified_at=tonumber(access.verified_at) or record.verified_at or 0
        record.valid_until=tonumber(access.valid_until) or 0
        record.access_status=access.status or record.access_status
        record.last_access_check=os.time()
        changed=true
    end)
    if changed then self.store:save_book(book_id,book) end
    return changed
end

function Access:resolve_path(book_id, path)
    local book = self.store:book(book_id)
    if not book then return path end
    if tostring(path or ""):sub(-#LOCK_SUFFIX) == LOCK_SUFFIX then
        local unlocked = tostring(path):sub(1, -#LOCK_SUFFIX - 1)
        if U.file_exists(unlocked) then return unlocked end
    end
    local found = path
    each_record(book, function(record)
        if found ~= path or type(record) ~= "table" then return end
        if tostring(record.file or "") == tostring(path or "")
            or tostring(record.original_file or "") == tostring(path or "") then
            found = record.file
        end
    end)
    return found
end

function Access:_probe(book_id, access, record)
    local ok, catalog, rows = pcall(catalog_rows, self.reader, book_id)
    if not ok then return nil, error_kind(catalog), tostring(catalog) end
    if #rows == 0 then return nil, "unknown", "未找到可验证章节" end

    local guard_uid = tostring((record and record.guard_chapter_uid) or access.guard_chapter_uid or "")
    local chapter
    if guard_uid ~= "" then
        for _, row in ipairs(rows) do
            if tostring(row.chapterUid or row.uid or "") == guard_uid then
                chapter = row
                break
            end
        end
    end
    chapter = chapter or rows[#rows]
    local format = catalog.format == "txt" and "txt" or "epub"
    local success, value = pcall(self.reader.chapter, self.reader,
        {bookId=tostring(book_id)}, chapter, format, {images=false})
    if success then
        return {
            guard_chapter_uid=tostring(chapter.chapterUid or chapter.uid or ""),
            catalog_count=#rows,
        }
    end
    if type(self.reader.is_access_denied_error) == "function"
        and self.reader.is_access_denied_error(value) then
        return nil, "blocked", tostring(value)
    end
    return nil, error_kind(value), tostring(value)
end

function Access:needs_verification(book_id,record)
    local book=self.store:book(book_id)
    if not book then return false end
    local access=type(book.access)=="table" and book.access or {}
    local current_vid=self:_account_vid()
    local bound_vid=tostring(access.account_vid or "")
    local account_changed=bound_vid~="" and current_vid~="" and current_vid~=bound_vid
    if not account_changed and (access.ownership=="purchased" or access.ownership=="personal_upload") then return false end
    if record and record_locked(record) then return true end
    if not record and self:is_locked(book) then return true end
    if account_changed then return true end
    local status=effective_status(record,access)
    if status~="allowed" then return true end
    local scope=record_scope(record)
    if not record and scope=="full" and tostring(access.access_scope or "")~="full" then return true end
    local deadline=effective_deadline(record,access)
    return deadline<os.time()
end

function Access:verify_open(book_id, force, record)
    book_id = tostring(book_id or "")
    local book = self.store:book(book_id)
    if not book then return true, {status="external"} end
    local access = type(book.access) == "table" and U.copy(book.access) or {}
    local target_scope = record_scope(record)
    local now = os.time()
    local current_vid=self:_account_vid()
    local bound_vid=tostring(access.account_vid or "")
    local account_changed=bound_vid~="" and current_vid~="" and current_vid~=bound_vid
    logger.info("[MiuRead][Access] verify start","book=",book_id,"force=",tostring(force==true),
        "status=",tostring(access.status or "unknown"),"ownership=",tostring(access.ownership or "unknown"),
        "scope=",target_scope,"account_changed=",tostring(account_changed))

    if not account_changed and (access.ownership == "purchased" or access.ownership == "personal_upload") then
        self:unlock_book(book_id, "all")
        return true, access
    end

    -- 1.1.49-beta.1 could overwrite permanent rights as temporary and then
    -- lock the file after shelf removal. Recover those rights from official
    -- book/reader data before relying on shelf membership.
    local reader_context
    local recovery_source=tostring(access.ownership_source or "")
    local needs_ownership_recovery=not account_changed and (
        recovery_source=="migration_from_1.1.49"
        or recovery_source=="official_shelf_policy"
        or tostring(access.ownership or "")=="unknown"
    )
    if needs_ownership_recovery then
        local state_ok,state_value=pcall(self.reader.access_state,self.reader,book_id)
        if state_ok then reader_context=state_value end
        local detail_ok,detail=pcall(self.api.book,self.api,book_id)
        local ownership,source=self:_ownership(nil,detail_ok and detail or nil,access,nil,reader_context)
        if ownership=="purchased" or ownership=="personal_upload" then
            local saved=self:_save(book_id,{ownership=ownership,ownership_source=source,
                account_vid=current_vid,status="allowed",access_scope="full",verified_at=now,
                valid_until=0,lock_reason="",last_verify_attempt=now,last_verify_error="",stale=nil})
            self:unlock_book(book_id,"all")
            return true,saved
        end
    end

    local deadline=effective_deadline(record,access)
    local still_valid = deadline >= now and not account_changed
    if not force and still_valid and effective_status(record,access)=="allowed" then
        if target_scope == "full" and access.access_scope == "preview" then
            if record then self:lock_record(book_id,record,"preview_only")
            else self:lock_book(book_id,"preview_only","full") end
            return false, {status="blocked", reason="preview_only", message=reason_text("preview_only"),global=false}
        end
        if record then self:unlock_record(book_id,record) else self:unlock_book(book_id,target_scope) end
        return true, access
    end

    local row
    if not force and not account_changed then row=self:_cached_shelf_row(book_id,15*60) end
    if not row then
        local ok,value=pcall(self._refresh_shelf_row,self,book_id)
        if ok then row=value else
            local kind=error_kind(value)
            local stale_allowed=not account_changed and previously_verified(record,access)
                and (target_scope=="preview" or tostring(access.access_scope or "")=="full"
                    or tostring(record and record.access_scope or "")=="full")
            self:_save(book_id,{
                status=stale_allowed and "allowed" or "pending",
                valid_until=stale_allowed and (now+RETRY_GRACE) or access.valid_until,
                last_verify_error=kind,last_verify_attempt=now,stale=stale_allowed or nil,
            })
            if stale_allowed then
                if record then self:unlock_record(book_id,record) else self:unlock_book(book_id,target_scope) end
                local state=U.merge(access,{status="allowed",valid_until=now+RETRY_GRACE,
                    stale=true,reason=kind,message="联网验证失败，已继续使用上次有效结果。"})
                return true,state
            end
            local reason=kind=="auth" and "login_required" or "network_required"
            return false,{status="pending",reason=reason,message=reason_text(reason)}
        end
    end

    if not row then
        self:_save(book_id,{shelf_present=false,status="blocked",lock_reason="not_in_shelf",
            valid_until=0,last_verify_attempt=now,stale=nil})
        self:lock_book(book_id,"not_in_shelf",target_scope)
        return false,{status="blocked",reason="not_in_shelf",message=reason_text("not_in_shelf"),global=true}
    end

    local state_ok,state_value=pcall(self.reader.access_state,self.reader,book_id)
    if state_ok then reader_context=state_value
    else logger.warn("[MiuRead][Access] reader rights unavailable","book=",book_id,"error=",U.first_line(state_value,160)) end
    local ownership,ownership_source=self:_ownership(row,nil,access,nil,reader_context)
    if ownership=="temporary" then
        local detail_ok,detail=pcall(self.api.book,self.api,book_id)
        if detail_ok then ownership,ownership_source=self:_ownership(row,detail,access,nil,reader_context) end
    end
    if ownership=="purchased" or ownership=="personal_upload" then
        local saved=self:_save(book_id,{ownership=ownership,ownership_source=ownership_source,
            account_vid=current_vid,shelf_present=true,status="allowed",access_scope="full",
            verified_at=now,valid_until=0,lock_reason="",last_verify_attempt=now,
            last_verify_error="",stale=nil})
        self:unlock_book(book_id,"all")
        return true,saved
    end

    if target_scope=="preview" and tostring(record and record.preview_mode or access.preview_mode or "")=="info" then
        local saved=self:_save(book_id,{ownership="temporary",account_vid=current_vid,
            shelf_present=true,access_scope="preview",status="allowed",verified_at=now,
            valid_until=now+TTL,lock_reason="preview_only",last_verify_attempt=now,
            last_verify_error="",stale=nil})
        if record then self:unlock_record(book_id,record) else self:unlock_book(book_id,"preview") end
        return true,saved
    end

    local probe,kind,probe_error=self:_probe(book_id,access,record)
    if probe then
        local saved=self:_save(book_id,{ownership="temporary",ownership_source="current_access",
            account_vid=current_vid,shelf_present=true,access_scope=target_scope,status="allowed",
            verified_at=now,valid_until=now+TTL,guard_chapter_uid=probe.guard_chapter_uid,
            catalog_count=probe.catalog_count or access.catalog_count,
            lock_reason=target_scope=="preview" and "preview_only" or "",
            last_verify_attempt=now,last_verify_error="",stale=nil})
        if record then self:unlock_record(book_id,record)
        elseif target_scope=="preview" then self:unlock_book(book_id,"preview")
        else self:unlock_book(book_id,"full") end
        return true,saved
    end

    if kind=="blocked" then
        local reason=target_scope=="full" and "preview_only" or "no_permission"
        self:_save(book_id,{ownership="temporary",shelf_present=true,
            access_scope=target_scope=="full" and "preview" or target_scope,
            status=target_scope=="full" and "restricted" or "blocked",valid_until=0,
            lock_reason=reason,last_verify_attempt=now,last_verify_error=probe_error,stale=nil})
        if record then self:lock_record(book_id,record,reason)
        else self:lock_book(book_id,reason,target_scope) end
        return false,{status="blocked",reason=reason,message=reason_text(reason),global=false}
    end

    local stale_allowed=not account_changed and previously_verified(record,access)
        and (target_scope=="preview" or tostring(access.access_scope or "")=="full"
            or tostring(record and record.access_scope or "")=="full")
    self:_save(book_id,{status=stale_allowed and "allowed" or "pending",
        valid_until=stale_allowed and (now+RETRY_GRACE) or access.valid_until,
        last_verify_error=kind,last_verify_attempt=now,stale=stale_allowed or nil})
    if stale_allowed then
        if record then self:unlock_record(book_id,record) else self:unlock_book(book_id,target_scope) end
        return true,U.merge(access,{status="allowed",valid_until=now+RETRY_GRACE,
            stale=true,reason=kind,message="联网验证失败，已继续使用上次有效结果。"})
    end
    local reason=kind=="auth" and "login_required"
        or (kind=="network" and "network_required" or "verify_failed")
    return false,{status="pending",reason=reason,message=reason_text(reason)}
end

function Access:status_text(book_or_id)
    local book
    if type(book_or_id)=="table" then
        book=book_or_id.local_record or self.store:book(book_or_id.bookId or book_or_id.book_id)
    else
        book=self.store:book(book_or_id)
    end
    local access=book and book.access or nil
    if type(access)~="table" then return nil end
    local current_vid=self:_account_vid()
    local bound_vid=tostring(access.account_vid or "")
    if bound_vid~="" and current_vid~="" and bound_vid~=current_vid then return "账号已切换 · 待确认" end
    if access.ownership=="purchased" then return "永久拥有" end
    if access.ownership=="personal_upload" then return "个人上传" end
    if access.access_scope=="preview" or access.lock_reason=="preview_only" then
        local readable=tonumber(access.readable_count or 0) or 0
        local catalog=tonumber(access.catalog_count or 0) or 0
        if access.preview_mode=="info" then return "仅有试读信息" end
        if catalog>0 then return "试读 · "..tostring(readable).."/"..tostring(catalog).."章" end
        return "试读"
    end
    if access.status=="blocked" or access.status=="restricted" then return reason_text(access.lock_reason) end
    if self:needs_verification(book.book_id or book.bookId,self:first_record(book,nil,false)) then return "需要联网确认" end
    if access.stale==true then return "上次验证有效 · 待联网更新" end
    return "当前可读"
end

Access.error_kind = error_kind
Access.reason_text = reason_text
Access._scan_ownership = scan_ownership
Access._record_scope = record_scope
Access._record_locked = record_locked

return Access
