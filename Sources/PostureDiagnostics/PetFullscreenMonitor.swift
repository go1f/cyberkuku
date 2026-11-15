import AppKit
import PostureCore

@MainActor enum PetFullscreenMonitor {
    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
    /// Read window geometry only, never titles or screen pixels, and never request AX access.
    static func coveredDisplays() -> Set<CGDirectDisplayID> {
        guard let primary = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] else { return [] }
        var result: Set<CGDirectDisplayID> = []
        for entry in windows {
            guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0.9,
                  let dict = entry[kCGWindowBounds as String] as? [String:Any],
                  let raw = CGRect(dictionaryRepresentation:dict as CFDictionary) else { continue }
            let frame = CGRect(x:raw.minX,y:primary.frame.maxY-raw.maxY,width:raw.width,height:raw.height)
            for screen in NSScreen.screens where PetEdgeBehavior.coversDisplay(window:frame,screen:screen.frame,safeTop:screen.safeAreaInsets.top) {
                result.insert(displayID(screen))
            }
        }
        return result
    }
}
