# 觅阅 4.0.0-beta.1 源码仓库

本包可直接作为 GitHub 仓库内容使用，当前代码对应 **内测通道**。

## 使用方式

1. 将本包内容完整上传到 `beta` 分支根目录，不要只上传 `miuread.koplugin`。
2. 在 GitHub 的 **Actions** 页面运行 `release-beta.yml`。
3. 工作流会检查版本与通道、生成完整安装包和源码包、创建 GitHub Release，并写回 `update-beta.json`。

## 双通道规则

- 正式版使用 `main` 分支、`update.json`、版本格式 `4.0.0`。
- 内测版使用 `beta` 分支、`update-beta.json`、版本格式 `4.0.0-beta.1`。
- 两个工作流都保留在仓库中，但会检查当前分支和 `CHANNEL`，错误通道会直接停止。

## 目录说明

- `miuread.koplugin/`：KOReader 插件完整源码。
- `.github/workflows/`：正式与内测两个独立发布工作流。
- `scripts/build_release.py`：版本检查、打包、清单和校验文件生成。
- `VERSION`：当前版本号。
- `CHANNEL`：当前源码所属通道。
- `update-beta.json`：当前通道更新清单。
- `RELEASE_NOTES.md`：本版发布说明。

当前包应放在 `beta` 分支；另一通道请使用对应源码包上传到 `main` 分支。
