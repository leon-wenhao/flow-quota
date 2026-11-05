import AppKit
import SwiftUI

/// Static review sheet: no application services, sampling, network or database access.
@main @MainActor struct RenderConcepts {
    static func main() throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        for concept in LogoConcept.allCases {
            try render(ConceptIcon(concept: concept), width: 1024, height: 1024)
                .write(to: folder.appendingPathComponent("\(concept.label)-\(concept.rawValue).png"))
            try render(ConceptMark(concept: concept, monochrome: true).environment(\.colorScheme, .light), width: 256, height: 256)
                .write(to: folder.appendingPathComponent("\(concept.label)-menu.png"))
            let paths = (0..<2).map { layer in
                "<path d=\"\(svgPath(concept.path(layer).cgPath))\" fill=\"url(#g\(layer))\"/>"
            }.joined(separator: "\n")
            let colors: [[String]] = switch concept {
            case .ribbon: [["#ffffff", "#e2f1ff"], ["#b9f5ff", "#70cfff"]]
            case .transfer: [["#429dff", "#175ce2"], ["#245fe7", "#0936ae"]]
            case .meter: [["#e6fff5", "#b5e8db"], ["#86f4d4", "#42dab6"]]
            }
            let gradients = colors.enumerated().map { i, c in
                "<linearGradient id=\"g\(i)\" x2=\"1\" y2=\"1\"><stop stop-color=\"\(c[0])\"/><stop offset=\"1\" stop-color=\"\(c[1])\"/></linearGradient>"
            }.joined()
            let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 100\"><defs>\(gradients)</defs>\(paths)</svg>"
            try Data(svg.utf8).write(to: folder.appendingPathComponent("\(concept.label)-mark.svg"))
        }
        try render(ReviewBoard(), width: 1500, height: 1080)
            .write(to: folder.appendingPathComponent("comparison.png"))
        print("Rendered three editable logo concepts and comparison sheet.")
    }

    static func render(_ view: some View, width: Int, height: Int) throws -> Data {
        let renderer = ImageRenderer(content: view.frame(width: CGFloat(width), height: CGFloat(height)))
        renderer.scale = 1
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    static func svgPath(_ path: CGPath) -> String {
        var result: [String] = []
        func point(_ p: CGPoint) -> String { String(format: "%.3f %.3f", locale: Locale(identifier: "en_US_POSIX"), p.x, p.y) }
        path.applyWithBlock { value in
            let p = value.pointee
            switch p.type {
            case .moveToPoint: result.append("M" + point(p.points[0]))
            case .addLineToPoint: result.append("L" + point(p.points[0]))
            case .addQuadCurveToPoint: result.append("Q" + point(p.points[0]) + " " + point(p.points[1]))
            case .addCurveToPoint: result.append("C" + point(p.points[0]) + " " + point(p.points[1]) + " " + point(p.points[2]))
            case .closeSubpath: result.append("Z")
            @unknown default: break
            }
        }
        return result.joined(separator: " ")
    }
}

struct ReviewBoard: View {
    private let ink = Color(hex: 0x17292C)
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("FLOW QUOTA").font(.custom("AvenirNext-DemiBold", size: 16)).tracking(4)
                    Text("让流量，一眼可见。")
                        .font(.custom("PingFangSC-Semibold", size: 48)).tracking(-1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Text("LOGO EXPLORATIONS / 02").font(.custom("AvenirNext-Medium", size: 12)).tracking(1.2)
                    Text("三种方向 · 应用图标与菜单栏预览")
                        .font(.custom("PingFangSC-Regular", size: 14)).foregroundStyle(ink.opacity(0.6))
                }
                .padding(.top, 5)
            }
            .padding(.bottom, 35)
            Rectangle().fill(ink.opacity(0.15)).frame(height: 1)
            HStack(alignment: .top, spacing: 34) {
                ForEach(LogoConcept.allCases, id: \.self) { concept in
                    conceptColumn(concept).frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 24)
            Spacer(minLength: 20)
            HStack(alignment: .center) {
                Text("更少元素 · 更清晰轮廓 · 可编辑矢量")
                    .font(.custom("PingFangSC-Regular", size: 15))
                Spacer()
                Text("仅为设计预览，尚未替换软件图标")
                    .font(.custom("PingFangSC-Regular", size: 13)).foregroundStyle(ink.opacity(0.55))
            }
        }
        .foregroundStyle(ink)
        .padding(58)
        .background(Color(hex: 0xF4F2ED))
    }

    private func conceptColumn(_ concept: LogoConcept) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(concept.label).font(.custom("AvenirNext-DemiBold", size: 16))
                Spacer()
                Text(concept == .ribbon ? "RECOMMENDED" : "ALTERNATIVE")
                    .font(.custom("AvenirNext-Medium", size: 10)).tracking(1.5)
                    .foregroundStyle(ink.opacity(0.5))
            }
            ZStack {
                RoundedRectangle(cornerRadius: 22)
                    .fill(concept == .transfer ? Color(hex: 0xE3E8F0) : Color(hex: 0xE9E7E1))
                ConceptIcon(concept: concept).frame(width: 326, height: 326)
            }
            .frame(height: 330).padding(.top, 15)
            Text(concept.title).font(.custom("PingFangSC-Semibold", size: 26)).padding(.top, 24)
            Text(concept.subtitle).font(.custom("PingFangSC-Regular", size: 15))
                .foregroundStyle(ink.opacity(0.6)).padding(.top, 7)
            HStack(alignment: .center, spacing: 18) {
                ConceptIcon(concept: concept).frame(width: 64, height: 64)
                ConceptIcon(concept: concept).frame(width: 40, height: 40)
                Text("64 / 40 px").font(.custom("AvenirNext-Medium", size: 11)).foregroundStyle(ink.opacity(0.45))
            }
            .padding(.top, 19)
            VStack(spacing: 0) {
                menuRow(concept, dark: false)
                menuRow(concept, dark: true)
            }
            .clipShape(RoundedRectangle(cornerRadius: 13))
            .padding(.top, 18)
            Text("菜单栏 · 18 px 单色图形")
                .font(.custom("PingFangSC-Regular", size: 12))
                .foregroundStyle(ink.opacity(0.5)).padding(.top, 10)
        }
    }

    private func menuRow(_ concept: LogoConcept, dark: Bool) -> some View {
        HStack(spacing: 7) {
            ConceptMark(concept: concept, monochrome: true).frame(width: 18, height: 18)
            Text("248 MB").font(.custom("AvenirNext-Medium", size: 12))
            Spacer()
            Image(systemName: "wifi").font(.system(size: 12))
            Image(systemName: "battery.100").font(.system(size: 16)).padding(.leading, 8)
            Text("09:41").font(.custom("AvenirNext-Medium", size: 12)).padding(.leading, 5)
        }
        .padding(.horizontal, 16).frame(height: 43)
        .foregroundStyle(dark ? Color.white : ink)
        .environment(\.colorScheme, dark ? .dark : .light)
        .background(dark ? Color(hex: 0x253033) : .white.opacity(0.85))
    }
}
