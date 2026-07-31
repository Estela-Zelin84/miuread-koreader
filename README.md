# 觅阅 · 微信读书助手

KOReader 的微信读书插件，支持 Kindle、Kobo 与 Android 等 KOReader 设备。

## 当前版本

当前源码为 `3.2.0-beta.38` 内测版，应提交到 `beta` 分支。

本版修复更新说明显示异常，并将更新弹窗改为简短摘要。

详细变更见 `CHANGELOG-3.2.0-beta.38.txt`。

## 分支与发布

- `main`：正式版源码，使用 `.github/workflows/release.yml` 发布并更新 `update.json`。
- `beta`：内测版源码，使用 `.github/workflows/release-beta.yml` 发布并更新 `update-beta.json`。

两个工作流文件需要同时保留在默认分支，GitHub Actions 左侧才会显示正式版与内测版两个发布入口。

## 安装

将完整安装包中的 `miuread.koplugin` 文件夹放入 KOReader 的 `plugins` 目录，然后完整重启 KOReader。
