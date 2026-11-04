# 002 真实网络过滤技术样机

状态：阻塞于可验证的系统扩展部署条件；尚未开始真实流量验收。

目标：按来源身份持续计量 TCP/UDP，并在额度触发后阻断已有流与新流。
依赖：官方 NetworkExtension 部署要求、系统扩展激活权限与必要 entitlement。
环境证据：本地 security find-identity 无有效代码签名身份，SIP enabled；systemextensionsctl list 返回 0 extension(s)。
范围：验证 sourceAppAuditToken、受控字节口径、offset 去重、Agent 通信和分块判定。
验收：真实应用 TCP/UDP、IPv4/IPv6、并发、超额、重连；记录误差、延迟和尾部流量。
阻塞处理：告知用户；不通过普通防火墙、网速轮询、假数据或关闭系统安全功能替代。正式发行暂缓不等于该阶段已通过。
恢复：明确可用的官方开发部署路径及相应资源后，先最小激活验证再实现引擎。
