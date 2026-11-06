import SwiftUI

/// Static explanations live in Help; settings keep only values and actionable failures.
struct SettingsUsageGuide: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "显示与刷新") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("外观与刷新间隔自动保存。外观可跟随系统，也可固定为浅色或深色。")
                    Text("刷新间隔可设为 1–5 秒，从下一轮等待生效，影响界面、菜单栏和通知检查；后台仍约每 2 秒采样。")
                    Text("菜单栏可显示 626M、1.2G 等紧凑用量；关闭后只保留图标，悬停可查看详情。")
                }
            }
            SettingsSection(title: "阈值与通知") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("接口每日总量、接口短时用量、各应用／服务短时用量分别判断，可独立关闭；阈值均为上传＋下载。应用每日阈值在“应用用量”中设置。关闭提醒仍统计用量。")
                    Text("短时窗口默认 3 分钟，可设 1–15 分钟。窗口未填满也可触发；记录显示实际连续观测时长。同来源提醒间隔控制短时预警冷却，每日总量按配置版本提醒一次。")
                    Text("切网、跨日、暂停、重启、修改配置或采样间断后，短时窗口重新积累。两类网络的用量、阈值与提醒分别保存。")
                    Text("1 MB = 1,000,000 bytes；1 GB = 1,000,000,000 bytes。阈值须为正数、精确到整数 byte，且不超出 Int64 范围。保存只表示配置已持久化，不会阻断连接。")
                    Text("在“系统设置 → 通知 → Flow Quota”调整通知。请保持主应用运行；关闭窗口不影响投递。授权失败不影响采样，但提醒无法确认送达。系统接受请求不保证出现横幅，专注模式可能影响展示。")
                    Text("只保留当天最多 256 条预警，不保存流量内容或逐次采样明细。共享系统服务的原始请求方可能无法确认。")
                    Text("预警记录按时间展示已触发的提醒，类型与来源在同一列显示；点击整条记录展开详情。通知“已提交”仅表示系统接受请求，不保证横幅出现或已被阅读。“状态与说明”可查看当前三类预警状态；读取、采样、保存或容量异常会直接显示。")
                }
            }
            SettingsSection(title: "流量来源与服务") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Mac 总流量来自物理接口，应用识别失败也不减量。主图显示所选时段总量，下方展示来源及上传、下载。空白表示未观测，圆点表示观测零量。")
                    Text("例如 Clash 已记录 800MB，虎牙与 YouTube 各识别到 300MB，则显示虎牙（Clash）300MB、YouTube（Clash）300MB、其他未识别（Clash）200MB；不再重复加入内核父项。")
                    Text("Clash 来源按当天、网络类别及分钟核对；已识别部分保留原数，余量全部保留为其他未识别。无法核对的分钟全量标为未识别，不按比例凑数。记录重启后保留，暂停、重启与故障间断不补量。")
                    Text("Clash 标签包括 Mihomo 的 DIRECT 规则，不表示必经代理节点。完整来源可滚动查看，容量和读取异常会提示；内核提醒设置与原始计数在用量详情中。物理接口与应用观测仍有时间和协议差异，不能保证每个字节都能唯一还原到应用。")
                    Text("若系统要求批准后台服务，请在登录项设置中允许，再刷新服务状态。“修复开发服务”仅用于重新构建后的开发包，系统批准仍需手动完成。")
                }
            }
            SettingsSection(title: "软件更新") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("更新检查只在点击按钮时执行。发现新版后由更新窗口下载安装，确认后自动替换并重启。")
                    Text("首次安装使用 DMG 拖拽到 Applications；后续更新无需再次拖拽。当前为 ad-hoc 签名、未公证，系统仍可能要求权限或到“隐私与安全性”选择“仍要打开”。更新保留规则和当天累计，重启期间流量不补算。")
                }
            }
        }
        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
    }
}
