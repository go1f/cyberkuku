import AppKit

@MainActor
enum CompanionHostChecks {
    static func run() {
        _ = NSApplication.shared
        let suite = "cyberkuku.check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = CompanionHost(defaults: defaults, presentsOnScreen: false)
        let companion = host.appearance.pet!
        precondition(host.posture.desktop == nil && !companion.userHidden)
        let shapes = host.statusMenu.item(withTitle: "切换形象")!.submenu!
        precondition(shapes.items.map(\.title) == ["小灰猫", "纸船"])
        let boat = shapes.item(withTitle: "纸船")!
        precondition(NSApp.sendAction(boat.action!, to: boat.target, from: boat))
        precondition(host.appearance.skin == .boat && boat.state == .on && shapes.items.first?.state == .off)
        precondition(host.statusMenu.item(withTitle: "应用更新…")?.target === host.updater)
        let settings = host.statusMenu.item(withTitle: "设置…")!
        precondition(NSApp.sendAction(settings.action!, to: settings.target, from: settings))
        let settingsWindow = host.settingsWindow!
        precondition(host.settingsPage == .companion)
        let openPostureSettings = host.statusMenu.item(withTitle: "设置注意坐姿…")!
        precondition(NSApp.sendAction(openPostureSettings.action!, to: openPostureSettings.target, from: openPostureSettings))
        precondition(host.settingsPage == .posture && host.settingsWindow === settingsWindow)
        host.setPostureEnabled(true)
        let desktop = host.posture.desktop!
        precondition(!desktop.model.hasStarted && desktop.pluginMenu.items.contains { $0.title == "打开监测窗口" })
        let update = BubbleSnapshot(alerts: [
            BubbleMessage(id: "head", title: "", message: "头向左扶正", seconds: 5, recovering: false)
        ], ongoingIDs: ["head"])
        let oldCallback = desktop.model.onReminderAlertsChanged!
        oldCallback(update)
        func ids() -> Set<String> { Set(host.output.snapshot["activeAlertIDs"] as? [String] ?? []) }
        precondition(ids() == ["posture/head"])
        let second = host.bubbles.open("second")
        second.publish(update)
        precondition(ids() == ["posture/head", "second/head"])
        precondition(host.appearance.pet === companion && ids().count == 2)
        precondition(host.output.snapshot["surface"] as? String == "companion")
        let postureMenu = host.statusMenu.item(withTitle: "注意坐姿")!.submenu!
        let rows = postureMenu.items.filter { !$0.isSeparatorItem && $0.view == nil }
        precondition(rows.map(\.title) == ["打开监测窗口", "画中画", "开始监测", "坐姿设置…"])
        host.settingsPage = .companion
        let deepLink = rows.last!
        precondition(NSApp.sendAction(deepLink.action!, to: deepLink.target, from: deepLink))
        precondition(host.settingsPage == .posture && host.settingsWindow === settingsWindow)
        host.setPostureEnabled(false)
        precondition(host.statusMenu.item(withTitle: "设置注意坐姿…") != nil)
        oldCallback(update)
        precondition(ids() == ["second/head"] && host.posture.desktop == nil)
        second.close()
        precondition(ids().isEmpty && !host.output.visible)
        host.shutdown()
        let restored = CompanionHost(defaults: defaults, presentsOnScreen: false)
        precondition(restored.appearance.skin == .boat && restored.appearance.pet != nil && restored.posture.desktop == nil)
        restored.shutdown()
        print("PASS companion host: always-on companion, menu skin selection, shared settings window, top-level updates, lazy capture and scoped bubbles")
    }
}
