local root=arg[1]
package.path=root.."/miuread.koplugin/?.lua;"..root.."/miuread.koplugin/miuread/?.lua;"..package.path
package.preload["miuread.config"]=function()
  return {LOW_MEMORY_SETTING="DGLOBAL_CACHE_FREE_PROPORTION",LOW_MEMORY_RATIO=0.15}
end
package.preload["logger"]=function() return {info=function() end,warn=function() end} end
local MemoryMode=require("miuread.memory_mode")
local function fake_defaults(initial)
  local values={DGLOBAL_CACHE_FREE_PROPORTION=initial}
  return {
    readSetting=function(self,key,default) local v=values[key]; if v==nil then return default end; return v end,
    saveSetting=function(self,key,value) values[key]=value end,
    delSetting=function(self,key) values[key]=nil end,
    flush=function() end,
    values=values,
  }
end
local function fake_store()
  local prefs={memory_mode={enabled=false,previous_known=false,previous_ratio=false}}
  return {
    preferences=function() return prefs end,
    save_preferences=function(self,value) prefs=value end,
    get_prefs=function() return prefs end,
  }
end
local function assert_eq(actual,expected,label)
  if actual~=expected then error((label or "value")..": expected "..tostring(expected).." got "..tostring(actual)) end
end

-- Normal enable/disable restores the previous value.
_G.G_defaults=fake_defaults(0.4)
local store=fake_store()
local mode=MemoryMode:new(store)
local ok,res=mode:set_enabled(true)
assert(ok,res)
assert_eq(_G.G_defaults.values.DGLOBAL_CACHE_FREE_PROPORTION,0.15,"enabled ratio")
assert_eq(store:get_prefs().memory_mode.enabled,true,"enabled pref")
assert_eq(store:get_prefs().memory_mode.previous_ratio,0.4,"saved previous")
ok,res=mode:set_enabled(false)
assert(ok,res)
assert_eq(_G.G_defaults.values.DGLOBAL_CACHE_FREE_PROPORTION,0.4,"restored ratio")
assert_eq(store:get_prefs().memory_mode.enabled,false,"disabled pref")
assert_eq(store:get_prefs().memory_mode.previous_known,true,"restore metadata retained")
assert_eq(store:get_prefs().memory_mode.previous_ratio,0.4,"restore ratio retained")

-- An external change is not overwritten when disabling.
_G.G_defaults=fake_defaults(0.4)
store=fake_store(); mode=MemoryMode:new(store)
assert(mode:set_enabled(true))
_G.G_defaults.values.DGLOBAL_CACHE_FREE_PROPORTION=0.25
ok,res=mode:set_enabled(false)
assert(ok,res)
assert_eq(res.external_change,true,"external change flag")
assert_eq(_G.G_defaults.values.DGLOBAL_CACHE_FREE_PROPORTION,0.25,"external ratio preserved")

-- A previously absent setting is removed again.
_G.G_defaults=fake_defaults(nil)
store=fake_store(); mode=MemoryMode:new(store)
assert(mode:set_enabled(true))
assert_eq(_G.G_defaults.values.DGLOBAL_CACHE_FREE_PROPORTION,0.15,"absent enable")
assert(mode:set_enabled(false))
assert_eq(_G.G_defaults.values.DGLOBAL_CACHE_FREE_PROPORTION,nil,"absent restored")


-- A target ratio with disabled plugin state is surfaced as external/residual.
_G.G_defaults=fake_defaults(0.15)
store=fake_store(); mode=MemoryMode:new(store)
local status=mode:status()
assert_eq(status.residual,true,"residual status")
ok,res=mode:set_enabled(true)
assert_eq(ok,nil,"residual enable should be blocked")
ok,res=mode:restore_detected()
assert(ok,res)
assert_eq(res.used_default,true,"residual default restore")
assert_eq(_G.G_defaults.values.DGLOBAL_CACHE_FREE_PROPORTION,nil,"residual setting removed")

-- Preserved restore metadata is preferred when a residual setting is detected.
_G.G_defaults=fake_defaults(0.15)
store=fake_store(); mode=MemoryMode:new(store)
local prefs=store:get_prefs(); prefs.memory_mode={enabled=false,previous_known=true,previous_ratio=0.4}
ok,res=mode:restore_detected()
assert(ok,res)
assert_eq(_G.G_defaults.values.DGLOBAL_CACHE_FREE_PROPORTION,0.4,"residual previous ratio restored")

-- Unsupported KOReader does not save a false enabled state.
_G.G_defaults=nil
store=fake_store(); mode=MemoryMode:new(store)
ok,res=mode:set_enabled(true)
assert_eq(ok,nil,"unsupported result")
assert_eq(store:get_prefs().memory_mode.enabled,false,"unsupported pref")
print("Memory mode tests OK")
