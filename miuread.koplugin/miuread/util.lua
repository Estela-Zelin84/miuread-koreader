local lfs = require("libs/libkoreader-lfs")
local U = {}
function U.copy(v, seen)
    if type(v) ~= "table" then return v end
    seen=seen or {}; if seen[v] then return seen[v] end
    local o={}; seen[v]=o; for k,x in pairs(v) do o[U.copy(k,seen)]=U.copy(x,seen) end; return o
end
function U.merge(a,b)
    local o=U.copy(a or {}); for k,v in pairs(b or {}) do if type(v)=="table" and type(o[k])=="table" then o[k]=U.merge(o[k],v) else o[k]=U.copy(v) end end; return o
end
function U.trim(s) return (tostring(s or ""):gsub("^%s+",""):gsub("%s+$","")) end
local function utf8_sequence_length(first)
    if not first then return 0 end
    if first < 0x80 then return 1 end
    if first >= 0xC2 and first <= 0xDF then return 2 end
    if first >= 0xE0 and first <= 0xEF then return 3 end
    if first >= 0xF0 and first <= 0xF4 then return 4 end
    return 0
end
local function utf8_char_end(value,index)
    local first=value:byte(index)
    local length=utf8_sequence_length(first)
    if length==0 then return index,false end
    if length==1 then return index,true end
    if index+length-1>#value then return index,false end
    local second=value:byte(index+1)
    if not second or second<0x80 or second>0xBF then return index,false end
    if length>=3 then
        if first==0xE0 and second<0xA0 then return index,false end
        if first==0xED and second>0x9F then return index,false end
        local third=value:byte(index+2)
        if not third or third<0x80 or third>0xBF then return index,false end
    end
    if length==4 then
        if first==0xF0 and second<0x90 then return index,false end
        if first==0xF4 and second>0x8F then return index,false end
        local fourth=value:byte(index+3)
        if not fourth or fourth<0x80 or fourth>0xBF then return index,false end
    end
    return index+length-1,true
end
function U.is_valid_utf8(value)
    value=tostring(value or "")
    local index=1
    while index<=#value do
        local ending,valid=utf8_char_end(value,index)
        if not valid then return false,index end
        index=ending+1
    end
    return true
end
function U.utf8_len(value)
    value=tostring(value or "")
    local index,count=1,0
    while index<=#value do
        local ending=utf8_char_end(value,index)
        index=ending+1
        count=count+1
    end
    return count
end
function U.utf8_sub(value,first,last)
    value=tostring(value or "")
    first=math.floor(tonumber(first) or 1)
    last=last==nil and math.huge or math.floor(tonumber(last) or 0)
    if first<1 then first=1 end
    if last<first or value=="" then return "" end
    local index,count,start_byte,end_byte=1,0,nil,nil
    while index<=#value do
        count=count+1
        local ending=utf8_char_end(value,index)
        if count==first then start_byte=index end
        if count<=last then end_byte=ending end
        if count>=last then break end
        index=ending+1
    end
    if not start_byte then return "" end
    return value:sub(start_byte,end_byte or #value)
end
function U.utf8_truncate(value,max_chars,ellipsis)
    value=tostring(value or "")
    max_chars=math.max(0,math.floor(tonumber(max_chars) or 0))
    ellipsis=ellipsis==nil and "…" or tostring(ellipsis)
    if max_chars==0 then return value=="" and "" or ellipsis end
    local index,count,last_end=1,0,0
    while index<=#value and count<max_chars do
        local ending=utf8_char_end(value,index)
        count=count+1
        last_end=ending
        index=ending+1
    end
    if index>#value then return value end
    return value:sub(1,last_end)..ellipsis
end
function U.contains_replacement_char(value)
    return tostring(value or ""):find("\239\191\189",1,true)~=nil
end
function U.replacement_char_count(value)
    local text=tostring(value or "")
    local _,count=text:gsub("\239\191\189","")
    return count
end
function U.first_line(s,n) local v=tostring(s or ""):match("^[^\r\n]*") or ""; return U.utf8_truncate(v,n or 240) end
function U.safe_name(s,f) local v=U.trim(tostring(s or ""):gsub("[%z%c/\\:%*%?\"<>|]","_")):gsub("%s+"," "); return v~="" and v or (f or "item") end
function U.id_name(s) local v=tostring(s or ""):gsub("[^%w%._%-]","_"); return v~="" and v or "unknown" end
function U.xml(s) return (tostring(s or ""):gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;"):gsub('"',"&quot;"):gsub("'","&apos;")) end
function U.url_decode(s) return (tostring(s or ""):gsub("+"," "):gsub("%%(%x%x)",function(h) return string.char(tonumber(h,16)) end)) end
function U.file_exists(p) local f=io.open(p,"rb"); if not f then return false end f:close(); return true end
function U.read_file(p,b) local f,e=io.open(p,b and "rb" or "r"); if not f then return nil,e end local d=f:read("*a"); f:close(); return d end
function U.file_size(p) local f=io.open(p,"rb"); if not f then return nil end local n=f:seek("end"); f:close(); return n end
function U.mkdir(p)
    if not p or p=="" then return false end
    if lfs.attributes(p,"mode")=="directory" then return true end
    local parent=p:match("^(.*)/[^/]+$"); if parent and parent~="" and parent~=p then U.mkdir(parent) end
    local ok=lfs.mkdir(p); return ok or lfs.attributes(p,"mode")=="directory"
end
function U.atomic_write(p,d,b)
    local parent=p:match("^(.*)/[^/]+$"); if parent then U.mkdir(parent) end
    local t=p..".tmp-"..tostring(os.time()).."-"..tostring(math.random(1000,9999)); local f,e=io.open(t,b and "wb" or "w"); if not f then return nil,e end
    local ok,er=f:write(d or ""); f:flush(); f:close(); if not ok then os.remove(t); return nil,er end
    os.remove(p); local r,re=os.rename(t,p); if not r then os.remove(t); return nil,re end; return true
end
function U.remove_tree(p)
    p=tostring(p or "")
    if p=="" then return true end
    local mode
    if type(lfs.symlinkattributes)=="function" then mode=lfs.symlinkattributes(p,"mode") end
    if not mode then mode=lfs.attributes(p,"mode") end
    if mode=="file" or mode=="link" then
        local ok,err=os.remove(p)
        if ok or not lfs.attributes(p,"mode") then return true end
        return nil,err
    end
    if mode~="directory" then return true end
    local ok,iter,state=pcall(lfs.dir,p)
    if not ok or type(iter)~="function" then return nil,tostring(iter or state or "无法读取目录") end
    for x in iter,state do
        if x~="." and x~=".." then
            local removed,err=U.remove_tree(p.."/"..x)
            if not removed then return nil,err end
        end
    end
    local removed,err=lfs.rmdir(p)
    if removed or lfs.attributes(p,"mode")~="directory" then return true end
    return nil,err
end
function U.list(p)
    local o={}; if lfs.attributes(p,"mode")~="directory" then return o end
    for x in lfs.dir(p) do if x~="." and x~=".." then o[#o+1]=p.."/"..x end end; table.sort(o); return o
end
function U.copy_file_stream(a,b,chunk_size)
    local input,open_error=io.open(a,"rb")
    if not input then return nil,open_error end
    local output,write_open_error=io.open(b,"wb")
    if not output then input:close(); return nil,write_open_error end
    local ok,err=true,nil
    local chunk=math.max(64*1024,tonumber(chunk_size) or 256*1024)
    while true do
        local data=input:read(chunk)
        if not data then break end
        local written,write_error=output:write(data)
        if not written then ok=false; err=write_error; break end
    end
    if ok then
        local flushed,flush_error=output:flush()
        if flushed==nil then ok=false; err=flush_error end
    end
    input:close(); output:close()
    if not ok then os.remove(b); return nil,err or "copy failed" end
    local source_size,target_size=U.file_size(a),U.file_size(b)
    if source_size and target_size~=source_size then
        os.remove(b)
        return nil,"copied file size mismatch"
    end
    return true
end
function U.move_file_safe(source,target,validator)
    source=tostring(source or "")
    target=tostring(target or "")
    if source=="" or target=="" then return nil,"invalid path" end
    local moved,move_error=os.rename(source,target)
    if moved then return true,"rename" end
    local stage=target..".miuread-copying-"..tostring(os.time()).."-"..tostring(math.random(1000,9999))
    os.remove(stage)
    local copied,copy_error=U.copy_file_stream(source,stage)
    if not copied then return nil,"rename failed: "..tostring(move_error).."; copy failed: "..tostring(copy_error) end
    if validator then
        local called,valid,validation_error=pcall(validator,stage)
        if not called or valid~=true then
            os.remove(stage)
            return nil,"copied file validation failed: "..tostring(called and validation_error or valid)
        end
    end
    local target_exists=U.file_exists(target)
    local old_backup=target..".miuread-old-"..tostring(os.time()).."-"..tostring(math.random(1000,9999))
    if target_exists then
        os.remove(old_backup)
        local backed_up,backup_error=os.rename(target,old_backup)
        if not backed_up then
            os.remove(stage)
            return nil,"existing target backup failed: "..tostring(backup_error)
        end
    end
    local installed,install_error=os.rename(stage,target)
    if not installed then
        if target_exists then os.rename(old_backup,target) end
        os.remove(stage)
        return nil,"copied file install failed: "..tostring(install_error)
    end
    if target_exists then os.remove(old_backup) end
    os.remove(source)
    return true,"copy"
end
function U.copy_file(a,b) local d,e=U.read_file(a,true); if not d then return nil,e end return U.atomic_write(b,d,true) end
function U.copy_tree(a,b)
    local m=lfs.attributes(a,"mode"); if m=="file" then return U.copy_file(a,b) end; if m~="directory" then return nil,"source missing" end
    U.mkdir(b); for x in lfs.dir(a) do if x~="." and x~=".." then local ok,e=U.copy_tree(a.."/"..x,b.."/"..x); if not ok then return nil,e end end end; return true
end
function U.extract_balanced_json(text,marker)
    local p=text:find(marker,1,true); if not p then return nil end; p=text:find("{",p,true); if not p then return nil end
    local depth,quote,esc=0,false,false; for i=p,#text do local c=text:sub(i,i); if quote then if esc then esc=false elseif c=="\\" then esc=true elseif c=='"' then quote=false end else if c=='"' then quote=true elseif c=="{" then depth=depth+1 elseif c=="}" then depth=depth-1; if depth==0 then return text:sub(p,i) end end end end
end
function U.clamp(v,a,b) v=tonumber(v) or a; if v<a then return a elseif v>b then return b end return v end
function U.percent(n,d) d=tonumber(d) or 0; if d<=0 then return 0 end return math.floor(U.clamp((tonumber(n) or 0)*100/d,0,100)+.5) end
function U.now_text(t) t=tonumber(t) or 0; return t>0 and os.date("%Y-%m-%d %H:%M:%S",t) or "—" end
function U.shell_quote(s) return "'"..tostring(s):gsub("'","'\\''").."'" end
local function semver_parse(value)
    local major, minor, patch, pre = tostring(value or ""):match("^v?(%d+)%.(%d+)%.(%d+)(.*)$")
    if not major then return nil end
    local out={major=tonumber(major),minor=tonumber(minor),patch=tonumber(patch),pre={}}
    pre=tostring(pre or ""):gsub("^[%-+]","")
    if pre~="" then
        pre=pre:match("^[^+]+") or pre
        for part in pre:gmatch("[^%.]+") do
            local number=part:match("^%d+$") and tonumber(part) or nil
            out.pre[#out.pre+1]=number or tostring(part):lower()
        end
    end
    return out
end
function U.semver_compare(a,b)
    local x,y=semver_parse(a),semver_parse(b)
    if not x or not y then return tostring(a)==tostring(b) and 0 or (tostring(a)>tostring(b) and 1 or -1) end
    for _,key in ipairs({"major","minor","patch"}) do
        if x[key]~=y[key] then return x[key]>y[key] and 1 or -1 end
    end
    if #x.pre==0 and #y.pre==0 then return 0 end
    if #x.pre==0 then return 1 end
    if #y.pre==0 then return -1 end
    for index=1,math.max(#x.pre,#y.pre) do
        local p,q=x.pre[index],y.pre[index]
        if p==nil then return -1 end
        if q==nil then return 1 end
        if p~=q then
            if type(p)=="number" and type(q)=="number" then return p>q and 1 or -1 end
            if type(p)=="number" then return -1 end
            if type(q)=="number" then return 1 end
            return tostring(p)>tostring(q) and 1 or -1
        end
    end
    return 0
end
function U.semver_newer(a,b) return U.semver_compare(a,b)>0 end
return U
