import AppKit

@MainActor
enum CompanionHostChecks {
    static func run() {
        let app = NSApplication.shared
        Task { @MainActor in
            do {
                try await check()
                print("PASS extensions: catalog, import, lifecycle, menu contributions, settings, artwork and restart")
                exit(0)
            } catch {
                fputs("Extension check failed: \(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }

    private static func check() async throws {
        let suite = "cyberkuku.check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let pureCatalog = Data(#"{"schema":1,"extensions":[{"id":"posture","apiVersion":1},{"id":"test-boat","apiVersion":1},{"id":"unknown","apiVersion":1}]}"#.utf8)
        let catalog = try ExtensionCatalog.decode(pureCatalog)
        let duplicate = Data(#"{"schema":1,"extensions":[{"id":"posture","apiVersion":1},{"id":"posture","apiVersion":1}]}"#.utf8)
        precondition((try? ExtensionCatalog.decode(duplicate)) == nil)
        let posture = PostureExtension.registration
        var oldOutput: BubbleOutput?
        let tracked = ExtensionRegistration(id: posture.id, title: posture.title, detail: posture.detail, symbol: posture.symbol) {
            oldOutput = $0.bubbles
            return posture.activate($0)
        }
        let boat = ExtensionRegistration(id: "test-boat", title: "纸船", detail: "", symbol: "sailboat") { _ in
            ActiveExtension(artwork: CompanionArtwork(id: "test-boat", title: "纸船") { rect in
                let sail = NSBezierPath()
                sail.move(to: CGPoint(x: rect.minX, y: rect.minY))
                sail.line(to: CGPoint(x: rect.midX, y: rect.maxY))
                sail.line(to: CGPoint(x: rect.maxX, y: rect.minY))
                sail.close()
                NSColor.windowBackgroundColor.setFill()
                sail.fill()
            })
        }
        let host = CompanionHost(registrations: [tracked, boat], defaults: defaults, presentsOnScreen: false,
                                 fetchCatalog: { catalog })
        let extensions = host.extensions
        precondition(extensions.installedEntries.isEmpty && host.availableArtwork.map(\.id) == ["cat"])
        precondition(host.statusMenu.items.map(\.title) == ["设置…", "退出 CyberKuku"])
        extensions.install(posture.id)
        precondition(extensions.installed.isEmpty)

        await extensions.refreshCatalog()
        precondition(extensions.catalogStatus == .loaded && extensions.catalog.map(\.id) == ["posture", "test-boat"])
        extensions.install(posture.id)
        precondition(extensions.installed[posture.id] == false && extensions.active[posture.id] == nil)
        extensions.setEnabled(true, for: posture.id)
        let submenu = host.statusMenu.item(withTitle: posture.title)!.submenu!
        let settingsItem = host.statusMenu.item(withTitle: "设置…")!
        precondition(NSApp.sendAction(settingsItem.action!, to: settingsItem.target, from: settingsItem))
        let window = host.settingsWindow!
        let pluginSettings = submenu.item(withTitle: "坐姿设置…")!
        precondition(NSApp.sendAction(pluginSettings.action!, to: pluginSettings.target, from: pluginSettings))
        precondition(host.settingsWindow === window && host.settingsPage == .configuration(posture.id))

        let sample = BubbleSnapshot(alerts: [
            BubbleMessage(id: "head", title: "", message: "头向左扶正", seconds: 5, recovering: false)
        ], ongoingIDs: ["head"])
        oldOutput!.publish(sample)
        func activeIDs() -> [String] { host.output.snapshot["activeAlertIDs"] as? [String] ?? [] }
        precondition(activeIDs() == ["posture/head"])
        extensions.setEnabled(false, for: posture.id)
        oldOutput!.publish(sample)
        precondition(activeIDs().isEmpty && host.settingsPage == .extensions && host.statusMenu.item(withTitle: posture.title) == nil)

        extensions.install(boat.id)
        precondition(host.availableArtwork.map(\.id) == ["cat"])
        extensions.setEnabled(true, for: boat.id)
        precondition(host.availableArtwork.map(\.id) == ["cat", "test-boat"] && host.appearance.selectedID == "test-boat")
        host.adopt(.cat)
        precondition(host.appearance.selectedID == "cat")
        host.adopt(host.availableArtwork[1])
        host.shutdown()

        let restored = CompanionHost(registrations: [tracked, boat], defaults: defaults, presentsOnScreen: false,
                                     fetchCatalog: { throw ExtensionCatalog.CatalogError.unavailable })
        await restored.extensions.refreshCatalog()
        precondition(restored.extensions.catalogStatus == .failed)
        precondition(restored.appearance.selectedID == "test-boat" && restored.extensions.installed[posture.id] == false)
        restored.extensions.setEnabled(false, for: boat.id)
        precondition(restored.availableArtwork.map(\.id) == ["cat"] && restored.appearance.selectedID == "cat")
        restored.shutdown()
    }
}
