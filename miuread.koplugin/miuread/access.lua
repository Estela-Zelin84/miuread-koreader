local Config = require("miuread.config")
local Http = require("miuread.http")
local U = require("miuread.util")
local logger = require("logger")

local Access = {}
Access.__index = Access

local TTL = tonumber(Config.ACCESS_VERIFY_TTL) or (3 * 24 * 60 * 60)
local LOCK_SUFFIX = ".miuread-locked"

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
        not_in_shelf = "本书已从微信读书官方书架移除。重新加入书架后，可在这里重新验证并打开。",
        no_permission = "微信读书当前无法打开本书内容。",
        preview_only = "微信读书当前仅允许试读，完整版已锁定。",
        login_required = "登录已失效，请重新扫码登录后再验证。",
        network_required = "当前无法联网验证，已保留本地文件和原有状态。",
        verify_failed = "暂时无法确认书籍状态，请稍后重新验证。",
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

local function record_locked(record)
    if type(record) ~= "table" then return false end
    local path = tostring(record.file or "")
    return record.locked == true or path:sub(-#LOCK_SUFFIX) == LOCK_SUFFIX
end

function Access:new(library, api, reader, store)
    return setmetatable({library=library, api=api, reader=reader, store=store}, self)
end

function Access:ttl() return TTL end
function Access:lock_suffix() return LOCK_SUFFIX end

function Access:_account_vid()
    local auth = self.store:auth()
    return tostring(auth.account and auth.account.vid or "")
end

function Access:_save(book_id, patch)
    local book = self.store:book(book_id) or {book_id=tostring(book_id), variants={}, chapters={}}
    local current = type(book.access) == "table" and book.access or {}
    patch = U.copy(patch or {})
    patch.policy_version = tonumber(Config.ACCESS_POLICY_VERSION) or 4
    local access = U.merge(current, patch)
    self.store:save_book(book_id, {access=access})
    return access
end

function Access:_refresh_shelf_row(book_id)
    local books, mp = self.library:refresh({retries=1, timeout={10,18}})
    return find_book(books, book_id) or find_book(mp, book_id), books, mp
end

function Access:is_locked(book_or_id)
    local book = type(book_or_id) == "table" and (book_or_id.local_record or book_or_id)
        or self.store:book(book_or_id)
    if type(book) ~= "table" then return false end
    local found = false
    each_record(book, function(record)
        if record_locked(record) then found = true end
    end)
    if found then return true end
    local access = type(book.access) == "table" and book.access or {}
    return access.status == "blocked" or access.status == "restricted"
end

function Access:first_record(book_or_id, wanted_scope, locked_only)
    local book = type(book_or_id) == "table" and (book_or_id.local_record or book_or_id)
        or self.store:book(book_or_id)
    if type(book) ~= "table" then return nil end
    local found
    each_record(book, function(record, kind)
        if found or type(record) ~= "table" then return end
        if wanted_scope and record_scope(record, kind) ~= wanted_scope then return end
        if locked_only and not record_locked(record) then return end
        found = record
    end)
    return found
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
            message=kind == "auth" and "登录已失效，请重新扫码登录后下载。"
                or "无法确认官方书架状态，本次未开始下载。",
        }
    end
    if not row then
        self:_save(id, {
            ownership="temporary", shelf_present=false, status="blocked",
            lock_reason="not_in_shelf", valid_until=0, shelf_checked_at=os.time(),
        })
        self:lock_book(id, "not_in_shelf", "all")
        return nil, {kind="blocked", message="请先将本书加入微信读书官方书架，再返回觅阅下载。"}
    end

    local now = os.time()
    local access = self:_save(id, {
        ownership="temporary",
        ownership_source="official_shelf_policy",
        account_vid=self:_account_vid(),
        shelf_present=true,
        shelf_checked_at=now,
        status="checking",
        lock_reason="",
    })
    book.bookId = id
    book.title = book.title or row.title
    book.author = book.author or row.author
    book.cover = book.cover or row.cover
    book.access_ownership = "temporary"
    book.access_ownership_source = "official_shelf_policy"
    book.access_account_vid = access.account_vid
    return book, access
end

function Access:lock_book(book_id, reason, wanted_scope)
    local book = self.store:book(book_id)
    if not book then return false end
    local changed = false
    each_record(book, function(record, kind)
        if type(record) ~= "table" or not scope_matches(record, kind, wanted_scope) then return end
        local path = tostring(record.file or "")
        if path == "" then return end
        if path:sub(-#LOCK_SUFFIX) == LOCK_SUFFIX then
            record.locked = true
            record.lock_reason = reason
            changed = true
            return
        end
        if not U.file_exists(path) or not path:lower():match("%.epub$") then return end
        local locked = path .. LOCK_SUFFIX
        if U.file_exists(locked) then
            record.original_file = path
            record.file = locked
            record.locked = true
            record.lock_reason = reason
            changed = true
            return
        end
        local ok, err = os.rename(path, locked)
        if ok then
            record.original_file = path
            record.file = locked
            record.locked = true
            record.lock_reason = reason
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
        changed = true
    end)
    if changed then self.store:save_book(book_id, book) end
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
            if tostring(row.chapterUid or row.uid or "") == guard_uid then chapter = row; break end
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

function Access:needs_verification(book_id, record)
    local book = self.store:book(book_id)
    if not book then return false end
    local access = type(book.access) == "table" and book.access or {}
    if self:is_locked(book) then return true end
    local current_vid = self:_account_vid()
    local bound_vid = tostring(access.account_vid or "")
    if bound_vid ~= "" and current_vid ~= bound_vid then return true end
    if tostring(access.status or "unverified") ~= "allowed" then return true end
    local scope = record_scope(record)
    if scope == "full" and tostring(access.access_scope or "") ~= "full" then return true end
    return (tonumber(access.valid_until or 0) or 0) < os.time()
end

function Access:verify_open(book_id, force, record)
    book_id = tostring(book_id or "")
    local book = self.store:book(book_id)
    if not book then return true, {status="external"} end
    local access = type(book.access) == "table" and U.copy(book.access) or {}
    local target_scope = record_scope(record)
    local now = os.time()
    local current_vid = self:_account_vid()
    local bound_vid = tostring(access.account_vid or "")
    local account_changed = bound_vid ~= "" and current_vid ~= bound_vid
    local still_valid = tonumber(access.valid_until or 0) >= now and not account_changed

    if not force and still_valid then
        if target_scope == "full" and access.access_scope == "preview" then
            self:lock_book(book_id, "preview_only", "full")
            return false, {status="blocked", reason="preview_only", message=reason_text("preview_only")}
        end
        self:unlock_book(book_id, target_scope == "preview" and "preview" or "full")
        return true, access
    end

    logger.info("[MiuRead][Access] verify start", "book=", book_id,
        "force=", tostring(force == true), "status=", tostring(access.status or "unknown"))

    local ok, row = pcall(self._refresh_shelf_row, self, book_id)
    if not ok then
        local kind = error_kind(row)
        self:_save(book_id, {status="pending", last_verify_error=kind, last_verify_attempt=now})
        local reason = kind == "auth" and "login_required" or "network_required"
        return false, {status="pending", reason=reason, message=reason_text(reason)}
    end
    if not row then
        self:_save(book_id, {
            ownership="temporary", shelf_present=false, status="blocked",
            lock_reason="not_in_shelf", valid_until=0, last_verify_attempt=now,
        })
        self:lock_book(book_id, "not_in_shelf", "all")
        return false, {status="blocked", reason="not_in_shelf", message=reason_text("not_in_shelf")}
    end

    if target_scope == "preview" and tostring(record and record.preview_mode or access.preview_mode or "") == "info" then
        local saved = self:_save(book_id, {
            ownership="temporary", ownership_source="official_shelf_policy",
            account_vid=current_vid, shelf_present=true, access_scope="preview",
            status="allowed", verified_at=now, valid_until=now + TTL,
            lock_reason="preview_only", last_verify_attempt=now, last_verify_error="",
        })
        self:lock_book(book_id, "preview_only", "full")
        self:unlock_book(book_id, "preview")
        return true, saved
    end

    local probe, kind, probe_error = self:_probe(book_id, access, record)
    if probe then
        local saved = self:_save(book_id, {
            ownership="temporary", ownership_source="official_shelf_policy",
            account_vid=current_vid, shelf_present=true, access_scope=target_scope,
            status="allowed", verified_at=now, valid_until=now + TTL,
            guard_chapter_uid=probe.guard_chapter_uid,
            catalog_count=probe.catalog_count or access.catalog_count,
            lock_reason=target_scope == "preview" and "preview_only" or "",
            last_verify_attempt=now, last_verify_error="",
        })
        if target_scope == "preview" then
            self:lock_book(book_id, "preview_only", "full")
            self:unlock_book(book_id, "preview")
        else
            self:unlock_book(book_id, "all")
        end
        return true, saved
    end

    if kind == "blocked" then
        if target_scope == "full" then
            self:_save(book_id, {
                ownership="temporary", shelf_present=true, access_scope="preview",
                status="restricted", valid_until=0, lock_reason="preview_only",
                last_verify_attempt=now, last_verify_error=probe_error,
            })
            self:lock_book(book_id, "preview_only", "full")
            return false, {status="blocked", reason="preview_only", message=reason_text("preview_only")}
        end
        self:_save(book_id, {
            ownership="temporary", shelf_present=true, access_scope="preview",
            status="blocked", valid_until=0, lock_reason="no_permission",
            last_verify_attempt=now, last_verify_error=probe_error,
        })
        self:lock_book(book_id, "no_permission", "all")
        return false, {status="blocked", reason="no_permission", message=reason_text("no_permission")}
    end

    self:_save(book_id, {status="pending", last_verify_error=kind, last_verify_attempt=now})
    local reason = kind == "auth" and "login_required"
        or (kind == "network" and "network_required" or "verify_failed")
    return false, {status="pending", reason=reason, message=reason_text(reason)}
end

function Access:status_text(book_or_id)
    local book
    if type(book_or_id) == "table" then
        book = book_or_id.local_record or self.store:book(book_or_id.bookId or book_or_id.book_id)
    else
        book = self.store:book(book_or_id)
    end
    local access = book and book.access or nil
    if type(access) ~= "table" then return nil end

    local reason = tostring(access.lock_reason or "")
    if reason == "not_in_shelf" then return "已移出官方书架 · 已锁定" end
    if reason == "no_permission" then return "当前不可阅读 · 已锁定" end
    if access.access_scope == "preview" or reason == "preview_only" then
        local readable = tonumber(access.readable_count or 0) or 0
        local catalog = tonumber(access.catalog_count or 0) or 0
        if access.preview_mode == "info" then return "试读信息" end
        if catalog > 0 then return "试读 · " .. tostring(readable) .. "/" .. tostring(catalog) .. "章" end
        return "试读"
    end
    if access.status == "pending" then
        if access.last_verify_error == "auth" then return "登录失效 · 等待验证" end
        return "等待联网验证"
    end
    if self:needs_verification(book.book_id or book.bookId, self:first_record(book, nil, false)) then
        return "需要联网确认"
    end
    return "官方书架已验证"
end

Access.error_kind = error_kind
Access.reason_text = reason_text
Access._record_scope = record_scope

return Access
