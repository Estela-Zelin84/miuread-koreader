local root=arg[1]
package.path=root.."/miuread.koplugin/?.lua;"..root.."/miuread.koplugin/miuread/?.lua;"..package.path
local shown={}
local function class(defaults)
  local c=defaults or {}
  function c:extend(extra)
    extra=extra or {}
    setmetatable(extra,{__index=self})
    extra.extend=self.extend
    extra.new=self.new
    return extra
  end
  function c:new(opts)
    opts=opts or {}
    setmetatable(opts,{__index=self})
    if opts.init then opts:init() end
    return opts
  end
  return c
end
local Screen={scaleBySize=function(_,v) return v end,getWidth=function() return 800 end,getHeight=function() return 1000 end,getSize=function() return {w=800,h=1000} end}
package.preload["ffi/blitbuffer"]=function() return {COLOR_WHITE=0} end
package.preload["device"]=function() return {screen=Screen,isTouchDevice=function() return false end,hasKeys=function() return false end} end
package.preload["ui/widget/container/inputcontainer"]=function() local c=class(); c.handleEvent=function() return false end; return c end
for _,name in ipairs({"ui/widget/button","ui/widget/container/framecontainer","ui/gesturerange","ui/widget/overlapgroup","ui/widget/verticalgroup","ui/widget/verticalspan"}) do
  package.preload[name]=function() return class() end
end
package.preload["ui/geometry"]=function() local c=class(); c.contains=function() return false end; c.copy=function(self) return self end; return c end
package.preload["ui/size"]=function() return {border={window=1}} end
package.preload["ui/widget/scrollhtmlwidget"]=function() return {new=function() error("cannot open ./fonts/noto/NotoSansCJKsc-Regular.otf: No such file") end} end
package.preload["ui/widget/textviewer"]=function() return class() end
package.preload["ui/widget/infomessage"]=function() return class() end
package.preload["ui/uimanager"]=function() return {show=function(_,widget) shown[#shown+1]=widget end,setDirty=function() end,close=function() end} end
package.preload["logger"]=function() return {warn=function() end} end
local Popup=require("miuread.thought_popup")
local ok,mode,reason=Popup.show{html="<p>评论</p>",fallback_text="原文\n\n评论"}
assert(ok==true,"fallback did not open")
assert(mode=="plain","fallback mode incorrect")
assert(tostring(reason):find("NotoSans",1,true),"rich error not preserved")
assert(#shown==1,"viewer not shown")
assert(shown[1].text=="原文\n\n评论","fallback text incorrect")
local ok2,mode2=Popup.show{html="<p>再次</p>",fallback_text="再次评论"}
assert(ok2==true and mode2=="plain","session fallback was not reused")
assert(#shown==2,"second fallback not shown")
print("Thought popup fallback tests OK")
