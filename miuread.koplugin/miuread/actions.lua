local Dispatcher=require("dispatcher")

local Actions={}
local registered=false

local general_actions={
    {"miuread_show","ShowMiuRead","觅阅：打开觅阅书架"},
    {"miuread_toggle_progress_sync","ToggleMiuReadProgressSync","觅阅：开关自动同步进度"},
    {"miuread_toggle_time_sync","ToggleMiuReadTimeSync","觅阅：开关自动同步时间"},
    {"miuread_downloads","ShowMiuReadDownloads","觅阅：下载管理"},
    {"miuread_sync_status","ShowMiuReadSyncStatus","觅阅：同步状态"},
    {"miuread_qr_login","MiuReadQRLogin","觅阅：扫码登录"},
}

function Actions.register()
    if registered then return end
    registered=true
    for _,row in ipairs(general_actions) do
        Dispatcher:registerAction(row[1],{
            category="none",event=row[2],title=row[3],general=true,
        })
    end
    Dispatcher:registerAction("miuread_close_book",{
        category="none",event="MiuReadCloseBook",title="觅阅：关闭书籍",reader=true,
    })
end

return Actions
