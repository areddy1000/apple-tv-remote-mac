import AppKit

/// Draws the now-playing artwork one time, at the size the UI shows it.
///
/// A view that decodes and scales the artwork in its body does it again on each update.
/// The store calls this only when the artwork changes, and the views show the result.
enum ArtworkRenderer {
    /// The pixels for each point. Retina screens use 2.
    private static let scale: CGFloat = 2

    /// Returns a bitmap of `side` points that the artwork fills, with round corners.
    /// - Parameter trailingMargin: Clear space on the right, in points.
    static func render(_ data: Data, side: CGFloat, cornerRadius: CGFloat, trailingMargin: CGFloat = 0) -> NSImage? {
        guard let source = NSImage(data: data) else { return nil }
        let size = NSSize(width: side + trailingMargin, height: side)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = size

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high

        let rect = NSRect(x: 0, y: 0, width: side, height: side)
        NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).addClip()
        // Fill the square and crop the long side, like a fill content mode.
        let aspect = source.size.width / max(source.size.height, 1)
        var drawRect = rect
        if aspect > 1 {
            drawRect.size.width = rect.height * aspect
            drawRect.origin.x = (rect.width - drawRect.width) / 2
        } else if aspect < 1 {
            drawRect.size.height = rect.width / aspect
            drawRect.origin.y = (rect.height - drawRect.height) / 2
        }
        source.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
        context.flushGraphics()

        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        image.isTemplate = false
        return image
    }
}
