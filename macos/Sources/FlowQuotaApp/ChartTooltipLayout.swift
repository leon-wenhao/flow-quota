import SwiftUI

private struct ChartTooltipViewportKey: EnvironmentKey {
    static let defaultValue: CGRect? = nil
}

extension EnvironmentValues {
    /// Visible scroll content in global coordinates; excludes toolbar and footer.
    var chartTooltipViewport: CGRect? {
        get { self[ChartTooltipViewportKey.self] }
        set { self[ChartTooltipViewportKey.self] = newValue }
    }
}

/// ChartProxy expects plot-relative coordinates; hovering axes must not select data.
enum ChartTooltipLayout {
    /// A long tooltip may cover controls above the plot, but stays inside the
    /// visible scroll viewport even when the chart is partially scrolled away.
    static func visibleBounds(chartFrame: CGRect, viewport: CGRect?) -> CGRect {
        guard let viewport else { return CGRect(origin: .zero, size: chartFrame.size) }
        let relative = viewport.offsetBy(dx: -chartFrame.minX, dy: -chartFrame.minY)
        let left = max(0, relative.minX)
        let right = min(chartFrame.width, relative.maxX)
        return CGRect(x: left, y: relative.minY, width: max(0, right - left), height: relative.height)
    }

    static func plotLocation(_ location: CGPoint, in frame: CGRect) -> CGPoint? {
        guard frame.width > 0, frame.height > 0, frame.contains(location) else { return nil }
        return CGPoint(x: location.x - frame.minX, y: location.y - frame.minY)
    }

    /// Flip near the trailing/bottom edge and keep the card inside the supplied visible bounds.
    static func origin(at pointer: CGPoint, size: CGSize, bounds: CGRect) -> CGPoint {
        let inset: CGFloat = 4
        let gap: CGFloat = 12
        let minX = bounds.minX + inset
        let minY = bounds.minY + inset
        let maxX = max(minX, bounds.maxX - size.width - inset)
        let maxY = max(minY, bounds.maxY - size.height - inset)
        let x = pointer.x + gap <= maxX ? pointer.x + gap : pointer.x - gap - size.width
        let y = pointer.y + gap <= maxY ? pointer.y + gap : pointer.y - gap - size.height
        return CGPoint(x: min(max(x, minX), maxX), y: min(max(y, minY), maxY))
    }
}
