import AppKit
import FlowQuotaCore
import SwiftUI

/// The menu bar is a quick glance surface; detailed workflows use the native window.
struct PanelView: View {
    let state: AppState
    let openPreferences: (PreferencesNavigation.Page) -> Void
    var openApplication: ((ApplicationSnapshot) -> Void)? = nil
    @AppStorage("hasReadLocalSetup") private var hasReadLocalSetup = false
    @AppStorage("hasShownInstallationGuide") private var hasShownInstallationGuide = false
    @State private var showInstallationGuide = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                FlowQuotaAppIcon().frame(width: 28, height: 28)
                Text("Flow Quota").font(.headline)
                Spacer()
                Button { state.refreshOnce() } label: {
                    ZStack {
                        if state.refreshing { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                    .frame(width: 20, height: 20)
                }
                .buttonStyle(FlowQuotaIconButtonStyle()).disabled(state.busy || state.refreshing)
                .accessibilityLabel("刷新服务状态").help("刷新服务状态")
                Button { openPreferences(.general) } label: { Image(systemName: "gearshape") }
                    .buttonStyle(FlowQuotaIconButtonStyle(emphasized: true)).accessibilityLabel("偏好设置").help("偏好设置")
            }
            .padding(16)
            TrafficCategorySelection(state: state)
                .padding(.horizontal, 16).padding(.bottom, 12)
            OverviewView(state: state, openPreferences: openPreferences, openApplication: openApplication)
                .padding(.horizontal, 16).padding(.bottom, 12)
            Divider()
            VStack(spacing: 8) {
                Button {
                    if state.updater.availableVersion != nil { openPreferences(.general) }
                    else { openPreferences(hasReadLocalSetup ? .applications : .help) }
                } label: {
                    Label(state.updater.availableVersion == nil ? "偏好设置" : "有新版本，查看更新",
                          systemImage: state.updater.availableVersion == nil ? "slider.horizontal.3" : "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .settingsAction()
                HStack(spacing: 8) {
                    ServiceFeedback(state: state)
                    Button("退出并停止采集") { state.requestQuit() }
                        .flowQuotaTextAction().controlSize(.small).foregroundStyle(.secondary)
                        .fixedSize().disabled(state.busy)
                }
                .frame(height: 24)
            }
            .padding(12)
        }
        .frame(width: 360)
        .background(.regularMaterial, in: Rectangle())
        .overlay(Rectangle().strokeBorder(FlowQuotaTheme.border))
        .onAppear {
            guard !hasShownInstallationGuide, !InstallationLocation.isInApplications else { return }
            hasShownInstallationGuide = true
            showInstallationGuide = true
        }
        .alert("请先完成 Flow Quota 安装", isPresented: $showInstallationGuide) {
            Button("打开 Applications 文件夹") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
            }
            Button("知道了", role: .cancel) {}
        } message: {
            Text("请将 Flow Quota.app 拖到 Applications 文件夹后再打开。若被系统拦截，请到系统设置 → 隐私与安全性中选择“仍要打开”。")
        }
    }
}
