import SwiftUI

/// Navigation owns selection; this view only renders destinations and their visual identity.
struct PreferencesSidebar: View {
    let navigation: PreferencesNavigation
    let version: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                FlowQuotaAppIcon().frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Flow Quota").font(.headline)
                    Text("流量与提醒").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(PreferencesNavigation.Page.allCases) { page in
                        if page == .general {
                            Divider().padding(.horizontal, 10).padding(.vertical, 8)
                        }
                        destination(page)
                    }
                }
            }
            .scrollIndicators(.hidden)
            Spacer(minLength: 0)
            Label("数据仅保存在本机", systemImage: "lock.shield")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 8)
        }
        .padding(12).padding(.top, 14)
        .frame(width: 194)
        .background(.regularMaterial)
    }

    private func destination(_ page: PreferencesNavigation.Page) -> some View {
        let selected = navigation.page == page
        return Button { navigation.select(page) } label: {
            HStack(spacing: 10) {
                PreferencesPageIcon(page: page)
                VStack(alignment: .leading, spacing: 2) {
                    Text(page.title).font(.subheadline.weight(selected ? .semibold : .medium))
                    if page == .about {
                        Text(version).font(.caption2).opacity(selected ? 0.85 : 0.65)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 9).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(FlowQuotaTheme.accent.gradient)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(FlowQuotaRowButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Fixed tile sizes keep symbols with different intrinsic widths aligned with the labels.
private struct PreferencesPageIcon: View {
    let page: PreferencesNavigation.Page

    var body: some View {
        Image(systemName: page.symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }

    private var tint: Color {
        switch page {
        case .applications: .indigo
        case .charts: .cyan
        case .details: .teal
        case .reminders: .orange
        case .history: .purple
        case .general: .gray
        case .help: .blue
        case .about: .orange
        }
    }
}
