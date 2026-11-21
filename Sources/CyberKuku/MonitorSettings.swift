import Foundation
import PostureCore

enum PiPSize: String, Codable, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var label: String { switch self { case .small: return "小"; case .medium: return "中"; case .large: return "大" } }
    var width: Double { switch self { case .small: return 360; case .medium: return 440; case .large: return 560 } }
    var height: Double { switch self { case .small: return 340; case .medium: return 390; case .large: return 460 } }
}
enum PiPCorner: String, Codable, CaseIterable, Identifiable {
    case topRight, topLeft, bottomRight, bottomLeft
    var id: String { rawValue }
    var label: String {
        switch self { case .topRight: return "右上"; case .topLeft: return "左上"; case .bottomRight: return "右下"; case .bottomLeft: return "左下" }
    }
}

enum PostureSensitivity: Int, CaseIterable, Identifiable {
    case high, balanced, relaxed
    var id: Self { self }
    var title: String {
        switch self {
        case .high: return "及时（3 秒）"
        case .balanced: return "均衡（5 秒）"
        case .relaxed: return "宽松（10 秒）"
        }
    }
}

struct MonitorSettings: Codable, Equatable {
    var automaticReminders = true
    var tuning = MonitorTuning()
    var handMouthMonitoring = true
    var experimentalLipMonitoring = false
    var experimentalFaceMonitoring = false
    var mouthShiftMonitoring = true
    var oralPoseMonitoring = true
    var jawSelfCheck = true
    var bodyBackend: BodyBackend = .mediaPipe
    var pipOnTop = true
    var pipShowsVideo = true
    var pipShowsSkeleton = true
    var pipSize: PiPSize = .small
    var pipCorner: PiPCorner = .topRight
    var pipScreenID = "automatic"
    var pipPlacement: FloatingWindowPlacement?
    var resumeOnLaunch = true
    var mirrored = false
    var dualPreview = false
    private var openPreviewOnCompanionDoubleClick: Bool?
    var companionDoubleClickOpensPreview: Bool {
        get { openPreviewOnCompanionDoubleClick ?? true }
        set { openPreviewOnCompanionDoubleClick = newValue }
    }
    var sustainedSeconds: Double { get { tuning.sustainedSeconds } set { tuning.sustainedSeconds = newValue } }
    var cooldownSeconds: Double { get { tuning.cooldownSeconds } set { tuning.cooldownSeconds = newValue } }
    var reminderConfiguration: ReminderConfiguration { tuning.reminderConfiguration }
    var sensitivity: PostureSensitivity {
        get {
            if tuning.sustainedSeconds == 3 { return .high }
            if tuning.sustainedSeconds == 10 { return .relaxed }
            return .balanced
        }
        set {
            switch newValue {
            case .high:
                tuning.sustainedSeconds = 3
                tuning.headEnterDegrees = 2
                tuning.shoulderEnterDegrees = 6
            case .balanced:
                tuning.sustainedSeconds = 5
                tuning.headEnterDegrees = 3
                tuning.shoulderEnterDegrees = 8
            case .relaxed:
                tuning.sustainedSeconds = 10
                tuning.headEnterDegrees = 5
                tuning.shoulderEnterDegrees = 10
            }
            tuning.headExitDegrees = tuning.headEnterDegrees / 2
            tuning.shoulderExitDegrees = tuning.shoulderEnterDegrees - 3
        }
    }
    init() {}
    static func load(defaults: UserDefaults = .standard) -> MonitorSettings {
        guard let data = defaults.data(forKey: "monitorSettings"),
              let settings = try? JSONDecoder().decode(MonitorSettings.self, from: data) else { return MonitorSettings() }
        var validated = settings
        validated.tuning = settings.tuning.normalized
        if validated.pipPlacement?.isValid == false { validated.pipPlacement = nil }
        return validated
    }
    func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: "monitorSettings") }
    }
}
