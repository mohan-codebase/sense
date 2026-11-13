import AppKit
import ImageIO
import UniformTypeIdentifiers

@main
struct IOSIconGenerator {
    static func main() throws {
        let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSGradient(colors: [NSColor(srgbRed: 0.08, green: 0.16, blue: 0.25, alpha: 1), NSColor(srgbRed: 0.025, green: 0.045, blue: 0.09, alpha: 1)])!
            .draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024), angle: -65)
        context.addPath(SenseMark.path(in: CGRect(x: 128, y: 128, width: 768, height: 768)))
        context.setLineWidth(98); context.setLineCap(.round); context.setLineJoin(.round)
        context.replacePathWithStrokedPath(); context.clip()
        NSGradient(colors: [NSColor(srgbRed: 0.08, green: 0.72, blue: 1, alpha: 1), NSColor(srgbRed: 0.13, green: 1, blue: 0.70, alpha: 1)])!
            .draw(from: NSPoint(x: 300, y: 200), to: NSPoint(x: 700, y: 820), options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
        NSGraphicsContext.restoreGraphicsState()
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
