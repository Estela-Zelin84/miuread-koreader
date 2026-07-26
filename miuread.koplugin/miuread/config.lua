local C = {
    NAME = "觅阅 · 微信读书助手",
    VERSION = "1.1.48-beta.3",
    SCHEMA = 40,
    PLUGIN_DIR = "miuread.koplugin",
    DATA_DIR = "miuread",

    -- 更新清单固定保存在仓库根目录；清单中的下载地址指向
    -- GitHub Release 全量包。旧版本仍可通过备用地址升级到本版本。
    -- This package is permanently bound to the beta channel. Installing a
    -- stable full package is the only supported way to return to stable.
    UPDATE_CHANNEL = "beta",
    UPDATE_CHANNEL_LABEL = "内测",
    UPDATE_MANIFEST = "https://raw.githubusercontent.com/miumiupy98-art/miuread-koreader/beta/update-beta.json",
    UPDATE_MANIFESTS = {
        "https://raw.githubusercontent.com/miumiupy98-art/miuread-koreader/beta/update-beta.json",
    },

    -- 仅作为 GitHub 官方资源访问失败时的回退入口。
    -- 下载后仍会执行大小与 SHA-256 校验，镜像不能改变安装内容。
    GITHUB_MIRRORS = {
        "https://ghfast.top/",
        "https://gh-proxy.com/",
        "https://ghproxy.net/",
    },

    READ_INTERVAL = 30,
    IDLE_TIMEOUT = 600,
    REMOTE_THRESHOLD = 2,

    -- Beta-only accelerated validation window. Stable builds use three days;
    -- beta builds use ten minutes so testers can exercise
    -- expiry, lock and recovery without changing the device clock.
    ACCESS_VERIFY_TTL = 10 * 60,
    ACCESS_POLICY_VERSION = 3,

    -- Coalesce page-turn control snapshots. Reading position stays in memory
    -- and is written at most once per window; suspend/close still flushes now.
    CONTROL_WRITE_DELAY = 30,
}
return C
