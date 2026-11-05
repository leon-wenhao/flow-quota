import AppKit
import SwiftUI

/// Selected concept C: shared vector geometry for the app, panel and template item.
/// Bars represent observed usage; the detached dot is a visual threshold cue.
struct FlowQuotaGlyph: Shape {
    enum Part: Int, CaseIterable {
        case usage, accent

        /// PNG, SwiftUI and SVG export all use this single palette.
        var gradientHex: [UInt32] {
            switch self {
            case .usage: [0xE6FFF5, 0xB5E8DB]
            case .accent: [0x86F4D4, 0x42DAB6]
            }
        }
    }
    let part: Part

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let capsule = CGSize(width: 7, height: 7)
        switch part {
        case .usage:
            path.addRoundedRect(in: CGRect(x: 22, y: 49, width: 14, height: 29), cornerSize: capsule)
            path.addRoundedRect(in: CGRect(x: 43, y: 34, width: 14, height: 44), cornerSize: capsule)
        case .accent:
            path.addRoundedRect(in: CGRect(x: 64, y: 40, width: 14, height: 38), cornerSize: capsule)
            path.addRoundedRect(in: CGRect(x: 64, y: 20, width: 14, height: 13), cornerSize: capsule)
        }
        let side = min(rect.width, rect.height)
        return path.applying(CGAffineTransform(scaleX: side / 100, y: side / 100))
            .applying(CGAffineTransform(translationX: rect.midX - side / 2, y: rect.midY - side / 2))
    }
}

private enum BrandPalette {
    static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

struct FlowQuotaSymbol: View {
    var body: some View {
        ZStack {
            ForEach(FlowQuotaGlyph.Part.allCases, id: \.rawValue) { part in
                FlowQuotaGlyph(part: part).fill(LinearGradient(
                    colors: part.gradientHex.map(BrandPalette.color),
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// Matches the selected preview, with transparent outer margins and vector rendering.
struct FlowQuotaAppIcon: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.185, style: .continuous)
                    .fill(LinearGradient(colors: [0x263C40, 0x11282D, 0x0B1B21].map(BrandPalette.color),
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        RoundedRectangle(cornerRadius: side * 0.185, style: .continuous)
                            .strokeBorder(.white.opacity(0.22), lineWidth: side / 512)
                    }
                    .frame(width: side * 0.8125, height: side * 0.8125)
                    .shadow(color: .black.opacity(0.16), radius: side * 0.018, y: side * 0.018)
                FlowQuotaSymbol()
                    .shadow(color: .black.opacity(0.08), radius: side * 0.01, y: side * 0.008)
                    .frame(width: side * 0.67, height: side * 0.67)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

@MainActor enum BrandIdentity {
    /// AppKit re-renders at display scale; template alpha lets the system choose
    /// light/dark menu-bar colors. No colored tile or raster decoding at runtime.
    static let menuBarImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { @Sendable rect in
            NSColor.black.setFill()
            for part in FlowQuotaGlyph.Part.allCases {
                let path = FlowQuotaGlyph(part: part).path(in: rect.insetBy(dx: 0.5, dy: 0.5))
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                context.addPath(path.cgPath)
                context.fillPath()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Flow Quota"
        return image
    }()
}
