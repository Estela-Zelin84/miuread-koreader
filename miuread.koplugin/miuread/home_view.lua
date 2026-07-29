local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")

local Screen = Device.screen
local unpack_args=unpack or table.unpack
local live_widget

local function image_widget(path,w,h)
    if not path or path=="" then return nil end
    local image
    local ok=pcall(function()
        image=ImageWidget:new{file=path,width=w,height=h,file_do_cache=false}
        image:getSize()
    end)
    if ok and image then return image end
    if image and image.free then pcall(image.free,image) end
    return nil
end

local function placeholder(w,h,title)
    local mark=tostring(title or "书"):gsub("^%s+",""):sub(1,3)
    if mark=="" then mark="书" end
    return FrameContainer:new{
        width=w,height=h,bordersize=Size.border.thin,padding=0,margin=0,
        background=Blitbuffer.COLOR_WHITE,
        CenterContainer:new{dimen=Geom:new{w=w,h=h},
            TextWidget:new{text=mark,face=Font:getFace("cfont",Screen:scaleBySize(22)),bold=true}},
    }
end

local TapBox = InputContainer:extend{
    dimen=nil, callback=nil, hold_callback=nil,
}
function TapBox:init()
    self.ges_events={
        TapSelect={GestureRange:new{ges="tap",range=self.dimen}},
        HoldSelect={GestureRange:new{ges="hold",range=self.dimen}},
    }
end
function TapBox:onTapSelect()
    if self.callback then self.callback() end
    return true
end
function TapBox:onHoldSelect()
    if self.hold_callback then self.hold_callback() end
    return true
end

local function action_button(text,w,h,callback)
    local box=TapBox:new{dimen=Geom:new{w=w,h=h},callback=callback}
    box[1]=FrameContainer:new{
        width=w,height=h,bordersize=Size.border.thin,padding=0,margin=0,
        CenterContainer:new{dimen=Geom:new{w=w,h=h},
            TextWidget:new{text=tostring(text or ""),face=Font:getFace("cfont",Screen:scaleBySize(14))}},
    }
    return box
end

local function section_header(title,count,w,h,on_more)
    local more_w=on_more and Screen:scaleBySize(86) or 0
    local title_w=math.max(1,w-more_w)
    local row=HorizontalGroup:new{align="center",
        LeftContainer:new{dimen=Geom:new{w=title_w,h=h},
            TextWidget:new{text=tostring(title)..(count and (" · "..tostring(count)) or ""),
                face=Font:getFace("cfont",Screen:scaleBySize(18)),bold=true}},
    }
    if on_more then
        table.insert(row,action_button("查看全部",more_w,h-Screen:scaleBySize(4),on_more))
    end
    return row
end

local function book_card(book,w,h,on_tap,on_hold)
    local pad=Screen:scaleBySize(5)
    local title_h=Screen:scaleBySize(42)
    local status_h=Screen:scaleBySize(24)
    local cover_h=math.max(Screen:scaleBySize(72),h-title_h-status_h-pad*3)
    local cover_w=math.max(Screen:scaleBySize(48),math.floor(cover_h*0.68))
    local max_cover_w=math.max(Screen:scaleBySize(48),w-pad*2)
    if cover_w>max_cover_w then
        cover_w=max_cover_w
        cover_h=math.max(Screen:scaleBySize(72),math.floor(cover_w/0.68))
    end
    local cover=image_widget(book.cover_path,cover_w,cover_h) or placeholder(cover_w,cover_h,book.title)
    local title=TextBoxWidget:new{
        text=tostring(book.title or "未命名"),face=Font:getFace("cfont",Screen:scaleBySize(15)),
        width=w-pad*2,height=title_h,height_adjust=true,height_overflow_show_ellipsis=true,
        alignment="center",bold=true,
    }
    local status=TextBoxWidget:new{
        text=tostring(book.status_text or book.status or book.format or ""),
        face=Font:getFace("smallinfofont",Screen:scaleBySize(12)),
        width=w-pad*2,height=status_h,height_adjust=true,height_overflow_show_ellipsis=true,
        alignment="center",fgcolor=Blitbuffer.COLOR_DARK_GRAY,
    }
    local column=VerticalGroup:new{align="center",
        CenterContainer:new{dimen=Geom:new{w=w,h=cover_h},cover},
        VerticalSpan:new{height=pad},title,status,
    }
    local card=TapBox:new{
        dimen=Geom:new{w=w,h=h},
        callback=function() if on_tap then on_tap(book) end end,
        hold_callback=function() if on_hold then on_hold(book) end end,
    }
    card[1]=FrameContainer:new{
        width=w,height=h,bordersize=0,padding=0,margin=0,
        CenterContainer:new{dimen=Geom:new{w=w,h=h},column},
    }
    return card
end

local function book_row(books,w,h,on_tap,on_hold)
    local gap=Screen:scaleBySize(10)
    local count=3
    local card_w=math.max(Screen:scaleBySize(90),math.floor((w-gap*(count-1))/count))
    local row=HorizontalGroup:new{align="top"}
    for i=1,count do
        if i>1 then table.insert(row,HorizontalSpan:new{width=gap}) end
        local book=books[i]
        if book then
            table.insert(row,book_card(book,card_w,h,on_tap,on_hold))
        else
            table.insert(row,CenterContainer:new{dimen=Geom:new{w=card_w,h=h},
                TextWidget:new{text="",face=Font:getFace("cfont",12)}})
        end
    end
    return row
end

local HomeWidget = InputContainer:extend{
    name="miuread_home",covers_fullscreen=true,
    opts=nil,dimen=nil,_miu_closed=false,
}
function HomeWidget:init()
    local sw,sh=Screen:getWidth(),Screen:getHeight()
    self.dimen=Geom:new{x=0,y=0,w=sw,h=sh}
    self.ges_events={
        TapBackground={GestureRange:new{ges="tap",range=self.dimen}},
        HoldBackground={GestureRange:new{ges="hold",range=self.dimen}},
        SwipeBackground={GestureRange:new{ges="swipe",range=self.dimen}},
    }

    local margin=Screen:scaleBySize(18)
    local content_w=sw-margin*2
    local title_h=Screen:scaleBySize(52)
    local action_w=Screen:scaleBySize(62)
    local action_gap=Screen:scaleBySize(7)
    local title_w=math.max(1,content_w-action_w*3-action_gap*3)
    local header=HorizontalGroup:new{align="center",
        LeftContainer:new{dimen=Geom:new{w=title_w,h=title_h},
            TextWidget:new{text=self.opts.title or "觅阅首页",face=Font:getFace("cfont",Screen:scaleBySize(23)),bold=true}},
        HorizontalSpan:new{width=action_gap},
        action_button("下载",action_w,title_h-Screen:scaleBySize(8),self.opts.on_downloads),
        HorizontalSpan:new{width=action_gap},
        action_button("菜单",action_w,title_h-Screen:scaleBySize(8),self.opts.on_menu),
        HorizontalSpan:new{width=action_gap},
        action_button("原生",action_w,title_h-Screen:scaleBySize(8),self.opts.on_native),
    }

    local top_books=self.opts.miuread_books or {}
    local local_books=self.opts.local_books or {}
    local has_local=#local_books>0
    local section_h=Screen:scaleBySize(38)
    local footer_h=Screen:scaleBySize(24)
    local vertical_gap=Screen:scaleBySize(8)
    local gap_count=has_local and 5 or 3
    local fixed=title_h+section_h+footer_h+vertical_gap*gap_count+(has_local and section_h or 0)
    local rows=has_local and 2 or 1
    local available=math.max(Screen:scaleBySize(190),sh-margin*2-fixed)
    local row_h
    if has_local then
        row_h=math.max(Screen:scaleBySize(190),math.floor(available/2))
    else
        row_h=math.max(Screen:scaleBySize(190),math.min(math.floor(available),math.floor(sh*0.48)))
    end

    local group=VerticalGroup:new{align="left",header,VerticalSpan:new{height=vertical_gap}}
    table.insert(group,section_header("觅阅书籍",self.opts.miuread_count or #top_books,content_w,section_h,self.opts.on_miuread_all))
    table.insert(group,VerticalSpan:new{height=vertical_gap})
    if #top_books>0 then
        table.insert(group,book_row(top_books,content_w,row_h,self.opts.on_open_miuread,self.opts.on_hold_miuread))
    else
        local empty=action_button("还没有已生成书籍 · 打开微信书架",content_w,row_h,self.opts.on_empty_miuread)
        table.insert(group,empty)
    end
    if has_local then
        table.insert(group,VerticalSpan:new{height=vertical_gap})
        table.insert(group,section_header("本地书籍",self.opts.local_count or #local_books,content_w,section_h,self.opts.on_local_all))
        table.insert(group,VerticalSpan:new{height=vertical_gap})
        table.insert(group,book_row(local_books,content_w,row_h,self.opts.on_open_local,self.opts.on_hold_local))
    end
    table.insert(group,VerticalSpan:new{height=vertical_gap})
    table.insert(group,TextBoxWidget:new{
        text=tostring(self.opts.footer_text or ""),face=Font:getFace("smallinfofont",Screen:scaleBySize(11)),
        width=content_w,height=footer_h,height_adjust=true,height_overflow_show_ellipsis=true,
        alignment="center",fgcolor=Blitbuffer.COLOR_DARK_GRAY,
    })

    self[1]=FrameContainer:new{
        width=sw,height=sh,bordersize=0,padding=margin,margin=0,
        background=Blitbuffer.COLOR_WHITE,
        group,
    }
end
function HomeWidget:onTapBackground() return true end
function HomeWidget:onHoldBackground() return true end
function HomeWidget:onSwipeBackground() return true end
function HomeWidget:onCloseWidget()
    self._miu_closed=true
    if live_widget==self then live_widget=nil end
    if self.opts and self.opts.on_close then pcall(self.opts.on_close,self) end
end

local HomeView={}
function HomeView.current() return live_widget end
function HomeView.is_shown()
    return live_widget and not live_widget._miu_closed and UIManager:isWidgetShown(live_widget)
end
function HomeView.close()
    if live_widget and not live_widget._miu_closed then UIManager:close(live_widget) end
    live_widget=nil
end
function HomeView.show(opts)
    if live_widget and not live_widget._miu_closed then UIManager:close(live_widget) end
    local ok,widget=pcall(HomeWidget.new,HomeWidget,{opts=opts or {}})
    if not ok or not widget then
        logger.err("[MiuRead][Home] build failed",tostring(widget))
        return nil,tostring(widget)
    end
    live_widget=widget
    UIManager:show(widget,"ui")
    return widget
end

return HomeView
