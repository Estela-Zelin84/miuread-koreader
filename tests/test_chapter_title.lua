local root=arg[1]
package.path=root.."/miuread.koplugin/?.lua;"..root.."/miuread.koplugin/?/init.lua;"..root.."/miuread.koplugin/miuread/?.lua;"..package.path
local empty_modules={
  "miuread.protocol","miuread.config","miuread.footnotes","miuread.internal_links",
  "miuread.thoughts","miuread.epub","miuread.json","miuread.http","miuread.download_plan",
  "miuread.annotation_cache","miuread.epub_installer",
}
for _,name in ipairs(empty_modules) do package.preload[name]=function() return {} end end
package.preload["miuread.codec"]=function() return {body=function(value) return tostring(value or "") end} end
package.preload["miuread.util"]=function()
  return {xml=function(value)
    return tostring(value or ""):gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;"):gsub('"','&quot;')
  end}
end
package.preload["logger"]=function() return {info=function() end,warn=function() end} end
local Downloader=require("miuread.downloader")
local prepare=assert(Downloader._prepare_chapter_body)
local function inserted(body)
  local _,count=body:gsub('class="miu%-chapter%-title"','')
  return count
end
local cases={
  {"missing",'<p>正文内容</p>',"第一章 开始",1},
  {"exact",'<h1>第一章 开始</h1><p>正文</p>',"第一章 开始",0},
  {"numbered variant",'<h1>第1章 锦朝</h1><p>正文</p>',"锦朝",0},
  {"cjk punctuation",'<h2>第一章：开始</h2><p>正文</p>',"第一章 开始",0},
  {"split headings",'<h2>第一夜</h2>\n<h2>我们的不幸是谁的错？</h2><p>正文</p>',"第一夜 我们的不幸是谁的错？",0},
  {"image alt",'<h1><img src="title.png" alt="第一章 开始"></h1><p>正文</p>',"第一章 开始",0},
  {"unrelated heading",'<h1>作者的话</h1><p>正文</p>',"第一章 开始",1},
  {"first paragraph title",'<p>第一章 开始</p><p>正文</p>',"第一章 开始",0},
  {"fullwidth ascii",'<h1>Ｃｈａｐｔｅｒ １：Ｓｔａｒｔ</h1><p>正文</p>',"Chapter 1: Start",0},
  {"later body mention",'<p>正文</p>'..string.rep('内容',2500)..'<h2>第一章 开始</h2>',"第一章 开始",1},
}
for _,case in ipairs(cases) do
  local result=prepare(case[2],case[3])
  local count=inserted(result)
  if count~=case[4] then
    io.stderr:write(case[1].." expected inserted="..case[4].." got="..count.."\n"..result.."\n")
    os.exit(1)
  end
end
print("Title tests OK: "..#cases)
