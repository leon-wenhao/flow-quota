import AppKit
import SwiftUI
import Testing
@testable import FlowQuotaApp

@MainActor struct UsageTimeRangePickerTests {
    private var day: Date { Calendar.current.startOfDay(for: Date()) }

    @Test func editingCommitsOnlyDisplayedMinutesAndDisabledFieldRejectsActions() {
        var selected = day
        let binding = Binding(get: { selected }, set: { selected = $0 })
        let coordinator = NativeUsageTimeField.Coordinator(selection: binding)
        let picker = NSDatePicker()
        picker.dateValue = day.addingTimeInterval(17 * 3_600 + 26 * 60 + 43)
        coordinator.changed(picker)
        #expect(selected == day.addingTimeInterval(17 * 3_600 + 26 * 60))
        picker.isEnabled = false
        picker.dateValue = day.addingTimeInterval(10 * 3_600)
        coordinator.changed(picker)
        #expect(selected == day.addingTimeInterval(17 * 3_600 + 26 * 60))
    }

    @Test func nativeFieldHasNoStepperAndPaddingFocusesTheEditor() throws {
        _ = NSApplication.shared
        let field = UsageTimeFieldView(frame: NSRect(x: 0, y: 0, width: 260, height: 36))
        field.label.stringValue = "开始时间"
        let window = NSWindow(contentRect: field.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = field
        defer { window.close() }
        window.makeFirstResponder(nil)
        field.layoutSubtreeIfNeeded()
        #expect(field.picker.datePickerStyle == .textField)
        #expect(field.picker.datePickerElements == .hourMinute)
        #expect(field.hitTest(NSPoint(x: 4, y: 4)) === field)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: NSPoint(x: 4, y: 4), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        field.mouseDown(with: event)
        #expect(window.firstResponder === field.picker)
        field.picker.isEnabled = false
        window.makeFirstResponder(nil)
        field.mouseDown(with: event)
        #expect(window.firstResponder !== field.picker)
    }

    @Test(arguments: [CGFloat(300), CGFloat(560)], [false, true])
    func layoutsAndValidationRemainReadable(width: CGFloat, invalid: Bool) throws {
        _ = NSApplication.shared
        let start = day.addingTimeInterval(9 * 3_600)
        let end = invalid ? start : day.addingTimeInterval(17 * 3_600 + 26 * 60)
        let host = NSHostingView(rootView: UsageTimeRangePicker(start: .constant(start), end: .constant(end),
            bounds: day...day.addingTimeInterval(18 * 3_600)).frame(width: width))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width == width)
        #expect(host.fittingSize.height <= (width < 400 ? 120 : 72))
        let editors = descendants(host).compactMap { $0 as? NSDatePicker }
        #expect(editors.count == 2)
        #expect(Set(editors.compactMap { $0.accessibilityLabel() }) == ["开始时间", "结束时间"])
        #expect(editors.allSatisfy { $0.minDate == day && $0.maxDate == day.addingTimeInterval(18 * 3_600) })
    }

    @Test func lightAndDarkNativePreviewUsesSyntheticTimes() throws {
        _ = NSApplication.shared
        let start = day
        let end = day.addingTimeInterval(17 * 3_600 + 26 * 60)
        let content = VStack(spacing: 0) {
            ForEach([false, true], id: \.self) { dark in
                VStack(alignment: .leading, spacing: 12) {
                    Text("自定义时段 · 样式预览").font(.headline)
                    UsageTimeRangePicker(start: .constant(start), end: .constant(end), bounds: day...end)
                }
                .padding(24).frame(width: 640)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
                .preferredColorScheme(dark ? .dark : .light)
            }
        }
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 250),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        let png = try #require(image.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/flow-quota-time-range-preview.png"))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
