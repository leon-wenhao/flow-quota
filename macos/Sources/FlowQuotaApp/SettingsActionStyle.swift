import SwiftUI

/// Consistent, softer action buttons for settings pages.
private struct SettingsActionStyle: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        content
            .buttonStyle(FlowQuotaButtonStyle(prominent: prominent))
            .controlSize(.regular)
    }
}

struct FlowQuotaButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .background(background(configuration), in: RoundedRectangle(cornerRadius: FlowQuotaTheme.controlRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: FlowQuotaTheme.controlRadius, style: .continuous)
                    .strokeBorder(prominent ? Color.white.opacity(0.08) : FlowQuotaTheme.border, lineWidth: 0.8)
            )
            .contentShape(RoundedRectangle(cornerRadius: FlowQuotaTheme.controlRadius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.84 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .modifier(FlowQuotaInteractionFeedback())
    }

    private func background(_ configuration: Configuration) -> some ShapeStyle {
        if prominent { return AnyShapeStyle(FlowQuotaTheme.accent.opacity(configuration.isPressed ? 0.82 : 1)) }
        return AnyShapeStyle(FlowQuotaTheme.cardFill.opacity(configuration.isPressed ? 0.92 : 0.68))
    }
}

struct FlowQuotaIconButtonStyle: ButtonStyle {
    var emphasized = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(emphasized ? FlowQuotaTheme.accent : FlowQuotaTheme.muted)
            .frame(width: 34, height: 34)
            .background(
                emphasized ? FlowQuotaTheme.accent.opacity(0.12) : FlowQuotaTheme.cardFill.opacity(0.64),
                in: RoundedRectangle(cornerRadius: FlowQuotaTheme.controlRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FlowQuotaTheme.controlRadius, style: .continuous)
                    .strokeBorder(FlowQuotaTheme.border, lineWidth: 0.8)
            )
            .contentShape(RoundedRectangle(cornerRadius: FlowQuotaTheme.controlRadius, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .modifier(FlowQuotaInteractionFeedback())
    }
}

struct FlowQuotaTextButtonStyle: ButtonStyle {
    var emphasized = false
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font((controlSize == .small ? Font.caption : .subheadline).weight(emphasized ? .semibold : .medium))
            .foregroundStyle(emphasized ? FlowQuotaTheme.accent : FlowQuotaTheme.muted)
            .padding(.horizontal, controlSize == .small ? 6 : 8)
            .padding(.vertical, 2)
            .background(
                emphasized ? FlowQuotaTheme.accent.opacity(0.10) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(configuration.isPressed ? 0.68 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .modifier(FlowQuotaInteractionFeedback())
    }
}

/// Interaction feedback leaves the label's geometry unchanged during disable.
struct FlowQuotaInteractionFeedback: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .opacity(isEnabled ? 1 : 0.42)
    }
}

/// Row actions keep their existing spacing and full-row hit area.
struct FlowQuotaRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(FlowQuotaTheme.accent.opacity(configuration.isPressed ? 0.08 : 0),
                        in: RoundedRectangle(cornerRadius: FlowQuotaTheme.controlRadius))
            .contentShape(Rectangle())
            .modifier(FlowQuotaInteractionFeedback())
    }
}

extension View {
    func settingsAction(prominent: Bool = false) -> some View {
        modifier(SettingsActionStyle(prominent: prominent))
    }

    func flowQuotaTextAction(emphasized: Bool = false) -> some View {
        buttonStyle(FlowQuotaTextButtonStyle(emphasized: emphasized))
    }
}
