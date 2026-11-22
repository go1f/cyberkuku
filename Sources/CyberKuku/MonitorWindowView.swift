import SwiftUI
import CoreText
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
        VStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    primaryControls
                    Spacer(minLength: 18)
                    previewControls
                }
                .frame(minWidth: 744)
                HStack {
                    primaryControls
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 20) {
                Circle().fill(model.hasStarted ? Color.green : Color.secondary).frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(model.monitorSummary)
                    .lineLimit(1)
                    .help(statusDetail)
                Spacer(minLength: 8)
                metric("头部偏移", model.rollDeviation)
                metric("肩线偏移", model.shoulderDeviation)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(height: 24)
        }
        .buttonStyle(MonitorToolbarButtonStyle())
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    private var primaryControls: some View {
        HStack(spacing: 8) {
            Button(action: model.toggleMonitoring) {
                Label(model.hasStarted ? "暂停监测" : "开始监测", systemImage: model.hasStarted ? "pause.fill" : "play.fill")
            }
            .buttonStyle(MonitorToolbarButtonStyle(prominent: true))
            .help("按空格开始或暂停监测")
            Menu {
                ForEach(ViewingContext.allCases) { context in
                    Button {
                        model.selectedContext = context
                    } label: {
                        if context == model.selectedContext {
                            Label(context.label, systemImage: "checkmark")
                        } else {
                            Text(context.label)
                        }
                    }
                }
            } label: {
                Text(model.selectedContext.label)
            }
            .modifier(MonitorToolbarMenuStyle())
            .accessibilityLabel("坐姿参考")
            .disabled(model.calibrationProgress != nil || model.oralSamples.isRecording)
            calibrationButton
        }
        .fixedSize()
    }

    private var statusDetail: String {
        if model.isDemo { return "演示输入" }
        if let detail = model.monitorDetail, !detail.isEmpty { return detail }
        if !model.habitTimingSummary.isEmpty { return model.habitTimingSummary }
        return model.profile == nil ? "尚未校准" : "参考已保存"
    }

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
        HStack(spacing: 6) {
            Text(title)
            Text(value.map { String(format: "%+.1f°", $0) } ?? "—")
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .monospacedDigit()
                .frame(minWidth: 45, alignment: .trailing)
        }
        .fixedSize()
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
                Label("画面", systemImage: "rectangle.on.rectangle")
            }
            .modifier(MonitorToolbarMenuStyle())
            .help("画面选项")
            Button(action: desktop.collapseMainToPiP) {
                Label("画中画", systemImage: "pip.enter")
            }
            .disabled(!model.status.isActive || model.isDemo)
            .help("画中画")
            Button(action: desktop.showSettings) {
                Label("设置", systemImage: "gearshape")
            }
            .help("坐姿设置")
        }
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

private enum MonitorToolbarGeometry {
    static let width: CGFloat = 120
    static let height: CGFloat = 38
    static let radius: CGFloat = 9
}

private struct MonitorToolbarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: MonitorToolbarGeometry.width, height: MonitorToolbarGeometry.height)
            .foregroundStyle(prominent ? Color(nsColor: .windowBackgroundColor) : .primary)
            .background(
                Color.primary.opacity(prominent ? 0.88 : configuration.isPressed ? 0.14 : 0.075),
                in: RoundedRectangle(cornerRadius: MonitorToolbarGeometry.radius)
            )
            .opacity(isEnabled ? 1 : 0.48)
    }
}

private struct MonitorToolbarMenuStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .menuStyle(.borderlessButton)
            .frame(width: MonitorToolbarGeometry.width, height: MonitorToolbarGeometry.height)
            .background(Color.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: MonitorToolbarGeometry.radius))
            .fixedSize()
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
                CameraPreview(session: model.cameraSession, sessionQueue: model.cameraSessionQueue, mirrored: mirrored, enabled: model.renderingImageRequested)
            }
            if let observation = model.frame?.observation, observation.faceCount == 1,
               let face = observation.faceBox, !model.previewReminderMessages.isEmpty {
                PreviewReminderEffect(observation: observation, face: face, mirrored: mirrored,
                                      messages: model.previewReminderMessages, layoutSeed: model.previewReminderLayoutSeed)
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


struct PreviewReminderEffect: View {
    static let comicFontRegistered: Bool = {
        guard let url = Bundle.main.url(forResource: "ZCOOLKuaiLe-Regular", withExtension: "ttf", subdirectory: "Fonts")
        else { return false }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            || NSFont(name: "ZCOOLKuaiLe-Regular", size: 20) != nil
    }()

    static func actionWords(for message: String, layoutSeed: UInt64) -> [String] {
        switch message {
        case "双肩放平": return ["高", "低", "不平！"]
        case "放松下颌": return layoutSeed.isMultiple(of: 2) ? ["张嘴"] : ["唔好", "咬", "啦！"]
        case "放松舌头": return ["吐舌"]
        case "放松嘴唇", "放松嘴角": return ["露齿", "笑"]
        case "手离开嘴唇": return ["手", "离开", "嘴唇"]
        case "放松双眼": return ["放松", "双眼"]
        default: return [message]
        }
    }

    private static let soundEffects = ["咻——", "啵", "噔！", "嘘……"]
    private static let asides = ["慢慢嚟", "差一啲啲", "就咁", "好喇"]
    private static let easterEggs = [
        ["立正！"], ["唔准", "抽水"], ["我眼睛", "想旅行"],
        ["小费", "可以多给一点吗"],
        ["双掌平推", "双腿下垂", "唔准抽水", "涡轮增压"]
    ]

    let observation: Observation
    let face: FaceBox
    let mirrored: Bool
    let messages: [String]
    let layoutSeed: UInt64

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
            let face = protectedFace.intersection(image)
            guard !face.isNull else { return }
            let left = CGRect(x: image.minX, y: image.minY, width: face.minX - image.minX, height: image.height)
            let right = CGRect(x: face.maxX, y: image.minY, width: image.maxX - face.maxX, height: image.height)
            let below = CGRect(x: image.minX, y: face.maxY, width: image.width, height: image.maxY - face.maxY)
            var occupied: [CGRect] = []
            var randomState = layoutSeed

            // Replay the same placements on every camera frame for this reminder.
            func nextFraction() -> CGFloat {
                randomState = randomState &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat(randomState >> 40) / 16_777_216
            }

            func draw(_ word: String, in region: CGRect, at fraction: CGFloat, scale: CGFloat, tilt baseTilt: Double, opacity: Double = 1) {
                let horizontalPosition = 0.15 + nextFraction() * 0.70
                let verticalPosition = fraction + (nextFraction() - 0.5) * 0.30
                let tilt = baseTilt + Double(nextFraction() - 0.5) * 12
                guard region.width > 28, region.height > 28 else { return }
                var fontSize = min(180, image.width * scale, region.height * 0.37)
                while fontSize >= (opacity < 0.5 ? 11 : 18) {
                    let text = context.resolve(Text(verbatim: word)
                        .font(Self.comicFontRegistered ? .custom("ZCOOLKuaiLe-Regular", size: fontSize)
                            : .system(size: fontSize, weight: .black, design: .rounded))
                        .foregroundColor(.white.opacity(opacity)))
                    let measured = text.measure(in: CGSize(width: 4096, height: 1024))
                    // Reserve room for the tilt and the outline around the lettering.
                    let padding = measured.width * abs(sin(tilt * .pi / 180)) + 6
                    let width = measured.width + padding
                    let height = measured.height + padding
                    if width <= region.width, height <= region.height {
                        let center = CGPoint(x: region.minX + width / 2 + (region.width - width) * horizontalPosition,
                            y: min(region.maxY - height / 2, max(region.minY + height / 2, region.minY + region.height * verticalPosition)))
                        let rect = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
                        if !occupied.contains(where: { $0.intersects(rect) }) {
                            var ink = context
                            ink.clip(to: Path(region))
                            ink.translateBy(x: center.x, y: center.y)
                            ink.rotate(by: .degrees(tilt))
                            ink.addFilter(.shadow(color: .black.opacity(0.95), radius: 4, y: 3))
                            ink.draw(text, at: .zero)
                            occupied.append(rect)
                            return
                        }
                    }
                    fontSize *= 0.86
                }
            }

            var seen: Set<String> = []
            let messages = self.messages.filter { seen.insert($0).inserted }
            let secondaryY = max(below.minY, image.minY + image.height * 0.75)
            let secondaryBand = CGRect(x: below.minX, y: secondaryY,
                                       width: below.width, height: below.maxY - secondaryY)
            func actionArea(_ side: CGRect) -> CGRect {
                guard messages.count > 1, secondaryBand.height >= 60 else { return side }
                return CGRect(x: side.minX, y: side.minY, width: side.width, height: secondaryY - side.minY)
            }
            let widerSide = actionArea(left.width >= right.width ? left : right)
            let otherSide = actionArea(left.width >= right.width ? right : left)

            func drawSecondary(_ message: String) {
                let words = Self.actionWords(for: message, layoutSeed: layoutSeed)
                let width = secondaryBand.width / CGFloat(words.count)
                for (index, word) in words.enumerated() {
                    let slot = CGRect(x: secondaryBand.minX + CGFloat(index) * width, y: secondaryBand.minY,
                                      width: width, height: secondaryBand.height)
                    draw(word, in: slot, at: 0.55, scale: 0.085, tilt: 0)
                }
            }

            let headDirections = ["头向左扶正": "向左", "头向右扶正": "向右"]
            if let instruction = messages.first(where: { headDirections[$0] != nil }),
               let direction = headDirections[instruction] {
                // An unmirrored camera shows the user's right on the viewer's left.
                let appearsOnRight = (direction == "向右") == mirrored
                let directionSide = actionArea(appearsOnRight ? right : left)
                let oppositeSide = actionArea(appearsOnRight ? left : right)
                draw(direction, in: directionSide, at: 0.42, scale: 0.18, tilt: appearsOnRight ? -7 : 7)
                draw("头", in: oppositeSide, at: 0.29, scale: 0.11, tilt: 8)
                draw("扶正", in: oppositeSide, at: 0.70, scale: 0.095, tilt: -5)
                if let secondary = messages.first(where: { $0 != instruction }) {
                    drawSecondary(secondary)
                }
                draw(direction, in: directionSide, at: 0.83, scale: 0.065, tilt: appearsOnRight ? 8 : -8, opacity: 0.54)
            } else if let instruction = messages.first {
                let words = Self.actionWords(for: instruction, layoutSeed: layoutSeed)
                for (index, word) in words.enumerated() {
                    var region = index == 1 ? otherSide : widerSide
                    if words.count == 3, index != 1 {
                        region.size.height /= 2
                        if index == 2 { region.origin.y += region.height }
                    }
                    let positions: [CGFloat] = words.count == 3 ? [0.48, 0.48, 0.52] : [0.35, 0.55]
                    let scales: [CGFloat] = [0.15, 0.15, 0.12]
                    draw(word, in: region, at: positions[index], scale: scales[index], tilt: index == 1 ? 6 : -6)
                }
                if let secondary = messages.dropFirst().first {
                    drawSecondary(secondary)
                }
                draw(words.last ?? instruction, in: widerSide, at: 0.83, scale: 0.06, tilt: 8, opacity: 0.54)
            }

            let decoration = nextFraction()
            if decoration < 0.10 {
                let phrase = Self.easterEggs[Int(nextFraction() * CGFloat(Self.easterEggs.count))]
                for (index, word) in phrase.enumerated() {
                    let region = index.isMultiple(of: 2) ? widerSide : otherSide
                    draw(word, in: region, at: index < 2 ? 0.12 : 0.90, scale: 0.04, tilt: -4, opacity: 0.34)
                }
            } else if decoration < 0.68 {
                let words = decoration < 0.40 ? Self.soundEffects : Self.asides
                let word = words[Int(nextFraction() * CGFloat(words.count))]
                draw(word, in: otherSide, at: 0.88, scale: 0.045, tilt: 7, opacity: 0.38)
            }
        }
    }
}
