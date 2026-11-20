import AppKit

@MainActor
enum CompanionHostChecks {
    static func run() {
        _ = NSApplication.shared
        let suite = "cyberkuku.check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = CompanionHost(defaults: defaults, presentsOnScreen: false)
        precondition(host.enabled == ["appearance"] && host.posture.desktop == nil && host.appearance.pet != nil)
        host.adopt(.boat)
        host.setEnabled(host.posture, true)
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
        host.setEnabled(host.appearance, false)
        precondition(host.appearance.pet == nil && ids().count == 2)
        precondition(host.output.snapshot["surface"] as? String == "banner")
        host.setEnabled(host.posture, false)
        oldCallback(update)
        precondition(ids() == ["second/head"] && host.posture.desktop == nil)
        second.close()
        precondition(ids().isEmpty && !host.output.visible)
        host.setEnabled(host.appearance, true)
        host.shutdown()
        let restored = CompanionHost(defaults: defaults, presentsOnScreen: false)
        precondition(restored.appearance.skin == .boat && restored.appearance.pet != nil && restored.posture.desktop == nil)
        restored.shutdown()
        print("PASS companion host: defaults, lazy capture, skin persistence, fallback routing, scoped bubbles and stale callbacks")
    }
}
