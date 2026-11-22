import AppKit
import SwiftUI
import AVFoundation
import PostureCore

@MainActor enum PresentationChecks {
    static func run(directory: String) {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            let model = DiagnosticModel(demo: true)
            let desktop = DesktopCoordinator(model: model)
            do {
                recoveryTransitions()
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                model.setRendering(image: true, skeleton: true)
                try await Task.sleep(nanoseconds: 250_000_000)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 690),
                    styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let host = NSHostingView(rootView: MonitorWindowView(model: model, desktop: desktop))
                host.sizingOptions = []; window.contentView = host
                let original = window.frame
                var menuSizes: [String] = []
                for index in 0..<12 {
                    model.monitorState = index.isMultiple(of: 2) ? .normal : .unknown(String(repeating: "正在等待清晰姿态，暂不提醒。", count: 8))
                    model.settings.dualPreview = index.isMultiple(of: 3)
                    model.mirrored = index.isMultiple(of: 2)
                    try await Task.sleep(nanoseconds: 40_000_000)
                    host.layoutSubtreeIfNeeded()
                    precondition(window.frame == original, "Status text resized the application window")
                    let snapshot = desktop.presentationSnapshot["statusPanel"] as! [String:Any]
                    precondition(snapshot["systemAnchored"] as? Bool == true)
                    precondition(snapshot["hasCustomRows"] as? Bool == false)
                    let titles = snapshot["itemTitles"] as! [String]
                    precondition(titles.contains("镜像预览") && !titles.contains(where: { $0.contains("更新") }))
                    menuSizes.append("\(snapshot["width"]!)x\(snapshot["height"]!)")
                }
                precondition(Set(menuSizes).count == 1, "Status changes resized the menu")
                @MainActor func renderMonitor(_ name: String, size: CGSize = CGSize(width: 940, height: 690),
                                   appearance: NSAppearance.Name = .aqua) async throws {
                    window.appearance = NSAppearance(named: appearance)
                    window.setContentSize(size)
                    try await Task.sleep(nanoseconds: 200_000_000)
                    host.layoutSubtreeIfNeeded()
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    guard let data = bitmap.representation(using: .png, properties: [:]) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try data.write(to: folder.appendingPathComponent(name + ".png"))
                }
                model.settings.dualPreview = true
                model.setRendering(image: true, skeleton: true)
                try await renderMonitor("dual-preview")
                model.settings.dualPreview = false
                model.setRendering(image: true, skeleton: true)
                try await renderMonitor("single-preview")
                model.toggleMonitoring()
                try await renderMonitor("paused-preview", size: CGSize(width: 720, height: 520))
                try await renderMonitor("dark-preview", appearance: .darkAqua)
                precondition(PreviewReminderEffect.comicFontRegistered, "Missing bundled comic font")
                let demo = DemoFrame.packet(scenario: .headTilt, timestamp: 1)
                if let face = demo.observation.faceBox, let image = demo.image {
                    var firstLayout: Data?
                    for (mirrored, seed, name) in [
                        (false, UInt64(17), "reminder-type.png"),
                        (false, UInt64(91), "reminder-type-alternate.png"),
                        (false, UInt64(17), "reminder-type-repeated.png"),
                        (true, UInt64(17), "reminder-type-mirrored.png")
                    ] {
                        let review = ZStack {
                            Color.black
                            Image(decorative: image, scale: 1).resizable().scaledToFit()
                                .scaleEffect(x: mirrored ? -1 : 1)
                            PreviewReminderEffect(observation: demo.observation, face: face, mirrored: mirrored,
                                                  messages: ["头向右扶正", "双肩放平"], layoutSeed: seed)
                        }.frame(width: 880, height: 495)
                        let renderer = ImageRenderer(content: review)
                        guard let data = renderer.nsImage?.tiffRepresentation,
                              let bitmap = NSBitmapImageRep(data: data),
                              let png = bitmap.representation(using: .png, properties: [:]) else {
                            throw CocoaError(.fileWriteUnknown)
                        }
                        if name == "reminder-type.png" { firstLayout = png }
                        if name == "reminder-type-alternate.png" { precondition(png != firstLayout) }
                        if name == "reminder-type-repeated.png" {
                            precondition(png == firstLayout)
                            continue
                        }
                        try png.write(to: folder.appendingPathComponent(name))
                    }
                }
                desktop.showPiP(present: false)
                let pip = desktop.presentationSnapshot
                precondition(pip["pipIsNativeVideo"] as? Bool == true)
                precondition(pip["pipHasRestoreButton"] as? Bool == true)
                precondition(pip["pipIsTitlelessAndRounded"] as? Bool == true && pip["pipOnTop"] as? Bool == true)
                precondition(NSSizeFromString(pip["pipContentAspectRatio"] as! String) == NSSize(width: 16, height: 9))
                precondition(pip["previewImageRequested"] as? Bool == false && pip["skeletonRenderingRequested"] as? Bool == false)
                desktop.hidePiP()

                var time = 0.0
                let banner = ReminderPanelController(router: DisplayRouter(), now: { time }, presentsOnScreen: false)
                let head = BubbleMessage(id: "head", title: "歪头", message: "头向左扶正", seconds: 8, recovering: false)
                banner.synchronize(BubbleSnapshot(alerts: [head], ongoingIDs: [head.id]))
                try banner.renderReview(to: folder.appendingPathComponent("reminder-active.png"))
                var recovering = head; recovering.recovering = true; recovering.recoveryProgress = 0.6
                time = 1; banner.synchronize(BubbleSnapshot(alerts: [recovering], ongoingIDs: [head.id]))
                try banner.renderReview(to: folder.appendingPathComponent("reminder-recovering.png"))
                time = 2; banner.synchronize(BubbleSnapshot(alerts: [], ongoingIDs: [], recoveredIDs: [head.id]))
                try banner.renderReview(to: folder.appendingPathComponent("reminder-complete.png"))
                time = 2.5; banner.synchronize(BubbleSnapshot(alerts: [], ongoingIDs: []))
                try banner.renderReview(to: folder.appendingPathComponent("reminder-recovered-hold.png"))
                banner.synchronize(BubbleSnapshot(alerts: [], ongoingIDs: [], enabled: false))
                for name in ["reminder-active.png", "reminder-recovering.png", "reminder-complete.png", "reminder-recovered-hold.png"] {
                    let image = NSBitmapImageRep(data: try Data(contentsOf: folder.appendingPathComponent(name)))!
                    precondition(image.colorAt(x: 0, y: 0)!.alphaComponent < 0.01, "Reminder corner became square")
                    precondition(image.colorAt(x: image.pixelsWide/2, y: image.pixelsHigh/2)!.alphaComponent > 0.99)
                }
                let report: [String:Any] = ["passed":true, "input":"synthetic images and offscreen native views; no camera or desktop capture",
                    "windowFrameStableAcrossStatusAndPreviewChanges":true, "nativeMenuSizeStable":true,
                    "menuAttachedToNativeStatusItem":true, "menuHasOnlyNativeRows":true,
                    "mirrorMenuPresent":true, "updateMenuAbsent":true, "menuSizes":menuSizes,
                    "roundedCornersPreservedAcrossRecovery":true,
                    "onlyVerifiedEpisodeTransitionsReportRecovery":true,
                    "nativeVideoOnlyPiP":true, "titlelessRoundedFloatingPiP":true,
                    "renders":["dual-preview.png","single-preview.png","paused-preview.png","dark-preview.png","reminder-active.png","reminder-recovering.png","reminder-complete.png","reminder-recovered-hold.png"]]
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
                try data.write(to: folder.appendingPathComponent("checks.json"), options:.atomic)
                print(String(data:data,encoding:.utf8)!)
                desktop.shutdown(); model.shutdown(); window.close(); app.terminate(nil)
            } catch { desktop.shutdown(); model.shutdown(); fputs("Presentation checks failed: \(error)\n",stderr); exit(1) }
        }
        app.run()
    }
    private static func recoveryTransitions() {
        var configuration = ReminderConfiguration()
        configuration.sustainedSeconds = 0.5; configuration.recoverySeconds = 0.5; configuration.settleSeconds = 0.2
        configuration.cooldownSeconds = 0
        var engine = ReminderEngine(configuration: configuration)
        var previous: [ReminderChannelSnapshot] = []
        var events: Set<String> = []
        @MainActor func sample(_ time: Double, roll: Double, shoulder: Double, context: String = "a") {
            let result = engine.observe(ReminderInput(timestamp: time, contextID: context, reliable: true,
                rollDeviation: roll, shoulderDeviation: shoulder))
            events.formUnion(BubbleSnapshot.recoveredPostureIDs(previous: previous, current: result.channels))
            previous = result.channels
        }
        for i in 0..<40 { sample(Double(i)/10, roll: 10, shoulder: 15) }
        precondition(previous.allSatisfy(\.hasReminded))
        for i in 40..<60 { sample(Double(i)/10, roll: 0, shoulder: 15) }
        precondition(events == ["posture.head"] && previous.last?.hasReminded == true)
        events = []
        for i in 60..<80 { sample(Double(i)/10, roll: 0, shoulder: 0, context: "b") }
        precondition(events.isEmpty, "Changing reference must not confirm the previous episode")
        for i in 80..<120 { sample(Double(i)/10, roll: 10, shoulder: 15, context: "b") }
        precondition(previous.allSatisfy(\.hasReminded))
        let reset = engine.reset()
        precondition(BubbleSnapshot.recoveredPostureIDs(previous: previous, current: reset.channels).isEmpty)
        previous = reset.channels; events = []
        for i in 120..<140 { sample(Double(i)/10, roll: 0, shoulder: 0, context: "b") }
        precondition(events.isEmpty, "Pause/reset must not be presented as confirmed recovery")
    }
    static func cameraConnections() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            print("{\"skipped\":true,\"reason\":\"Existing camera permission required; none requested\"}"); return
        }
        do {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified) else {
                throw NSError(domain:"CyberKukuDualPreview",code:1,userInfo:[NSLocalizedDescriptionKey:"Built-in camera unavailable"])
            }
            let session = AVCaptureSession(); session.beginConfiguration(); session.sessionPreset = .high
            let input = try AVCaptureDeviceInput(device: device)
            precondition(session.canAddInput(input)); session.addInput(input)
            let original = AVCaptureVideoPreviewLayer(session: session)
            let mirrored = AVCaptureVideoPreviewLayer(session: session)
            session.commitConfiguration(); session.startRunning()
            defer { session.stopRunning(); original.session = nil; mirrored.session = nil }
            guard let a = original.connection, let b = mirrored.connection else {
                throw NSError(domain:"CyberKukuDualPreview",code:2,userInfo:[NSLocalizedDescriptionKey:"Two preview connections were not created"])
            }
            precondition(a !== b && a.isVideoMirroringSupported && b.isVideoMirroringSupported)
            a.automaticallyAdjustsVideoMirroring = false; a.isVideoMirrored = false
            b.automaticallyAdjustsVideoMirroring = false; b.isVideoMirrored = true
            precondition(session.isRunning && session.inputs.count == 1 && !a.isVideoMirrored && b.isVideoMirrored)
            print("{\"passed\":true,\"input\":\"brief built-in camera connection check; no images saved\",\"cameraInputs\":1,\"independentMirroredPreviewConnections\":2}")
        } catch { fputs("Dual preview check failed: \(error)\n",stderr); exit(1) }
    }
}
