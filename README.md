# 觅阅 · 微信读书助手

KOReader 的微信读书插件，支持 Kindle、Kobo 与 Android 等 KOReader 设备。

## 当前版本

当前源码为 `3.2.0-beta.37` 内测版，应提交到 `beta` 分支。

本版重新整理运行模式、阅读控制、同步入口、下载限制与使用提醒：

- 新增明确的“觅阅桌面模式 / 插件模式”，切换后重启生效。
- 插件模式不替代 KOReader 或其他美化界面，下载、评论、同步、修复等功能仍可使用。
- 重做阅读快捷面板，补回字体、字号、完整排版、进度同步、时间同步与当前书籍入口。
- 恢复 KOReader 底部原生排版面板，顶部入口按用户的点击或滑动设置工作。
- 下载固定为“一本正在下载 + 一本等待”，不提供多本并行或无限队列。
- 增加阅读时下载、低电量、低存储、扫描、修复、全屏刷新、锁屏封面和模式切换提醒。

详细变更见 `CHANGELOG-3.2.0-beta.37.txt`。

## 分支与发布

- `main`：正式版源码，使用 `.github/workflows/release.yml` 发布并更新 `update.json`。
- `beta`：内测版源码，使用 `.github/workflows/release-beta.yml` 发布并更新 `update-beta.json`。

两个工作流文件需要同时保留在默认分支，GitHub Actions 左侧才会显示正式版与内测版两个发布入口。

## 安装

将完整安装包中的 `miuread.koplugin` 文件夹放入 KOReader 的 `plugins` 目录，然后完整重启 KOReader。
