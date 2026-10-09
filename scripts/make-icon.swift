import AppKit

// Draws the app icon and writes Resources/AppIcon.icns.
// Run: swift scripts/make-icon.swift

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// Draws the icon into the current graphics context at `size` pixels.
func render(size: CGFloat) {
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let inset = size * 0.08
    let body = rect.insetBy(dx: inset, dy: inset)
    let path = NSBezierPath(roundedRect: body, xRadius: size * 0.22, yRadius: size * 0.22)

    // Dark glass body with a soft top highlight.
    let gradient = NSGradient(colors: [
        NSColor(calibratedWhite: 0.16, alpha: 1),
        NSColor(calibratedWhite: 0.06, alpha: 1),
    ])!
    gradient.draw(in: path, angle: -90)
    NSColor(calibratedWhite: 1, alpha: 0.10).setStroke()
    path.lineWidth = max(1, size * 0.01)
    path.stroke()

    // The clickpad.
    let pad = NSRect(
        x: body.minX + body.width * 0.22,
        y: body.minY + body.height * 0.40,
        width: body.width * 0.56,
        height: body.height * 0.40
    )
    let padPath = NSBezierPath(roundedRect: pad, xRadius: size * 0.09, yRadius: size * 0.09)
    NSColor(calibratedWhite: 1, alpha: 0.12).setFill()
    padPath.fill()

    // Three buttons.
    let buttonSize = body.width * 0.12
    let y = body.minY + body.height * 0.20
    for index in 0..<3 {
        let x = body.minX + body.width * (0.26 + CGFloat(index) * 0.18)
        let dot = NSBezierPath(ovalIn: NSRect(x: x, y: y, width: buttonSize, height: buttonSize))
        NSColor(calibratedWhite: 1, alpha: index == 1 ? 0.28 : 0.14).setFill()
        dot.fill()
    }

    // A small accent ring in the pad centre.
    let ring = NSBezierPath(ovalIn: NSRect(
        x: pad.midX - size * 0.045, y: pad.midY - size * 0.045, width: size * 0.09, height: size * 0.09
    ))
    NSColor(calibratedRed: 0.35, green: 0.60, blue: 1.0, alpha: 0.9).setStroke()
    ring.lineWidth = max(1.5, size * 0.018)
    ring.stroke()
}

func write(size: Int, scale: Int) {
    let pixels = size * scale
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // The context scales points to pixels on its own.
    render(size: CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
    try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
}

for size in [16, 32, 128, 256, 512] {
    write(size: size, scale: 1)
    write(size: size, scale: 2)
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
