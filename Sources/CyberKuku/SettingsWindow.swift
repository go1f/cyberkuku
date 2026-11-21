import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private(set) var window: NSWindow?

    func show<Content: View>(_ content: @autoclosure () -> Content, activate: Bool = true) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 750, height: 550),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "CyberKuku 设置"
            window.contentMinSize = NSSize(width: 620, height: 460)
            window.isReleasedWhenClosed = false
            let view = NSHostingView(rootView: content())
            view.sizingOptions = []
            window.contentView = view
            window.center()
            self.window = window
        }
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
    }

    func close() {
        window?.close()
        window?.contentView = nil
        window = nil
    }
}

struct CyberKukuSettingsView: View {
    @ObservedObject var host: CompanionHost

    var body: some View {
        NavigationSplitView {
            List(selection: $host.settingsPage) {
                Label("伙伴", systemImage: "pawprint")
                    .tag(CompanionHost.SettingsPage.companion)
                Label("拓展", systemImage: "puzzlepiece.extension")
                    .tag(CompanionHost.SettingsPage.extensions)
                let configurable = host.extensions.enabledEntries.filter {
                    host.extensions.active[$0.id]?.configuration != nil || host.extensions.active[$0.id]?.artwork != nil
                }
                if !configurable.isEmpty {
                    Section("插件配置") {
                        ForEach(configurable) { entry in
                            Label(entry.title, systemImage: entry.symbol)
                                .tag(CompanionHost.SettingsPage.configuration(entry.id))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 208)
        } detail: {
            switch host.settingsPage ?? .companion {
            case .companion:
                companionSettings
            case .extensions:
                ExtensionsSettings(manager: host.extensions)
            case .configuration(let id):
                if let instance = host.extensions.active[id] {
                    if let configuration = instance.configuration {
                        configuration().id(id)
                    } else if let artwork = instance.artwork {
                        artworkPreview(artwork)
                    }
                }
            }
        }.navigationSplitViewStyle(.balanced)
    }

    private var companionSettings: some View {
        Form {
            Section("桌面形象") {
                Picker("切换形象", selection: Binding(get: { host.appearance.selectedID }, set: { id in
                    if let artwork = host.availableArtwork.first(where: { $0.id == id }) { host.adopt(artwork) }
                })) {
                    ForEach(host.availableArtwork) { Text($0.title).tag($0.id) }
                }
            }
            Section("应用") {
                LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                Button("应用更新…") { host.updater.showWindow() }
            }
        }.formStyle(.grouped)
    }

    private func artworkPreview(_ artwork: CompanionArtwork) -> some View {
        VStack(spacing: 14) {
            if let draw = artwork.draw {
                let image = NSImage(size: NSSize(width: 140, height: 100), flipped: false) { rect in
                    draw(rect.insetBy(dx: 12, dy: 12))
                    return true
                }
                Image(nsImage: image).accessibilityHidden(true)
            }
            Text(artwork.title).font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ExtensionsSettings: View {
    @ObservedObject var manager: ExtensionManager

    var body: some View {
        Form {
            Section("已安装") {
                if manager.installedEntries.isEmpty {
                    Text("还没有安装插件").foregroundStyle(.secondary)
                }
                ForEach(manager.installedEntries) { entry in
                    Toggle(isOn: Binding(get: { manager.installed[entry.id] == true }, set: {
                        manager.setEnabled($0, for: entry.id)
                    })) { extensionLabel(entry) }
                    .toggleStyle(.switch)
                }
            }

            Section("插件商店") {
                if manager.catalogStatus == .loading {
                    ProgressView("正在读取商店…").controlSize(.small)
                }
                if manager.catalogStatus == .failed {
                    Text("暂时无法读取插件商店。").foregroundStyle(.secondary)
                }
                if manager.catalogStatus == .loaded && manager.catalog.isEmpty {
                    Text("暂无适用于当前版本的插件。").foregroundStyle(.secondary)
                }
                ForEach(manager.catalog) { entry in
                    LabeledContent {
                        if manager.installed[entry.id] != nil {
                            Text("已导入").foregroundStyle(.secondary)
                        } else {
                            Button("导入") { manager.install(entry.id) }
                                .accessibilityLabel("导入" + entry.title)
                        }
                    } label: { extensionLabel(entry) }
                }
                Button("刷新商店") { Task { await manager.refreshCatalog() } }
                    .disabled(manager.catalogStatus == .loading)
            }
        }
        .formStyle(.grouped)
        .task {
            if manager.catalogStatus == .idle { await manager.refreshCatalog() }
        }
    }

    private func extensionLabel(_ entry: ExtensionRegistration) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                Text(entry.detail).font(.caption).foregroundStyle(.secondary)
            }
        } icon: { Image(systemName: entry.symbol) }
    }
}
