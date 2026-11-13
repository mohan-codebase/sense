import AppKit

/// Sense branding: an app mark and a minimal chip silhouette for the menu bar.
enum SenseMark {
    static func path(in rect: CGRect) -> CGPath {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        let path = CGMutablePath()
        path.move(to: p(0.76, 0.77))
        path.addCurve(to: p(0.26, 0.69), control1: p(0.57, 0.97), control2: p(0.26, 0.89))
        path.addCurve(to: p(0.50, 0.50), control1: p(0.26, 0.53), control2: p(0.34, 0.52))
        path.addCurve(to: p(0.74, 0.31), control1: p(0.66, 0.48), control2: p(0.74, 0.47))
        path.addCurve(to: p(0.24, 0.23), control1: p(0.74, 0.11), control2: p(0.43, 0.03))
        return path
    }

    static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // Match the outlined chip used by the app icon.
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(1.05)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            for offset: CGFloat in [6.5, 9, 11.5] {
                context.move(to: CGPoint(x: offset, y: 2))
                context.addLine(to: CGPoint(x: offset, y: 4))
                context.move(to: CGPoint(x: offset, y: 14))
                context.addLine(to: CGPoint(x: offset, y: 16))
                context.move(to: CGPoint(x: 2, y: offset))
                context.addLine(to: CGPoint(x: 4, y: offset))
                context.move(to: CGPoint(x: 14, y: offset))
                context.addLine(to: CGPoint(x: 16, y: offset))
            }
            context.strokePath()
            context.addPath(CGPath(roundedRect: CGRect(x: 4, y: 4, width: 10, height: 10), cornerWidth: 1.7, cornerHeight: 1.7, transform: nil))
            context.strokePath()
            context.addPath(CGPath(roundedRect: CGRect(x: 6.8, y: 6.8, width: 4.4, height: 4.4), cornerWidth: 0.7, cornerHeight: 0.7, transform: nil))
            context.strokePath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Sense — system monitor"
        return image
    }
}
