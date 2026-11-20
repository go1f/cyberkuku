import AppKit
import AVFoundation

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
final class AppearancePlugin {
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
        let companion = DesktopPetController(defaults: defaults, presentsOnScreen: presentsOnScreen, allowsHiding: false)
        companion.useSkin(skin)
        pet = companion
        output.attachCompanion(companion)
    }
    func deactivate() { output.attachCompanion(nil); pet = nil }
}

@MainActor
final class PosturePlugin {
    let id = "posture", title = "注意坐姿"
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
final class CompanionHost: NSObject {
    let output: ReminderPanelController
    let bubbles: BubbleHub
    let appearance: AppearancePlugin
    let posture: PosturePlugin
    let updater: AppUpdater
    private let defaults: UserDefaults
    private var statusItem: NSStatusItem?
    let statusMenu = NSMenu()
    private let shapeMenu = NSMenu(title: "切换形象")
    private let appMenu = NSMenu(title: "CyberKuku")

    init(defaults: UserDefaults = .standard, presentsOnScreen: Bool = true) {
        self.defaults = defaults
        let output = ReminderPanelController(router: DisplayRouter(), presentsOnScreen: presentsOnScreen, hosted: true)
        self.output = output
        bubbles = BubbleHub(renderer: output)
        let updater = AppUpdater(enabled: presentsOnScreen)
        self.updater = updater
        appearance = AppearancePlugin(output: output, defaults: defaults, presentsOnScreen: presentsOnScreen)
        posture = PosturePlugin(output: bubbles, updater: updater)
        super.init()
        output.onOpenMonitor = { [weak self] in self?.posture.desktop?.openMain() }
        appearance.activate()
        if defaults.bool(forKey: "plugins.posture") { posture.activate() }
        rebuildStatusMenu()
        if presentsOnScreen {
            if let model = posture.desktop?.model, model.settings.resumeOnLaunch, !model.profiles.isEmpty,
               AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
                model.start()
            }
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

    @objc func togglePosture() {
        let enable = posture.desktop == nil
        if enable { posture.activate() } else { posture.deactivate() }
        defaults.set(enable, forKey: "plugins.posture")
        rebuildStatusMenu()
    }

    @objc private func selectSkin(_ item: NSMenuItem) {
        guard let name = item.representedObject as? String, let skin = CompanionSkin(rawValue: name) else { return }
        adopt(skin)
    }
    func adopt(_ skin: CompanionSkin) {
        appearance.skin = skin
        for item in shapeMenu.items {
            item.state = item.representedObject as? String == skin.rawValue ? .on : .off
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
        shapeMenu.removeAllItems()
        for skin in CompanionSkin.allCases {
            let row = addItem(shapeMenu, skin.title, #selector(selectSkin(_:)), self)
            row.representedObject = skin.rawValue
            row.state = appearance.skin == skin ? .on : .off
        }
        let shapes = NSMenuItem(title: shapeMenu.title, action: nil, keyEquivalent: "")
        shapes.submenu = shapeMenu
        statusMenu.addItem(shapes)
        if let desktop = posture.desktop {
            let menu = desktop.pluginMenu
            if !menu.items.contains(where: { $0.action == #selector(togglePosture) }) {
                menu.addItem(.separator())
                let disable = addItem(menu, "停用注意坐姿", #selector(togglePosture), self)
                disable.isEnabled = true
            }
            let row = NSMenuItem(title: posture.title, action: nil, keyEquivalent: "")
            row.submenu = menu
            statusMenu.addItem(row)
        } else {
            addItem(statusMenu, "启用注意坐姿", #selector(togglePosture), self)
        }
        statusMenu.addItem(.separator())
        addItem(statusMenu, "应用更新…", #selector(AppUpdater.showWindow(_:)), updater)
        addItem(statusMenu, "退出 CyberKuku", #selector(NSApplication.terminate(_:)), NSApp)
    }

    private func installApplicationMenu() {
        let root = NSMenu(), file = NSMenu(title: "文件")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; root.addItem(appItem)
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
        posture.deactivate()
        appearance.deactivate()
        output.shutdown()
        statusMenu.removeAllItems()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }
}
