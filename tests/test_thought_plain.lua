local root=arg[1]
package.path=root.."/miuread.koplugin/?.lua;"..root.."/miuread.koplugin/miuread/?.lua;"..package.path
package.preload["miuread.json"]=function() return {encode=function() return "[]" end,decode=function() return {} end} end
package.preload["logger"]=function() return {info=function() end} end
package.preload["libs/libkoreader-lfs"]=function() return {attributes=function() return nil end} end
package.preload["miuread.util"]=function()
  local function trim(v) return tostring(v or ""):match("^%s*(.-)%s*$") end
  return {trim=trim,copy=function(t) local o={} for k,v in pairs(t or {}) do o[k]=v end return o end,
    xml=function(v) return tostring(v or "") end,atomic_write=function() return true end,mkdir=function() end,id_name=tostring,
    read_file=function() return nil end}
end
local Thoughts=require("miuread.thoughts")
local text=Thoughts.plain_text({texts={
  {abstract="原文片段",author="甲",content="第一条想法",likes=2,review_id="1"},
  {abstract="原文片段",author="甲",content="第一条想法",likes=2,review_id="1"},
  {author="乙",content="第二条想法",likes=0,review_id="2"},
}})
assert(text:find("正文",1,true),"source heading missing")
assert(text:find("原文片段",1,true),"source missing")
assert(text:find("甲 · 赞 2",1,true),"author and likes missing")
assert(text:find("第二条想法",1,true),"second comment missing")
local _,count=text:gsub("第一条想法","")
assert(count==1,"duplicate comment not removed")
print("Thought plain-text tests OK")
