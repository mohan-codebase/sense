// Render the shared Sense mark as a macOS app icon.
import AppKit

@main
struct IconGenerator {
    static func main() throws {
        let size: CGFloat = 1024
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let body = rect.insetBy(dx: 100, dy: 100)
            let tile = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
            shadow.shadowBlurRadius = 24
            shadow.shadowOffset = NSSize(width: 0, height: -12)
            shadow.set()
            NSColor.black.setFill()
            tile.fill()
            NSGraphicsContext.restoreGraphicsState()

            NSColor.black.setFill()
            tile.fill()
            let rim = NSBezierPath(roundedRect: body.insetBy(dx: 1, dy: 1), xRadius: 184, yRadius: 184)
            NSColor.white.withAlphaComponent(0.18).setStroke()
            rim.lineWidth = 2
            rim.stroke()

            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            NSGraphicsContext.saveGraphicsState()
            // A clean, precision-drawn chip, adapted from the menu bar mark.
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setLineWidth(18)
            let chip = CGRect(x: 320, y: 320, width: 384, height: 384)
            context.addPath(CGPath(roundedRect: chip, cornerWidth: 64, cornerHeight: 64, transform: nil))
            context.strokePath()
            context.setLineWidth(16)
            for offset: CGFloat in [416, 512, 608] {
                context.move(to: CGPoint(x: offset, y: 254))
                context.addLine(to: CGPoint(x: offset, y: 320))
                context.move(to: CGPoint(x: offset, y: 704))
                context.addLine(to: CGPoint(x: offset, y: 770))
                context.move(to: CGPoint(x: 254, y: offset))
                context.addLine(to: CGPoint(x: 320, y: offset))
                context.move(to: CGPoint(x: 704, y: offset))
                context.addLine(to: CGPoint(x: 770, y: offset))
            }
            context.strokePath()
            context.setLineWidth(15)
            context.addPath(CGPath(roundedRect: CGRect(x: 426, y: 426, width: 172, height: 172), cornerWidth: 27, cornerHeight: 27, transform: nil))
            context.strokePath()
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
