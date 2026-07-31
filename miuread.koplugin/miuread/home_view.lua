local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local GestureBridge = require("miuread.gesture_bridge")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local U = require("miuread.util")

local Screen = Device.screen
local live_widget

local function face(name, nominal, maximum)
    return Font:getFace(name, math.min(maximum or nominal, Screen:scaleBySize(nominal)))
end

local OffsetContainer = WidgetContainer:extend{x_off = 0, y_off = 0}
function OffsetContainer:getSize() return self[1]:getSize() end
function OffsetContainer:paintTo(bb, x, y)
    self[1]:paintTo(bb, x + self.x_off, y + self.y_off)
end

local function fixed_frame(width, height, options, content)
    options = options or {}
    local border = tonumber(options.bordersize) or 0
    local padding = tonumber(options.padding) or 0
    local margin = tonumber(options.margin) or 0
    local inset = border + padding + margin
    return FrameContainer:new{
        bordersize = border,
        radius = options.radius or 0,
        padding = padding,
        margin = margin,
        background = options.background,
        color = options.color or Blitbuffer.COLOR_BLACK,
        CenterContainer:new{
            dimen = Geom:new{
                w = math.max(1, width - inset * 2),
                h = math.max(1, height - inset * 2),
            },
            content or Widget:new{dimen = Geom:new{w = 1, h = 1}},
        },
    }
end

local function background(width, height)
    return fixed_frame(width, height, {background = Blitbuffer.COLOR_WHITE})
end

local TapBox = InputContainer:extend{dimen = nil, callback = nil}
function TapBox:init()
    self.dimen = self.dimen or Geom:new{w = 1, h = 1}
    self.ges_events = {
        TapSelect = {GestureRange:new{ges = "tap", range = self.dimen}},
    }
end
function TapBox:getSize() return Geom:new{w = self.dimen.w, h = self.dimen.h} end
function TapBox:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    if self[1] then self[1]:paintTo(bb, x, y) end
end
function TapBox:onTapSelect()
    if self.callback then self.callback() end
    return true
end
function TapBox:handleEvent(event)
    -- Child cards only own taps. Let swipes reach HomeWidget first so the
    -- quick panel and shelf paging are not consumed by KOReader underneath.
    return InputContainer.handleEvent(self, event)
end

local function tappable(width, height, child, callback)
    local tap = TapBox:new{
        dimen = Geom:new{w = width, h = height},
        callback = callback,
    }
    tap[1] = CenterContainer:new{dimen = Geom:new{w = width, h = height}, child}
    return tap
end

local function text_button(text, width, height, callback, options)
    options = options or {}
    return tappable(width, height, fixed_frame(width, height, {
        bordersize = options.borderless and 0 or Size.border.thin,
        padding = math.max(3, Screen:scaleBySize(3)),
        background = Blitbuffer.COLOR_WHITE,
    }, TextWidget:new{
        text = tostring(text or ""),
        face = face(options.font or "smallinfofont", options.size or 11, options.maximum or 15),
        bold = options.bold ~= false,
        fgcolor = options.fgcolor or Blitbuffer.COLOR_DARK_GRAY,
    }), callback)
end

local function image_widget(path, width, height)
    if not path or path == "" then return nil end
    local image
    local ok = pcall(function()
        image = ImageWidget:new{
            file = path,
            width = width,
            height = height,
            scale_factor = 0,
            file_do_cache = true,
        }
        image:getSize()
        -- ImageWidget reports the requested box when width/height are set.
        -- Clear them after rendering so CenterContainer can center the actual
        -- aspect-preserving bitmap inside the cover box.
        image.width = nil
        image.height = nil
    end)
    if ok and image then
        return CenterContainer:new{dimen = Geom:new{w = width, h = height}, image}
    end
    if image and image.free then pcall(image.free, image) end
    return nil
end

local function placeholder(width, height, title)
    local mark = U.utf8_sub(tostring(title or "书"):gsub("^%s+", ""), 1, 1)
    if mark == "" then mark = "书" end
    return fixed_frame(width, height, {
        bordersize = Size.border.thin,
        background = Blitbuffer.COLOR_WHITE,
    }, TextWidget:new{text = mark, face = face("cfont", 18, 22), bold = true})
end

local function solid_bar(width, height, color)
    return fixed_frame(width, height, {background = color or Blitbuffer.COLOR_BLACK})
end

local function progress_bar(width, height, progress)
    progress = math.max(0, math.min(1, tonumber(progress) or 0))
    local filled = math.floor(width * progress + .5)
    local rest = math.max(0, width - filled)
    local row = HorizontalGroup:new{align = "center"}
    if filled > 0 then table.insert(row, solid_bar(filled, height, Blitbuffer.COLOR_BLACK)) end
    if rest > 0 then table.insert(row, solid_bar(rest, height, Blitbuffer.COLOR_GRAY)) end
    return row
end

local function section_header(title, width, height, on_more)
    local right_w = on_more and math.max(76, math.floor(width * .18)) or 0
    local left_w = width - right_w
    local row = HorizontalGroup:new{
        align = "center",
        LeftContainer:new{dimen = Geom:new{w = left_w, h = height}, TextWidget:new{
            text = tostring(title or ""),
            face = face("cfont", 16, 19),
            bold = true,
        }},
    }
    if on_more then
        table.insert(row, text_button("全部 ›", right_w, height, on_more, {
            borderless = true,
            size = 11,
            maximum = 14,
        }))
    end
    return row
end

local function notice_strip(item, width, height)
    local pad = math.max(7, Screen:scaleBySize(6))
    local progress_w = item.progress and math.max(92, math.floor(width * .20)) or 0
    local detail_w = math.max(1, width - progress_w - pad * 3)
    local text = tostring(item.title or "")
    if item.detail and tostring(item.detail) ~= "" then
        text = text .. "　" .. tostring(item.detail)
    end
    local row = HorizontalGroup:new{
        align = "center",
        LeftContainer:new{dimen = Geom:new{w = detail_w, h = height - pad * 2}, TextBoxWidget:new{
            text = text,
            face = face("smallinfofont", 11, 14),
            bold = item.important == true,
            width = detail_w,
            height = height - pad * 2,
            height_adjust = false,
            height_overflow_show_ellipsis = true,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }},
    }
    if progress_w > 0 then
        table.insert(row, HorizontalSpan:new{width = pad})
        table.insert(row, progress_bar(progress_w, math.max(3, Screen:scaleBySize(3)), item.progress))
    end
    return tappable(width, height, fixed_frame(width, height, {
        bordersize = item.important == true and Size.border.thick or Size.border.thin,
        padding = pad,
        background = Blitbuffer.COLOR_WHITE,
    }, row), item.on_tap)
end

local function hero_card(book, width, height, callback, compact)
    local pad = math.max(9, math.min(15, math.floor(math.min(width, height) * .042)))
    local inner_w = math.max(1, width - pad * 2)
    local inner_h = math.max(1, height - pad * 2)
    -- Keep the cover clearly visible without sacrificing the much more useful
    -- metadata column on the right.
    local cover_w = math.max(58, math.min(
        math.floor(inner_w * (compact and .17 or .19)),
        math.floor(inner_h * .62)
    ))
    local cover_h = math.max(84, math.min(inner_h, math.floor(cover_w / .68)))
    local cover = image_widget(book.cover_path, cover_w, cover_h) or placeholder(cover_w, cover_h, book.title)
    local gap = math.max(12, math.floor(width * .020))
    local text_w = math.max(1, inner_w - cover_w - gap)
    local heading_h = math.max(17, math.floor(inner_h * .08))
    local title_h = math.max(42, math.floor(inner_h * (compact and .25 or .27)))
    local line_h = math.max(21, math.floor(inner_h * .12))
    local progress_value = math.max(0, math.min(100, tonumber(book.progress) or 0))
    local progress_text = progress_value > 0
        and ("阅读至 " .. tostring(math.floor(progress_value + .5)) .. "%")
        or "尚未开始"
    if book.last_read_text and tostring(book.last_read_text) ~= "" then
        progress_text = progress_text .. " · " .. tostring(book.last_read_text)
    end

    local function unique_parts(values, used)
        local out = {}
        used = used or {}
        for _, value in ipairs(values or {}) do
            value = U.trim(tostring(value or ""))
            if value ~= "" and not used[value] then
                used[value] = true
                out[#out + 1] = value
            end
        end
        return out, used
    end

    local meta_parts, used = unique_parts({book.author, book.category, book.translator})
    local bibliographic = {book.publisher, book.series}
    local words = tonumber(book.wordCount or book.word_count)
    if words and words > 0 then
        bibliographic[#bibliographic + 1] = words >= 10000
            and (tostring(math.floor(words / 10000 + .5)) .. "万字")
            or (tostring(math.floor(words + .5)) .. "字")
    elseif tonumber(book.pages) and tonumber(book.pages) > 0 then
        bibliographic[#bibliographic + 1] = tostring(math.floor(tonumber(book.pages) + .5)) .. "页"
    end
    local format = U.trim(tostring(book.format or "")):upper()
    if format ~= "" then bibliographic[#bibliographic + 1] = format end
    local detail_parts
    detail_parts, used = unique_parts(bibliographic, used)
    local source_parts = unique_parts({book.source_text, book.status_text, book.edition_text, book.language}, used)

    local text = VerticalGroup:new{align = "left"}
    table.insert(text, TextBoxWidget:new{
        text = tostring(book.heading or "最近阅读"),
        face = face("smallinfofont", 10, 12),
        bold = true,
        width = text_w,
        height = heading_h,
        height_adjust = false,
        height_overflow_show_ellipsis = true,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    })
    table.insert(text, TextBoxWidget:new{
        text = tostring(book.title or "未命名"),
        face = face("cfont", compact and 15 or 17, compact and 18 or 21),
        bold = true,
        width = text_w,
        height = title_h,
        height_adjust = false,
        height_overflow_show_ellipsis = true,
    })
    for _, row in ipairs({meta_parts, detail_parts, source_parts}) do
        table.insert(text, TextBoxWidget:new{
            text = table.concat(row or {}, " · "),
            face = face("smallinfofont", 10, 12),
            width = text_w,
            height = line_h,
            height_adjust = false,
            height_overflow_show_ellipsis = true,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        })
    end
    table.insert(text, TextBoxWidget:new{
        text = progress_text,
        face = face("smallinfofont", 11, 13),
        width = text_w,
        height = line_h,
        height_adjust = false,
        height_overflow_show_ellipsis = true,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    })
    local used_h = heading_h + title_h + line_h * 4
    if used_h < inner_h then table.insert(text, Widget:new{dimen = Geom:new{w = 1, h = inner_h - used_h}}) end

    local content = fixed_frame(width, height, {
        bordersize = 0,
        padding = pad,
        background = Blitbuffer.COLOR_WHITE,
    }, HorizontalGroup:new{
        align = "center",
        cover,
        HorizontalSpan:new{width = gap},
        text,
    })
    local layered = OverlapGroup:new{dimen = Geom:new{w = width, h = height}, allow_mirroring = false}
    layered[#layered + 1] = content
    layered[#layered + 1] = OffsetContainer:new{
        x_off = 0,
        y_off = math.max(0, height - Size.line.thin),
        LineWidget:new{background = Blitbuffer.COLOR_GRAY, dimen = Geom:new{w = width, h = Size.line.thin}},
    }
    return tappable(width, height, layered, callback)
end

local function welcome_card(width, height, callback)
    return tappable(width, height, fixed_frame(width, height, {
        bordersize = Size.border.thin,
        background = Blitbuffer.COLOR_WHITE,
    }, VerticalGroup:new{
        align = "center",
        TextWidget:new{text = "开始阅读", face = face("cfont", 18, 22), bold = true},
        VerticalSpan:new{height = 7},
        TextWidget:new{
            text = "从微信书架选择一本书",
            face = face("smallinfofont", 12, 14),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        },
    }), callback)
end

local function shelf_book_card(book, width, height, callback)
    local pad = math.max(3, math.floor(width * .022))
    local inner_w = math.max(1, width - pad * 2)
    local title_h = math.max(28, math.min(40, math.floor(height * .16)))
    local status_h = math.max(16, math.min(22, math.floor(height * .08)))
    local cover_h = math.max(48, height - title_h - status_h - 10)
    local cover_w = math.max(36, math.min(inner_w, math.floor(cover_h * .70)))
    local cover = image_widget(book.cover_path, cover_w, cover_h) or placeholder(cover_w, cover_h, book.title)
    local progress = math.max(0, math.min(100, tonumber(book.progress) or 0))
    local status = U.trim(tostring(book.status_text or ""))
    local reading_badge = ""
    if progress >= 100 then
        reading_badge = "已读"
    elseif progress > 0 then
        reading_badge = tostring(math.floor(progress + .5)) .. "%"
    end

    if status == "未生成" or status == "未开始" or status == "已读完"
        or status:match("^阅读%s+%d+%%$") then
        status = ""
    end
    status = U.utf8_truncate(status, 10, "")
    local status_important = status:match("下载中") or status:match("生成中")
        or status == "失败" or status == "待修复" or status == "排队中"

    local cover_layer = OverlapGroup:new{dimen = Geom:new{w = cover_w, h = cover_h}, allow_mirroring = false}
    cover_layer[#cover_layer + 1] = cover
    if reading_badge ~= "" then
        local chars = math.max(2, U.utf8_len(reading_badge))
        local badge_w = math.max(34, math.min(66, 16 + chars * 9))
        local badge_h = math.max(18, math.min(24, math.floor(cover_h * .10)))
        cover_layer[#cover_layer + 1] = OffsetContainer:new{
            x_off = math.max(0, cover_w - badge_w),
            y_off = 0,
            fixed_frame(badge_w, badge_h, {
                bordersize = 0,
                radius = math.max(3, Screen:scaleBySize(3)),
                padding = 2,
                background = Blitbuffer.COLOR_BLACK,
            }, TextWidget:new{
                text = reading_badge,
                face = face("smallinfofont", 8, 10),
                bold = true,
                fgcolor = Blitbuffer.COLOR_WHITE,
            }),
        }
    end

    local body = VerticalGroup:new{
        align = "center",
        cover_layer,
        VerticalSpan:new{height = 4},
        TextBoxWidget:new{
            text = tostring(book.title or "未命名"),
            face = face("cfont", 12, 15),
            bold = true,
            width = inner_w,
            height = title_h,
            height_adjust = false,
            height_overflow_show_ellipsis = true,
            alignment = "center",
        },
        TextBoxWidget:new{
            text = status,
            face = face("smallinfofont", 8, 10),
            bold = status_important and true or false,
            width = inner_w,
            height = status_h,
            height_adjust = false,
            height_overflow_show_ellipsis = true,
            alignment = "center",
            fgcolor = status_important and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
        },
    }
    return tappable(width, height,
        CenterContainer:new{dimen = Geom:new{w = width, h = height}, body},
        function() if callback then callback(book) end end)
end

local function category_tabs(tabs, width, height)
    tabs = tabs or {}
    if #tabs == 0 then return fixed_frame(width, height, {background = Blitbuffer.COLOR_WHITE}) end
    local gap = math.max(3, Screen:scaleBySize(3))
    local item_w = math.floor((width - gap * (#tabs - 1)) / #tabs)
    local row = HorizontalGroup:new{align = "center"}
    for index, tab in ipairs(tabs) do
        local label = tostring(tab.title or "")
        if tonumber(tab.count) then label = label .. " " .. tostring(tab.count) end
        local item = OverlapGroup:new{dimen = Geom:new{w = item_w, h = height}, allow_mirroring = false}
        item[#item + 1] = CenterContainer:new{dimen = Geom:new{w = item_w, h = height}, TextBoxWidget:new{
            text = label,
            face = face("smallinfofont", 10, 13),
            bold = tab.selected == true,
            width = math.max(1, item_w - 8),
            height = math.max(18, height - 8),
            height_adjust = false,
            height_overflow_show_ellipsis = true,
            alignment = "center",
            fgcolor = tab.selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
        }}
        if tab.selected then
            local line_w = math.max(28, math.floor(item_w * .54))
            item[#item + 1] = OffsetContainer:new{
                x_off = math.floor((item_w - line_w) / 2),
                y_off = math.max(0, height - Size.line.thick),
                LineWidget:new{background = Blitbuffer.COLOR_BLACK, dimen = Geom:new{w = line_w, h = Size.line.thick}},
            }
        end
        table.insert(row, tappable(item_w, height, item, tab.on_tap))
        if index < #tabs then table.insert(row, HorizontalSpan:new{width = gap}) end
    end
    return row
end

local function empty_section(width, height, text, callback)
    return tappable(width, height, fixed_frame(width, height, {
        bordersize = 0,
        padding = math.max(8, Screen:scaleBySize(7)),
        background = Blitbuffer.COLOR_WHITE,
    }, TextBoxWidget:new{
        text = tostring(text or "暂时没有内容"),
        face = face("smallinfofont", 12, 14),
        width = math.max(1, width - 32),
        alignment = "center",
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }), callback)
end

local HomeWidget = InputContainer:extend{
    name = "miuread_home",
    covers_fullscreen = true,
    stop_events_propagation = true,
    opts = nil,
    dimen = nil,
    header_dimen = nil,
    content_dimen = nil,
    section_dimen = nil,
    _miu_closed = false,
}


function HomeWidget:handleEvent(event)
    if event and event.handler=="onGesture" then
        local ges=event.args and event.args[1]
        local direction=ges and ges.direction
        local gesture=ges and ges.ges
        local pos=ges and (ges.start_pos or ges.pos)
        local shelf_owned=(direction=="west" or direction=="east") and pos and self.section_dimen
            and pos.x>=self.section_dimen.x and pos.x<=self.section_dimen.x+self.section_dimen.w
            and pos.y>=self.section_dimen.y and pos.y<=self.section_dimen.y+self.section_dimen.h
        -- Forward unowned swipe-style gestures before the fullscreen home can
        -- stop propagation. Taps and holds remain owned by books and buttons.
        local pointer_action=gesture=="tap" or gesture=="hold" or gesture=="hold_release"
            or gesture=="double_tap" or gesture=="two_finger_tap"
        if not pointer_action and not shelf_owned
            and GestureBridge.dispatch(ges) then return true end
    end
    return InputContainer.handleEvent(self,event)
end

function HomeWidget:_add(children, x, y, widget)
    children[#children + 1] = OffsetContainer:new{x_off = x, y_off = y, widget}
end

function HomeWidget:_metrics()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local portrait = sw < sh
    local margin = math.max(12, math.min(24, math.floor(sw * .022)))
    local header_h = portrait
        and math.max(54, math.min(68, math.floor(sh * .055)))
        or math.max(48, math.min(60, math.floor(sh * .075)))
    local gap = math.max(8, math.min(14, math.floor(sh * .009)))
    return {
        sw = sw,
        sh = sh,
        portrait = portrait,
        margin = margin,
        gap = gap,
        content_w = sw - margin * 2,
        header_h = header_h,
        body_y = margin + header_h + Size.line.thin + gap,
        body_h = sh - (margin + header_h + Size.line.thin + gap) - margin,
    }
end

function HomeWidget:_register_top_swipe(m)
    if not Device:isTouchDevice() then self.ges_events={}; return end
    self.ges_events={
        HomeShelfSwipe={GestureRange:new{
            ges="swipe",
            range=function() return self.section_dimen or self.content_dimen end,
        }},
    }
end

function HomeWidget:onHomeShelfSwipe(_,ges)
    if not (ges and self.opts and self.opts.on_shelf_page) then return false end
    if ges.direction=="west" then self.opts.on_shelf_page(1); return true end
    if ges.direction=="east" then self.opts.on_shelf_page(-1); return true end
    return false
end

function HomeWidget:_build_header(children, m)
    local menu_w = math.max(72, math.min(92, math.floor(m.content_w * .10)))
    local title_w = math.max(92, math.min(132, math.floor(m.content_w * .15)))
    local account_w = math.max(150, math.min(280, math.floor(m.content_w * .27)))
    local gap = math.max(5, math.floor(m.content_w * .009))
    local status_w = math.max(1, m.content_w - title_w - account_w - menu_w - gap * 3)
    local header = HorizontalGroup:new{
        align = "center",
        LeftContainer:new{dimen = Geom:new{w = title_w, h = m.header_h}, TextWidget:new{
            text = self.opts.title or "觅阅",
            face = face("cfont", 21, 25),
            bold = true,
        }},
        HorizontalSpan:new{width = gap},
        tappable(status_w, m.header_h, TextBoxWidget:new{
            text = tostring(self.opts.status_line or ""),
            face = face("smallinfofont", 11, 13),
            width = status_w,
            height = math.max(22, math.floor(m.header_h * .52)),
            height_adjust = false,
            height_overflow_show_ellipsis = true,
            alignment = "right",
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }, self.opts.on_quick_panel),
        HorizontalSpan:new{width = gap},
        tappable(account_w, m.header_h, TextBoxWidget:new{
            text = tostring(self.opts.account_name or "账户"),
            face = face("smallinfofont", 11, 13),
            width = account_w,
            height = math.max(22, math.floor(m.header_h * .52)),
            height_adjust = false,
            height_overflow_show_ellipsis = true,
            alignment = "right",
            bold = true,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }, self.opts.on_account),
        HorizontalSpan:new{width = gap},
        text_button("⋯", menu_w, math.max(40, m.header_h - 6), function()
            logger.info("[MiuRead][Home] menu tapped")
            if self.opts and self.opts.on_menu then self.opts.on_menu() end
        end, {
            font = "cfont",
            size = 12,
            maximum = 22,
            borderless = true,
        }),
    }
    self:_add(children, m.margin, m.margin, header)
    self:_add(children, m.margin, m.margin + m.header_h,
        LineWidget:new{
            background = Blitbuffer.COLOR_GRAY,
            dimen = Geom:new{w = m.content_w, h = Size.line.thin},
        })
end

function HomeWidget:_grid_geometry(m, width, available_h, count, force_rows)
    local columns = m.portrait and 3 or 4
    -- Keep every page on the same 3×2 / 4×2 grid. The last page leaves empty
    -- slots instead of enlarging the remaining covers.
    local rows = force_rows or 2
    rows = math.max(1, math.min(rows, 2))
    local col_gap = math.max(10, m.gap)
    local row_gap = math.max(8, m.gap)
    if rows == 2 and math.floor((available_h - row_gap) / 2) < Screen:scaleBySize(118) then rows = 1 end
    local card_w = math.max(1, math.floor((width - col_gap * (columns - 1)) / columns))
    local raw_card_h = math.max(1, math.floor((available_h - row_gap * (rows - 1)) / rows))
    local preferred_card_h = math.max(Screen:scaleBySize(142), math.floor(card_w * 1.62))
    local card_h = math.min(raw_card_h, preferred_card_h)
    return columns, rows, col_gap, row_gap, card_w, card_h
end

function HomeWidget:_render_grid(children, m, x, y, width, height, books, on_open, force_rows)
    if #books == 0 then return 0 end
    local columns, rows, col_gap, row_gap, card_w, card_h = self:_grid_geometry(m, width, height, #books, force_rows)
    local capacity = columns * rows
    local shown = math.min(#books, capacity)
    for index = 1, shown do
        local row = math.floor((index - 1) / columns)
        local col = (index - 1) % columns
        local start_x = x
        self:_add(children,
            start_x + col * (card_w + col_gap),
            y + row * (card_h + row_gap),
            shelf_book_card(books[index], card_w, card_h, on_open))
    end
    return rows * card_h + math.max(0, rows - 1) * row_gap
end

local function page_footer(width, height, page, pages, on_page)
    page = math.max(1, tonumber(page) or 1)
    pages = math.max(1, tonumber(pages) or 1)
    local arrow_w = math.max(64, math.floor(width * .18))
    local middle_w = math.max(1, width - arrow_w * 2)
    local row = HorizontalGroup:new{align = "center"}
    table.insert(row, text_button("‹", arrow_w, height, page > 1 and function() on_page(-1) end or nil, {
        borderless = true, font = "cfont", size = 19, maximum = 24,
        fgcolor = page > 1 and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
    }))
    table.insert(row, CenterContainer:new{dimen = Geom:new{w = middle_w, h = height}, TextWidget:new{
        text = tostring(page) .. " / " .. tostring(pages),
        face = face("smallinfofont", 10, 12),
        bold = true,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }})
    table.insert(row, text_button("›", arrow_w, height, page < pages and function() on_page(1) end or nil, {
        borderless = true, font = "cfont", size = 19, maximum = 24,
        fgcolor = page < pages and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
    }))
    return row
end

function HomeWidget:_build_sections(children, m, compact)
    local x, y, w, gap = m.margin, m.body_y, m.content_w, m.gap
    local bottom = m.body_y + m.body_h
    local notice = (self.opts.alerts or {})[1] or self.opts.download_notice
    if notice then
        local h = math.max(42, math.min(52, math.floor(m.body_h * .07)))
        self:_add(children, x, y, notice_strip(notice, w, h))
        y = y + h + gap
    end

    local tabs_h = math.max(40, math.min(48, math.floor(m.body_h * .065)))
    local section_h = math.max(32, math.min(40, math.floor(m.body_h * .052)))
    local books = self.opts.shelf_books or {}
    local title = tostring(self.opts.shelf_title or "书架")

    if not m.portrait then
        local available_h = math.max(1, bottom - y)
        local hero_w = math.max(230, math.min(math.floor(w * .35), 390))
        local shelf_x = x + hero_w + gap
        local shelf_w = math.max(1, w - hero_w - gap)
        if self.opts.hero then
            self:_add(children, x, y, hero_card(self.opts.hero, hero_w, available_h, self.opts.hero.on_tap, compact))
        else
            self:_add(children, x, y, welcome_card(hero_w, available_h, self.opts.on_empty_account))
        end
        self.section_dimen = Geom:new{x = shelf_x, y = y, w = shelf_w, h = available_h}
        self:_add(children, shelf_x, y, category_tabs(self.opts.tabs, shelf_w, tabs_h))
        local sy = y + tabs_h + math.max(5, math.floor(gap * .6))
        self:_add(children, shelf_x, sy, section_header(title, shelf_w, section_h, self.opts.on_shelf_all))
        sy = sy + section_h + math.max(4, math.floor(gap * .5))
        local footer_h = math.max(34, math.min(44, math.floor(available_h * .10)))
        local grid_h = math.max(1, bottom - sy - footer_h)
        if #books > 0 then
            self:_render_grid(children, m, shelf_x, sy, shelf_w, grid_h, books, self.opts.on_open_book, 2)
        else
            self:_add(children, shelf_x, sy, empty_section(shelf_w, grid_h, self.opts.empty_text or "暂时没有内容", self.opts.on_shelf_all))
        end
        self:_add(children, shelf_x, bottom - footer_h, page_footer(shelf_w, footer_h, self.opts.shelf_page, self.opts.shelf_pages, self.opts.on_shelf_page or function() end))
        return
    end

    local hero_h = compact
        and math.max(225, math.min(285, math.floor(m.body_h * .22)))
        or math.max(300, math.min(350, math.floor(m.body_h * .27)))
    if y + hero_h < bottom then
        if self.opts.hero then
            self:_add(children, x, y, hero_card(self.opts.hero, w, hero_h, self.opts.hero.on_tap, compact))
        else
            self:_add(children, x, y, welcome_card(w, hero_h, self.opts.on_empty_account))
        end
        y = y + hero_h + gap
    end
    self.section_dimen = Geom:new{x = x, y = y, w = w, h = math.max(1, bottom - y)}
    if y + tabs_h < bottom then
        self:_add(children, x, y, category_tabs(self.opts.tabs, w, tabs_h))
        y = y + tabs_h + math.max(5, math.floor(gap * .6))
    end
    if y + section_h < bottom then
        self:_add(children, x, y, section_header(title, w, section_h, self.opts.on_shelf_all))
        y = y + section_h + math.max(4, math.floor(gap * .5))
    end
    local footer_h = math.max(36, math.min(48, math.floor(m.body_h * .045)))
    local grid_h = math.max(1, bottom - y - footer_h)
    if #books > 0 then
        self:_render_grid(children, m, x, y, w, grid_h, books, self.opts.on_open_book, 2)
    else
        self:_add(children, x, y, empty_section(w, grid_h, self.opts.empty_text or "暂时没有内容", self.opts.on_shelf_all))
    end
    self:_add(children, x, bottom - footer_h, page_footer(w, footer_h, self.opts.shelf_page, self.opts.shelf_pages, self.opts.on_shelf_page or function() end))
end

function HomeWidget:_rebuild()
    local m = self:_metrics()
    self.dimen = Geom:new{x = 0, y = 0, w = m.sw, h = m.sh}
    self.header_dimen = Geom:new{x = 0, y = 0, w = m.sw, h = math.min(m.sh, m.body_y)}
    self.content_dimen = Geom:new{x = 0, y = m.body_y, w = m.sw, h = math.max(1, m.sh - m.body_y)}
    self.section_dimen = self.content_dimen:copy()
    self:_register_top_swipe(m)
    local children = OverlapGroup:new{dimen = self.dimen:copy(), allow_mirroring = false}
    children[#children + 1] = background(m.sw, m.sh)
    self:_build_header(children, m)
    self:_build_sections(children, m, tostring(self.opts.layout_style or "standard") == "compact")
    local previous = self[1]
    self[1] = children
    if previous and previous ~= children and previous.free then pcall(previous.free, previous) end
end

function HomeWidget:_mark_dirty(kind, previous_region)
    local region
    if kind == "section" then region = self.section_dimen
    elseif kind == "header" then region = self.header_dimen
    elseif kind == "content" then region = self.content_dimen
    else
        UIManager:setDirty(self, "full")
        return
    end
    if previous_region and region then region = previous_region:combine(region)
    else region = region or previous_region end
    if region then
        UIManager:setDirty(self, function() return "ui", region end)
    else
        UIManager:setDirty(self, "full")
    end
end

function HomeWidget:update(opts, refresh_kind)
    local previous_region
    if refresh_kind == "section" and self.section_dimen then previous_region = self.section_dimen:copy()
    elseif refresh_kind == "header" and self.header_dimen then previous_region = self.header_dimen:copy()
    elseif refresh_kind == "content" and self.content_dimen then previous_region = self.content_dimen:copy() end
    self.opts = opts or self.opts or {}
    self:_rebuild()
    self:_mark_dirty(refresh_kind or "full", previous_region)
    return self
end

function HomeWidget:updateSection(opts)
    opts = opts or {}
    self.opts.tabs = opts.tabs or self.opts.tabs
    self.opts.shelf_title = opts.shelf_title or self.opts.shelf_title
    self.opts.shelf_books = opts.shelf_books or {}
    self.opts.empty_text = opts.empty_text or self.opts.empty_text
    self.opts.on_open_book = opts.on_open_book or self.opts.on_open_book
    self.opts.on_shelf_all = opts.on_shelf_all or self.opts.on_shelf_all
    self.opts.on_shelf_page = opts.on_shelf_page or self.opts.on_shelf_page
    self.opts.shelf_page = opts.shelf_page or self.opts.shelf_page
    self.opts.shelf_pages = opts.shelf_pages or self.opts.shelf_pages
    return self:update(self.opts, "section")
end

function HomeWidget:init()
    self.key_events = self.key_events or {}
    if Device:hasKeys() then
        if Device.input and Device.input.group and Device.input.group.Back then
            self.key_events.Back = {{Device.input.group.Back}}
        end
        self.key_events.Menu = {{"Menu"}}
        self.key_events.Home = {{"Home"}}
        if Device.input and Device.input.group then
            if Device.input.group.PgFwd then self.key_events.ShelfNext = {{Device.input.group.PgFwd}} end
            if Device.input.group.PgBack then self.key_events.ShelfPrevious = {{Device.input.group.PgBack}} end
        end
    end
    self:_rebuild()
end

function HomeWidget:onShelfNext()
    if self.opts and self.opts.on_shelf_page then self.opts.on_shelf_page(1) end
    return true
end
function HomeWidget:onShelfPrevious()
    if self.opts and self.opts.on_shelf_page then self.opts.on_shelf_page(-1) end
    return true
end

function HomeWidget:onMenu()
    logger.info("[MiuRead][Home] physical menu")
    if self.opts and self.opts.on_menu then self.opts.on_menu() end
    return true
end
function HomeWidget:onBack()
    -- The MiuRead home is the root page. Back must not leak to FileManager.
    logger.info("[MiuRead][Home] back consumed at root")
    return true
end
function HomeWidget:onHome()
    logger.info("[MiuRead][Home] home consumed at root")
    return true
end

function HomeWidget:onSetDimensions()
    self:_rebuild()
    UIManager:setDirty(self, "full")
    return true
end
function HomeWidget:onScreenResize() return self:onSetDimensions() end
function HomeWidget:onRotation() return self:onSetDimensions() end

function HomeWidget:onCloseWidget()
    self._miu_closed = true
    if live_widget == self then live_widget = nil end
    if self.opts and self.opts.on_close then pcall(self.opts.on_close, self) end
end

local HomeView = {}
function HomeView.current() return live_widget end
function HomeView.is_shown()
    return live_widget and not live_widget._miu_closed and UIManager:isWidgetShown(live_widget)
end
-- FileManager is recreated after ReaderUI closes so KOReader's docless
-- plugins (including Gesture Manager) remain alive beneath MiuRead. Move the
-- already-built home above that native base without closing/rebuilding it.
function HomeView.raise()
    if not HomeView.is_shown() then return false end
    local stack = UIManager._window_stack or {}
    local window, index
    for i = #stack, 1, -1 do
        if stack[i] and stack[i].widget == live_widget then
            window, index = stack[i], i
            break
        end
    end
    if not window then return false end
    table.remove(stack, index)
    local insert_at = 1
    -- Match UIManager:show ordering for a standard non-modal widget: below
    -- modal dialogs/toasts, above the uppermost normal page.
    for i = #stack, 0, -1 do
        local top = stack[i]
        if top and top.widget and top.widget.toast then
            -- Keep looking below the toast group.
        elseif not top or not top.widget or not top.widget.modal then
            insert_at = i + 1
            break
        end
    end
    table.insert(stack, insert_at, window)
    UIManager:setDirty(live_widget, "ui")
    return true
end
function HomeView.close()
    if live_widget and not live_widget._miu_closed then UIManager:close(live_widget) end
    live_widget = nil
end
function HomeView.refresh(kind)
    if not HomeView.is_shown() then return false end
    local ok, err = pcall(live_widget.update, live_widget, live_widget.opts or {}, kind or "content")
    if not ok then logger.warn("[MiuRead][Home] refresh failed", tostring(err)); return false end
    return true
end
function HomeView.update_section(opts)
    if not HomeView.is_shown() or not live_widget.updateSection then return false end
    local ok, err = pcall(live_widget.updateSection, live_widget, opts or {})
    if not ok then logger.warn("[MiuRead][Home] section update failed", tostring(err)); return false end
    return true
end
function HomeView.show(opts, refresh_kind)
    opts = opts or {}
    if HomeView.is_shown() then
        local ok, err = pcall(live_widget.update, live_widget, opts, refresh_kind)
        if ok then return live_widget end
        logger.warn("[MiuRead][Home] in-place update failed", tostring(err))
    end
    if live_widget and not live_widget._miu_closed then UIManager:close(live_widget) end
    local ok, widget = pcall(HomeWidget.new, HomeWidget, {opts = opts})
    if not ok or not widget then
        logger.err("[MiuRead][Home] build failed", tostring(widget))
        return nil, tostring(widget)
    end
    live_widget = widget
    UIManager:show(widget, "ui", widget.dimen)
    return widget
end
return HomeView
