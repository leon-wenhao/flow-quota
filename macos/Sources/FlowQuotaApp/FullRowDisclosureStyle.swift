import SwiftUI

/// Only the header is a button; controls inside the expanded content keep their own actions.
struct FullRowDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: 12).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "已展开" : "已收起")
            .accessibilityHint(configuration.isExpanded ? "收起内容" : "展开内容")
            if configuration.isExpanded {
                // Keep nested disclosures on the same full-row interaction style.
                configuration.content
                    .disclosureGroupStyle(FullRowDisclosureStyle())
                    .padding(.leading, 18).padding(.top, 6)
            }
        }
    }
}
