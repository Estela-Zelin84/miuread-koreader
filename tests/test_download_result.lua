local root=arg[1]
package.path=root.."/miuread.koplugin/?.lua;"..root.."/miuread.koplugin/miuread/?.lua;"..package.path
local Result=require("miuread.download_result")
local function assert_eq(actual,expected,label)
  if actual~=expected then error((label or "value")..": expected "..tostring(expected).." got "..tostring(actual)) end
end
local complete={annotation_pending=false}
local pending={annotation_pending=true}
local fallback={annotation_fallback=true}
local both={annotation_pending=true,annotation_fallback=true}
assert_eq(Result.state(complete,false),"completed","complete state")
assert_eq(Result.state(pending,false),"annotation_pending","pending state")
assert_eq(Result.state(pending,true),"pending_install","pending install state")
assert_eq(Result.shelf_status(pending,false),"已生成 · 划线或想法待补全","pending shelf")
assert_eq(Result.shelf_status(pending,true),"等待关闭后更新 · 划线或想法待补全","pending install shelf")
assert_eq(Result.shelf_status(fallback,false),"已生成 · 少量内容已保留在章节末尾","fallback shelf")
assert_eq(Result.variant_label("划线与想法版",pending),"划线与想法版 · 待补全","pending variant label")
assert_eq(Result.variant_label("划线与想法版",fallback),"划线与想法版 · 章节末尾保留","fallback variant label")
local aggregate=Result.aggregate({complete,pending,fallback})
assert_eq(aggregate.annotation_pending,true,"aggregate pending")
assert_eq(aggregate.annotation_fallback,true,"aggregate fallback")
assert(Result.notice("测试书",fallback,false):find("章节末尾",1,true),"fallback notice missing")
assert(Result.summary_note(fallback):find("章节末尾",1,true),"fallback summary missing")
assert(Result.summary_note(both):find("重新下载补全",1,true) and Result.summary_note(both):find("章节末尾",1,true),"combined summary missing")
assert(Result.notice("测试书",pending,false):find("待补全",1,true),"pending notice missing")
assert(Result.summary_note(pending):find("稍后重新下载补全",1,true),"pending summary missing")
assert_eq(Result.summary_note(complete),nil,"complete summary")
print("Download result tests OK")
