import SwiftUI

/// Preview geometry only. Shipping BrandIdentity and installed icons are unchanged.
enum LogoConcept: String, CaseIterable {
    case ribbon, transfer, meter
    var title: String {
        switch self { case .ribbon: "流带"; case .transfer: "双向流"; case .meter: "流量刻度" }
    }
    var subtitle: String {
        switch self {
        case .ribbon: "流动的 F · 鲜明、轻盈"
        case .transfer: "上传与下载 · 干净、直接"
        case .meter: "用量与阈值 · 安静、克制"
        }
    }
    var label: String {
        switch self { case .ribbon: "A"; case .transfer: "B"; case .meter: "C" }
    }
    var background: [Color] {
        switch self {
        case .ribbon: [Color(hex: 0x398FFF), Color(hex: 0x1757E9), Color(hex: 0x123BCC)]
        case .transfer: [Color(hex: 0xFFFFFF), Color(hex: 0xF2F4F9), Color(hex: 0xE5EAF3)]
        case .meter: [Color(hex: 0x263C40), Color(hex: 0x11282D), Color(hex: 0x0B1B21)]
        }
    }
    var colors: [[Color]] {
        switch self {
        case .ribbon: [[Color(hex: 0xFFFFFF), Color(hex: 0xE2F1FF)],
                       [Color(hex: 0xB9F5FF), Color(hex: 0x70CFFF)]]
        case .transfer: [[Color(hex: 0x429DFF), Color(hex: 0x175CE2)],
                         [Color(hex: 0x245FE7), Color(hex: 0x0936AE)]]
        case .meter: [[Color(hex: 0xE6FFF5), Color(hex: 0xB5E8DB)],
                      [Color(hex: 0x86F4D4), Color(hex: 0x42DAB6)]]
        }
    }
    /// All marks use a normalized 100-point canvas; the same shapes export to SVG.
    func path(_ layer: Int) -> Path {
        var p = Path()
        switch self {
        case .ribbon:
            if layer == 0 {
                p.move(to: CGPoint(x: 25, y: 78))
                p.addLine(to: CGPoint(x: 25, y: 40))
                p.addCurve(to: CGPoint(x: 49, y: 18), control1: CGPoint(x: 25, y: 25), control2: CGPoint(x: 34, y: 18))
                p.addLine(to: CGPoint(x: 79, y: 18))
                p.addLine(to: CGPoint(x: 72, y: 35))
                p.addLine(to: CGPoint(x: 50, y: 35))
                p.addCurve(to: CGPoint(x: 42, y: 44), control1: CGPoint(x: 44, y: 35), control2: CGPoint(x: 42, y: 38))
                p.addLine(to: CGPoint(x: 42, y: 66))
                p.addCurve(to: CGPoint(x: 30, y: 78), control1: CGPoint(x: 42, y: 73), control2: CGPoint(x: 37, y: 78))
                p.closeSubpath()
            } else {
                p.move(to: CGPoint(x: 25, y: 58))
                p.addCurve(to: CGPoint(x: 45, y: 43), control1: CGPoint(x: 29, y: 48), control2: CGPoint(x: 35, y: 43))
                p.addLine(to: CGPoint(x: 70, y: 43))
                p.addLine(to: CGPoint(x: 63, y: 60))
                p.addLine(to: CGPoint(x: 43, y: 60))
                p.addCurve(to: CGPoint(x: 25, y: 75), control1: CGPoint(x: 33, y: 60), control2: CGPoint(x: 27, y: 67))
                p.closeSubpath()
            }
        case .transfer:
            if layer == 0 {
                p.move(to: CGPoint(x: 29, y: 73))
                p.addLine(to: CGPoint(x: 29, y: 35))
                p.addCurve(to: CGPoint(x: 40, y: 24), control1: CGPoint(x: 29, y: 28), control2: CGPoint(x: 33, y: 24))
                p.addLine(to: CGPoint(x: 58, y: 24))
                p.move(to: CGPoint(x: 48, y: 14)); p.addLine(to: CGPoint(x: 59, y: 24)); p.addLine(to: CGPoint(x: 48, y: 34))
            } else {
                p.move(to: CGPoint(x: 71, y: 27))
                p.addLine(to: CGPoint(x: 71, y: 65))
                p.addCurve(to: CGPoint(x: 60, y: 76), control1: CGPoint(x: 71, y: 72), control2: CGPoint(x: 67, y: 76))
                p.addLine(to: CGPoint(x: 42, y: 76))
                p.move(to: CGPoint(x: 52, y: 66)); p.addLine(to: CGPoint(x: 41, y: 76)); p.addLine(to: CGPoint(x: 52, y: 86))
            }
            p = p.strokedPath(StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round))
        case .meter:
            if layer == 0 {
                p.addRoundedRect(in: CGRect(x: 22, y: 49, width: 14, height: 29), cornerSize: CGSize(width: 7, height: 7))
                p.addRoundedRect(in: CGRect(x: 43, y: 34, width: 14, height: 44), cornerSize: CGSize(width: 7, height: 7))
            } else {
                p.addRoundedRect(in: CGRect(x: 64, y: 40, width: 14, height: 38), cornerSize: CGSize(width: 7, height: 7))
                p.addRoundedRect(in: CGRect(x: 64, y: 20, width: 14, height: 13), cornerSize: CGSize(width: 7, height: 7))
            }
        }
        return p
    }
}

struct ConceptLayer: Shape {
    let concept: LogoConcept
    let layer: Int
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        return concept.path(layer).applying(CGAffineTransform(scaleX: side / 100, y: side / 100))
            .applying(CGAffineTransform(translationX: rect.midX - side / 2, y: rect.midY - side / 2))
    }
}

struct ConceptMark: View {
    let concept: LogoConcept
    var monochrome = false
    var body: some View {
        ZStack {
            ForEach(0..<2) { layer in
                ConceptLayer(concept: concept, layer: layer)
                    .fill(LinearGradient(colors: monochrome ? [.primary] : concept.colors[layer],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct ConceptIcon: View {
    let concept: LogoConcept
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.185, style: .continuous)
                    .fill(LinearGradient(colors: concept.background, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        RoundedRectangle(cornerRadius: s * 0.185, style: .continuous)
                            .strokeBorder(.white.opacity(concept == .transfer ? 0.8 : 0.22), lineWidth: s / 512)
                    }
                    .shadow(color: .black.opacity(0.16), radius: s * 0.018, y: s * 0.018)
                    .frame(width: s * 0.8125, height: s * 0.8125)
                ConceptMark(concept: concept)
                    .shadow(color: .black.opacity(concept == .ribbon ? 0.14 : 0.08), radius: s * 0.01, y: s * 0.008)
                    .frame(width: s * 0.67, height: s * 0.67)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}
