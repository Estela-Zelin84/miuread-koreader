local logger = require("logger")
local Thoughts = require("miuread.thoughts")
local Http = require("miuread.http")
local U = require("miuread.util")
local ok_socket, socket = pcall(require, "socket")

local Annotations = {}
Annotations.__index = Annotations

local AnnotationStyle = require("miuread.annotation_style")
local CSS = AnnotationStyle.CSS

local function pause(seconds)
    if ok_socket and socket and type(socket.sleep) == "function" then socket.sleep(seconds) end
end

local function is_network_failure(value)
    local text=tostring(value or ""):lower()
    return text:find("network request failed",1,true)~=nil
        or text:find("timeout",1,true)~=nil
        or text:find("connection refused",1,true)~=nil
        or text:find("network is unreachable",1,true)~=nil
end

local function call_with_retry(label, fn)
    local last
    for attempt = 1, 3 do
        local ok, value = pcall(fn)
        if ok and type(value) == "table" then return true, value, false end
        last = ok and (label .. " returned invalid data") or tostring(value)
        if Http.is_auth_error(last) then return false,last,false,"authentication" end
        if Http.is_rate_limit_error(last) then return false,last,false,"rate_limit" end
        if Http.is_forbidden_error(last) then return false,last,false,"forbidden" end
        local network_down=is_network_failure(last)
        local max_attempts=network_down and 2 or 3
        if attempt < max_attempts then
            logger.warn("[MiuRead][Annotations] retry", "label=", label, "attempt=", tostring(attempt), "error=", tostring(last))
            pause(attempt == 1 and 0.6 or 1.4)
        else
            return false,last,network_down,nil
        end
    end
    return false,last,is_network_failure(last),nil
end


local function is_data_specific_failure(value)
    local text=tostring(value or ""):lower()
    return text:find("params error",1,true)~=nil
        or text:find("invalid range",1,true)~=nil
        or text:find("invalid parameter",1,true)~=nil
        or text:find("range error",1,true)~=nil
end

local function str(v) return v == nil and "" or tostring(v) end
local function scalar_str(v)
    local kind=type(v)
    if kind=="string" or kind=="number" then return tostring(v) end
    return ""
end

local function range_key(v)
    if type(v) ~= "table" then return "" end
    return scalar_str(rawget(v,"range") or rawget(v,"markRange") or rawget(v,"bookmarkRange"))
end

local function array_from(data, names)
    if type(data) ~= "table" then return {} end
    for _, name in ipairs(names) do if type(data[name]) == "table" then return data[name] end end
    if #data > 0 then return data end
    return {}
end

local function table_entries(data)
    local rows, invalid = {}, 0
    if type(data) ~= "table" then return rows, invalid end
    for _, value in ipairs(data) do
        if type(value) == "table" then
            rows[#rows + 1] = value
        else
            invalid = invalid + 1
        end
    end
    return rows, invalid
end

local function parse_range(value)
    local a, b = str(value):match("^(%d+)%-(%d+)$")
    a, b = tonumber(a), tonumber(b)
    if not a or not b or b <= a then return nil end
    return a, b
end

local function review_texts(group)
    local rows, seen, invalid = {}, {}, 0
    local pages, skipped = table_entries(array_from(group, {"pageReviews", "reviews", "updated"}))
    invalid = invalid + skipped
    for _, page in ipairs(pages) do
        -- Review payloads occasionally contain placeholders, functions or tables
        -- with surprising metatables. Keep each entry isolated so one malformed
        -- review can never abort the whole book download.
        local ok, item = pcall(function()
            if type(page) ~= "table" then return nil end
            local nested = rawget(page, "review")
            local r = type(nested) == "table" and nested or page
            if type(r) ~= "table" then return nil end
            local content = scalar_str(rawget(r, "content") or rawget(r, "review") or rawget(r, "text"))
            if content == "" then return nil end
            local author = type(rawget(r, "author")) == "table" and rawget(r, "author") or {}
            local author_name = scalar_str(rawget(author, "nick") or rawget(author, "name") or rawget(r, "authorName"))
            local key = scalar_str(rawget(r, "reviewId") or rawget(r, "id"))
            if key == "" then key = content .. "\0" .. author_name end
            return {
                key = key,
                content = content,
                abstract = scalar_str(rawget(r, "abstract") or rawget(r, "contextAbstract") or rawget(r, "markText")),
                created = tonumber(rawget(r, "createTime") or rawget(r, "createdAt") or 0) or 0,
                author = author_name,
                likes = tonumber(rawget(page, "likesCount") or rawget(r, "likesCount") or 0) or 0,
                review_id = scalar_str(rawget(r, "reviewId") or rawget(r, "id")),
            }
        end)
        if ok and item and not seen[item.key] then
            seen[item.key] = true
            item.key = nil
            rows[#rows + 1] = item
        elseif not ok or item == nil then
            invalid = invalid + 1
        end
    end
    return rows, invalid
end

local function normalize_reviews(data)
    local map, groups, group_count, entry_count, invalid_count = {}, {}, 0, 0, 0
    local source, skipped = table_entries(array_from(data, {"reviews", "updated"}))
    invalid_count = invalid_count + skipped
    for _, group in ipairs(source) do
        local key = range_key(group)
        if key ~= "" then
            local texts, invalid = review_texts(group)
            invalid_count = invalid_count + invalid
            if #texts > 0 then
                if not map[key] then group_count = group_count + 1; map[key] = {} end
                for _, item in ipairs(texts) do map[key][#map[key] + 1] = item end
                entry_count = entry_count + #texts
            end
        end
    end
    for key, texts in pairs(map) do groups[#groups + 1] = {range = key, texts = texts} end
    table.sort(groups, function(a, b) return tostring(a.range) < tostring(b.range) end)
    return map, groups, group_count, entry_count, invalid_count
end

function Annotations:new(api) return setmetatable({api = api}, self) end

function Annotations:fetch_chapter(book_id, uid, progress)
    local result={book_id=str(book_id),chapter_uid=str(uid),underlines={},review_map={},review_groups={},
        underline_count=0,thought_count=0,thought_entry_count=0,errors={},underline_request_ok=false,
        underlines_partial=false,completed_ranges={},pending_ranges={},review_complete=false,complete=false}
    progress=progress or function() end
    local ok,data,network_down,error_kind=call_with_retry("underlines",function()
        return self.api:underlines(book_id,uid)
    end)
    if not ok then
        local err=str(data)
        result.errors[#result.errors+1]=err
        result.auth_required=error_kind=="authentication"
        result.forbidden=error_kind=="forbidden"
        result.rate_limited=error_kind=="rate_limit"
        result.error_kind=error_kind or (network_down and "network") or "server"
        logger.warn("[MiuRead][Annotations] underlines failed","book=",result.book_id,
            "chapter=",result.chapter_uid,"kind=",tostring(result.error_kind),"error=",err)
        return result
    end

    result.underline_request_ok=true
    local invalid_underlines
    result.underlines,invalid_underlines=table_entries(array_from(data,{"underlines","updated","bookmarks"}))
    result.underline_count=#result.underlines
    if invalid_underlines>0 then
        result.underlines_partial=true
        result.error_kind=result.error_kind or "data"
        result.errors[#result.errors+1]="underline response contained invalid entries"
        logger.warn("[MiuRead][Annotations] ignored invalid underline entries",
            "book=",result.book_id,"chapter=",result.chapter_uid,"count=",tostring(invalid_underlines))
    end

    local ranges,seen={},{ }
    for _,row in ipairs(result.underlines) do
        local key=range_key(row)
        if key~="" and not seen[key] then seen[key]=true; ranges[#ranges+1]=key end
    end
    progress("underlines",result.underline_count,result.underline_count,"")
    if #ranges==0 then
        result.review_complete=true
        result.complete=result.underline_request_ok and result.underlines_partial~=true
        return result
    end

    local groups={}
    local batches=self.api:review_batches(ranges,5)
    local completed,pending={},{}
    local function mark_batch(batch,target)
        for _,item in ipairs(batch or {}) do
            local key=range_key(item)
            if key~="" then target[key]=true end
        end
    end
    local function mark_remaining(first)
        for index=first,#batches do mark_batch(batches[index],pending) end
    end

    for index,batch in ipairs(batches) do
        progress("thoughts",index,#batches,"")
        local good,response,batch_network,batch_kind=call_with_retry("thoughts batch "..tostring(index),function()
            return self.api:readreviews(book_id,uid,batch)
        end)
        if good then
            local rows,invalid=table_entries(array_from(response,{"reviews","updated"}))
            for _,item in ipairs(rows) do groups[#groups+1]=item end
            if invalid>0 then
                mark_batch(batch,pending)
                result.error_kind=result.error_kind or "data"
                result.errors[#result.errors+1]="batch "..tostring(index).." contained invalid review groups"
                logger.warn("[MiuRead][Annotations] ignored invalid review groups","book=",result.book_id,
                    "chapter=",result.chapter_uid,"batch=",tostring(index),"count=",tostring(invalid))
            else
                mark_batch(batch,completed)
            end
        elseif is_data_specific_failure(response) then
            logger.warn("[MiuRead][Annotations] thoughts batch failed; trying individual ranges",
                "book=",result.book_id,"chapter=",result.chapter_uid,"batch=",index,"/",#batches)
            local stop=false
            for item_index,item in ipairs(batch) do
                progress("thoughts",index,#batches,"逐条补全 "..tostring(item_index).."/"..tostring(#batch))
                local single_ok,single_response,single_network,single_kind=call_with_retry(
                    "thought range "..tostring(index).."."..tostring(item_index),function()
                        return self.api:readreviews(book_id,uid,{item})
                    end)
                local key=range_key(item)
                if single_ok then
                    local rows,invalid=table_entries(array_from(single_response,{"reviews","updated"}))
                    for _,row in ipairs(rows) do groups[#groups+1]=row end
                    if invalid>0 then
                        if key~="" then pending[key]=true end
                        result.error_kind=result.error_kind or "data"
                        result.errors[#result.errors+1]="review range contained invalid entries"
                        logger.warn("[MiuRead][Annotations] ignored invalid review groups",
                            "book=",result.book_id,"chapter=",result.chapter_uid,"count=",tostring(invalid))
                    elseif key~="" then
                        completed[key]=true
                    end
                else
                    if key~="" then pending[key]=true end
                    result.errors[#result.errors+1]=str(single_response)
                    result.error_kind=single_kind or (single_network and "network") or "server"
                    result.auth_required=single_kind=="authentication"
                    result.forbidden=single_kind=="forbidden"
                    result.rate_limited=single_kind=="rate_limit"
                    if result.auth_required or result.forbidden or result.rate_limited or single_network then
                        for rest=item_index+1,#batch do mark_batch({batch[rest]},pending) end
                        mark_remaining(index+1)
                        stop=true
                        break
                    end
                end
            end
            if stop then break end
        else
            mark_remaining(index)
            result.errors[#result.errors+1]="batch "..tostring(index)..": "..str(response)
            result.error_kind=batch_kind or (batch_network and "network") or "server"
            result.auth_required=batch_kind=="authentication"
            result.forbidden=batch_kind=="forbidden"
            result.rate_limited=batch_kind=="rate_limit"
            logger.warn("[MiuRead][Annotations] thoughts batch deferred","book=",result.book_id,
                "chapter=",result.chapter_uid,"batch=",tostring(index),"/",tostring(#batches),
                "kind=",tostring(result.error_kind))
            break
        end
    end

    local invalid_reviews
    result.review_map,result.review_groups,result.thought_count,result.thought_entry_count,invalid_reviews=
        normalize_reviews({reviews=groups})
    for key in pairs(completed) do result.completed_ranges[#result.completed_ranges+1]=key end
    for key in pairs(pending) do result.pending_ranges[#result.pending_ranges+1]=key end
    table.sort(result.completed_ranges)
    table.sort(result.pending_ranges)
    result.review_complete=#result.pending_ranges==0
    result.complete=result.underline_request_ok and result.underlines_partial~=true and result.review_complete
    if invalid_reviews>0 then logger.warn("[MiuRead][Annotations] ignored invalid review entries",
        "book=",result.book_id,"chapter=",result.chapter_uid,"count=",tostring(invalid_reviews)) end
    logger.info("[MiuRead][Annotations] chapter fetched","book=",result.book_id,"chapter=",result.chapter_uid,
        "underlines=",result.underline_count,"thought_groups=",result.thought_count,
        "thought_entries=",result.thought_entry_count,"pending_ranges=",#result.pending_ranges)
    return result
end

local function utf8_len_at(text, i)
    local c = text:byte(i)
    if not c or c < 0x80 then return 1 end
    if c < 0xE0 then return 2 end
    if c < 0xF0 then return 3 end
    return 4
end

local NAMED_ENTITIES = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'",
    nbsp = " ", ensp = " ", emsp = " ", thinsp = " ",
    hellip = "…", mdash = "—", ndash = "–",
    lsquo = "‘", rsquo = "’", ldquo = "“", rdquo = "”",
    zwnj = "", zwj = "",
}

local function utf8_encode(codepoint)
    codepoint = tonumber(codepoint)
    if not codepoint or codepoint < 0 or codepoint > 0x10FFFF
        or (codepoint >= 0xD800 and codepoint <= 0xDFFF) then
        return nil
    end
    if codepoint < 0x80 then
        return string.char(codepoint)
    elseif codepoint < 0x800 then
        return string.char(0xC0 + math.floor(codepoint / 0x40), 0x80 + (codepoint % 0x40))
    elseif codepoint < 0x10000 then
        return string.char(
            0xE0 + math.floor(codepoint / 0x1000),
            0x80 + (math.floor(codepoint / 0x40) % 0x40),
            0x80 + (codepoint % 0x40)
        )
    end
    return string.char(
        0xF0 + math.floor(codepoint / 0x40000),
        0x80 + (math.floor(codepoint / 0x1000) % 0x40),
        0x80 + (math.floor(codepoint / 0x40) % 0x40),
        0x80 + (codepoint % 0x40)
    )
end

local function decode_html_unit(unit)
    unit = tostring(unit or "")
    local decimal = unit:match("^&#(%d+);$")
    if decimal then return utf8_encode(tonumber(decimal, 10)) or unit end
    local hexadecimal = unit:match("^&#[xX]([%x]+);$")
    if hexadecimal then return utf8_encode(tonumber(hexadecimal, 16)) or unit end
    local named = unit:match("^&([%w]+);$")
    if named and NAMED_ENTITIES[named] ~= nil then return NAMED_ENTITIES[named] end
    return unit
end

local function split_units(raw)
    local units, p = {}, 1
    while p <= #raw do
        local entity = raw:sub(p):match("^&[#%w]+;")
        if entity then
            units[#units + 1] = entity
            p = p + #entity
        else
            local n = utf8_len_at(raw, p)
            units[#units + 1] = raw:sub(p, p + n - 1)
            p = p + n
        end
    end
    return units
end

local function is_ignorable_text(value)
    if value == nil or value == "" then return true end
    if value:match("^%s+$") then return true end
    return value == "\194\160"       -- non-breaking space
        or value == "\227\128\128" -- ideographic space
        or value == "\226\128\139" -- zero-width space
        or value == "\226\128\140" -- zero-width non-joiner
        or value == "\226\128\141" -- zero-width joiner
        or value == "\239\187\191" -- UTF-8 BOM
end

local SKIP_TEXT_TAGS = {
    script = true, style = true, noscript = true, template = true, svg = true,
}

local function tag_info(raw)
    local slash, name = tostring(raw or ""):match("^<%s*(/?)%s*([%w:_%-]+)")
    if not name then return false, "", false end
    return slash == "/", name:lower(), tostring(raw):match("/%s*>$") ~= nil
end

local function tokenize(html)
    local tokens, visible = {}, 0
    local i, skip_depth, anchor_depth = 1, 0, 0
    while i <= #html do
        if html:sub(i, i) == "<" then
            local j = html:find(">", i + 1, true)
            if not j then
                local raw = html:sub(i)
                tokens[#tokens + 1] = {
                    kind="text", raw=raw, units=split_units(raw), start=visible,
                    skip=skip_depth > 0, inside_anchor=anchor_depth > 0,
                }
                if skip_depth == 0 then visible = visible + #tokens[#tokens].units end
                break
            end
            local raw = html:sub(i, j)
            local closing, name, self_closing = tag_info(raw)
            if closing and name == "a" then anchor_depth = math.max(0, anchor_depth - 1) end
            tokens[#tokens + 1] = {kind="tag", raw=raw}
            if closing and SKIP_TEXT_TAGS[name] then
                skip_depth = math.max(0, skip_depth - 1)
            elseif not closing and not self_closing and SKIP_TEXT_TAGS[name] then
                skip_depth = skip_depth + 1
            end
            if not closing and not self_closing and name == "a" then anchor_depth = anchor_depth + 1 end
            i = j + 1
        else
            local j = html:find("<", i, true) or (#html + 1)
            local raw = html:sub(i, j - 1)
            local units = split_units(raw)
            local skipped = skip_depth > 0
            tokens[#tokens + 1] = {
                kind="text", raw=raw, units=units, start=visible,
                stop=skipped and visible or (visible + #units), skip=skipped,
                inside_anchor=anchor_depth > 0,
            }
            if not skipped then visible = visible + #units end
            i = j
        end
    end
    return tokens, visible
end

local function utf16_width(value)
    local first = tostring(value or ""):byte(1) or 0
    return first >= 0xF0 and 2 or 1
end

local function build_text_index(tokens)
    local pieces, starts, ends, ordinals = {}, {}, {}, {}
    local compact_bounds, utf16_bounds = {}, {}
    local byte_pos, compact_count, utf16_count = 1, 0, 0

    for _, token in ipairs(tokens or {}) do
        if token.kind == "text" and not token.skip then
            for index, unit in ipairs(token.units or {}) do
                local raw_pos = token.start + index - 1
                local decoded = decode_html_unit(unit)

                if utf16_bounds[utf16_count] == nil then utf16_bounds[utf16_count] = raw_pos end
                local width = utf16_width(decoded)
                if width > 1 then
                    for extra = 1, width - 1 do utf16_bounds[utf16_count + extra] = raw_pos end
                end
                utf16_count = utf16_count + width
                utf16_bounds[utf16_count] = raw_pos + 1

                if not is_ignorable_text(decoded) then
                    compact_bounds[compact_count] = compact_bounds[compact_count] or raw_pos
                    pieces[#pieces + 1] = decoded
                    starts[byte_pos] = raw_pos
                    ordinals[byte_pos] = compact_count
                    local end_byte = byte_pos + #decoded - 1
                    ends[end_byte] = raw_pos + 1
                    byte_pos = end_byte + 1
                    compact_count = compact_count + 1
                    compact_bounds[compact_count] = raw_pos + 1
                end
            end
        end
    end

    return {
        text = table.concat(pieces), starts = starts, ends = ends, ordinals = ordinals,
        compact_bounds = compact_bounds, compact_count = compact_count,
        utf16_bounds = utf16_bounds, utf16_count = utf16_count,
    }
end

local function normalize_text(value)
    local raw = tostring(value or ""):gsub("<[^>]+>", "")
    local out, count = {}, 0
    for _, unit in ipairs(split_units(raw)) do
        local decoded = decode_html_unit(unit)
        if not is_ignorable_text(decoded) then
            out[#out + 1] = decoded
            count = count + 1
        end
    end
    return table.concat(out), count
end

local function quote_candidates(row, data)
    local values, seen = {}, {}
    local function add(value)
        local normalized, count = normalize_text(value)
        if count >= 2 and count <= 800 and normalized ~= "" and not seen[normalized] then
            seen[normalized] = true
            values[#values + 1] = normalized
        end
    end

    row = type(row) == "table" and row or {}
    for _, key in ipairs({"markText", "bookmarkText", "rangeText", "abstract", "text", "content"}) do
        add(row[key])
    end
    local reviews = data and data.review_map and data.review_map[range_key(row)] or nil
    for _, review in ipairs(reviews or {}) do add(review.abstract) end
    return values
end

local function locate_quote(index, needle, expected)
    if not index or tostring(index.text or "") == "" or tostring(needle or "") == "" then return nil end
    local best_a, best_b, best_score
    local from = 1
    while true do
        local first, last = index.text:find(needle, from, true)
        if not first then break end
        local a, b = index.starts[first], index.ends[last]
        if a ~= nil and b ~= nil and b > a then
            local compact_a = index.ordinals[first] or a
            local score = math.min(math.abs(a - expected), math.abs(compact_a - expected))
            if best_score == nil or score < best_score then
                best_a, best_b, best_score = a, b, score
            end
        end
        from = first + 1
    end
    return best_a, best_b
end

local function numeric_interval(a, b, visible_count, index)
    -- WeRead ranges are generated by JavaScript and may use UTF-16 offsets.
    -- Mapping through decoded text preserves positions after emoji/non-BMP text.
    local mapped_a = index and index.utf16_bounds and index.utf16_bounds[a]
    local mapped_b = index and index.utf16_bounds and index.utf16_bounds[b]
    if mapped_a ~= nil and mapped_b ~= nil and mapped_b > mapped_a then
        return mapped_a, mapped_b
    end
    a, b = math.max(0, a), math.min(visible_count, b)
    if b > a then return a, b end
end

local function intervals(data, visible_count, index)
    local out, unresolved, unresolved_seen = {}, {}, {}
    local stats = {quote_aligned=0, numeric=0, dropped=0, fallback=0}

    local function unresolved_item(row, reason)
        row = type(row) == "table" and row or {}
        local key = range_key(row)
        local dedupe = key ~= "" and ("range:" .. key) or ("row:" .. tostring(row))
        if unresolved_seen[dedupe] then return end
        unresolved_seen[dedupe] = true
        local quotes = quote_candidates(row, data)
        unresolved[#unresolved + 1] = {
            key=key,
            quote=quotes[1] or "",
            thought=key ~= "" and #(data.review_map[key] or {}) > 0,
            reason=reason,
        }
        stats.dropped = stats.dropped + 1
        stats.fallback = stats.fallback + 1
    end

    for _, row in ipairs(data.underlines or {}) do
        local raw_a, raw_b = parse_range(range_key(row))
        if raw_a then
            local a, b
            for _, quote in ipairs(quote_candidates(row, data)) do
                a, b = locate_quote(index, quote, raw_a)
                if a then break end
            end
            if a then
                stats.quote_aligned = stats.quote_aligned + 1
            else
                a, b = numeric_interval(raw_a, raw_b, visible_count, index)
                stats.numeric = stats.numeric + 1
            end
            if a and b and b > a then
                out[#out + 1] = {
                    a=a, b=b, key=range_key(row), row=row,
                    thought=#(data.review_map[range_key(row)] or {}) > 0,
                }
            else
                unresolved_item(row, "position")
            end
        else
            unresolved_item(row, "range")
        end
    end
    table.sort(out, function(x,y) if x.a==y.a then return x.b<y.b end return x.a<y.a end)
    local clean, cursor = {}, -1
    for _, it in ipairs(out) do
        if it.a >= cursor then
            it.row = nil
            clean[#clean + 1] = it
            cursor = it.b
        else
            unresolved_item(it.row, "overlap")
        end
    end
    return clean, stats, unresolved
end

local function render_text_token(token, marks, data)
    if token.skip or not token.units or #token.units == 0 then return token.raw end
    local out, pos = {}, token.start
    local active, thought_link_open = nil, false
    local function close_active()
        if not active then return end
        out[#out + 1] = "</span>"
        if thought_link_open then out[#out + 1] = "</a>" end
        active = nil
        thought_link_open = false
    end
    for _, unit in ipairs(token.units) do
        local mark
        for _, it in ipairs(marks) do if pos >= it.a and pos < it.b then mark = it; break end end
        if mark ~= active then
            close_active()
            active = mark
            if active then
                -- HTML does not allow links inside links. When an underline overlaps
                -- an existing footnote/noteref link, preserve the underline style but
                -- leave the original link as the only clickable target.
                if active.thought and not token.inside_anchor then
                    local href = Thoughts.href(data.book_id, data.chapter_uid, active.key)
                    out[#out + 1] = '<a class="miu-thought-link" href="' .. href .. '">'
                    thought_link_open = true
                end
                local mark_class = Thoughts.mark_class(active.key)
                local display_class = active.thought and "miu-thought-mark" or "miu-inline-mark"
                out[#out + 1] = '<span class="' .. display_class .. ' ' .. mark_class .. '" data-miu-range="' .. active.key .. '">'
            end
        end
        out[#out + 1] = unit
        pos = pos + 1
        if active and pos >= active.b then close_active() end
    end
    close_active()
    return table.concat(out)
end

local function append_before_body(html, section)
    html, section = tostring(html or ""), tostring(section or "")
    if section == "" then return html end
    local body_end = html:lower():find("</body>", 1, true)
    if body_end then return html:sub(1, body_end - 1) .. section .. html:sub(body_end) end
    return html .. section
end

local function unresolved_section(data, unresolved)
    if type(unresolved) ~= "table" or #unresolved == 0 then return "" end
    local rows = {
        '<section class="miu-unlocated" data-miuread-unlocated="1">',
        '<h2>未定位内容</h2>',
        '<p class="miu-unlocated-note">以下划线未能准确定位到正文，已保留在章节末尾。</p>',
    }
    for _, item in ipairs(unresolved) do
        local text = U.trim(tostring(item.quote or ""))
        if text == "" then text = "一条未能定位的划线" end
        local key = tostring(item.key or "")
        rows[#rows + 1] = '<div class="miu-unlocated-item">'
        if item.thought and key ~= "" then
            local href = Thoughts.href(data.book_id, data.chapter_uid, key)
            rows[#rows + 1] = '<a class="miu-thought-link" href="' .. U.xml(href) .. '"><span class="miu-thought-mark ' .. Thoughts.mark_class(key) .. '" data-miu-range="' .. U.xml(key) .. '">' .. U.xml(text) .. '</span></a>'
        else
            rows[#rows + 1] = '<span class="miu-inline-mark">' .. U.xml(text) .. '</span>'
        end
        rows[#rows + 1] = '</div>'
    end
    rows[#rows + 1] = '</section>'
    return table.concat(rows, "\n")
end

local function inject(html, data)
    local tokens, visible_count = tokenize(html)
    local index = build_text_index(tokens)
    local marks, stats, unresolved = intervals(data, visible_count, index)
    local rendered = tostring(html or "")
    if #marks > 0 then
        local out = {}
        for _, token in ipairs(tokens) do
            if token.kind == "text" then out[#out + 1] = render_text_token(token, marks, data)
            else out[#out + 1] = token.raw end
        end
        rendered = table.concat(out)
    end
    return append_before_body(rendered, unresolved_section(data, unresolved)), stats
end

function Annotations:apply(html, data)
    if not data or data.underline_count == 0 then return html, "", {underlines=0,thoughts=0} end
    local rendered, alignment = inject(html, data)
    logger.info("[MiuRead][Annotations] alignment",
        "book=", tostring(data.book_id or ""), "chapter=", tostring(data.chapter_uid or ""),
        "quote=", tostring(alignment and alignment.quote_aligned or 0),
        "numeric=", tostring(alignment and alignment.numeric or 0),
        "dropped=", tostring(alignment and alignment.dropped or 0),
        "fallback=", tostring(alignment and alignment.fallback or 0))
    return rendered, CSS, {
        underlines=data.underline_count, thoughts=data.thought_count,
        thought_entries=data.thought_entry_count or 0, errors=#(data.errors or {}),
        quote_aligned=alignment and alignment.quote_aligned or 0,
        dropped=alignment and alignment.dropped or 0,
        fallback=alignment and alignment.fallback or 0,
    }
end

local CACHE_UNDERLINE_FIELDS={"range","markRange","bookmarkRange","markText","bookmarkText","rangeText","abstract","text","content"}
local CACHE_REVIEW_FIELDS={"content","abstract","created","author","likes","review_id"}

local function safe_scalar_copy(source,fields)
    local out={}
    source=type(source)=="table" and source or {}
    for _,key in ipairs(fields) do
        local value=rawget(source,key)
        if type(value)=="string" or type(value)=="number" or type(value)=="boolean" then out[key]=value end
    end
    return out
end

local function cached_groups(groups)
    local out={}
    for _,group in ipairs(groups or {}) do
        local key=tostring(group.range or "")
        if key~="" then
            local texts={}
            for _,review in ipairs(group.texts or {}) do
                local item=safe_scalar_copy(review,CACHE_REVIEW_FIELDS)
                if tostring(item.content or "")~="" then texts[#texts+1]=item end
            end
            out[#out+1]={range=key,texts=texts}
        end
    end
    table.sort(out,function(a,b) return tostring(a.range)<tostring(b.range) end)
    return out
end

function Annotations:to_cache(data)
    data=type(data)=="table" and data or {}
    local underlines={}
    for _,row in ipairs(data.underlines or {}) do underlines[#underlines+1]=safe_scalar_copy(row,CACHE_UNDERLINE_FIELDS) end
    return {
        schema=1,book_id=str(data.book_id),chapter_uid=str(data.chapter_uid),underlines=underlines,
        review_groups=cached_groups(data.review_groups),completed_ranges=data.completed_ranges or {},
        pending_ranges=data.pending_ranges or {},underline_request_ok=data.underline_request_ok==true,
        underlines_partial=data.underlines_partial==true,review_complete=data.review_complete==true,
        complete=data.complete==true,error_kind=data.error_kind,
    }
end

function Annotations:from_cache(value)
    value=type(value)=="table" and value or {}
    local groups=cached_groups(value.review_groups)
    local map,group_count,entry_count={},0,0
    for _,group in ipairs(groups) do
        map[group.range]=group.texts
        if #group.texts>0 then group_count=group_count+1; entry_count=entry_count+#group.texts end
    end
    local underlines={}
    for _,row in ipairs(value.underlines or {}) do underlines[#underlines+1]=safe_scalar_copy(row,CACHE_UNDERLINE_FIELDS) end
    return {book_id=str(value.book_id),chapter_uid=str(value.chapter_uid),underlines=underlines,
        review_map=map,review_groups=groups,underline_count=#underlines,thought_count=group_count,
        thought_entry_count=entry_count,errors={},completed_ranges=value.completed_ranges or {},
        pending_ranges=value.pending_ranges or {},underline_request_ok=value.underline_request_ok==true,
        underlines_partial=value.underlines_partial==true,review_complete=value.review_complete==true,
        complete=value.complete==true,error_kind=value.error_kind,
        cached=true}
end

local function merge_review_lists(old_rows,new_rows)
    local out,positions={},{}
    local function add(rows,replace)
        for _,item in ipairs(rows or {}) do
            local key=tostring(item.review_id or "")
            if key=="" then key=tostring(item.content or "").."\0"..tostring(item.author or "") end
            if key~="" then
                local index=positions[key]
                if index and replace then out[index]=item
                elseif not index then positions[key]=#out+1; out[#out+1]=item end
            end
        end
    end
    add(old_rows,false)
    add(new_rows,true)
    table.sort(out,function(a,b)
        local ac,bc=tonumber(a.created or 0) or 0,tonumber(b.created or 0) or 0
        if ac==bc then return tostring(a.review_id or a.content or "")<tostring(b.review_id or b.content or "") end
        return ac<bc
    end)
    return out
end

local function merge_underlines(old_rows,new_rows)
    local out,positions={},{}
    local function add(rows,replace)
        for _,row in ipairs(rows or {}) do
            local key=range_key(row)
            if key~="" then
                local index=positions[key]
                if index and replace then out[index]=row
                elseif not index then positions[key]=#out+1; out[#out+1]=row end
            end
        end
    end
    add(old_rows,false)
    add(new_rows,true)
    return out
end

function Annotations:merge(previous,current)
    previous=type(previous)=="table" and previous or nil
    current=type(current)=="table" and current or {}
    if current.underline_request_ok~=true then
        if previous then
            previous.errors=current.errors or {}
            previous.error_kind=current.error_kind
            previous.auth_required=current.auth_required
            previous.forbidden=current.forbidden
            previous.rate_limited=current.rate_limited
            previous.complete=false
            previous.review_complete=false
            return previous
        end
        current.complete=false
        current.review_complete=false
        return current
    end

    if current.underlines_partial==true and previous then
        current.underlines=merge_underlines(previous.underlines,current.underlines)
    end

    local completed,pending={},{}
    for _,key in ipairs(current.completed_ranges or {}) do completed[tostring(key)]=true end
    for _,key in ipairs(current.pending_ranges or {}) do pending[tostring(key)]=true end
    local old_map=previous and previous.review_map or {}
    local new_map=current.review_map or {}
    local active,groups={},{}
    for _,row in ipairs(current.underlines or {}) do
        local key=range_key(row)
        if key~="" then active[key]=true end
    end
    for key in pairs(active) do
        local texts
        if completed[key] then texts=new_map[key] or {}
        elseif pending[key] then texts=merge_review_lists(old_map[key],new_map[key])
        else texts=merge_review_lists(old_map[key],new_map[key]) end
        groups[#groups+1]={range=key,texts=texts}
    end
    table.sort(groups,function(a,b) return tostring(a.range)<tostring(b.range) end)
    current.review_groups=cached_groups(groups)
    current.review_map={}
    current.thought_count=0
    current.thought_entry_count=0
    for _,group in ipairs(current.review_groups) do
        current.review_map[group.range]=group.texts
        if #group.texts>0 then
            current.thought_count=current.thought_count+1
            current.thought_entry_count=current.thought_entry_count+#group.texts
        end
    end
    current.underline_count=#(current.underlines or {})
    current.review_complete=#(current.pending_ranges or {})==0
    current.complete=current.underline_request_ok and current.underlines_partial~=true and current.review_complete
    return current
end

return Annotations
