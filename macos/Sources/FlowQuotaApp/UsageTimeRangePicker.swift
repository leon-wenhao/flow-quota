import AppKit
import SwiftUI

/// Current-day minute selection. Native fields preserve keyboard editing and accessibility.
struct UsageTimeRangePicker: View {
    @Binding var start: Date
    @Binding var end: Date
    let bounds: ClosedRange<Date>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    field("开始时间", selection: $start)
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    field("结束时间", selection: $end)
                }
                VStack(spacing: 8) {
                    field("开始时间", selection: $start)
                    field("结束时间", selection: $end)
                }
            }
            if start >= end {
                Label("开始时间须早于结束时间", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func field(_ title: String, selection: Binding<Date>) -> some View {
        NativeUsageTimeField(title: title, selection: selection, bounds: bounds)
            .frame(minWidth: 210, maxWidth: .infinity, minHeight: FlowQuotaTheme.controlHeight)
            .background(FlowQuotaTheme.inputFill.opacity(0.82), in: RoundedRectangle(cornerRadius: FlowQuotaTheme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: FlowQuotaTheme.controlRadius)
                .strokeBorder(FlowQuotaTheme.border, lineWidth: 0.8))
    }

    static func minute(_ date: Date) -> Date {
        Calendar.current.dateInterval(of: .minute, for: date)?.start ?? date
    }
}

struct NativeUsageTimeField: NSViewRepresentable {
    let title: String
    @Binding var selection: Date
    let bounds: ClosedRange<Date>
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> UsageTimeFieldView {
        let view = UsageTimeFieldView()
        view.picker.target = context.coordinator
        view.picker.action = #selector(Coordinator.changed(_:))
        return view
    }

    func updateNSView(_ view: UsageTimeFieldView, context: Context) {
        context.coordinator.selection = $selection
        view.label.stringValue = title
        view.picker.setAccessibilityLabel(title)
        view.picker.calendar = .current
        view.picker.timeZone = .current
        view.picker.locale = .current
        view.picker.minDate = bounds.lowerBound
        view.picker.maxDate = bounds.upperBound
        // Polling must not reset a selected hour/minute segment while the user types.
        let value = min(max(selection, bounds.lowerBound), bounds.upperBound)
        if view.picker.dateValue != value { view.picker.dateValue = value }
        view.picker.isEnabled = isEnabled
        view.alphaValue = isEnabled ? 1 : 0.45
    }

    @MainActor final class Coordinator: NSObject {
        var selection: Binding<Date>
        init(selection: Binding<Date>) { self.selection = selection }

        @objc func changed(_ picker: NSDatePicker) {
            guard picker.isEnabled else { return }
            selection.wrappedValue = UsageTimeRangePicker.minute(picker.dateValue)
        }
    }
}

/// Padding and label clicks focus the same native editor as a click on the time.
final class UsageTimeFieldView: NSView {
    let label = NSTextField(labelWithString: "")
    let picker = NSDatePicker()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        picker.datePickerStyle = .textField
        picker.datePickerMode = .single
        picker.datePickerElements = .hourMinute
        picker.isBordered = false
        picker.isBezeled = false
        picker.drawsBackground = false
        picker.toolTip = "点击编辑小时或分钟；也可用方向键调整。"
        picker.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        picker.setContentHuggingPriority(.required, for: .horizontal)
        picker.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        for view in [label, picker] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            picker.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            picker.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            picker.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: 190, height: FlowQuotaTheme.controlHeight) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === label ? self : hit
    }

    override func mouseDown(with event: NSEvent) {
        guard picker.isEnabled else { return }
        window?.makeFirstResponder(picker)
    }
}
