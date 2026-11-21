import SwiftUI
import PostureCore

struct MonitorWindowView: View {
    @ObservedObject var model: DiagnosticModel
    @ObservedObject var desktop: DesktopCoordinator
    private var details: String {
        [model.monitorDetail ?? "", model.habitTimingSummary].filter { !$0.isEmpty }.joined(separator: "\n")
    }
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("坐姿监测").font(.title2.weight(.semibold))
                    Text(model.isDemo ? "演示输入 · 摄像头未启动" : model.monitorSummary)
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Toggle("双画面对照", isOn: $model.settings.dualPreview).toggleStyle(.switch).controlSize(.small)
                    .help("上下同时显示非镜像与镜像画面")
                Button { desktop.collapseMainToPiP() } label: { Label("画中画", systemImage: "pip.enter") }
                Button { desktop.showSettings() } label: { Label("设置", systemImage: "gearshape") }
                Button { desktop.hideMain() } label: { Image(systemName: "minus") }.help("收起到菜单栏")
            }.frame(height: 50)
            VStack(spacing: 10) {
                if model.settings.dualPreview {
                    MonitorVideoPane(model: model, mirrored: false, title: "非镜像 · 原始画面")
                    MonitorVideoPane(model: model, mirrored: true, title: "镜像画面")
                } else { MonitorVideoPane(model: model, mirrored: model.mirrored, title: nil) }
            }.frame(minHeight: 0, maxHeight: .infinity)
            HStack(spacing: 20) {
                metric("头部偏移", model.rollDeviation)
                metric("肩线偏移", model.shoulderDeviation)
                Spacer(minLength: 0)
                Text(model.monitorSummary).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: 180, alignment: .trailing).help(model.monitorSummary)
                Button(model.hasStarted ? "暂停监测" : "开始监测") { model.toggleMonitoring() }
                    .buttonStyle(.borderedProminent).frame(width: 88)
                    .help("窗口聚焦时，按空格暂停或继续监测")
            }.frame(height: 44)
            Text(details.isEmpty ? " " : details).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true).frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: 32, alignment: .topLeading).help(details)
        }.padding(18).frame(minWidth: 720, minHeight: 520)
            .background(Color(nsColor: .windowBackgroundColor))
            .transaction { $0.animation = nil }
    }
    private func metric(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.map { String(format: "%+.1f°", $0) } ?? "—")
                .font(.system(.title3, design: .rounded)).monospacedDigit()
        }.frame(width: 100, alignment: .leading)
    }
}

private struct MonitorVideoPane: View {
    @ObservedObject var model: DiagnosticModel
    let mirrored: Bool
    let title: String?
    var body: some View {
        ZStack {
            Color.black.opacity(0.9)
            if model.isDemo, let frame = model.frame, let image = frame.image {
                Image(decorative: image, scale: 1).resizable().scaledToFit().scaleEffect(x: mirrored ? -1 : 1, y: 1)
                LandmarkOverlay(observation: frame.observation, metrics: model.metrics, mirrored: mirrored)
            } else if model.status.isActive {
                CameraPreview(session: model.cameraSession, mirrored: mirrored, enabled: model.renderingImageRequested)
                if let frame = model.frame { LandmarkOverlay(observation: frame.observation, metrics: model.metrics, mirrored: mirrored) }
                if model.firstVideoSeconds == nil {
                    Text("正在启动摄像头，识别模块随后就绪").font(.callout).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "camera.viewfinder").font(.system(size: 30, weight: .light))
                    Text(model.hasStarted ? "等待系统恢复后继续监测" : "监测已暂停").font(.headline)
                    if !model.hasStarted { Button("开始监测") { model.toggleMonitoring() }.buttonStyle(.borderedProminent) }
                    if model.status == .denied { Button("打开摄像头设置") { model.openPrivacySettings() } }
                }.foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            if let title {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.black.opacity(0.5), in: Capsule()).padding(10)
            }
        }.clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
