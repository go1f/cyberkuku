import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private(set) var window: NSWindow?

    func show<Content: View>(_ content: @autoclosure () -> Content, activate: Bool = true) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 750, height: 550),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "CyberKuku 设置"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
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

struct SettingsForm<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
    }
}

struct CyberKukuSettingsView: View {
    @ObservedObject var host: CompanionHost

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 208)
                .background { Rectangle().fill(.regularMaterial).ignoresSafeArea(edges: .vertical) }
            Divider().ignoresSafeArea(edges: .vertical)
            VStack(spacing: 0) {
                pageHeader
                    .padding(.top, -18)
                detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background { Color(nsColor: .controlBackgroundColor).ignoresSafeArea(edges: .vertical) }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                sidebarRow("伙伴", symbol: "pawprint", page: .companion)
                sidebarRow("拓展", symbol: "puzzlepiece.extension", page: .extensions)
                let configurable = host.extensions.enabledEntries.filter {
                    host.extensions.active[$0.id]?.configuration != nil || host.extensions.active[$0.id]?.artwork != nil
                }
                if !configurable.isEmpty {
                    Text("插件配置")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 10)
                        .padding(.top, 16)
                        .padding(.bottom, 3)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(configurable) { entry in
                        sidebarRow(entry.title, symbol: "puzzlepiece.extension", page: .configuration(entry.id))
                    }
                }
            }
            .padding(10)
        }
    }

    private func sidebarRow(_ title: String, symbol: String, page: CompanionHost.SettingsPage) -> some View {
        let selected = host.settingsPage == page || (page == .companion && host.settingsPage == .updates)
        return Button {
            host.settingsPage = page
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 23, height: 23)
                    .accessibilityHidden(true)
                Text(title)
                    .fontWeight(selected ? .semibold : .regular)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(selected ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var pageHeader: some View {
        HStack(spacing: 10) {
            if host.settingsPage == .updates {
                Button {
                    host.settingsPage = .companion
                } label: {
                    Label("返回伙伴", systemImage: "chevron.left").labelStyle(.iconOnly)
                }
            }
            Text(pageTitle).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(height: 38)
    }

    private var pageTitle: String {
        switch host.settingsPage ?? .companion {
        case .companion: "伙伴"
        case .updates: "软件更新"
        case .extensions: "拓展"
        case .configuration(let id): host.extensions.enabledEntries.first { $0.id == id }?.title ?? "插件配置"
        }
    }

    @ViewBuilder private var detail: some View {
        switch host.settingsPage ?? .companion {
        case .companion:
            companionSettings
        case .updates:
            AppUpdateSettingsView(updater: host.updater)
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
    }

    private var companionSettings: some View {
        SettingsForm {
            Section("桌面形象") {
                Picker("切换形象", selection: Binding(get: { host.appearance.selectedID }, set: { id in
                    if let artwork = host.availableArtwork.first(where: { $0.id == id }) { host.adopt(artwork) }
                })) {
                    ForEach(host.availableArtwork) { Text($0.title).tag($0.id) }
                }
            }
            Section("应用") {
                Button(action: host.showUpdateSettings) {
                    HStack {
                        Label("软件更新", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
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
        SettingsForm {
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
                Button("刷新商店") { manager.requestCatalog() }
                    .disabled(manager.catalogStatus == .loading)
            }
        }
    }

    private func extensionLabel(_ entry: ExtensionRegistration) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                Text(entry.detail).font(.caption).foregroundStyle(.secondary)
            }
        } icon: { Image(systemName: "puzzlepiece.extension") }
    }
}
