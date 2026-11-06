import AppKit
import SwiftUI
import Testing
@testable import FlowQuotaApp

/// Dispatch local mouse events into fixture windows, without sampling or global input permissions.
@Suite(.serialized) @MainActor
struct ControlHitAreaTests {
    @Test(arguments: [2, 3], [false, true])
    func segmentedOptionsRespondOutsideTheirText(count: Int, disabled: Bool) async {
        let selection = Selection()
        let titles = count == 2 ? ["热点／高成本", "普通网络"] : ["跟随系统", "浅色", "深色"]
        let view = FlowQuotaSegmentedControl(options: Array(0..<count),
            selection: Binding(get: { selection.value }, set: { selection.value = $0 }),
            title: { titles[$0] }).disabled(disabled)
        let fixture = await MouseFixture(view, size: NSSize(width: 360, height: 30))
        defer { fixture.window.close() }
        let optionWidth = (360 - 4 - CGFloat(count - 1) * 3) / CGFloat(count)
        // Force a different selection before each click so an ignored click cannot pass.
        for option in 0..<count {
            let origin = 2 + CGFloat(option) * (optionWidth + 3)
            for point in [NSPoint(x: origin + 8, y: 6),
                          NSPoint(x: origin + optionWidth - 8, y: 24)] {
                let previous = (option + 1) % count
                selection.value = previous
                await fixture.settle()
                fixture.click(point)
                await fixture.settle()
                #expect(selection.value == (disabled ? previous : option),
                        "Option \(option) at \(point), disabled: \(disabled)")
            }
        }
    }

    @Test func disclosureHeaderRespondsAcrossTheWholeRow() async {
        let selection = Selection()
        let view = DisclosureGroup(isExpanded: Binding(
            get: { selection.value == 1 }, set: { selection.value = $0 ? 1 : 0 })) {
                Text("测试详情")
            } label: { Text("详细信息") }
            .disclosureGroupStyle(FullRowDisclosureStyle())
            .frame(width: 240, height: 100, alignment: .topLeading)
        let fixture = await MouseFixture(view)
        defer { fixture.window.close() }
        fixture.click(NSPoint(x: 225, y: 14))
        await fixture.settle()
        #expect(selection.value == 1)
        fixture.click(NSPoint(x: 220, y: 20))
        await fixture.settle()
        #expect(selection.value == 0)
    }

    @Test(arguments: ButtonKind.allCases, [false, true])
    func sharedButtonsRespondInPaddingAndRespectDisabledState(kind: ButtonKind, disabled: Bool) async {
        let actions = Selection()
        let fixture = await MouseFixture(kind.button { actions.value += 1 }.disabled(disabled))
        defer { fixture.window.close() }
        let size = fixture.host.bounds.size
        for point in [NSPoint(x: 3, y: size.height / 2),
                      NSPoint(x: size.width - 3, y: size.height / 2),
                      NSPoint(x: size.width / 2, y: 3),
                      NSPoint(x: size.width / 2, y: size.height - 3)] {
            let before = actions.value
            fixture.click(point)
            await fixture.settle()
            #expect(actions.value == before + (disabled ? 0 : 1), "\(kind), disabled: \(disabled), at \(point)")
        }
    }

    enum ButtonKind: CaseIterable {
        case regular, prominent, icon, text, smallText, row

        @MainActor @ViewBuilder func button(action: @escaping () -> Void) -> some View {
            switch self {
            case .regular, .prominent:
                Button(action: action) { Text("保存").frame(width: 180) }
                    .settingsAction(prominent: self == .prominent)
            case .icon:
                Button(action: action) { Image(systemName: "gearshape") }
                    .buttonStyle(FlowQuotaIconButtonStyle())
            case .text:
                Button("返回", action: action).flowQuotaTextAction()
            case .smallText:
                Button("返回", action: action).flowQuotaTextAction().controlSize(.small)
            case .row:
                Button(action: action) {
                    Text("整行入口").frame(width: 200, height: 34, alignment: .leading)
                }
                .buttonStyle(FlowQuotaRowButtonStyle())
            }
        }
    }

    @Observable final class Selection {
        var value = 0
    }
}

@MainActor private final class MouseFixture<Content: View> {
    let host: NSHostingView<Content>
    let window: NSWindow

    init(_ view: Content, size: NSSize? = nil) async {
        _ = NSApplication.shared
        host = NSHostingView(rootView: view)
        let size = size ?? host.fittingSize
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        window.orderFront(nil)
        await settle()
    }

    func settle() async {
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
    }

    func click(_ point: NSPoint) {
        // Fixture coordinates use a top-left origin, matching SwiftUI layout.
        let location = NSPoint(x: point.x, y: host.bounds.height - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            window.sendEvent(event)
        }
    }
}
