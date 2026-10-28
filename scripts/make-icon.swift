import AppKit

// Vector icon drawn directly into local bitmap contexts; no screen capture or UI launch.
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let factor = CGFloat(pixels) / 1024
        let transform = AffineTransform(scale: factor)
        (transform as NSAffineTransform).concat()
        NSColor(calibratedWhite: 0.14, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 204, yRadius: 204).fill()
        NSColor.white.setStroke()
        let back = NSBezierPath(roundedRect: NSRect(x: 340, y: 436, width: 480, height: 350), xRadius: 34, yRadius: 34)
        back.lineWidth = 38; back.stroke()
        NSColor(calibratedWhite: 0.14, alpha: 1).setFill()
        let front = NSBezierPath(roundedRect: NSRect(x: 204, y: 290, width: 480, height: 350), xRadius: 34, yRadius: 34)
        front.fill(); front.lineWidth = 38; front.stroke()
        let base = NSBezierPath()
        base.move(to: NSPoint(x: 444, y: 290)); base.line(to: NSPoint(x: 444, y: 218))
        base.move(to: NSPoint(x: 346, y: 218)); base.line(to: NSPoint(x: 542, y: 218))
        base.lineWidth = 38; base.lineCapStyle = .round; base.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
