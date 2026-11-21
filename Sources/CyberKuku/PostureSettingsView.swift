import SwiftUI
import PostureCore

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
