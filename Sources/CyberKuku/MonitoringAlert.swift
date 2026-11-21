import PostureCore

extension BubbleSnapshot {
    static func recoveredPostureIDs(previous: [ReminderChannelSnapshot], current: [ReminderChannelSnapshot]) -> Set<String> {
        let reminded = Set(previous.filter(\.hasReminded).map(\.channel))
        return Set(current.filter {
            reminded.contains($0.channel) && !$0.hasReminded && $0.isObservable && $0.state == .normal
        }.map { "posture." + $0.channel.rawValue })
    }
}
