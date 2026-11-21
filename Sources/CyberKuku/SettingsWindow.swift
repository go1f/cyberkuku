import AppKit
import SwiftUI
import PostureCore

@MainActor
final class SettingsWindowController {
    private(set) var window: NSWindow?

    func show<Content: View>(_ content: @autoclosure () -> Content, activate: Bool = true) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 510),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "CyberKuku 设置"
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
        TabView(selection: $host.settingsPage) {
            Form {
                Section("桌面形象") {
                    Picker("当前形象", selection: Binding(get: { host.appearance.skin }, set: host.adopt)) {
                        ForEach(CompanionSkin.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
            }.formStyle(.grouped)
                .tabItem { Label("伙伴", systemImage: "pawprint") }
                .tag(CompanionHost.SettingsPage.companion)

            VStack(spacing: 0) {
                Toggle("启用注意坐姿", isOn: Binding(get: { host.posture.desktop != nil }, set: host.setPostureEnabled))
                    .toggleStyle(.switch)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                Divider()
                if let desktop = host.posture.desktop {
                    PostureSettingsForm(model: desktop.model, desktop: desktop)
                } else {
                    Spacer()
                    Text("启用后，可从菜单栏开始监测。")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .tabItem { Label("注意坐姿", systemImage: "figure.seated.side") }
            .tag(CompanionHost.SettingsPage.posture)
        }
        .padding(12)
    }
}

struct PostureSettingsForm: View {
    @ObservedObject var model: DiagnosticModel
    @ObservedObject var desktop: DesktopCoordinator

    var body: some View {
        Form {
            Section("校准") {
                Picker("看向哪里", selection: $model.selectedContext) {
                    ForEach(ViewingContext.allCases) { Text($0.label).tag($0) }
                }
                .disabled(model.calibrationProgress != nil || model.oralSamples.isRecording)

                if let progress = model.calibrationProgress {
                    ProgressView(value: progress)
                    Button("取消校准", action: { model.cancelCalibration() })
                } else if model.status.isActive || model.hasStarted {
                    Button(model.profile == nil ? "校准坐姿" : "重新校准") { model.beginCalibration() }
                        .disabled(!model.canCalibrate)
                } else {
                    Button("开始监测以校准") { model.start() }
                }
                Text(model.calibrationMessage).font(.caption).foregroundStyle(.secondary)
            }

            Section("提醒") {
                Toggle("坐姿提醒", isOn: $model.settings.automaticReminders)
                Picker("提醒强度", selection: Binding(get: { model.settings.sensitivity }, set: { model.settings.sensitivity = $0 })) {
                    ForEach(PostureSensitivity.allCases) { Text($0.title).tag($0) }
                }.disabled(!model.settings.automaticReminders)
                Button("试播提醒", action: desktop.previewReminder)
            }

            Section("监测") {
                Toggle("启动时继续上次监测", isOn: $model.settings.resumeOnLaunch)
                Toggle("镜像预览", isOn: $model.mirrored)
            }

            DisclosureGroup("手口习惯") {
                Toggle("手靠近嘴唇时提醒", isOn: $model.settings.handMouthMonitoring)
                Toggle("定时提醒放松下颌", isOn: $model.settings.jawSelfCheck)
                Button("个人动作示范…") { desktop.showingOralSamples = true }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $desktop.showingOralSamples, onDismiss: { if model.oralSamples.isRecording { model.cancelOralRecording() } }) {
            VStack(spacing: 0) {
                Form {
                    OralSampleSettingsView(model: model, store: model.oralSamples)
                }.formStyle(.grouped)
                Button("完成") { desktop.showingOralSamples = false }
                    .keyboardShortcut(.defaultAction)
                    .padding()
            }.frame(width: 420, height: 365)
        }
    }
}
