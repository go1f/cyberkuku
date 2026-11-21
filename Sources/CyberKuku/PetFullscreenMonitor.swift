import AppKit
import Darwin

@MainActor enum PetFullscreenMonitor {
    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
    // SkyLight's read-only Space metadata is undocumented. Resolve optionally and fail open:
    // never substitute window geometry (zoomed windows are not native full-screen Spaces).
    private static let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)
    private typealias Connection = @convention(c) () -> UInt32
    private typealias Spaces = @convention(c) (UInt32) -> Unmanaged<CFArray>?
    static func fullScreenIdentifiers(_ entries: [[String:Any]]) -> Set<String> {
        Set(entries.compactMap { entry in
            guard let current = entry["Current Space"] as? [String:Any],
                  (current["type"] as? NSNumber)?.intValue == 4 else { return nil }
            return entry["Display Identifier"] as? String
        })
    }
    static func coveredDisplays() -> Set<CGDirectDisplayID> {
        guard let library, let connectionSymbol = dlsym(library,"CGSMainConnectionID"),
              let spacesSymbol = dlsym(library,"CGSCopyManagedDisplaySpaces") else { return [] }
        let connection = unsafeBitCast(connectionSymbol,to:Connection.self)
        let spaces = unsafeBitCast(spacesSymbol,to:Spaces.self)
        guard let values = spaces(connection())?.takeRetainedValue() as? [[String:Any]] else { return [] }
        let identifiers = fullScreenIdentifiers(values)
        return Set(NSScreen.screens.compactMap { screen in
            let id = displayID(screen)
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
            return identifiers.contains(CFUUIDCreateString(nil,uuid) as String) ? id : nil
        })
    }
}
