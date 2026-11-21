import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class CompanionAppearance {
    private let output: ReminderPanelController
    private let defaults: UserDefaults
    private let presentsOnScreen: Bool
    private(set) var pet: DesktopPetController?
    var selectedID: String { defaults.string(forKey: "appearance.skin") ?? CompanionArtwork.cat.id }
    func apply(_ artwork: CompanionArtwork) {
        defaults.set(artwork.id, forKey: "appearance.skin")
        pet?.useArtwork(artwork)
    }
    init(output: ReminderPanelController, defaults: UserDefaults, presentsOnScreen: Bool) {
        self.output = output; self.defaults = defaults; self.presentsOnScreen = presentsOnScreen
    }
    func activate() {
        guard pet == nil else { return }
        let companion = DesktopPetController(defaults: defaults, presentsOnScreen: presentsOnScreen, allowsHiding: false)
        companion.useArtwork(.cat)
        pet = companion
        output.attachCompanion(companion)
    }
    func deactivate() { output.attachCompanion(nil); pet = nil }
}

@MainActor
final class CompanionHost: NSObject, ObservableObject {
    enum SettingsPage: Hashable { case companion, extensions, configuration(String) }
    @Published var settingsPage: SettingsPage? = .companion
    private let settings = SettingsWindowController()
    var settingsWindow: NSWindow? { settings.window }
    let output: ReminderPanelController
    let bubbles: BubbleHub
    let appearance: CompanionAppearance
    let extensions: ExtensionManager
    let updater: AppUpdater
    private let presentsOnScreen: Bool
    private var statusItem: NSStatusItem?
    let statusMenu = NSMenu()
    private let appMenu = NSMenu(title: "CyberKuku")

    init(registrations: [ExtensionRegistration], defaults: UserDefaults = .standard, presentsOnScreen: Bool = true,
         fetchCatalog: @escaping () async throws -> ExtensionCatalog = { try await ExtensionCatalog.fetch() }) {
        self.presentsOnScreen = presentsOnScreen
        let output = ReminderPanelController(router: DisplayRouter(), presentsOnScreen: presentsOnScreen, hosted: true)
        self.output = output
        bubbles = BubbleHub(renderer: output)
        updater = AppUpdater(enabled: presentsOnScreen)
        appearance = CompanionAppearance(output: output, defaults: defaults, presentsOnScreen: presentsOnScreen)
        extensions = ExtensionManager(registrations: registrations, defaults: defaults, bubbles: bubbles, fetchCatalog: fetchCatalog)
        super.init()
        output.onOpenMonitor = { [weak self] in self?.openPrimaryWindow() }
        extensions.openSettings = { [weak self] id in self?.showExtensionSettings(id) }
        extensions.onChange = { [weak self] id, enabled in self?.extensionsChanged(id, enabled: enabled) }
        appearance.activate()
        extensions.restore()
        if presentsOnScreen {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let url = Bundle.main.url(forResource: "StatusIcon", withExtension: "png"), let icon = NSImage(contentsOf: url) {
                item.button?.image = AppAppearance.statusIcon(source: icon)
            }
            item.button?.toolTip = "CyberKuku"
            statusItem = item
            item.menu = statusMenu
            installApplicationMenu()
        }
    }

    var availableArtwork: [CompanionArtwork] {
        [.cat] + extensions.enabledEntries.compactMap { extensions.active[$0.id]?.artwork }
    }

    private func extensionsChanged(_ id: String?, enabled: Bool) {
        let activated = id.flatMap { extensions.active[$0]?.artwork }
        let remembered = availableArtwork.first { $0.id == appearance.selectedID }
        adopt((enabled ? activated : nil) ?? remembered ?? .cat)
        if let id, !enabled, settingsPage == .configuration(id) { settingsPage = .extensions }
        rebuildStatusMenu()
    }

    func adopt(_ artwork: CompanionArtwork) {
        objectWillChange.send()
        appearance.apply(artwork)
    }

    @objc func showSettings() { settings.show(CyberKukuSettingsView(host: self), activate: presentsOnScreen) }
    @objc func showExtensions() { settingsPage = .extensions; showSettings() }
    func showExtensionSettings(_ id: String) {
        guard extensions.active[id]?.configuration != nil else { return }
        settingsPage = .configuration(id)
        showSettings()
    }

    func openPrimaryWindow() {
        if let open = extensions.enabledEntries.compactMap({ extensions.active[$0.id]?.openWindow }).first {
            open()
        } else {
            showSettings()
        }
    }

    @discardableResult
    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector, _ target: AnyObject, key: String = "") -> NSMenuItem {
        let row = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        row.target = target
        return row
    }

    private func rebuildStatusMenu() {
        statusMenu.items.forEach { $0.submenu = nil }
        statusMenu.removeAllItems()
        for entry in extensions.enabledEntries {
            guard let makeMenu = extensions.active[entry.id]?.makeMenu else { continue }
            let row = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            row.submenu = makeMenu()
            statusMenu.addItem(row)
        }
        if !statusMenu.items.isEmpty { statusMenu.addItem(.separator()) }
        addItem(statusMenu, "设置…", #selector(showSettings), self)
        addItem(statusMenu, "退出 CyberKuku", #selector(NSApplication.terminate(_:)), NSApp)
    }

    private func installApplicationMenu() {
        let root = NSMenu(), file = NSMenu(title: "文件")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; root.addItem(appItem)
        addItem(appMenu, "设置…", #selector(showSettings), self, key: ",")
        addItem(appMenu, "应用更新…", #selector(AppUpdater.showWindow(_:)), updater)
        appMenu.addItem(.separator())
        addItem(appMenu, "退出 CyberKuku", #selector(NSApplication.terminate(_:)), NSApp, key: "q")
        let fileItem = NSMenuItem(); fileItem.submenu = file; root.addItem(fileItem)
        file.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        editItem.submenu = edit; root.addItem(editItem)
        for (title, action, key) in [("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"),
                                    ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        NSApp.mainMenu = root
    }
    func shutdown() {
        settings.close()
        extensions.shutdown()
        appearance.deactivate()
        output.shutdown()
        statusMenu.removeAllItems()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }
}
