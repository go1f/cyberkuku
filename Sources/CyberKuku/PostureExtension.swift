import AppKit
import AVFoundation
import SwiftUI

@MainActor
enum PostureExtension {
    static let id = "posture"

    static var registration: ExtensionRegistration {
        ExtensionRegistration(
            id: id, title: "同学请注意坐姿！",
            detail: "用本机摄像头观察坐姿，通过桌面伙伴提醒。",
            symbol: "figure.seated.side"
        ) { context in
            let model = DiagnosticModel()
            let desktop = DesktopCoordinator(model: model, output: context.bubbles)
            desktop.openPostureSettings = context.openSettings
            if context.restoringAtLaunch, model.settings.resumeOnLaunch, !model.profiles.isEmpty,
               AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
                model.start()
            }
            return ActiveExtension(
                configuration: { AnyView(PostureSettingsForm(model: model, desktop: desktop)) },
                makeMenu: { desktop.pluginMenu },
                openWindow: { desktop.openMain() },
                stop: { desktop.shutdown(); model.shutdown() }
            )
        }
    }

    static func carryForwardInstallation(defaults: UserDefaults = .standard) {
        let previousKey = "plugins.posture"
        guard let previous = defaults.object(forKey: previousKey) as? Bool else { return }
        if defaults.object(forKey: ExtensionManager.preferenceKey) == nil {
            defaults.set([id: previous], forKey: ExtensionManager.preferenceKey)
        }
        defaults.removeObject(forKey: previousKey)
    }
}
