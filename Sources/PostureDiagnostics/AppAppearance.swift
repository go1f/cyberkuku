import AppKit

/// The reviewed Dock icon keeps its white tile. Status-item tinting is owned by AppKit.
@MainActor
final class AppAppearance {
    private var observation: NSKeyValueObservation?
    private var lightImage: NSImage?
    private var darkImage: NSImage?

    func start() {
        guard observation == nil else { return }
        lightImage = icon(named: "KukusitLight")
        darkImage = icon(named: "KukusitDark")
        observation = NSApplication.shared.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.updateIcon() }
        }
        updateIcon()
    }

    func stop() {
        observation?.invalidate()
        observation = nil
    }

    static func usesDarkBackground(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static func statusIcon(source: NSImage) -> NSImage {
        let image = NSImage(size:NSSize(width:22,height:22),flipped:false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState(); defer { context.restoreGState() }
            context.translateBy(x:rect.width,y:0); context.scaleBy(x:-1,y:1)
            source.draw(in:rect,from:.zero,operation:.sourceOver,fraction:1)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "KukuSeat 坐姿监测"
        return image
    }
    private func icon(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }

    private func updateIcon() {
        let image = lightImage // The reviewed application logo always has a white background.
        // A missing resource retains the bundle icon instead of a generic icon.
        if let image { NSApplication.shared.applicationIconImage = image }
    }
}
