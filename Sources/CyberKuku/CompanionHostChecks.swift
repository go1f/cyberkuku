import AppKit

@MainActor
enum CompanionHostChecks {
    static func run() {
        let app = NSApplication.shared
        Task { @MainActor in
            do {
                try await check()
                print("PASS extensions: background catalog, preview shortcut, native menus, settings routes, artwork and restart")
                exit(0)
            } catch {
                fputs("Extension check failed: \(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }

    private struct CheckFailure: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }

    private static func require(_ condition: @autoclosure () -> Bool,
                                _ detail: String = "Unexpected host state", line: UInt = #line) throws {
        guard condition() else { throw CheckFailure(detail: "Line \(line): \(detail)") }
    }

    private static func check() async throws {
        let suite = "cyberkuku.check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let pureCatalog = Data(#"{"schema":1,"extensions":[{"id":"posture","apiVersion":1},{"id":"test-boat","apiVersion":1},{"id":"unknown","apiVersion":1}]}"#.utf8)
        let catalog = try ExtensionCatalog.decode(pureCatalog)
        let duplicate = Data(#"{"schema":1,"extensions":[{"id":"posture","apiVersion":1},{"id":"posture","apiVersion":1}]}"#.utf8)
        try require((try? ExtensionCatalog.decode(duplicate)) == nil)
        let posture = PostureExtension.registration
        var oldOutput: BubbleOutput?
        var allowPreview = true
        var previewsOpened = 0
        let tracked = ExtensionRegistration(id: posture.id, title: posture.title, detail: posture.detail, symbol: posture.symbol) {
            oldOutput = $0.bubbles
            var instance = posture.activate($0)
            instance.openWindow = { previewsOpened += 1 }
            instance.allowsCompanionShortcut = { allowPreview }
            return instance
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
                                 fetchCatalog: { try await Task.sleep(for: .milliseconds(75)); return catalog })
        let extensions = host.extensions
        try require(extensions.installedEntries.isEmpty && host.availableArtwork.map(\.id) == ["cat"])
        try require(host.statusMenu.minimumWidth >= 200 && host.statusMenu.items.filter { !$0.isSeparatorItem }.map(\.title) == ["设置…", "退出 CyberKuku"])
        extensions.install(posture.id)
        try require(extensions.installed.isEmpty)

        host.settingsPage = .extensions
        let refresh = extensions.requestCatalog(onlyIfIdle: true)!
        host.settingsPage = .companion
        host.settingsPage = .extensions
        try require(extensions.catalog.isEmpty && host.settingsPage == .extensions)
        await refresh.value
        try require(extensions.requestCatalog(onlyIfIdle: true) == nil)
        try require(extensions.catalogStatus == .loaded && extensions.catalog.map(\.id) == ["posture", "test-boat"])
        extensions.install(posture.id)
        try require(extensions.installed[posture.id] == false && extensions.active[posture.id] == nil)
        extensions.setEnabled(true, for: posture.id)
        let submenu = host.statusMenu.item(withTitle: posture.title)!.submenu!
        try require(submenu.items.first?.title == "打开监测窗口" && submenu.items.allSatisfy { $0.view == nil })
        host.output.onOpenMonitor()
        try require(previewsOpened == 1)
        allowPreview = false
        host.output.onOpenMonitor()
        try require(previewsOpened == 1)
        host.openPrimaryWindow()
        try require(previewsOpened == 2)
        let settingsItem = host.statusMenu.item(withTitle: "设置…")!
        try require(NSApp.sendAction(settingsItem.action!, to: settingsItem.target, from: settingsItem))
        let window = host.settingsWindow!
        window.contentView?.layoutSubtreeIfNeeded()
        try require(window.styleMask.contains(.fullSizeContentView), "Settings must extend into the title bar")
        host.showUpdateSettings()
        try require(host.settingsPage == .updates && host.settingsWindow === window)
        let pluginSettings = submenu.item(withTitle: "坐姿设置…")!
        try require(NSApp.sendAction(pluginSettings.action!, to: pluginSettings.target, from: pluginSettings))
        try require(host.settingsWindow === window && host.settingsPage == .configuration(posture.id))
        if let path = ProcessInfo.processInfo.environment["CYBERKUKU_SETTINGS_RENDER_DIR"] {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (page, filename) in [(CompanionHost.SettingsPage.companion, "companion"),
                                     (.extensions, "extensions"), (.updates, "updates"), (.configuration(posture.id), "posture")] {
                host.settingsPage = page
                if filename == "posture" { window.setContentSize(NSSize(width: 750, height: 855)) }
                try await Task.sleep(for: .milliseconds(80))
                if let view = window.contentView {
                    view.layoutSubtreeIfNeeded()
                    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        try bitmap.representation(using: .png, properties: [:])?
                            .write(to: folder.appendingPathComponent(filename + ".png"))
                    }
                }
            }
        }

        let sample = BubbleSnapshot(alerts: [
            BubbleMessage(id: "head", title: "", message: "头向左扶正", seconds: 5, recovering: false)
        ], ongoingIDs: ["head"])
        oldOutput!.publish(sample)
        func activeIDs() -> [String] { host.output.snapshot["activeAlertIDs"] as? [String] ?? [] }
        try require(activeIDs() == ["posture/head"])
        extensions.setEnabled(false, for: posture.id)
        oldOutput!.publish(sample)
        try require(activeIDs().isEmpty && host.settingsPage == .extensions && host.statusMenu.item(withTitle: posture.title) == nil)

        extensions.install(boat.id)
        try require(host.availableArtwork.map(\.id) == ["cat"])
        extensions.setEnabled(true, for: boat.id)
        try require(host.availableArtwork.map(\.id) == ["cat", "test-boat"] && host.appearance.selectedID == "test-boat")
        host.adopt(.cat)
        try require(host.appearance.selectedID == "cat")
        host.adopt(host.availableArtwork[1])
        host.shutdown()

        let restored = CompanionHost(registrations: [tracked, boat], defaults: defaults, presentsOnScreen: false,
                                     fetchCatalog: { throw ExtensionCatalog.CatalogError.unavailable })
        await restored.extensions.requestCatalog()?.value
        try require(restored.extensions.catalogStatus == .failed)
        try require(restored.appearance.selectedID == "test-boat" && restored.extensions.installed[posture.id] == false)
        restored.extensions.setEnabled(false, for: boat.id)
        try require(restored.availableArtwork.map(\.id) == ["cat"] && restored.appearance.selectedID == "cat")
        restored.shutdown()
    }
}
