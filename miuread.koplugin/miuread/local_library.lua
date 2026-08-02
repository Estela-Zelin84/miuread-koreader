local lfs = require("libs/libkoreader-lfs")

local LocalLibrary = {}

local SUPPORTED = {
    epub=true, pdf=true, mobi=true, azw=true, azw3=true, fb2=true,
    txt=true, html=true, htm=true, rtf=true,
    cbz=true, cbr=true, cb7=true, djvu=true, xps=true, oxps=true,
    md=true, chm=true,
}

local SKIP_DIRS = {
    ["."]=true, [".."]=true, [".sdr"]=true, [".git"]=true,
    ["koreader"]=true, ["plugins"]=true, ["extensions"]=true,
    ["system"]=true, ["linkss"]=true, ["fonts"]=true,
    ["screensaver"]=true, ["screensavers"]=true, ["thumbnails"]=true,
    ["cache"]=true, ["tmp"]=true,
}

local function basename(path)
    return tostring(path or ""):match("([^/]+)$") or tostring(path or "")
end

local function dirname(path)
    return tostring(path or ""):match("^(.*)/[^/]+$") or ""
end

local function stem(path)
    local name=basename(path)
    return (name:gsub("%.[^%.]+$",""))
end

local function extension(path)
    return (tostring(path or ""):match("%.([%w]+)$") or ""):lower()
end

local function exists(path)
    return path and lfs.attributes(path,"mode")=="file"
end

local function cover_path(path)
    local dir=dirname(path)
    local base=stem(path)
    local candidates={
        dir.."/"..base..".sdr/cover.jpg",
        dir.."/"..base..".sdr/cover.jpeg",
        dir.."/"..base..".sdr/cover.png",
        path..".sdr/cover.jpg",
        path..".sdr/cover.jpeg",
        path..".sdr/cover.png",
        dir.."/"..base..".jpg",
        dir.."/"..base..".jpeg",
        dir.."/"..base..".png",
    }
    for _,candidate in ipairs(candidates) do
        if exists(candidate) then return candidate end
    end
    return nil
end

local function title_from_path(path)
    local title=stem(path)
    title=title:gsub("[_%-]+"," "):gsub("%s+"," ")
    title=title:gsub("^%s+",""):gsub("%s+$","")
    return title~="" and title or "未命名"
end

local function should_skip_dir(name, full, root)
    local lower=tostring(name or ""):lower()
    if lower:sub(1,1)=="." then return true end
    if SKIP_DIRS[lower] then return true end
    if lower:match("%.sdr$") then return true end
    -- When the KOReader home is /mnt/us, avoid descending into its runtime
    -- and support directories. User book folders remain visible.
    if root=="/mnt/us" and (lower=="kmc" or lower=="documents/.sdr") then return true end
    return false
end


local function normalized_path(path)
    return tostring(path or ""):gsub("\\","/"):gsub("/+","/"):lower()
end

function LocalLibrary.is_likely_dictionary(path, title)
    local normalized=normalized_path(path)
    local ext=extension(path)
    if normalized:find("/dictionaries/",1,true) or normalized:find("/dictionary/",1,true)
        or normalized:find("/dict/",1,true) or normalized:find("/system/dictionaries/",1,true) then
        return true
    end
    -- Kindle dictionaries are commonly AZW/MOBI files placed among ordinary
    -- downloads. Restrict name-based filtering to those container formats so
    -- a normal EPUB whose title mentions a dictionary is not hidden by mistake.
    if ext=="azw" or ext=="azw3" or ext=="mobi" then
        local name=(tostring(title or "").." "..basename(path)):lower()
        for _,token in ipairs({"词典","字典","辞典","dictionary","thesaurus","lexicon"}) do
            if name:find(token,1,true) then return true end
        end
    end
    return false
end

function LocalLibrary.is_supported(path)
    return SUPPORTED[extension(path)]==true
end

function LocalLibrary.scan(root, options)
    options=options or {}
    root=tostring(root or "")
    local limit=math.max(1,tonumber(options.limit) or 800)
    local max_depth=math.max(0,tonumber(options.max_depth) or 8)
    local rows={}
    local visited={}
    local stopped=false

    local function walk(dir,depth)
        if stopped or depth>max_depth or visited[dir] then return end
        visited[dir]=true
        local ok,iter,state,var=pcall(lfs.dir,dir)
        if not ok or not iter then return end
        while true do
            local name=iter(state,var)
            var=name
            if not name then break end
            if name~="." and name~=".." then
                local full=(dir=="/" and "/"..name or dir.."/"..name)
                local attr=lfs.attributes(full)
                if attr and attr.mode=="directory" then
                    if not should_skip_dir(name,full,root) then walk(full,depth+1) end
                elseif attr and attr.mode=="file" and LocalLibrary.is_supported(full) then
                    local title=title_from_path(full)
                    if options.include_dictionaries==true or not LocalLibrary.is_likely_dictionary(full,title) then
                    rows[#rows+1]={
                        file=full,
                        title=title,
                        author="",
                        format=extension(full):upper(),
                        size=tonumber(attr.size) or 0,
                        modified_at=tonumber(attr.modification) or 0,
                        cover_path=cover_path(full),
                    }
                    if #rows>=limit then stopped=true; break end
                    end
                end
            end
        end
    end

    if lfs.attributes(root,"mode")=="directory" then walk(root,0) end
    table.sort(rows,function(a,b)
        local am,bm=tonumber(a.modified_at) or 0,tonumber(b.modified_at) or 0
        if am~=bm then return am>bm end
        return tostring(a.title or ""):lower()<tostring(b.title or ""):lower()
    end)
    return {root=root,scanned_at=os.time(),books=rows,truncated=stopped==true}
end

return LocalLibrary
