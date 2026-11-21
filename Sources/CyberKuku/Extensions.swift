import AppKit
import SwiftUI

struct CompanionArtwork: Identifiable {
    let id: String
    let title: String
    var draw: ((CGRect) -> Void)? = nil

    static let cat = CompanionArtwork(id: "cat", title: "小灰猫")
}

struct ExtensionContext {
    let bubbles: BubbleOutput
    let openSettings: () -> Void
    let restoringAtLaunch: Bool
}

@MainActor
struct ActiveExtension {
    var configuration: (() -> AnyView)? = nil
    var makeMenu: (() -> NSMenu)? = nil
    var openWindow: (() -> Void)? = nil
    var allowsCompanionShortcut: () -> Bool = { false }
    var artwork: CompanionArtwork? = nil
    var stop: () -> Void = {}
}

@MainActor
struct ExtensionRegistration: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let activate: (ExtensionContext) -> ActiveExtension
}

struct ExtensionCatalog: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        let id: String
        let apiVersion: Int
    }
    let schema: Int
    let extensions: [Entry]

    static func decode(_ data: Data) throws -> Self {
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        guard catalog.schema == 1, catalog.extensions.count <= 200,
              Set(catalog.extensions.map(\.id)).count == catalog.extensions.count else { throw CatalogError.invalid }
        return catalog
    }

    static func fetch() async throws -> Self {
        let url = URL(string: "https://github.com/go1f/cyberkuku/releases/latest/download/extensions.json")!
        let (bytes, response) = try await URLSession.shared.bytes(for: URLRequest(url: url, timeoutInterval: 15))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CatalogError.unavailable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 128 * 1024 else { throw CatalogError.invalid }
            data.append(byte)
        }
        return try decode(data)
    }

    enum CatalogError: Error { case unavailable, invalid }
}

@MainActor
final class ExtensionManager: ObservableObject {
    static let preferenceKey = "extensions.installed"

    private let registrations: [ExtensionRegistration]
    private let defaults: UserDefaults
    private let bubbles: BubbleHub
    private var catalogTask: Task<Void, Never>?
    private let fetchCatalog: @Sendable () async throws -> ExtensionCatalog
    var onChange: (String?, Bool) -> Void = { _, _ in }
    var openSettings: (String) -> Void = { _ in }
    @Published private(set) var installed: [String: Bool]
    @Published private(set) var active: [String: ActiveExtension] = [:]
    @Published private(set) var catalog: [ExtensionRegistration] = []
    @Published private(set) var catalogStatus: CatalogStatus = .idle

    enum CatalogStatus { case idle, loading, loaded, failed }

    init(registrations: [ExtensionRegistration], defaults: UserDefaults, bubbles: BubbleHub,
         fetchCatalog: @escaping @Sendable () async throws -> ExtensionCatalog = { try await ExtensionCatalog.fetch() }) {
        self.registrations = registrations
        self.defaults = defaults
        self.bubbles = bubbles
        self.fetchCatalog = fetchCatalog
        installed = defaults.dictionary(forKey: Self.preferenceKey) as? [String: Bool] ?? [:]
    }

    var installedEntries: [ExtensionRegistration] { registrations.filter { installed[$0.id] != nil } }
    var enabledEntries: [ExtensionRegistration] { installedEntries.filter { active[$0.id] != nil } }

    func restore() {
        for entry in installedEntries where installed[entry.id] == true {
            start(entry, restoringAtLaunch: true)
        }
        onChange(nil, false)
    }

    @discardableResult
    func requestCatalog(onlyIfIdle: Bool = false) -> Task<Void, Never>? {
        if let catalogTask { return catalogTask }
        guard !onlyIfIdle || catalogStatus == .idle else { return nil }
        let fetch = fetchCatalog
        let task = Task(priority: .utility) { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.catalogStatus = .loading
            do {
                let result = try await fetch()
                guard !Task.isCancelled, let self else { return }
                let supported = Set(result.extensions.filter { $0.apiVersion == 1 }.map(\.id))
                catalog = registrations.filter { supported.contains($0.id) }
                catalogStatus = .loaded
            } catch {
                if !Task.isCancelled { self?.catalogStatus = .failed }
            }
            self?.catalogTask = nil
        }
        catalogTask = task
        return task
    }

    func install(_ id: String) {
        guard installed[id] == nil, catalog.contains(where: { $0.id == id }) else { return }
        installed[id] = false
        persist()
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        guard let previous = installed[id], previous != enabled,
              let entry = registrations.first(where: { $0.id == id }) else { return }
        installed[id] = enabled
        if enabled { start(entry, restoringAtLaunch: false) } else { active.removeValue(forKey: id)?.stop() }
        persist()
        onChange(id, enabled)
    }

    private func start(_ entry: ExtensionRegistration, restoringAtLaunch: Bool) {
        let output = bubbles.open(entry.id)
        var extensionInstance = entry.activate(ExtensionContext(
            bubbles: output, openSettings: { [weak self] in self?.openSettings(entry.id) },
            restoringAtLaunch: restoringAtLaunch))
        let stop = extensionInstance.stop
        extensionInstance.stop = { output.close(); stop() }
        active[entry.id] = extensionInstance
    }

    func shutdown() {
        catalogTask?.cancel()
        catalogTask = nil
        let running = active.values
        active = [:]
        for instance in running { instance.stop() }
    }

    private func persist() { defaults.set(installed, forKey: Self.preferenceKey) }
}
