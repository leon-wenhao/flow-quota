import SwiftUI

/// Shared visual language for the settings window and compact menu-bar surfaces.
/// Colors use AppKit semantic colors so light and dark appearance stay native.
enum FlowQuotaTheme {
    static let accent = Color(nsColor: .controlAccentColor)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let cardFill = Color(nsColor: .controlBackgroundColor)
    static let inputFill = Color(nsColor: .textBackgroundColor)
    static let border = Color(nsColor: .separatorColor).opacity(0.55)
    static let muted = Color(nsColor: .secondaryLabelColor)
    static let cardRadius: CGFloat = 14
    static let controlRadius: CGFloat = 9
    static let controlHeight: CGFloat = 36
}

struct FlowQuotaCardModifier: ViewModifier {
    var padding: CGFloat = 16
    var prominent = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                prominent ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(FlowQuotaTheme.cardFill.opacity(0.72)),
                in: RoundedRectangle(cornerRadius: FlowQuotaTheme.cardRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FlowQuotaTheme.cardRadius, style: .continuous)
                    .strokeBorder(FlowQuotaTheme.border, lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
    }
}

struct FlowQuotaControlModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 11)
            .frame(minHeight: FlowQuotaTheme.controlHeight)
            .background(FlowQuotaTheme.inputFill.opacity(0.82), in: RoundedRectangle(cornerRadius: FlowQuotaTheme.controlRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: FlowQuotaTheme.controlRadius, style: .continuous)
                    .strokeBorder(FlowQuotaTheme.border, lineWidth: 0.8)
            )
    }
}

enum FlowQuotaStepperLayout {
    case inline
    case stacked
}

/// A compact, consistent segmented control for the app's short option lists.
struct FlowQuotaSegmentedControl<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    var accessibilityLabel: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(FlowQuotaSegmentButtonStyle(isSelected: selection == option))
                .modifier(FlowQuotaInteractionFeedback())
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
        .padding(2)
        .background(FlowQuotaTheme.inputFill.opacity(0.78), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(FlowQuotaTheme.border, lineWidth: 0.8)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel ?? "选项")
    }
}

private struct FlowQuotaSegmentButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? Color.primary : FlowQuotaTheme.muted)
            .frame(minHeight: 26)
            // Hit testing must include the expanded option, including transparent unselected padding.
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(
                isSelected ? AnyShapeStyle(FlowQuotaTheme.accent.opacity(0.12)) : AnyShapeStyle(Color.clear),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(FlowQuotaTheme.accent.opacity(0.2), lineWidth: 0.8)
                }
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// One native switch style keeps keyboard, accessibility and confirmed-state semantics.
struct FlowQuotaToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(isOn: configuration.$isOn) { configuration.label }
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(FlowQuotaTheme.accent)
    }
}

struct FlowQuotaStepper: View {
    let title: String
    let suffix: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var layout: FlowQuotaStepperLayout = .stacked

    var body: some View {
        Group {
            switch layout {
            case .inline:
                HStack(spacing: 12) {
                    Text(title).frame(maxWidth: .infinity, alignment: .leading)
                    control
                }
            case .stacked:
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.subheadline)
                    control
                }
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue("\(value) \(suffix)")
    }

    private var control: some View {
        HStack(spacing: 0) {
            Text("\(value) \(suffix)")
                .font(.subheadline.weight(.medium).monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .center)
            Divider().frame(height: 20)
            HStack(spacing: 2) {
                stepperButton(systemName: "minus", enabled: value > range.lowerBound) {
                    value = max(range.lowerBound, value - 1)
                }
                stepperButton(systemName: "plus", enabled: value < range.upperBound) {
                    value = min(range.upperBound, value + 1)
                }
            }
            .frame(width: 82)
        }
        .frame(width: 284, height: FlowQuotaTheme.controlHeight)
        .background(FlowQuotaTheme.inputFill.opacity(0.82), in: RoundedRectangle(cornerRadius: FlowQuotaTheme.controlRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: FlowQuotaTheme.controlRadius, style: .continuous)
                .strokeBorder(FlowQuotaTheme.border, lineWidth: 0.8)
        )
    }

    private func stepperButton(systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.caption.weight(.bold))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(FlowQuotaRowButtonStyle())
        .accessibilityLabel(systemName == "minus" ? "减少\(title)" : "增加\(title)")
        .foregroundStyle(enabled ? FlowQuotaTheme.accent : FlowQuotaTheme.muted.opacity(0.45))
        .disabled(!enabled)
    }
}

extension View {
    func flowQuotaCard(padding: CGFloat = 16, prominent: Bool = false) -> some View {
        modifier(FlowQuotaCardModifier(padding: padding, prominent: prominent))
    }

    func flowQuotaControl() -> some View {
        modifier(FlowQuotaControlModifier())
    }

    func flowQuotaPageTitle() -> some View {
        font(.system(size: 23, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.bottom, 2)
    }

    func flowQuotaSecondaryText() -> some View {
        font(.caption).foregroundStyle(FlowQuotaTheme.muted)
    }
}
