import SwiftUI

/// Visual grouping only; settings state and mutations stay with their owning views.
/// Direct children each receive a card; separators belong inside a child container.
/// Pages with dense visualizations can reduce card padding without changing other settings sections.
struct SettingsSection<Content: View>: View {
    let title: String
    var cardPadding: CGFloat = 16
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .flowQuotaCard(padding: cardPadding)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
