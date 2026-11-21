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
        precondition(extensions.installedEntries.isEmpty && host.availableArtwork.map(\.id) == ["cat"])
        precondition(host.statusMenu.minimumWidth >= 200 && host.statusMenu.items.filter { !$0.isSeparatorItem }.map(\.title) == ["设置…", "退出 CyberKuku"])
        extensions.install(posture.id)
        precondition(extensions.installed.isEmpty)

        host.settingsPage = .extensions
        let refresh = extensions.requestCatalog(onlyIfIdle: true)!
        host.settingsPage = .companion
        host.settingsPage = .extensions
        precondition(extensions.catalog.isEmpty && host.settingsPage == .extensions)
        await refresh.value
        precondition(extensions.requestCatalog(onlyIfIdle: true) == nil)
        precondition(extensions.catalogStatus == .loaded && extensions.catalog.map(\.id) == ["posture", "test-boat"])
        extensions.install(posture.id)
        precondition(extensions.installed[posture.id] == false && extensions.active[posture.id] == nil)
        extensions.setEnabled(true, for: posture.id)
        let submenu = host.statusMenu.item(withTitle: posture.title)!.submenu!
        precondition(submenu.items.first?.title == "打开监测窗口" && submenu.items.allSatisfy { $0.view == nil })
        host.output.onOpenMonitor()
        precondition(previewsOpened == 1)
        allowPreview = false
        host.output.onOpenMonitor()
        precondition(previewsOpened == 1)
        host.openPrimaryWindow()
        precondition(previewsOpened == 2)
        let settingsItem = host.statusMenu.item(withTitle: "设置…")!
        precondition(NSApp.sendAction(settingsItem.action!, to: settingsItem.target, from: settingsItem))
        let window = host.settingsWindow!
        window.contentView?.layoutSubtreeIfNeeded()
        precondition(window.styleMask.contains(.fullSizeContentView), "Settings must extend into the title bar")
        host.showUpdateSettings()
        precondition(host.settingsPage == .updates && host.settingsWindow === window)
        let pluginSettings = submenu.item(withTitle: "坐姿设置…")!
        precondition(NSApp.sendAction(pluginSettings.action!, to: pluginSettings.target, from: pluginSettings))
        precondition(host.settingsWindow === window && host.settingsPage == .configuration(posture.id))
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
        await restored.extensions.requestCatalog()?.value
        precondition(restored.extensions.catalogStatus == .failed)
        precondition(restored.appearance.selectedID == "test-boat" && restored.extensions.installed[posture.id] == false)
        restored.extensions.setEnabled(false, for: boat.id)
        precondition(restored.availableArtwork.map(\.id) == ["cat"] && restored.appearance.selectedID == "cat")
        restored.shutdown()
    }
}
