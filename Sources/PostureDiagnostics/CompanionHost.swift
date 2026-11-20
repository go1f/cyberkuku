import AppKit
import AVFoundation
import SwiftUI

enum CompanionSkin: String, CaseIterable {
    case cat, boat
    var title: String { self == .cat ? "小灰猫" : "纸船" }
}

enum PaperBoat {
    static func draw(in rect: CGRect) {
        func fold(_ points: [(CGFloat, CGFloat)], color: NSColor) {
            let path = NSBezierPath()
            for (index, point) in points.enumerated() {
                let p = CGPoint(x: rect.minX + point.0 * rect.width, y: rect.minY + point.1 * rect.height)
                if index == 0 { path.move(to: p) } else { path.line(to: p) }
            }
            path.close()
            color.setFill()
            path.fill()
            NSColor.darkGray.setStroke()
            path.lineWidth = 0.8
            path.stroke()
        }
        fold([(0.20,0.45),(0.57,0.96),(0.77,0.50)], color: .init(white: 0.95, alpha: 1))
        fold([(0,0.57),(0.46,0.36),(1,0.62),(0.73,0.10),(0.29,0.07)], color: .init(red: 0.83, green: 0.76, blue: 0.64, alpha: 1))
    }
}

@MainActor
protocol CompanionPlugin: AnyObject {
    var id: String { get }
    var title: String { get }
    var defaultEnabled: Bool { get }
    func activate()
    func deactivate()
}

@MainActor
final class AppearancePlugin: CompanionPlugin {
    let id = "appearance", title = "桌面形象", defaultEnabled = true
    private let output: ReminderPanelController
    private let defaults: UserDefaults
    private let presentsOnScreen: Bool
    private(set) var pet: DesktopPetController?
    var skin: CompanionSkin {
        get { CompanionSkin(rawValue: defaults.string(forKey: "appearance.skin") ?? "") ?? .cat }
        set { defaults.set(newValue.rawValue, forKey: "appearance.skin"); pet?.useSkin(newValue) }
    }
    init(output: ReminderPanelController, defaults: UserDefaults, presentsOnScreen: Bool) {
        self.output = output; self.defaults = defaults; self.presentsOnScreen = presentsOnScreen
    }
    func activate() {
        guard pet == nil else { return }
        let companion = DesktopPetController(defaults: defaults, presentsOnScreen: presentsOnScreen)
        companion.useSkin(skin)
        pet = companion
        output.attachCompanion(companion)
    }
    func deactivate() { output.attachCompanion(nil); pet = nil }
}

@MainActor
final class PosturePlugin: CompanionPlugin {
    let id = "posture", title = "注意坐姿", defaultEnabled = false
    private let output: BubbleHub
    private let updater: AppUpdater
    private(set) var desktop: DesktopCoordinator?
    init(output: BubbleHub, updater: AppUpdater) {
        self.output = output; self.updater = updater
    }
    func activate() {
        guard desktop == nil else { return }
        desktop = DesktopCoordinator(model: DiagnosticModel(), output: output.open(id), appUpdater: updater)
    }
    func deactivate() {
        desktop?.shutdown()
        desktop?.model.shutdown()
        desktop = nil
    }
}

@MainActor
final class CompanionHost: NSObject, ObservableObject, NSMenuDelegate {
    let output: ReminderPanelController
    let bubbles: BubbleHub
    let appearance: AppearancePlugin
    let posture: PosturePlugin
    let updater: AppUpdater
    private let defaults: UserDefaults
    let plugins: [CompanionPlugin]
    @Published private(set) var enabled = Set<String>()
    @Published var previewSkin: CompanionSkin?
    @Published var showingAbilities = false
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private var visibilityItem: NSMenuItem?

    init(defaults: UserDefaults = .standard, presentsOnScreen: Bool = true) {
        self.defaults = defaults
        let output = ReminderPanelController(router: DisplayRouter(), presentsOnScreen: presentsOnScreen, hosted: true)
        self.output = output
        bubbles = BubbleHub(renderer: output)
        let updater = AppUpdater(enabled: presentsOnScreen)
        self.updater = updater
        appearance = AppearancePlugin(output: output, defaults: defaults, presentsOnScreen: presentsOnScreen)
        posture = PosturePlugin(output: bubbles, updater: updater)
        plugins = [appearance, posture]
        super.init()
        output.onOpenMonitor = { [weak self] in
            guard let self else { return }
            if let desktop = self.posture.desktop { desktop.openMain() } else { self.openHome() }
        }
        output.onPetVisibilityChanged = { [weak self] in self?.refreshVisibility() }
        for plugin in plugins where defaults.object(forKey: "plugins." + plugin.id) as? Bool ?? plugin.defaultEnabled {
            plugin.activate()
            enabled.insert(plugin.id)
        }
        if presentsOnScreen {
            if let model = posture.desktop?.model, model.settings.resumeOnLaunch, !model.profiles.isEmpty,
               AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
                model.start()
            }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let url = Bundle.main.url(forResource: "StatusIcon", withExtension: "png"), let icon = NSImage(contentsOf: url) {
                item.button?.image = AppAppearance.statusIcon(source: icon)
            }
            item.button?.toolTip = "cyberkuku"
            statusItem = item
            item.menu = statusMenu
            statusMenu.delegate = self
            rebuildMenus()
        }
    }
    func setEnabled(_ plugin: CompanionPlugin, _ value: Bool) {
        guard enabled.contains(plugin.id) != value else { return }
        if value { plugin.activate(); enabled.insert(plugin.id) }
        else { plugin.deactivate(); enabled.remove(plugin.id) }
        defaults.set(value, forKey: "plugins." + plugin.id)
        if statusItem != nil { rebuildMenus() }
    }
    func adopt(_ skin: CompanionSkin) {
        objectWillChange.send()
        appearance.skin = skin
        refreshVisibility()
    }
    func menuWillOpen(_ menu: NSMenu) { refreshVisibility() }
    private func refreshVisibility() {
        let state = output.petMenuPresentation
        visibilityItem?.title = state.action.replacingOccurrences(of: "小灰猫", with: appearance.skin.title)
        visibilityItem?.state = state.check
    }
    @objc private func togglePet() { output.togglePet() }
    @objc func openHome() { showingAbilities = false; showWindow() }
    @objc func openAbilities() { showingAbilities = true; showWindow() }
    private func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 410),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "cyberkuku"; w.isReleasedWhenClosed = false
            let view = NSHostingView(rootView: CompanionHome(host: self))
            view.sizingOptions = []
            w.contentView = view
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
    }
    private func rebuildMenus() {
        // An NSMenu can belong to only one parent. Detach the plugin contribution before rebuilding.
        statusMenu.items.forEach { $0.submenu = nil }
        statusMenu.removeAllItems()
        func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ target: AnyObject, _ key: String = "") -> NSMenuItem {
            let row = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            row.target = target
            return row
        }
        _ = item(statusMenu, "打开伙伴", #selector(openHome), self)
        visibilityItem = enabled.contains(appearance.id) ? item(statusMenu, "", #selector(togglePet), self) : nil
        refreshVisibility()
        if let desktop = posture.desktop {
            let row = NSMenuItem(title: posture.title, action: nil, keyEquivalent: "")
            row.submenu = desktop.pluginMenu
            statusMenu.addItem(row)
        }
        statusMenu.addItem(.separator())
        _ = item(statusMenu, "管理能力…", #selector(openAbilities), self)
        _ = item(statusMenu, "退出 cyberkuku", #selector(NSApplication.terminate(_:)), NSApp)
        let root = NSMenu(), app = NSMenu(title: "cyberkuku"), file = NSMenu(title: "文件")
        let appItem = NSMenuItem(); appItem.submenu = app; root.addItem(appItem)
        _ = item(app, "伙伴设置…", #selector(openAbilities), self, ",")
        _ = item(app, "检查更新…", #selector(AppUpdater.checkForUpdates(_:)), updater)
        app.addItem(.separator())
        _ = item(app, "退出 cyberkuku", #selector(NSApplication.terminate(_:)), NSApp, "q")
        let fileItem = NSMenuItem(); fileItem.submenu = file; root.addItem(fileItem)
        file.addItem(withTitle: "打开伙伴", action: #selector(openHome), keyEquivalent: "0").target = self
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
        plugins.reversed().filter { enabled.contains($0.id) }.forEach { $0.deactivate() }
        enabled.removeAll()
        window?.close()
        window = nil
        output.shutdown()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }
}

private struct CompanionHome: View {
    @ObservedObject var host: CompanionHost
    var body: some View {
        VStack(spacing: 20) {
            Picker("页面", selection: $host.showingAbilities) {
                Text("伙伴").tag(false)
                Text("能力").tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 184)
            if host.showingAbilities {
                Form {
                    ForEach(host.plugins, id: \.id) { plugin in
                        Toggle(plugin.title, isOn: Binding(get: { host.enabled.contains(plugin.id) },
                            set: { host.setEnabled(plugin, $0) })).toggleStyle(.switch)
                    }
                    if let posture = host.posture.desktop {
                        Button("打开监测窗口", action: posture.openMain)
                        Button("坐姿设置…", action: posture.showSettings)
                        Button("预览提醒", action: posture.previewReminder)
                    }
                }.formStyle(.grouped)
            } else {
                Spacer()
                if host.enabled.contains(host.appearance.id) {
                    let skin = host.previewSkin ?? host.appearance.skin
                    if skin == .cat, let url = Bundle.main.url(forResource: "Companion", withExtension: "png"),
                       let image = NSImage(contentsOf: url) {
                        Image(nsImage: image).resizable().scaledToFit().frame(height: 155)
                    } else if skin == .boat {
                        Image(nsImage: NSImage(size: NSSize(width: 112, height: 80), flipped: false) { rect in PaperBoat.draw(in: rect); return true })
                            .frame(height: 155)
                    }
                    Text(skin.title).font(.title2)
                    HStack {
                        Picker("形象", selection: Binding(get: { host.previewSkin ?? host.appearance.skin }, set: { host.previewSkin = $0 })) {
                            ForEach(CompanionSkin.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.frame(width: 150)
                        Button("采用") { host.adopt(skin); host.previewSkin = nil }.disabled(skin == host.appearance.skin)
                        if skin != host.appearance.skin {
                            Button("取消") { host.previewSkin = nil }
                        }
                    }
                } else {
                    Text("桌面形象已关闭").foregroundStyle(.secondary)
                    Button("管理能力", action: host.openAbilities)
                }
                Spacer()
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
    }
}
