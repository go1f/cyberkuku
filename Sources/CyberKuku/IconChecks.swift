import AppKit

@MainActor enum IconChecks {
    static func run() throws -> [String] {
        guard let url = Bundle.main.url(forResource:"StatusIcon",withExtension:"png"),let source = NSImage(contentsOf:url),let originalPixels = NSBitmapImageRep(data:try Data(contentsOf:url)) else { return ["status source unavailable; icon check skipped"] }
        let icon = AppAppearance.statusIcon(source:source)
        precondition(icon.isTemplate && icon.size == NSSize(width:22,height:22))
        precondition(originalPixels.pixelsWide == 44 && originalPixels.pixelsHigh == 44)
        func render(_ image: NSImage) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:44,pixelsHigh:44,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
        NSGraphicsContext.current!.cgContext.clear(CGRect(x:0,y:0,width:44,height:44))
        NSGraphicsContext.current!.cgContext.scaleBy(x:2,y:2)
        image.draw(in:NSRect(x:0,y:0,width:22,height:22))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
        }
        let bitmap = render(icon), original = render(source)
        var error = 0.0
        for y in 0..<44 { for x in 0..<44 {
            error += abs(bitmap.colorAt(x:x,y:y)!.alphaComponent-original.colorAt(x:43-x,y:y)!.alphaComponent)
        } }
        precondition(error/(44*44)<0.01)
        return ["mirrored status icon preserves original alpha cutouts at retina size", "status icon is a native template for per-display AppKit contrast tinting"]
    }
}
