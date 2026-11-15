import AppKit

// Preserve the original artwork and clip its opaque paper background to the Dock tile.
let arguments = CommandLine.arguments
guard (3...4).contains(arguments.count),
      let source = NSImage(contentsOfFile: arguments[1]) else {
    fatalError("Usage: swift scripts/build_icons.swift source.png output.iconset [transparent|light|dark]")
}
let background = arguments.count == 4 ? arguments[3] : "transparent"
guard ["transparent", "light", "dark"].contains(background) else { fatalError("Invalid icon appearance") }
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let canvas = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        context.cgContext.clear(canvas)
        // Mirror the reviewed character and its chair; the centred tile keeps its geometry.
        context.cgContext.translateBy(x:CGFloat(pixels),y:0)
        context.cgContext.scaleBy(x:-1,y:1)
        let contentRect: NSRect
        NSGraphicsContext.saveGraphicsState()
        if background == "transparent" {
            contentRect = canvas
        } else {
            // Match the ~80% opaque tile width of neighbouring Dock icons.
            let inset = CGFloat(pixels) * 0.10
            let tile = canvas.insetBy(dx: inset, dy: inset)
            (background == "dark" ? NSColor.black : NSColor.white).setFill()
            let outline = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.height * 0.225)
            outline.fill()
            outline.addClip() // The raster's white corners must never escape the rounded tile.
            contentRect = tile.insetBy(dx: tile.width * 0.03, dy: tile.height * 0.03)
        }
        let ratio = min(contentRect.width / source.size.width, contentRect.height / source.size.height)
        let size = NSSize(width: source.size.width * ratio, height: source.size.height * ratio)
        source.draw(in: NSRect(x: contentRect.midX - size.width / 2,
                              y: contentRect.midY - size.height / 2,
                              width: size.width, height: size.height),
                    from: .zero, operation: .sourceOver, fraction: 1)
        // The posture symbol is monochrome. Keep it legible on the black Dock tile.
        if background == "dark" {
            context.cgContext.setBlendMode(.sourceAtop)
            context.cgContext.setFillColor(NSColor.white.cgColor)
            // Tint only the symbol; the rounded tile must retain its black background.
            let mask = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: arguments[1])))!.cgImage!
            let rect = NSRect(x: contentRect.midX - size.width / 2,
                              y: contentRect.midY - size.height / 2,
                              width: size.width, height: size.height)
            context.cgContext.saveGState()
            context.cgContext.clip(to: rect, mask: mask)
            context.cgContext.fill(rect)
            context.cgContext.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let file = output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: file)
    }
}
