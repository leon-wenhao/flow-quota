import AppKit

/// A fixed, light Finder canvas: only the arrow and instructions are rasterized;
/// the app, Applications link and instructions file remain real draggable items.
@main @MainActor struct GenerateDMGBackground {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "FlowQuotaDMG", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Usage: GenerateDMGBackground <output.tiff>"])
        }
        let size = NSSize(width: 720, height: 500)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedRed: 0.97, green: 0.98, blue: 0.98, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let ink = NSColor(calibratedRed: 0.08, green: 0.18, blue: 0.20, alpha: 1)
        let muted = NSColor(calibratedRed: 0.30, green: 0.38, blue: 0.39, alpha: 1)
        let accent = NSColor(calibratedRed: 0.08, green: 0.55, blue: 0.47, alpha: 1)
        text("Flow Quota", x: 42, top: 28, size: 28, weight: .semibold, color: ink)
        text("拖到“应用程序”，即可安装", x: 43, top: 69, size: 14, color: muted)

        // Finder item centers use a top-left origin; AppKit drawing uses bottom-left.
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 316, y: 327))
        arrow.line(to: NSPoint(x: 390, y: 327))
        arrow.line(to: NSPoint(x: 378, y: 339))
        arrow.move(to: NSPoint(x: 390, y: 327))
        arrow.line(to: NSPoint(x: 378, y: 315))
        arrow.lineWidth = 5
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        accent.setStroke()
        arrow.stroke()

        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 30, y: 30, width: 660, height: 176),
                     xRadius: 16, yRadius: 16).fill()
        text("安装后，从“应用程序”打开 Flow Quota", x: 50, top: 315,
             size: 17, weight: .medium, color: ink)
        text("首次打开若被 macOS 阻止，请前往", x: 50, top: 353, size: 13, color: muted)
        text("系统设置 → 隐私与安全性 → 仍要打开", x: 50, top: 376, size: 13, color: muted)
        text("当前为 ad-hoc 签名，未经 Apple 公证。", x: 50, top: 427, size: 12, color: muted)
        image.unlockFocus()

        // Two explicit bitmap sizes preserve point dimensions on Retina displays.
        let representations = try [1, 2].map { scale -> NSBitmapImageRep in
            let pixels = NSSize(width: size.width * CGFloat(scale), height: size.height * CGFloat(scale))
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                throw NSError(domain: "FlowQuotaDMG", code: 2)
            }
            bitmap.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            image.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            return bitmap
        }
        guard let data = NSBitmapImageRep.tiffRepresentationOfImageReps(in: representations) else {
            throw NSError(domain: "FlowQuotaDMG", code: 3)
        }
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }

    static func text(_ string: String, x: CGFloat, top: CGFloat, size: CGFloat,
                     weight: NSFont.Weight = .regular, color: NSColor) {
        (string as NSString).draw(at: NSPoint(x: x, y: 500 - top - size * 1.25), withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
        ])
    }
}
