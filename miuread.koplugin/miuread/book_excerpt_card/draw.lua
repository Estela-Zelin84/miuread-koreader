--[[--
绘制原语：颜色解析 / 混合 / 渐变填充 / 二维码 / 锦书装饰线。

@module koplugin.miuread.book_excerpt_card.draw
--]]--

local Config = require("miuread.book_excerpt_card.config")
local BlitBuffer = require("ffi/blitbuffer")
local logger = require("logger")

local ds = Config.ds

-- ---------------------------------------------------------------------------
-- 颜色工具
-- ---------------------------------------------------------------------------

--- "RRGGBB" → BlitBuffer.ColorRGB32
local function hexToColor(hex, alpha)
    alpha = alpha or 0xFF
    local r = tonumber(hex:sub(1, 2), 16) or 0
    local g = tonumber(hex:sub(3, 4), 16) or 0
    local b = tonumber(hex:sub(5, 6), 16) or 0
    return BlitBuffer.ColorRGB32(r, g, b, alpha)
end

--- fg 与 bg 按 ratio 混合（分隔线 / 弱化元素用）。
local function mixColor(fg_hex, bg_hex, ratio)
    local function ch(hex, i)
        return tonumber(hex:sub(i, i + 1), 16) or 0
    end
    local r = math.floor(ch(fg_hex, 1) * ratio + ch(bg_hex, 1) * (1 - ratio))
    local g = math.floor(ch(fg_hex, 3) * ratio + ch(bg_hex, 3) * (1 - ratio))
    local b = math.floor(ch(fg_hex, 5) * ratio + ch(bg_hex, 5) * (1 - ratio))
    return BlitBuffer.ColorRGB32(r, g, b, 0xFF)
end

--- 垂直渐变填充(逐行插值，RGB32)。
local function drawVGradient(bb, x, y, w, h, c1, c2)
    if h <= 0 or w <= 0 then return end
    if h == 1 then
        bb:paintRectRGB32(x, y, w, 1, c1)
        return
    end
    local r1, g1, b1 = c1.r, c1.g, c1.b
    local r2, g2, b2 = c2.r, c2.g, c2.b
    for i = 0, h - 1 do
        local t = i / (h - 1)
        bb:paintRectRGB32(x, y + i, w, 1, BlitBuffer.ColorRGB32(
            math.floor(r1 + (r2 - r1) * t),
            math.floor(g1 + (g2 - g1) * t),
            math.floor(b1 + (b2 - b1) * t), 0xFF))
    end
end

--- 对角线渐变填充(start{0,0}→end{1,1}):
--- t = (px*w + py*h)/(w²+h²) — 线性渐变像素投影。
--- 注意:在高卡片(375×~890)上投影主要沿 y(垂直),水平分量很弱;
--- 之前的 (px/w+py/h)/2 归一化公式水平分量过强,导致左右偏色。
local function drawVGradientDiag(bb, x, y, w, h, c1, c2)
    if h <= 0 or w <= 0 then return end
    if w == 1 and h == 1 then
        bb:paintRectRGB32(x, y, 1, 1, c1)
        return
    end
    local r1, g1, b1 = c1.r, c1.g, c1.b
    local r2, g2, b2 = c2.r, c2.g, c2.b
    local dr, dg, db = r2 - r1, g2 - g1, b2 - b1
    local denom = w * w + h * h
    local inv_denom = 1 / denom
    for py = 0, h - 1 do
        -- 行内水平渐变:左端 t = py*h/denom,右端 t = (w² + py*h)/denom
        local t0 = py * h * inv_denom
        local r0, g0, b0 = r1 + dr * t0, g1 + dg * t0, b1 + db * t0
        local rstep, gstep, bstep = dr * w * inv_denom, dg * w * inv_denom, db * w * inv_denom
        for px = 0, w - 1 do
            bb:paintRectRGB32(x + px, y + py, 1, 1, BlitBuffer.ColorRGB32(
                math.floor(r0 + rstep * px + 0.5),
                math.floor(g0 + gstep * px + 0.5),
                math.floor(b0 + bstep * px + 0.5), 0xFF))
        end
    end
end

-- ---------------------------------------------------------------------------
-- 二维码（ffi/qrencode = luaqrcode，纯 Lua；返回 (true, matrix)，matrix[x][y]>0 为深色）
-- 注意 luaqrcode 的 ec_level 是数字 1-4（1=L 级默认），传字符串会报错。
-- ---------------------------------------------------------------------------

local function drawQR(bb, x, y, size, url, fg_color, bg_color)
    local ok_lib, qrcode_lib = pcall(require, "ffi/qrencode")
    if not ok_lib or type(qrcode_lib) ~= "table" or type(qrcode_lib.qrcode) ~= "function" then
        logger.warn("miuread: ffi/qrencode unavailable, skip QR")
        return false
    end
    local ok, matrix = qrcode_lib.qrcode(url, 1)
    if not ok or type(matrix) ~= "table" or #matrix < 21 then
        logger.warn("miuread: qrcode encode failed")
        return false
    end
    local n = #matrix
    local quiet = math.max(1, math.floor(size / 24))       -- quiet zone
    local inner = size - 2 * quiet
    local module = math.max(1, math.floor(inner / n))
    local used = module * n
    local off = quiet + math.max(0, math.floor((inner - used) / 2))
    bb:paintRectRGB32(x, y, size, size, bg_color)
    for xm = 1, n do
        local row = matrix[xm]
        if type(row) == "table" then
            for ym = 1, n do
                if row[ym] and row[ym] > 0 then
                    bb:paintRectRGB32(
                        x + off + (xm - 1) * module,
                        y + off + (ym - 1) * module,
                        module, module, fg_color)
                end
            end
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- 模板装饰（锦书装饰线）
-- ---------------------------------------------------------------------------

--- 锦书：页眉装饰分隔线（两侧线段 + 中央方块）。
local function drawOrnateDivider(bb, x, y, width, color)
    local h = ds(3)
    local mid_w = ds(20)
    local side_w = math.max(0, math.floor((width - mid_w) / 2))
    bb:paintRectRGB32(x, y, side_w, h, color)
    bb:paintRectRGB32(x + side_w + mid_w, y, side_w, h, color)
    bb:paintRectRGB32(x + side_w + math.floor((mid_w - h) / 2), y, h, h, color)
end

return {
    hexToColor = hexToColor,
    mixColor = mixColor,
    drawVGradient = drawVGradient,
    drawVGradientDiag = drawVGradientDiag,
    drawQR = drawQR,
    drawOrnateDivider = drawOrnateDivider,
}
