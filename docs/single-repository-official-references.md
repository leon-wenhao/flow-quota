# 单仓库发布依据（2026-11-06）

- GitHub CLI `gh release create/edit/upload`：https://cli.github.com/manual/gh_release_create 、https://cli.github.com/manual/gh_release_edit 、https://cli.github.com/manual/gh_release_upload 。已读取官方页面与本机帮助；`--verify-tag` 使用已经核对的源码 tag，`--latest=false` 延后激活，`--latest` 在附件核对后激活，不覆盖正式附件。
- GitHub REST Releases 与资产：https://docs.github.com/en/rest/releases/releases 、https://docs.github.com/en/rest/releases/assets 。使用 API 返回的名称、状态、size、SHA-256 digest 核验，避免为验收重新下载 DMG。`releases/latest/download/update-manifest.json` 由 GitHub 按 latest 正式版解析。
- 仓库公开：https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/managing-repository-settings/setting-repository-visibility 。公开前检查全部历史；不把删除 HEAD 文件当成历史已清理。
- 仓库删除：https://docs.github.com/en/repositories/creating-and-managing-repositories/deleting-a-repository 。GitHub CLI 删除要求 admin 权限及 `delete_repo` scope；只在新仓库发布核验完成后删除指定旧仓库，不删除当前源码仓库。
- MIT 标准模板通过 GitHub 官方 `GET /licenses/mit` 取得，版权年 2026、权利人 leon-wenhao；本次未引入第三方代码依赖。工具链和平台边界沿用项目既有约束。
