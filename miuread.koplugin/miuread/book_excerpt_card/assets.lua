--[[--
卡片资产：墨白横条/竖线图片与静影背景图（只使用随插件打包的资产）。

墨白横条/竖线图片渲染：
墨白模板的横条(icon_line_header/footer/bottom)与竖线(icon_line_left/
middle/right)都是带透明通道的图片 + 主题色染色:源图片 alpha 作蒙版填主题色,
叠在背景上(纯色矩形只是近似)。这里加载插件自带资产,缩放到目标尺寸后
用 colorblitFromRGB32 染色叠加(与 koreader 文本染色同一路径);资产缺失
时回退纯色矩形,保证功能不依赖图片文件。

@module koplugin.miuread.book_excerpt_card.assets
--]]--

local BlitBuffer = require("ffi/blitbuffer")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

-- 插件目录:由本文件所在路径推导(本文件位于 book_excerpt_card/ 下)
-- 匹配 .../book_excerpt_card/assets.lua，插件目录 = book_excerpt_card/ 所在目录，
-- 资产随模块打包于 book_excerpt_card/assets/cards/
local plugin_dir = (debug.getinfo(1, "S").source or ""):match("^@(.*/book_excerpt_card)/assets%.lua$") or ""

local line_raws = {} -- name -> { w, h, data } 原始 RGBA(缓存)
local function getLineRaw(name)
    if line_raws[name] ~= nil then return line_raws[name] end
    -- 用 lodepng 直接解码 RGBA(不依赖 mupdf;RenderImage 的 PNG 路径走 mupdf,
    -- 在无 mupdf 的构建/测试环境会失败)。ffi/png decodeFromFile 用
    -- lodepng_decode,内存由 lodepng malloc,复制进 Lua 字符串后须 free。
    local ok_png, Png = pcall(require, "ffi/png")
    if not (ok_png and Png) then
        line_raws[name] = false
        return nil
    end
    -- koreader ffi/util joinPath 只拼两参,多余参数会被静默丢弃,须单段拼接
    local path = ffiutil.joinPath(plugin_dir, "assets/cards/inkwhite/" .. name .. ".png")
    local ok_dec, _, dec = pcall(Png.decodeFromFile, path, 4)
    if ok_dec and dec and dec.width and dec.height and dec.data then
        local n = dec.width * dec.height * 4
        local data = ffi.string(dec.data, n)
        if ffi.C.free then pcall(ffi.C.free, dec.data) end
        line_raws[name] = { w = dec.width, h = dec.height, data = data }
        return line_raws[name]
    end
    line_raws[name] = false
    return nil
end

local tinted_cache = {} -- name:tint -> 已染色的原尺寸 RGB32 bb(缓存)
-- 画一张主题色染色的横条/竖线图片。染色语义:源图片 alpha 作蒙版,
-- RGB 替换为主题色,alpha 混合叠加(纯色矩形只是近似)。
-- @return true=图片绘制成功;false=资产缺失(调用方应回退纯色矩形)
local function drawLineImage(bb, x, y, name, w, h, tint)
    local raw = getLineRaw(name)
    if not raw then return false end
    if w <= 0 or h <= 0 then return false end
    local key = name .. ":" .. tostring(tint.r) .. "," .. tostring(tint.g) .. "," .. tostring(tint.b)
    local tinted = tinted_cache[key]
    if not tinted then
        -- 逐像素:RGB = tint,alpha = 源 alpha
        local n = raw.w * raw.h
        local tr, tg, tb = tint.r, tint.g, tint.b
        local data = raw.data
        local parts = {}
        for i = 0, n - 1 do
            local o = i * 4
            parts[i + 1] = string.char(tr, tg, tb, data:byte(o + 4))
        end
        tinted = BlitBuffer.fromstring(raw.w, raw.h,
            BlitBuffer.TYPE_BBRGB32, table.concat(parts))
        tinted_cache[key] = tinted
    end
    local scaled = tinted:scale(w, h)
    bb:alphablitFrom(scaled, x, y, 0, 0, w, h)
    scaled:free()
    return true
end

--- 背景图本地路径:只使用随插件打包的资产(assets/cards/stillness/bg_N.jpg,
-- 与墨白 icon_line 同目录约定);缺失返回 nil(渲染回退纯色,见 render.lua)。
local function backgroundImagePath(idx)
    -- koreader ffi/util 的 joinPath 只拼两个参数,多余参数会被静默丢弃
    -- (曾把路径截断成 .../assets 目录,导致头图永远回退),须单段拼接
    local asset = ffiutil.joinPath(plugin_dir,
        "assets/cards/stillness/bg_" .. tostring(idx) .. ".jpg")
    if lfs.attributes(asset) then
        return asset
    end
    logger.warn("miuread: stillness bg asset not bundled: ", asset)
    return nil
end

return {
    drawLineImage = drawLineImage,
    backgroundImagePath = backgroundImagePath,
}
