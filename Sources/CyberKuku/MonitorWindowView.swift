import SwiftUI
import PostureCore

struct MonitorWindowView: View {
    @ObservedObject var model: DiagnosticModel
    @ObservedObject var desktop: DesktopCoordinator

    var body: some View {
        GeometryReader { layout in
            let width = min(layout.size.width, max(0, layout.size.height - 114) * 16 / 9)
            VStack(spacing: 14) {
                instrumentBar
                mediaConsole(width: width)
            }
            .frame(width: width)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .transaction { $0.animation = nil }
    }

    private var instrumentBar: some View {
        HStack(spacing: 16) {
            metric("头部偏移", model.rollDeviation)
            separator
            metric("肩线偏移", model.shoulderDeviation)
            separator

            VStack(alignment: .leading, spacing: 4) {
                Text("坐姿参考").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Picker("观看情境", selection: $model.selectedContext) {
                        ForEach(ViewingContext.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .accessibilityLabel("坐姿参考")
                    .disabled(model.calibrationProgress != nil || model.oralSamples.isRecording)
                    .fixedSize()
                    calibrationButton
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 4) {
                Label(model.monitorSummary, systemImage: model.hasStarted ? "waveform" : "pause.circle")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: 200, alignment: .trailing)
            .help([model.monitorDetail, model.habitTimingSummary].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 12)
        .frame(height: 58)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    private var statusDetail: String {
        if model.isDemo { return "演示输入" }
        if let detail = model.monitorDetail, !detail.isEmpty { return detail }
        if !model.habitTimingSummary.isEmpty { return model.habitTimingSummary }
        return model.profile == nil ? "尚未校准" : "参考已保存"
    }

    private var separator: some View { Divider().frame(height: 30) }

    private var calibrationButton: some View {
        Group {
            if let progress = model.calibrationProgress {
                ProgressView(value: progress).frame(width: 46).accessibilityLabel("校准进度")
                Button("取消", action: { model.cancelCalibration() })
            } else {
                Button(model.profile == nil ? "校准…" : "重新校准…") {
                    if model.canCalibrate { model.beginCalibration() }
                    else { desktop.showSettings() }
                }
            }
        }
        .controlSize(.small)
        .help(model.calibrationMessage)
        .fixedSize()
    }

    private func metric(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.map { String(format: "%+.1f°", $0) } ?? "—")
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: 83, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func mediaConsole(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            video.frame(height: width * 9 / 16)
            Divider()
            playbackBar
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.10)) }
    }

    private var playbackBar: some View {
        HStack(spacing: 10) {
            Button(action: model.toggleMonitoring) {
                Label(model.hasStarted ? "暂停监测" : "开始监测", systemImage: model.hasStarted ? "pause.fill" : "play.fill")
                    .font(.callout.weight(.medium))
            }
            .help("按空格开始或暂停监测")

            Spacer(minLength: 0)

            ControlGroup {
                Menu {
                    Toggle("镜像预览", isOn: $model.mirrored)
                        .disabled(model.settings.dualPreview)
                    Toggle("双画面对照", isOn: $model.settings.dualPreview)
                    Toggle("显示关键点", isOn: $model.settings.showsPreviewLandmarks)
                } label: {
                    Label("画面选项", systemImage: "rectangle.on.rectangle")
                }
                .help("画面选项")
                Button(action: desktop.collapseMainToPiP) {
                    Label("画中画", systemImage: "pip.enter")
                }
                .disabled(!model.status.isActive || model.isDemo)
                .help("画中画")
                Button(action: desktop.showSettings) {
                    Label("坐姿设置", systemImage: "gearshape")
                }
                .help("坐姿设置")
            }
            .labelStyle(.iconOnly)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    private var video: some View {
        ZStack {
            Color(nsColor: NSColor(srgbRed: 0.09, green: 0.10, blue: 0.11, alpha: 1))
            if model.status.isActive || (model.isDemo && model.frame?.image != nil) {
                if model.settings.dualPreview {
                    VStack(spacing: 1) {
                        MonitorVideoPane(model: model, mirrored: false, label: "原始画面")
                        MonitorVideoPane(model: model, mirrored: true, label: "镜像画面")
                    }
                } else {
                    MonitorVideoPane(model: model, mirrored: model.mirrored, label: nil)
                }
                if !model.isDemo && model.firstVideoSeconds == nil {
                    videoStatus("正在启动摄像头", icon: "video")
                }
            } else {
                videoStatus(model.status == .denied ? "需要摄像头权限" : "摄像头待命", icon: "video.slash")
            }
        }
    }

    private func videoStatus(_ title: String, icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .accessibilityHidden(true)
            Text(title).font(.callout)
            if model.status == .denied {
                Button("打开摄像头设置", action: model.openPrivacySettings)
            }
        }
        .foregroundStyle(.white.opacity(0.75))
    }
}

private struct MonitorVideoPane: View {
    @ObservedObject var model: DiagnosticModel
    let mirrored: Bool
    let label: String?

    var body: some View {
        ZStack {
            if model.isDemo, let image = model.frame?.image {
                Image(decorative: image, scale: 1)
                    .resizable().scaledToFit().scaleEffect(x: mirrored ? -1 : 1, y: 1)
            } else {
                CameraPreview(session: model.cameraSession, mirrored: mirrored, enabled: model.renderingImageRequested)
            }
            if model.settings.showsPreviewLandmarks, let frame = model.frame {
                LandmarkOverlay(observation: frame.observation, metrics: model.metrics, mirrored: mirrored)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            if let label {
                Text(label).font(.caption.weight(.medium)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.65), in: Capsule()).padding(10)
            }
        }
        .clipped()
    }
}
