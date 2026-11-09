# GitHub 与 Gitee 同步分发方案

2026-11-09 用户要求后续代码提交和版本发布同步至 GitHub、Gitee，并提供国内更新入口。已创建公开仓库 `Leon-wh/flow-quota` 并同步原有正式源码及版本 tag；客户端双源查询及双端发布脚本已实现并进行离线验证；Gitee Release 凭据、真实附件和匿名下载仍未验收，线上继续只有已验证的 GitHub 更新源。

## 目标与一致性

- GitHub 保持现有 leon-wenhao/flow-quota，Gitee 使用已确认账号下的 Leon-wh/flow-quota。
- 维护同一条源码历史。发布 tag 在两端指向同一源码提交；推送只包含明确分支与发布 tag，不强制覆盖远端，也不使用镜像推送删除远端引用。
- 安装包只构建并签名一次，两端 DMG 的大小、SHA-256 和 Ed25519 签名保持一致。版本号、内部构建号和更新内容一致；不得用两次构建结果代替相同安装包。
- 两端发布不能作为跨平台原子事务处理。任一端失败必须报告部分完成状态，保存可继续核验的发布记录；重试复用已有相同附件，不覆盖已正式发布版本或回滚另一端。
- 延续明确附件白名单，源码库不包含统计库、日志、DMG、私钥或本机配置。Gitee 发布凭据仅用于发布机，不能随应用分发，也不写入 Git 历史或打印到日志。

## 应用内更新

仅同步代码和 Release 页面不足以交付国内更新。还需验证 Gitee 的版本入口、更新说明及真实安装包可在无登录、无发布凭据条件下取得，下载不得最终依赖 GitHub。

双源需要各自可用的架构 appcast，其 enclosure 指向本平台可匿名下载的同一安装包。包签名沿用原密钥；appcast 因下载 URL 不同需分别生成并签名，不能修改已签名文件中的地址。继续校验 feed 和包签名，不因备用源不可用而跳过安全验证。

实现使用 Sparkle 2.10.1 官方 `feedURLStringForUpdater:` 选择动态源，先用 `checkForUpdateInformation()` 完成静默且有签名校验的探测。GitHub 探测失败才读取 Gitee 公开 Release 列表与附件入口；正常“无新版本”不回退。Gitee 仅选择正式版且带 `flow-quota-ready` 标记的最高构建，架构清单必须来自无凭据 HTTPS Gitee 地址。手动检查探测成功后再进入同源标准 Sparkle 界面，自动检查仅提示；两端都失败保留两个原因，手动操作打开通用设置显示错误。每次新检查恢复 GitHub 优先。完整附件核验后才激活客户端能看到的版本入口；Gitee 不应照搬尚未由官方文档确认的 GitHub draft 或 latest 激活语义。自动检查开关、各网络类别均查询、仅提示版本及用户确认下载安装的既有行为保持不变。

## 已核对的官方能力

读取 Gitee 官方 Open API 文档 /api/v5/doc_json，文档版本 5.4.93（2026-11-09）。文档列出了仓库创建、Release 创建／查询／更新、附件上传／查询／下载接口；这只确认接口定义，不代表当前账号已具备访问或发布权限，也不证明实际附件可匿名下载。

- POST /api/v5/user/repos：创建仓库。当前 schema 对个人仓库的 private 参数注明“个人创建仓库仅支持私有”；是否能通过界面申请公开及其实际状态需在该账号核实，不能假定 API 创建即公开。
- POST /api/v5/repos/{owner}/{repo}/releases：接受 tag_name、name、body、target_commitish、prerelease；没有列出 GitHub 式 draft 或 make_latest 参数。
- POST /api/v5/repos/{owner}/{repo}/releases/{release_id}/attach_files：上传附件。
- GET /api/v5/repos/{owner}/{repo}/releases/{release_id}/attach_files：列出附件；返回结构含 id、name、size、browser_download_url，没有声明服务器 SHA-256。最终一致性验证不能仅比较文件名和大小。
- GET /api/v5/repos/{owner}/{repo}/releases/{release_id}/attach_files/{attach_file_id}/download：附件下载接口；目标仓库下的匿名可用性、重定向和频率限制仍需核实。

官方入口：https://gitee.com/api/v5/swagger 。本地核对副本位于忽略目录 .artifacts/gitee-api-doc.json，不作为凭据或发布附件。

## 接入前置条件与验收

2026-11-09 已通过恢复后的 Computer Use，在用户已登录的 Chrome 中创建公开仓库 Leon-wh/flow-quota。公开 API 确认 public=true、private=false、default_branch=main。现有 SSH 授权可用；原有 Git 凭据用于 API 验证返回 401，不能将 Git 推送授权等同于 Release API 发布授权。未创建新令牌。

当前仓库已配置独立 gitee remote，地址为 git@gitee.com:Leon-wh/flow-quota.git；origin 的 fetch 仍为 GitHub，两个 push URL 分别为 GitHub HTTPS 和 Gitee SSH。常规 git push origin 会向两端尝试推送，但不是跨平台原子事务；失败时须核对并补推。此配置仅在当前本机 .git/config，克隆到新机器需要重新设置。Release API 发布授权仍需配置；双端脚本 `push_sources.py`、`publish_dual.py` 及使用方式见 [发布流程](release-macos.md)。先使用模拟 API 和临时 Git 仓库验证中断恢复、tag 冲突、附件白名单、摘要不符及单端失败；再在目标仓库执行已授权的实际同步与匿名入口核验。验证受“不制造热点实验流量”约束，不能为测试在热点下重新下载安装包。

交付必须分别记录：源码双端一致、版本附件双端一致、国内匿名下载、客户端双源查询及安全安装。未完成的项目直接标明，不能将可浏览源码等同于国内更新已可用。

## 2026-11-09 仓库创建与源码同步验证

已通过公开页面与无需令牌的仓库 API 确认公开状态。以现有 SSH 密钥完成 main 及 10 个版本 tag 的首次原子推送；Gitee main 和 v0.1.11 均为 e057d3a78699691e8b36327aa5aa03ce0fc07e0c，对应原有正式源码。工作区未提交的界面和自动检查改动未被提交、推送或发布。

同步前检查 main 和本地发布 tag 可达的 799 个历史 blob，未发现本次检查的私钥、GitHub 令牌、AWS access key、Slack token 格式；该结果不保证覆盖所有可能凭据格式。记录在忽略目录 .artifacts/gitee-source-audit.json。未上传安装包或创建 Gitee Release，未改客户端更新地址，也未生成热点实验流量。

## 2026-11-09 双源实现与验收边界

- 客户端新增 `UpdateSourceFallback` 管理一次性回退与手动／自动意图，`GiteeUpdateFeed` 以无 Cookie 的临时会话读取公开元数据。分页最多 10 页，每个响应最多 1 MiB，单请求 15 秒；容量、无已激活版本、异常 JSON、缺失／重复附件及外部地址均直接失败，不默默使用低版本。关闭自动检查不取消已发出的请求，但阻止后续备用探测；手动不受开关限制。
- `SUFeedURL` 仍为既有 GitHub 架构 feed；仅在已激活 Gitee Release 发现合法 URL 后由 delegate 切换。未修改公钥、`SURequireSignedFeed`、包预验证及安装交接。探测阶段不会停采集、进入恢复或下载包；进入标准窗口之后发生的下载安装失败按原 Sparkle 流程报告，用户重新检查可重新选择源，不自动重启安装流程。
- 发布器保留原始 GitHub bundle，Gitee 两个签名 feed 放在同级 `-gitee` 目录。包保持相同字节与签名；公共清单保持原始审计数据。Gitee 无 ready 标记时对本客户端不可见，prerelease 并非平台私有草稿，仓库访问者仍可能看到预览版。
- 实际令牌未配置，未创建 Gitee Release、未上传包、未下载包作实验，未触发真实安装；因此暂不能宣布国内匿名更新可用。首次发布须取得 API 发布权限，通过真实附件匿名回读、摘要及重定向核验，并在允许的环境验证实际跨版本安装。若平台不允许公开下载或返回未支持域名，脚本明确停止，不降低验收标准。
- 官方依据：Gitee `/api/v5/doc_json` 5.4.93；Sparkle 固定依赖 2.10.1 的 `SPUUpdater.h`、`SPUUpdaterDelegate.h` 与 `SPUUpdater.m`。源码确认 completion 回调前清除 driver／session，回退仍通过下一轮主线程与 `canCheckForUpdates` 门控启动；没有设置废弃的 `feedURL` 属性。

本轮最终验证：157 项应用测试串行通过、55 项 Python 发布测试通过，双架构 Release 构建与严格签名审计通过；并行轮询测试的一次超时、独立及串行复测证据均记录在 [实施状态](implementation-status.md) 对应章节。没有进行真实 Gitee 附件上传／下载或跨版本安装。
