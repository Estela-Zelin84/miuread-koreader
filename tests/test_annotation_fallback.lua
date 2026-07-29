local root=arg[1]
package.path=root.."/miuread.koplugin/?.lua;"..root.."/miuread.koplugin/miuread/?.lua;"..package.path
package.preload["logger"]=function() return {info=function() end,warn=function() end} end
package.preload["miuread.http"]=function()
  return {is_auth_error=function() return false end,is_rate_limit_error=function() return false end,is_forbidden_error=function() return false end}
end
package.preload["miuread.thoughts"]=function()
  return {
    href=function(book,chapter,range) return "#thought-"..tostring(range) end,
    mark_class=function(range) return "mark-"..tostring(range):gsub("[^%w]","-") end,
  }
end
package.preload["miuread.annotation_style"]=function() return {CSS=".miu-inline-mark{}"} end
package.preload["miuread.util"]=function()
  local function trim(v) return tostring(v or ""):match("^%s*(.-)%s*$") end
  local function xml(v)
    return tostring(v or ""):gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;"):gsub('"',"&quot;")
  end
  return {trim=trim,xml=xml}
end
local Annotations=require("miuread.annotations")
local worker=Annotations:new({})
local function assert_true(value,label) if not value then error(label or "assertion failed") end end
local html="<p>正文内容</p>"
local data={
  book_id="b",chapter_uid="c",underline_count=1,thought_count=1,thought_entry_count=1,errors={},
  underlines={{range="999-1000",markText="无法定位的原文"}},
  review_map={["999-1000"]={{content="评论"}}},
}
local rendered,css,stats=worker:apply(html,data)
assert_true(stats.fallback==1,"fallback count")
assert_true(rendered:find('data-miuread-unlocated="1"',1,true),"fallback section missing")
assert_true(rendered:find("无法定位的原文",1,true),"fallback quote missing")
assert_true(rendered:find("#thought-999-1000",1,true),"fallback thought link missing")
assert_true(css~="","annotation css missing")

local aligned={
  book_id="b",chapter_uid="c",underline_count=1,thought_count=0,thought_entry_count=0,errors={},
  underlines={{range="0-2",markText="正文"}},review_map={},
}
local normal,_,normal_stats=worker:apply(html,aligned)
assert_true(normal_stats.fallback==0,"normal mark should not fallback")
assert_true(normal:find("miu-inline-mark",1,true),"normal inline mark missing")
assert_true(not normal:find("miu-unlocated",1,true),"normal mark received fallback section")
print("Annotation fallback tests OK")
