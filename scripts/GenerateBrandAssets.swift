import AppKit
import Foundation
import SwiftUI

/// Compile alongside BrandIdentity.swift: generated PNG/SVG and ICNS share the UI geometry.
@main @MainActor struct GenerateBrandAssets {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw Failure.message("Usage: GenerateBrandAssets <brand-output-folder> <iconset-folder>")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let iconset = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = size * scale
                let suffix = scale == 2 ? "@2x" : ""
                try png(FlowQuotaAppIcon(), size: pixels).write(
                    to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
            }
        }
        try png(FlowQuotaAppIcon(), size: 1024).write(to: output.appendingPathComponent("app-icon.png"))
        try png(FlowQuotaAppIcon(), size: 512).write(to: output.appendingPathComponent("logo-preview.png"))
        try png(FlowQuotaSymbol(), size: 1024).write(to: output.appendingPathComponent("logo-mark.png"))
        let parts = FlowQuotaGlyph.Part.allCases.map { part in
            let path = FlowQuotaGlyph(part: part).path(in: CGRect(x: 0, y: 0, width: 100, height: 100))
            return "<path d=\"\(svgPath(path.cgPath))\" fill=\"url(#part\(part.rawValue))\"/>"
        }.joined(separator: "\n")
        let gradients = FlowQuotaGlyph.Part.allCases.map { part in
            let stops = part.gradientHex.enumerated().map { index, hex in
                let offset = Double(index) / Double(part.gradientHex.count - 1)
                return String(format: "<stop offset=\"%.1f\" stop-color=\"#%06x\"/>", offset, hex)
            }.joined()
            return "<linearGradient id=\"part\(part.rawValue)\" x1=\"0\" y1=\"0\" x2=\"1\" y2=\"1\">\(stops)</linearGradient>"
        }.joined(separator: "\n")
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" role="img" aria-label="Flow Quota">
          <defs>\(gradients)</defs>
          \(parts)
        </svg>
        """
        try Data(svg.utf8).write(to: output.appendingPathComponent("logo-mark.svg"))
        print("Generated Flow Quota brand assets in \(output.path)")
    }

    static func png(_ view: some View, size: Int) throws -> Data {
        let renderer = ImageRenderer(content: view.frame(width: CGFloat(size), height: CGFloat(size)))
        renderer.scale = 1
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw Failure.message("Failed to render \(size)-pixel icon")
        }
        return data
    }

    /// Export the actual vector outlines, avoiding a second hand-edited logo.
    static func svgPath(_ path: CGPath) -> String {
        var commands: [String] = []
        func point(_ point: CGPoint) -> String {
            String(format: "%.4f %.4f", locale: Locale(identifier: "en_US_POSIX"), point.x, point.y)
        }
        path.applyWithBlock { pointer in
            let item = pointer.pointee
            switch item.type {
            case .moveToPoint: commands.append("M" + point(item.points[0]))
            case .addLineToPoint: commands.append("L" + point(item.points[0]))
            case .addQuadCurveToPoint: commands.append("Q" + point(item.points[0]) + " " + point(item.points[1]))
            case .addCurveToPoint:
                commands.append("C" + point(item.points[0]) + " " + point(item.points[1]) + " " + point(item.points[2]))
            case .closeSubpath: commands.append("Z")
            @unknown default: break
            }
        }
        return commands.joined(separator: " ")
    }

    enum Failure: Error { case message(String) }
}
