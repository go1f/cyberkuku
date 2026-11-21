import AppKit
import SwiftUI
import Combine
import PostureCore

@MainActor
final class DesktopCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    let model: DiagnosticModel
    let router = DisplayRouter()
    private let sharedOutput: BubbleOutput?
    lazy var reminders: ReminderPanelController = {
        let offscreen = CommandLine.arguments.contains("--window-interaction-check") || CommandLine.arguments.contains("--presentation-check")
        let controller = ReminderPanelController(router: router,presentsOnScreen:!offscreen)
        controller.onOpenMonitor = { [weak self] in self?.openMain() }
        controller.onPetVisibilityChanged = { [weak self] in self?.statusPanel.updateGeometry() }
        return controller
    }()
    @Published var showingOralSamples = false
    @Published private(set) var pipVisible = false
    private var mainVisible = false
    private var mainWindow: NSWindow?
    private let standaloneSettings = SettingsWindowController()
    var openPostureSettings: (() -> Void)?
    private var pipPanel: MonitorPanel?
    private var pipVideo: CameraPreviewNSView?
    private var placingPiP = false
    private var lastPlacedFrame: NSRect?
    private var placementWork: DispatchWorkItem?
    private var spaceMonitor: Any?
    private var statusClickMonitor: Any?
    private lazy var statusPanel = StatusPanelController(model: model, desktop: self)
    private var statusItem: NSStatusItem?
    private var subscriptions: Set<AnyCancellable> = []
    private var screenObserver: NSObjectProtocol?

    var embedded: Bool { sharedOutput != nil }
    var pluginMenu: NSMenu { statusPanel.pluginMenu }
    init(model: DiagnosticModel, output: BubbleOutput? = nil) {
        sharedOutput = output
        self.model = model
        super.init()
        if output == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItem = item
            let source = Bundle.main.url(forResource:"StatusIcon",withExtension:"png").flatMap(NSImage.init(contentsOf:))
            item.button?.image = source.map { AppAppearance.statusIcon(source:$0) }
            statusPanel.attach(to: item)
            item.button?.toolTip = "坐姿监测 · 点击查看状态，⌥点击切换画中画"
            statusClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self, event.modifierFlags.contains(.option), let button = self.statusItem?.button,
                          let window = button.window, event.window === window,
                          button.bounds.contains(button.convert(event.locationInWindow, from: nil)) else { return false }
                    self.togglePiP(); return true
                }
                return consumed ? nil : event
            }
        }
        if let output {
            model.onReminderEvent = { event in
                if case .nudge(let text) = event { output.nudge(text) }
            }
            model.onReminderAlertsChanged = { output.publish($0) }
        } else {
            model.onReminderEvent = { [weak self] event in self?.reminders.handle(event) }
            model.onReminderAlertsChanged = { [weak self] update in self?.reminders.synchronize(update) }
        }
        model.onSettingsChanged = { [weak self] _, _ in
            self?.updateRendering()
            self?.statusPanel.updateGeometry()
        }
        model.$status.removeDuplicates().sink { [weak self] status in
            self?.updatePiPVideo(cameraActive: status.isActive)
        }.store(in: &subscriptions)
        model.onWindowClosed = { [weak self] in self?.mainVisible = false; self?.updateRendering() }
        model.$previewExpanded.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateRendering() }
        }.store(in: &subscriptions)
        model.$monitorState.removeDuplicates().sink { [weak self] state in
            self?.statusItem?.button?.toolTip = "坐姿监测 · \(state.label) · ⌥点击切换画中画"
            DispatchQueue.main.async { self?.statusPanel.updateGeometry() }
        }.store(in: &subscriptions)
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated {
                self?.placementWork?.cancel(); self?.placementWork = nil; self?.placePiP()
            } }
        if output == nil { installApplicationMenu() }
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, event.keyCode == 49,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                      let window = event.window, window.isKeyWindow,
                      window === self.mainWindow || window === self.pipPanel,
                      window.attachedSheet == nil, NSApplication.shared.modalWindow == nil,
                      RunLoop.current.currentMode != .eventTracking,
                      !((window.firstResponder as? NSTextView)?.isEditable ?? false) else { return false }
                if !event.isARepeat { self.model.toggleMonitoring() }
                return true
            }
            return consumed ? nil : event
        }
        updateRendering()
    }

    @objc func togglePopover() {
        if NSApplication.shared.currentEvent?.modifierFlags.contains(.option) == true { togglePiP(); return }
        guard let button = statusItem?.button else { return }
        _ = router.workingScreen()
        statusPanel.toggle(relativeTo: button)
    }
    @objc func openMain() { showMain(expandPreview: true) }
    @objc func showSettings() {
        statusPanel.hide()
        if let openPostureSettings {
            openPostureSettings()
        } else {
            standaloneSettings.show(PostureSettingsForm(model: model, desktop: self))
        }
    }

    func showMain(expandPreview: Bool) {
        statusPanel.hide()
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 690),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = PostureExtension.title
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: MonitorWindowView(model: model, desktop: self))
            host.sizingOptions = []
            window.contentView = host
            window.contentMinSize = NSSize(width: 720, height: 520)
            window.delegate = self
            window.center()
            mainWindow = window
            model.attachWindow(window)
        }
        mainVisible = true
        model.previewExpanded = true
        updateRendering()
        NSApplication.shared.activate(ignoringOtherApps: true)
        if mainWindow?.isMiniaturized == true { mainWindow?.deminiaturize(nil) }
        mainWindow?.makeKeyAndOrderFront(nil)
    }
    func hideMain() {
        mainVisible = false; model.previewExpanded = false
        mainWindow?.orderOut(nil); updateRendering()
    }
    @objc func togglePiP() {
        if pipVisible { hidePiP() }
        else if model.status.isActive && !model.isDemo { showPiP() }
    }
    func showPiP(present: Bool = true) {
        statusPanel.hide()
        if pipPanel == nil {
            let panel = MonitorPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: WindowLayout.pipHeight(width: 360)),
                                     styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
            panel.title = "画中画"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.titlebarSeparatorStyle = .none
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                panel.standardWindowButton(button)?.isHidden = true
            }
            panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = false
            panel.level = .floating
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.contentAspectRatio = NSSize(width: 16, height: 9)
            panel.contentMinSize = NSSize(width: 240, height: WindowLayout.pipHeight(width: 240))
            panel.contentMaxSize = NSSize(width: 800, height: WindowLayout.pipHeight(width: 800))
            let video = CameraPreviewNSView(frame: .zero, sessionQueue: model.cameraSessionQueue)
            video.layer?.cornerRadius = 12
            video.layer?.cornerCurve = .continuous
            video.layer?.masksToBounds = true
            video.onDoubleClick = { [weak self] in self?.expandPiP() }
            video.setAccessibilityLabel("摄像头视频，双击返回监测窗口")
            let restoreLabel = "返回监控窗口"
            let restore = NSButton(
                image: NSImage(systemSymbolName: "pip.exit", accessibilityDescription: restoreLabel)
                    ?? NSImage(named: NSImage.revealFreestandingTemplateName)
                    ?? NSImage(),
                target: self,
                action: #selector(expandPiP)
            )
            restore.imagePosition = .imageOnly
            restore.bezelStyle = .push
            restore.controlSize = .large
            restore.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
            restore.toolTip = restoreLabel
            restore.setAccessibilityLabel(restoreLabel)
            restore.translatesAutoresizingMaskIntoConstraints = false
            video.addSubview(restore)
            NSLayoutConstraint.activate([
                restore.topAnchor.constraint(equalTo: video.topAnchor, constant: 10),
                restore.trailingAnchor.constraint(equalTo: video.trailingAnchor, constant: -10),
                restore.widthAnchor.constraint(equalToConstant: 48),
                restore.heightAnchor.constraint(equalToConstant: 38)
            ])
            panel.contentView = video
            panel.delegate = self
            pipVideo = video
            pipPanel = panel
        }
        pipVisible = true
        placePiP()
        updateRendering()
        if present { pipPanel?.orderFrontRegardless() }
    }
    func hidePiP() {
        flushPiPPlacement()
        pipVisible = false
        pipPanel?.orderOut(nil)
        updateRendering()
    }
    @objc func expandPiP() { hidePiP(); showMain(expandPreview: true) }
    func collapseMainToPiP() {
        guard model.status.isActive, !model.isDemo else { return }
        showPiP()
        hideMain()
    }
    func windowDidMove(_ notification: Notification) { queuePiPPlacement(notification) }
    func windowDidResize(_ notification: Notification) { queuePiPPlacement(notification) }
    private func queuePiPPlacement(_ notification: Notification) {
        guard !placingPiP, pipVisible, let panel = notification.object as? NSWindow,
              panel === pipPanel, panel.isVisible, panel.frame != lastPlacedFrame else { return }
        lastPlacedFrame = nil
        placementWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flushPiPPlacement() }
        }
        placementWork = work
        DispatchQueue.main.asyncAfter(deadline: .now()+0.3, execute: work)
    }
    private func flushPiPPlacement() {
        guard placementWork != nil, let panel = pipPanel, let screen = panel.screen else { return }
        placementWork?.cancel(); placementWork = nil
        let placement = FloatingWindowPlacement(displayID: router.identifier(screen), frame: panel.frame,
            visibleFrame: screen.visibleFrame, contentWidth: panel.contentRect(forFrameRect: panel.frame).width)
        if model.settings.pipPlacement != placement { model.settings.pipPlacement = placement }
    }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === pipPanel { flushPiPPlacement(); pipVisible = false; updateRendering() }
    }
    func windowDidMiniaturize(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === mainWindow { mainVisible = false; updateRendering() }
    }
    func windowDidDeminiaturize(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === mainWindow { mainVisible = true; updateRendering() }
    }
    private func placePiP() {
        guard let panel = pipPanel else { return }
        flushPiPPlacement()
        let saved = model.settings.pipPlacement
        let screen = saved.flatMap { placement in
            NSScreen.screens.first { router.identifier($0) == placement.displayID }
        } ?? router.workingScreen()
        guard let screen else { return }
        placingPiP = true; defer { placingPiP = false }
        let area = screen.visibleFrame
        let chrome = panel.frame.height - panel.contentRect(forFrameRect: panel.frame).height
        let width = min(saved?.contentWidth ?? 360, area.width - 36, (area.height - chrome - 36) * 16 / 9)
        panel.setContentSize(NSSize(width: width, height: WindowLayout.pipHeight(width: width)))
        let frame = panel.frame
        let origin = saved?.origin(visibleFrame: area, windowSize: frame.size)
            ?? NSPoint(x: area.maxX - frame.width - 18, y: area.maxY - frame.height - 18)
        panel.setFrameOrigin(origin)
        lastPlacedFrame = panel.frame
    }

    private func updatePiPVideo(cameraActive: Bool) {
        guard let pipVideo else { return }
        let playing = pipVisible && cameraActive && !model.isDemo
        pipVideo.preview.isHidden = !playing
        if playing {
            pipVideo.configure(session: model.cameraSession, mirrored: model.mirrored, enabled: true)
        } else {
            pipVideo.detach()
        }
    }

    private func updateRendering() {
        let full = mainVisible && model.previewExpanded
        model.setRendering(image: full, skeleton: full && model.settings.showsPreviewLandmarks)
        updatePiPVideo(cameraActive: model.status.isActive)
    }
    var petMenuPresentation: PetMenuPresentation { reminders.petMenuPresentation }
    func showPet() { reminders.showPet(); statusPanel.updateGeometry() }
    @objc func togglePet() { reminders.togglePet(); statusPanel.updateGeometry() }
    func previewReminder() {
        if let sharedOutput { sharedOutput.nudge("坐正，放松肩膀", preview: true) }
        else { reminders.preview() }
    }
    func shutdown() {
        flushPiPPlacement(); placementWork?.cancel()
        if let spaceMonitor { NSEvent.removeMonitor(spaceMonitor) }
        if let statusClickMonitor { NSEvent.removeMonitor(statusClickMonitor) }
        model.onReminderAlertsChanged = nil
        model.onReminderEvent = nil
        model.onSettingsChanged = nil
        model.onWindowClosed = nil
        subscriptions.removeAll()
        statusPanel.hide()
        mainWindow?.close(); standaloneSettings.close(); pipPanel?.close()
        if sharedOutput == nil { reminders.shutdown() }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }
    private func installApplicationMenu() {
        let root = NSMenu()
        let appItem = NSMenuItem(title: "CyberKuku", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "CyberKuku")
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self; menu.addItem(settings)
        let status = NSMenuItem(title: "显示菜单栏状态", action: #selector(togglePopover), keyEquivalent: "M")
        status.keyEquivalentModifierMask = [.command, .shift]; status.target = self; menu.addItem(status)
        let open = NSMenuItem(title: "打开监测窗口", action: #selector(openMain), keyEquivalent: "D")
        open.keyEquivalentModifierMask = [.command, .shift]; open.target = self; menu.addItem(open)
        let pip = NSMenuItem(title: "切换画中画", action: #selector(togglePiP), keyEquivalent: "p")
        pip.keyEquivalentModifierMask = [.command, .option]; pip.target = self; menu.addItem(pip)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 CyberKuku", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = menu; root.addItem(appItem)
        let fileItem = NSMenuItem(title: "文件", action: nil, keyEquivalent: "")
        let file = NSMenu(title: "文件")
        let close = NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        close.keyEquivalentModifierMask = [.command]
        // A nil target uses AppKit's responder chain and closes the current window.
        file.addItem(close); fileItem.submenu = file; root.addItem(fileItem)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "编辑")
        edit.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit; root.addItem(editItem)
        NSApplication.shared.mainMenu = root
    }
    var presentationSnapshot: [String: Any] {
        ["pipVisible": pipVisible, "mainVisible": mainVisible, "previewExpanded": model.previewExpanded,
         "popoverVisible": statusPanel.visible, "statusPanel": statusPanel.snapshot,
         "statusItemVisible": statusItem?.isVisible ?? false,
         "pipOnTop": pipPanel?.level == .floating, "pipCanBecomeKey": pipPanel?.canBecomeKey ?? false,
         "previewImageRequested": model.renderingImageRequested, "skeletonRenderingRequested": model.renderingSkeletonRequested,
         "lastFrameHasImage": model.frame?.image != nil,
         "pipContentAspectRatio": pipPanel.map { NSStringFromSize($0.contentAspectRatio) } ?? "",
         "pipIsTitlelessAndRounded": pipPanel?.titleVisibility == .hidden
            && pipPanel?.titlebarAppearsTransparent == true
            && pipPanel?.standardWindowButton(.closeButton)?.isHidden == true
            && pipVideo?.layer?.cornerRadius == 12 && pipVideo?.layer?.masksToBounds == true,
         "pipHasRestoreButton": pipVideo?.subviews.contains { guard let button = $0 as? NSButton else { return false }
            return button.action == #selector(expandPiP) && button.imagePosition == .imageOnly && button.image != nil } == true,
         "pipIsNativeVideo": pipPanel?.contentView === pipVideo && pipVideo != nil,
         "pipFrame": pipPanel.map { NSStringFromRect($0.frame) } ?? "",
         "pipDisplayID": pipPanel?.screen.map { router.identifier($0) } ?? ""]
    }
}
