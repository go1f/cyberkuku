import Foundation

/// The host owns rendering. A plugin can only publish through its current activation.
@MainActor
final class BubbleOutput {
    private weak var hub: BubbleHub?
    fileprivate let owner: String
    fileprivate let generation = UUID()

    fileprivate init(owner: String, hub: BubbleHub) {
        self.owner = owner; self.hub = hub
    }
    func publish(_ update: BubbleSnapshot) { hub?.publish(update, from: self) }
    func nudge(_ text: String, preview: Bool = false) { hub?.nudge(text, preview: preview, from: self) }
    func close() { hub?.remove(self); hub = nil }
}

@MainActor
final class BubbleHub {
    private let renderer: ReminderPanelController
    private var generations: [String: UUID] = [:]
    private var snapshots: [String: BubbleSnapshot] = [:]

    init(renderer: ReminderPanelController) { self.renderer = renderer }

    func open(_ owner: String) -> BubbleOutput {
        let output = BubbleOutput(owner: owner, hub: self)
        snapshots[owner] = nil
        renderer.withdraw(owner: owner)
        generations[owner] = output.generation
        return output
    }
    fileprivate func publish(_ update: BubbleSnapshot, from output: BubbleOutput) {
        guard generations[output.owner] == output.generation else { return }
        func key(_ id: String) -> String { output.owner + "/" + id }
        snapshots[output.owner] = update.enabled ? BubbleSnapshot(
            alerts: update.alerts.map { var row = $0; row.id = key(row.id); return row },
            ongoingIDs: Set(update.ongoingIDs.map(key)), recoveredIDs: Set(update.recoveredIDs.map(key))) : nil
        if !update.enabled { renderer.withdraw(owner: output.owner, includingPreview: false) }
        refresh()
        snapshots[output.owner]?.recoveredIDs.removeAll()
    }
    fileprivate func nudge(_ text: String, preview: Bool, from output: BubbleOutput) {
        guard generations[output.owner] == output.generation else { return }
        renderer.showNudge(text, ignoreInterval: preview, owner: output.owner)
    }
    fileprivate func remove(_ output: BubbleOutput) {
        guard generations[output.owner] == output.generation else { return }
        generations[output.owner] = nil; snapshots[output.owner] = nil
        renderer.withdraw(owner: output.owner)
        refresh()
    }
    private func refresh() {
        let ordered = snapshots.keys.sorted().compactMap { snapshots[$0] }
        renderer.synchronize(BubbleSnapshot(alerts: ordered.flatMap(\.alerts),
            ongoingIDs: ordered.reduce(into: []) { $0.formUnion($1.ongoingIDs) },
            recoveredIDs: ordered.reduce(into: []) { $0.formUnion($1.recoveredIDs) }))
    }
}
