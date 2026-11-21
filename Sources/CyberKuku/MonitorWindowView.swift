import SwiftUI
import PostureCore

struct MonitorWindowView: View {
    @ObservedObject var model: DiagnosticModel
    @ObservedObject var desktop: DesktopCoordinator

    var body: some View {
        VStack(spacing: 8) {
            instrumentBar
            video.clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(10)
        .frame(minWidth: 720, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .transaction { $0.animation = nil }
    }

    private var instrumentBar: some View {
        HStack(spacing: 12) {
            monitoringControl
            separator
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

            Spacer(minLength: 2)
            previewControls
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 4)
        .frame(height: 48)
    }

    private var monitoringControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: model.toggleMonitoring) {
                Label(model.hasStarted ? "暂停监测" : "开始监测", systemImage: model.hasStarted ? "pause.fill" : "play.fill")
            }
            .help("按空格开始或暂停监测")
            Text(model.monitorSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(statusDetail)
        }
        .frame(width: 104, alignment: .leading)
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
        .help(model.calibrationMessage)
        .fixedSize()
    }

    private func metric(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.map { String(format: "%+.1f°", $0) } ?? "—")
                .font(.system(size: 19, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: 64, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var previewControls: some View {
        HStack(spacing: 6) {
            Menu {
                Toggle("镜像预览", isOn: $model.mirrored)
                    .disabled(model.settings.dualPreview)
                Toggle("双画面对照", isOn: $model.settings.dualPreview)
                Toggle("显示关键点", isOn: $model.settings.showsPreviewLandmarks)
            } label: {
                Label("画面选项", systemImage: "rectangle.on.rectangle")
            }
            .menuStyle(.borderedButton)
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
            if let observation = model.frame?.observation, observation.faceCount == 1,
               let face = observation.faceBox, !model.previewReminderMessages.isEmpty {
                PreviewReminderEffect(observation: observation, face: face, mirrored: mirrored,
                                      messages: model.previewReminderMessages)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
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


private struct PreviewReminderEffect: View {
    let observation: Observation
    let face: FaceBox
    let mirrored: Bool
    let messages: [String]

    var body: some View {
        Canvas { context, size in
            func position(_ x: Double, _ y: Double) -> CGPoint {
                let point = Geometry.previewPoint(Point(x, y), source: observation.imageSize,
                    viewport: ImageSize(size.width, size.height), mirrored: mirrored)
                return CGPoint(x: point.x, y: point.y)
            }
            func bounds(_ a: CGPoint, _ b: CGPoint) -> CGRect {
                CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            }
            let image = bounds(position(0, 0), position(1, 1)).insetBy(dx: 8, dy: 6)
            let protectedFace = bounds(position(face.x, face.y),
                position(face.x + face.width, face.y + face.height)).insetBy(dx: -14, dy: -14)
            let fontSize = min(58, max(18, image.width / 17))
            let step = fontSize * 1.45
            guard image.width > 2 * step, image.height > step else { return }
            var index = 0
            for (row, y) in stride(from: image.minY + step / 2, to: image.maxY, by: step).enumerated() {
                var x = image.minX + CGFloat(row % 2) * fontSize * 0.65
                while x < image.maxX {
                    let text = context.resolve(Text(messages[index % messages.count])
                        .font(.system(size: fontSize, weight: .black))
                        .foregroundColor(.white.opacity(row.isMultiple(of: 2) ? 0.82 : 0.56)))
                    let measured = text.measure(in: CGSize(width: image.width, height: step))
                    let rect = CGRect(x: x, y: y - measured.height / 2, width: measured.width, height: measured.height)
                    if image.contains(rect), !protectedFace.intersects(rect) {
                        var shadow = context
                        shadow.addFilter(.shadow(color: .black.opacity(0.85), radius: 3, y: 2))
                        shadow.draw(text, at: rect.origin, anchor: .topLeading)
                        index += 1
                    }
                    x += max(fontSize, measured.width) + fontSize * 0.75
                }
            }
        }
    }
}
