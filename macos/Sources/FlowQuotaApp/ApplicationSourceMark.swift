import SwiftUI

/// Decorative source identity shared by list rows and detail headers, never a checkbox.
struct ApplicationSourceMark: View {
    let name: String
    var symbol = "app"
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.10))
            if symbol == "app" {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size / 2, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            } else {
                Image(systemName: symbol).font(.system(size: size / 2, weight: .medium))
                    .foregroundStyle(symbol == "exclamationmark.octagon" ? Color.red : Color.orange)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
