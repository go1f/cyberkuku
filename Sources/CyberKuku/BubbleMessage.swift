import Foundation

struct BubbleMessage: Equatable, Identifiable {
    var id: String
    var title: String
    var message: String
    var seconds: Int
    var recovering: Bool
    var recoveryProgress: Double = 0
    var resolved = false
    var suspended = false
    var animateRecovery = true
}

struct BubbleSnapshot {
    var alerts: [BubbleMessage]
    var ongoingIDs: Set<String>
    var recoveredIDs: Set<String> = []
    var enabled = true
}
