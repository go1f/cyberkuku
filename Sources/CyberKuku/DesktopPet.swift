import AppKit
import PostureCore

struct PetMenuPresentation: Equatable {
    let action: String
    let detail: String
    let check: NSControl.StateValue
    let canHide: Bool
}

/// Independent windows keep the space between the companion and speech clickable.
@MainActor final class DesktopPetController {
    var onDismiss: () -> Void = {}
    var onOpenMonitor: () -> Void = {}
    var onVisibilityChanged: () -> Void = {}
    private let cat = PassivePanel(contentRect:NSRect(origin:.zero,size:PetPlacement.companionSize),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
    private var bubbles: [String:(PassivePanel,ComicBubbleView)] = [:]
    private var order: [String] = []
    private var timer: Timer?, environmentTimer: Timer?, proximityTimer: Timer?
    private var hoverPeeking = false, peekReturning = false, peekArmed = true
    private var foldedAnchor: CGRect?, peekLeaveAt: Double?
    private var peekGeneration = 0
    private var pointerDrag: PetPointerDrag?
    private var pressedPointer = CGPoint.zero, pressedFrame = CGRect.zero
    private struct FullScreenReturn {
        let frame: CGRect
        let expanded: CGRect
        let anchor: CGRect?
        let behavior: PetEdgeBehavior
        let display: CGDirectDisplayID
    }
    private struct EdgeTravel {
        let start: CGPoint, end: CGPoint
        let began: Double
        let side: PetEdge
        let target: CGRect
        let generation: Int
    }
    private var fullScreenPinned = false
    private var fullScreenReturn: FullScreenReturn?
    private var edgeTravel: EdgeTravel?
    private var fullScreenGeneration = 0
    private var automaticEdge: PetEdge?
    private var timerRate = 0.0, lastPaint = 0.0
    private var enabled = false, placed = false, suppressed = false, dragging = false
    private var hidden: Bool
    private var manuallyShown: Bool
    private var sessionBlockers: Set<MonitoringInterruption> = []
    private var sessionObservers: [NSObjectProtocol] = []
    private let defaults: UserDefaults
    private let presentsOnScreen: Bool
    private let displayCoverage: @MainActor () -> Set<CGDirectDisplayID>
    private var lastMenuPresentation: PetMenuPresentation?
    private let router = DisplayRouter()
    private var screenObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var catView: CatCompanionView!
    private var behavior = PetEdgeBehavior()
    private var rng = SystemRandomNumberGenerator()
    private var lastMessages: [BubbleMessage] = []
    private var lastText = "", lastPresentation = -Double.infinity
    private var expandedFrame = CGRect.zero
    private var stableFrames: [String:CGRect] = [:]
    private var lastCatFrame = CGRect.zero, lastArea = CGRect.zero
    private var layoutSeed = Int.random(in:0..<8)
    private var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    init(defaults: UserDefaults = .standard,presentsOnScreen: Bool = true,allowsHiding: Bool = true,coveredDisplays: @escaping @MainActor () -> Set<CGDirectDisplayID> = { PetFullscreenMonitor.coveredDisplays() }) {
        self.defaults = defaults; self.presentsOnScreen = presentsOnScreen; self.displayCoverage = coveredDisplays
        hidden = allowsHiding && defaults.bool(forKey:"desktopPet.hidden")
        manuallyShown = allowsHiding && defaults.bool(forKey:"desktopPet.manuallyShown")
        configure(cat); cat.title = "CyberKuku 小灰猫"
        catView = CatCompanionView(frame:NSRect(origin:.zero,size:cat.frame.size))
        catView.onClick = { [weak self] in
            guard let self else { return }
            if self.hoverPeeking || self.peekReturning { self.pinHoverPeek() }
            else if self.behavior.edge != nil { self.unfold() }
            else { self.onDismiss() }
        }
        catView.onDoubleClick = { [weak self] in self?.onOpenMonitor() }
        catView.onPress = { [weak self] point in self?.capturePress(at:point) }
        catView.onMove = { [weak self] point, finished in self?.move(point,finished:finished) }
        if allowsHiding { catView.onHide = { [weak self] in self?.hideByUser() } }
        catView.onInteraction = { [weak self] in self?.updateRotation(); self?.ensureTimer() }
        cat.contentView = catView
        screenObserver = NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }
                self.refreshEnvironment()
                if !self.dragging && self.fullScreenReturn == nil { self.cancelHoverPeek(); self.restore() }
                self.refreshEnvironment(); self.layout() }
        }
        for (name,reason) in [(NSWorkspace.willSleepNotification,MonitoringInterruption.systemSleep),
                              (NSWorkspace.screensDidSleepNotification,.displaySleep),
                              (NSWorkspace.sessionDidResignActiveNotification,.sessionInactive)] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspendAppearance(reason) }
            })
        }
        for (name,reason) in [(NSWorkspace.didWakeNotification,MonitoringInterruption.systemSleep),
                              (NSWorkspace.screensDidWakeNotification,.displaySleep),
                              (NSWorkspace.sessionDidBecomeActiveNotification,.sessionInactive)] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeAppearance(reason) }
            })
        }
        for (name,locked) in [("com.apple.screenIsLocked",true),("com.apple.screenIsUnlocked",false)] {
            sessionObservers.append(DistributedNotificationCenter.default().addObserver(forName:NSNotification.Name(name),object:nil,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if locked { self?.suspendAppearance(.screenLocked) }
                    else { self?.sessionBlockers.removeAll(); self?.refreshVisibility() }
                }
            })
        }
        for name in [NSWorkspace.activeSpaceDidChangeNotification,NSWorkspace.didActivateApplicationNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshEnvironment() }
            })
        }
        if manuallyShown && !hidden { refreshVisibility() }
    }
    deinit {
        timer?.invalidate(); environmentTimer?.invalidate(); proximityTimer?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in sessionObservers { DistributedNotificationCenter.default().removeObserver(observer) }
    }
    private func publishState() {
        let state = menuPresentation
        guard state != lastMenuPresentation else { return }
        lastMenuPresentation = state; onVisibilityChanged()
    }
    private func showCat() { if presentsOnScreen { cat.orderFrontRegardless() } }
    private func configure(_ panel: NSPanel) {
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = false; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenNone,.ignoresCycle]
    }
    private func screenForCat() -> NSScreen? {
        if let best = NSScreen.screens.max(by:{ overlap($0.visibleFrame,cat.frame) < overlap($1.visibleFrame,cat.frame) }), overlap(best.visibleFrame,cat.frame)>0 { return best }
        return NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }
    private func overlap(_ a: CGRect,_ b: CGRect) -> CGFloat { let i = a.intersection(b); return i.isNull ? 0 : i.width*i.height }
    var userHidden: Bool { hidden }
    func useSkin(_ skin: CompanionSkin) {
        catView.skin = skin
        cat.title = "CyberKuku " + skin.title
        catView.setAccessibilityLabel(skin.title + "，双击打开伙伴或监测窗口，拖到左右边缘收纳")
    }
    private var wantsVisible: Bool { !hidden && (enabled || manuallyShown) }
    private var allowsDisplay: Bool { wantsVisible && sessionBlockers.isEmpty }
    var menuPresentation: PetMenuPresentation {
        if hidden { return PetMenuPresentation(action:"显示小灰猫",detail:"小灰猫：已隐藏",check:.off,canHide:false) }
        if !sessionBlockers.isEmpty { return PetMenuPresentation(action:"显示小灰猫",detail:"小灰猫：系统中断，暂时隐藏",check:.mixed,canHide:false) }
        if !wantsVisible { return PetMenuPresentation(action:"显示小灰猫",detail:"小灰猫：未显示",check:.off,canHide:false) }
        if suppressed && !fullScreenPinned { return PetMenuPresentation(action:"显示小灰猫",detail:"小灰猫：全屏中，已自动收纳",check:.mixed,canHide:false) }
        if hoverPeeking || peekReturning { return PetMenuPresentation(action:"固定小灰猫",detail:"小灰猫：临时探出，点击固定",check:.mixed,canHide:false) }
        if let edge = behavior.edge { return PetMenuPresentation(action:"展开小灰猫",detail:"小灰猫：已收纳在"+(edge == .left ? "左侧" : "右侧"),check:.mixed,canHide:false) }
        if presentsOnScreen && (!cat.isVisible || !cat.isOnActiveSpace) { return PetMenuPresentation(action:"显示小灰猫",detail:"小灰猫：当前桌面未显示",check:.off,canHide:false) }
        return PetMenuPresentation(action:"隐藏小灰猫",detail:enabled ? "小灰猫：已显示" : "小灰猫：已显示（静止）",check:.on,canHide:true)
    }
    func setEnabled(_ value: Bool) {
        guard enabled != value || !placed else { return }
        enabled = value; catView.breathes = value
        refreshVisibility()
    }
    private func refreshVisibility() {
        guard allowsDisplay else { shutdownWindows(); publishState(); return }
        if !placed { restore() }
        startEnvironmentTimer(); refreshEnvironment()
        showCat(); catView.synchronizePointer()
        updateRotation(); ensureTimer(); publishState()
    }
    private func suspendAppearance(_ reason: MonitoringInterruption) {
        sessionBlockers.insert(reason); shutdownWindows(); publishState()
    }
    private func resumeAppearance(_ reason: MonitoringInterruption) {
        sessionBlockers.remove(reason); refreshVisibility()
    }
    func toggleVisibility() { if menuPresentation.canHide { hideByUser() } else { showByUser() } }
    private func hideByUser() {
        hidden = true; manuallyShown = false
        if fullScreenReturn != nil { restoreAfterFullScreen(animated:false,show:false) }
        defaults.set(true,forKey:"desktopPet.hidden"); defaults.set(false,forKey:"desktopPet.manuallyShown")
        shutdownWindows(); publishState()
    }
    func showByUser() {
        hidden = false; manuallyShown = true
        defaults.set(false,forKey:"desktopPet.hidden"); defaults.set(true,forKey:"desktopPet.manuallyShown")
        guard sessionBlockers.isEmpty else { publishState(); return }
        if fullScreenReturn != nil { restoreAfterFullScreen(animated:false,show:false) }
        if hoverPeeking || peekReturning { pinHoverPeek(); refreshVisibility(); return }
        cancelInteractions(); catView.finishAnimations()
        if !placed { restore() }
        let covered = displayCoverage()
        let work = router.workingScreen() ?? NSScreen.main
        let available = NSScreen.screens.filter { !covered.contains(PetFullscreenMonitor.displayID($0)) }
        guard let screen = available.first(where:{ $0 === work }) ?? available.first ?? work else { publishState(); return }
        let oldSide = behavior.edge; behavior.unfold(); foldedAnchor = nil
        let area = screen.visibleFrame.insetBy(dx:8,dy:8)
        if !area.contains(expandedFrame) || expandedFrame.size != PetPlacement.companionSize {
            expandedFrame = CGRect(x:area.minX+0.85*max(0,area.width-PetPlacement.companionSize.width),y:area.minY+0.18*max(0,area.height-PetPlacement.companionSize.height),width:PetPlacement.companionSize.width,height:PetPlacement.companionSize.height)
        }
        cat.setFrame(PetPlacement.clamp(expandedFrame,to:area),display:true)
        catView.breathes = enabled
        catView.setExpanded(from:oldSide,animated:!reduced)
        updateFacing(screen:screen); savePlacement(screen:screen)
        refreshVisibility(); presentFresh()
    }
    private func startEnvironmentTimer() {
        guard environmentTimer == nil else { return }
        environmentTimer = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshEnvironment() } }
    }
    private func refreshEnvironment() {
        guard allowsDisplay, let screen = screenForCat() else { return }
        let value = displayCoverage().contains(PetFullscreenMonitor.displayID(screen))
        applySuppression(value)
        if reduced { if suppressed && !fullScreenPinned && !hoverPeeking && !peekReturning { settleFullScreenCompact() } else { catView.finishAnimations() } }
        if !suppressed || fullScreenPinned || hoverPeeking { catView.synchronizePointer() }
        updateRotation(); ensureTimer(); publishState()
    }
    private func applySuppression(_ value: Bool) {
        guard value != suppressed else { return }
        if value { collectForFullScreen() }
        else { restoreAfterFullScreen(animated:!reduced,show:true) }
        updateRotation(); ensureTimer(); publishState()
    }
    private func collectForFullScreen() {
        guard let screen = screenForCat() else { return }
        cancelHoverPeek(); cancelInteractions(); catView.finishAnimations()
        fullScreenReturn = FullScreenReturn(frame:cat.frame,expanded:expandedFrame,anchor:foldedAnchor,behavior:behavior,display:PetFullscreenMonitor.displayID(screen))
        suppressed = true; fullScreenPinned = false; fullScreenGeneration += 1; clearBubbleWindows()
        cat.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle]
        catView.fullScreenCompact = true; catView.breathes = false
        let side = behavior.edge ?? PetEdgeBehavior.nearestEdge(cat.frame,area:screen.frame)
        automaticEdge = side
        behavior.fold(side,using:&rng)
        let target = PetEdgeBehavior.foldedFrame(side:side,centerY:cat.frame.midY,area:screen.frame)
        foldedAnchor = target; peekArmed = false
        if reduced || fullScreenReturn?.behavior.edge != nil {
            cat.setFrame(target,display:true); catView.setFolded(side,pose:behavior.pose,animated:false)
        } else {
            let edgeOrigin = CGPoint(x:side == .left ? screen.frame.minX : screen.frame.maxX-cat.frame.width,y:cat.frame.minY)
            edgeTravel = EdgeTravel(start:cat.frame.origin,end:edgeOrigin,began:ProcessInfo.processInfo.systemUptime,side:side,target:target,generation:fullScreenGeneration)
        }
        showCat(); updateRotation(); ensureTimer()
    }
    private func advanceEdgeTravel() {
        guard let travel = edgeTravel else { return }
        let p = min(1,max(0,(ProcessInfo.processInfo.systemUptime-travel.began)/0.28)), eased = p*p*(3-2*p)
        cat.setFrameOrigin(CGPoint(x:travel.start.x+(travel.end.x-travel.start.x)*eased,y:travel.start.y+(travel.end.y-travel.start.y)*eased))
        if let screen = screenForCat() { catView.face(behavior.updateFacing(centerX:cat.frame.midX,screen:screen.frame),animated:!reduced) }
        if p>=1 {
            edgeTravel = nil
            catView.retreat(travel.side) { [weak self] in
                guard let self, self.suppressed, self.fullScreenGeneration == travel.generation else { return }
                self.cat.setFrame(travel.target,display:true)
                self.catView.setFolded(travel.side,pose:self.behavior.pose,animated:!self.reduced && self.allowsDisplay)
            }
        }
    }
    private func settleFullScreenCompact() {
        guard suppressed, let side = automaticEdge, let target = foldedAnchor else { return }
        fullScreenGeneration += 1; edgeTravel = nil; catView.finishAnimations()
        cat.setFrame(target,display:false); catView.setFolded(side,pose:behavior.pose,animated:false)
    }
    private func restoreAfterFullScreen(animated: Bool,show: Bool) {
        guard var saved = fullScreenReturn else { suppressed = false; return }
        let wasPinned = fullScreenPinned
        if fullScreenPinned { saved = FullScreenReturn(frame:cat.frame,expanded:expandedFrame,anchor:foldedAnchor,behavior:behavior,display:saved.display) }
        cancelHoverPeek(); fullScreenPinned = false
        fullScreenGeneration += 1; edgeTravel = nil; catView.finishAnimations()
        let side = automaticEdge
        fullScreenReturn = nil; automaticEdge = nil; suppressed = false
        behavior = saved.behavior; behavior.setPaused(true,at:ProcessInfo.processInfo.systemUptime,delay:30)
        expandedFrame = saved.expanded; foldedAnchor = saved.anchor
        cat.collectionBehavior = [.canJoinAllSpaces,.fullScreenNone,.ignoresCycle]
        catView.fullScreenCompact = false; catView.breathes = enabled
        let screen = NSScreen.screens.first { PetFullscreenMonitor.displayID($0) == saved.display } ?? screenForCat()
        let area = screen?.visibleFrame ?? saved.frame
        cat.setFrame(PetPlacement.clamp(saved.frame,to:area),display:true)
        if let originalSide = behavior.edge {
            foldedAnchor = cat.frame
            catView.setFolded(originalSide,pose:behavior.pose,animated:false)
        } else {
            catView.setExpanded(from:side,animated:animated)
            catView.face(behavior.mirrored,animated:false)
        }
        peekArmed = false
        if wasPinned, let screen { savePlacement(screen:screen) }
        if show && allowsDisplay { showCat(); catView.synchronizePointer() }
        updateRotation(); ensureTimer()
    }
    private func updateRotation() {
        behavior.setPaused(hoverPeeking || peekReturning || !enabled || hidden || !sessionBlockers.isEmpty || suppressed || reduced || catView.isInteracting || catView.isAnimating || dragging,
                           at:ProcessInfo.processInfo.systemUptime,delay:Double.random(in:30...60))
    }
    private func ensureTimer() {
        ensureProximityTimer()
        guard allowsDisplay && (suppressed && !fullScreenPinned ? (edgeTravel != nil || catView.isAnimating) : (enabled || catView.isAnimating)) else { timer?.invalidate(); timer = nil; return }
        let rate = catView.isAnimating || edgeTravel != nil ? 60.0 : 15.0
        guard timer == nil || timerRate != rate else { return }
        timer?.invalidate(); timerRate = rate
        timer = Timer.scheduledTimer(withTimeInterval:1/rate,repeats:true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        if let timer { RunLoop.main.add(timer,forMode:.common) }
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        advanceEdgeTravel()
        updateRotation()
        if behavior.rotate(at:now,delay:Double.random(in:30...60),using:&rng) {
            catView.changePose(behavior.pose,animated:!reduced)
        }
        catView.advanceAnimation()
        if catView.isAnimating || edgeTravel != nil || !suppressed && (behavior.edge == nil || hoverPeeking) && !reduced && now-lastPaint >= 1.0/15 {
            catView.needsDisplay = true; lastPaint = now
        }
        for (_,view) in bubbles.values where !view.finishedInflating { view.needsDisplay = true }
        ensureTimer()
    }
    func present(_ alerts: [BubbleMessage],text: String) {
        lastMessages = alerts; lastText = text; lastPresentation = ProcessInfo.processInfo.systemUptime
        guard enabled && allowsDisplay && (!suppressed || fullScreenPinned) && behavior.edge == nil && !dragging else { clearBubbleWindows(); return }
        let items: [(String,String,Bool,Bool)] = alerts.isEmpty ? (text.isEmpty ? [] : [("nudge",text,false,false)]) : alerts.map { ($0.id,$0.message,$0.recovering,$0.resolved) }
        let ids = Set(items.map { $0.0 })
        for id in order where !ids.contains(id) { bubbles[id]?.0.orderOut(nil); bubbles[id] = nil }
        order.removeAll { !ids.contains($0) }
        var added = 0
        for (id,message,recovering,resolved) in items {
            if let (panel, view) = bubbles[id] {
                view.update(message: message, recovering: recovering, resolved: resolved)
                let size = view.preferredSize
                if panel.frame.size != size {
                    stableFrames[id] = nil
                    panel.setContentSize(size)
                }
            }
            else {
                let view = ComicBubbleView(message:message,delay:Double(added)*0.65)
                view.update(message:message,recovering:recovering,resolved:resolved)
                let panel = PassivePanel(contentRect:NSRect(origin:.zero,size:view.frame.size),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
                configure(panel)
                if suppressed { panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle] }
                panel.contentView = view; view.onClick = { [weak self] in self?.onDismiss() }
                bubbles[id] = (panel,view); order.append(id); added += 1
            }
        }
        layout()
        for (panel,_) in bubbles.values where presentsOnScreen && !panel.isVisible { panel.orderFrontRegardless() }
    }
    private func presentFresh() {
        if ProcessInfo.processInfo.systemUptime-lastPresentation < 1 { present(lastMessages,text:lastText) }
    }
    private func clearBubbleWindows() {
        for (panel,_) in bubbles.values { panel.orderOut(nil) }
        bubbles.removeAll(); stableFrames = [:]; order = []
    }
    func hideBubbles() { clearBubbleWindows(); lastMessages = []; lastText = ""; lastPresentation = -.infinity }
    func shutdown() { enabled = false; manuallyShown = false; shutdownWindows() }
    private func cancelInteractions() {
        if dragging, behavior.edge == nil, let screen = screenForCat() {
            cat.setFrame(PetPlacement.clamp(cat.frame,to:screen.visibleFrame.insetBy(dx:8,dy:8)),display:false)
            expandedFrame = cat.frame; savePlacement(screen:screen)
        }
        dragging = false; pointerDrag = nil
        if behavior.edge != nil { peekArmed = false }
        catView.edgeHint = nil; catView.cancelInteraction()
    }
    private func shutdownWindows() {
        cancelHoverPeek(); cancelInteractions(); catView.finishAnimations()
        if suppressed && !fullScreenPinned && !hoverPeeking && !peekReturning { settleFullScreenCompact() }
        timer?.invalidate(); timer = nil; environmentTimer?.invalidate(); environmentTimer = nil; proximityTimer?.invalidate(); proximityTimer = nil
        cat.orderOut(nil); clearBubbleWindows(); updateRotation()
    }
    private func restore() {
        guard fullScreenReturn == nil else { return }
        catView.finishAnimations()
        let id = defaults.string(forKey:"desktopPet.screen")
        guard let screen = NSScreen.screens.first(where:{ router.identifier($0) == id }) ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let area = screen.visibleFrame.insetBy(dx:8,dy:8)
        let x = defaults.object(forKey:"desktopPet.x") as? Double ?? 0.85
        let y = defaults.object(forKey:"desktopPet.y") as? Double ?? 0.18
        expandedFrame = CGRect(x:area.minX+min(1,max(0,x))*max(0,area.width-PetPlacement.companionSize.width),y:area.minY+min(1,max(0,y))*max(0,area.height-PetPlacement.companionSize.height),width:PetPlacement.companionSize.width,height:PetPlacement.companionSize.height)
        let edge = defaults.string(forKey:"desktopPet.edge").flatMap(PetEdge.init(rawValue:))
        if let edge {
            behavior.fold(edge,using:&rng)
            cat.setFrame(PetEdgeBehavior.foldedFrame(side:edge,centerY:expandedFrame.midY,area:screen.visibleFrame),display:true)
            foldedAnchor = cat.frame; peekArmed = true
            catView.setFolded(edge,pose:behavior.pose,animated:false)
        } else {
            foldedAnchor = nil
            behavior.unfold(); cat.setFrame(expandedFrame,display:true); catView.setExpanded(from:nil,animated:false)
            updateFacing(screen:screen)
        }
        placed = true
    }
    private func savePlacement(screen: NSScreen) {
        guard fullScreenReturn == nil else { return }
        let area = screen.visibleFrame.insetBy(dx:8,dy:8)
        defaults.set(router.identifier(screen),forKey:"desktopPet.screen")
        defaults.set(min(1,max(0,(expandedFrame.minX-area.minX)/max(1,area.width-expandedFrame.width))),forKey:"desktopPet.x")
        defaults.set(min(1,max(0,(expandedFrame.minY-area.minY)/max(1,area.height-expandedFrame.height))),forKey:"desktopPet.y")
        defaults.set(behavior.edge?.rawValue,forKey:"desktopPet.edge")
    }
    private func fold(_ side: PetEdge,screen: NSScreen) {
        expandedFrame = PetPlacement.clamp(cat.frame,to:screen.visibleFrame.insetBy(dx:8,dy:8))
        behavior.fold(side,using:&rng); clearBubbleWindows()
        catView.cancelPendingClick()
        let finalFrame = PetEdgeBehavior.foldedFrame(side:side,centerY:expandedFrame.midY,area:screen.visibleFrame)
        foldedAnchor = finalFrame; hoverPeeking = false; peekReturning = false; peekArmed = false; peekLeaveAt = nil
        let arrive: () -> Void = { [weak self] in
            guard let self else { return }
            self.cat.setFrame(finalFrame,display:true)
            self.catView.setFolded(side,pose:self.behavior.pose,animated:!self.reduced && !self.suppressed && self.enabled && !self.hidden)
        }
        if reduced { arrive() }
        else {
            cat.setFrameOrigin(CGPoint(x:side == .left ? screen.visibleFrame.minX : screen.visibleFrame.maxX-cat.frame.width,y:cat.frame.minY))
            catView.retreat(side,completion:arrive)
        }
        savePlacement(screen:screen); updateRotation(); ensureTimer(); publishState()
    }
    private func unfold(animate: Bool = true) {
        if hoverPeeking || peekReturning { pinHoverPeek(); return }
        guard let side = behavior.edge, let screen = screenForCat() else { return }
        let centerY = cat.frame.midY
        if suppressed { fullScreenPinned = true; catView.fullScreenCompact = false; catView.breathes = enabled }
        behavior.unfold(); foldedAnchor = nil
        manuallyShown = true; defaults.set(true,forKey:"desktopPet.manuallyShown")
        let area = screen.visibleFrame.insetBy(dx:8,dy:8)
        expandedFrame = PetPlacement.clamp(CGRect(x:side == .left ? area.minX+10 : area.maxX-PetPlacement.companionSize.width-10,y:centerY-PetPlacement.companionSize.height/2,width:PetPlacement.companionSize.width,height:PetPlacement.companionSize.height),to:area)
        cat.setFrame(expandedFrame,display:true); catView.setExpanded(from:side,animated:animate && !reduced)
        updateFacing(screen:screen); savePlacement(screen:screen); updateRotation(); ensureTimer(); presentFresh(); publishState()
    }
    private func updateFacing(screen: NSScreen) {
        catView.face(behavior.updateFacing(centerX:cat.frame.midX,screen:screen.frame),animated:!reduced)
        ensureTimer()
    }
    private func move(_ point: NSPoint,finished: Bool) {
        guard !suppressed || fullScreenPinned || hoverPeeking || peekReturning else { return }
        if !dragging {
            guard !finished else { return }
            if hoverPeeking || peekReturning { pinHoverPeek() }
            else if behavior.edge != nil {
                // Expand under the original grab point, not at a new unrelated window origin.
                let grab = CGPoint(x:(pressedPointer.x-pressedFrame.minX)/max(1,pressedFrame.width),y:(pressedPointer.y-pressedFrame.minY)/max(1,pressedFrame.height))
                behavior.unfold(); foldedAnchor = nil
                let origin = CGPoint(x:pressedPointer.x-grab.x*PetPlacement.companionSize.width,y:pressedPointer.y-grab.y*PetPlacement.companionSize.height)
                cat.setFrame(CGRect(origin:origin,size:PetPlacement.companionSize),display:true)
                catView.setExpanded(from:nil,animated:false)
                pointerDrag = PetPointerDrag(pointer:pressedPointer,origin:origin)
            }
            dragging = true; clearBubbleWindows(); updateRotation()
        }
        guard let anchor = pointerDrag else { return }
        cat.setFrameOrigin(anchor.origin(at:point))
        guard let screen = screenForCat() else { return }
        let edge = PetEdgeBehavior.nearEdge(cat.frame,area:screen.visibleFrame)
        catView.edgeHint = finished ? nil : edge
        updateFacing(screen:screen)
        if finished {
            dragging = false; pointerDrag = nil
            if let edge { fold(edge,screen:screen) }
            else {
                cat.setFrame(PetPlacement.clamp(cat.frame,to:screen.visibleFrame.insetBy(dx:8,dy:8)),display:true)
                expandedFrame = cat.frame; savePlacement(screen:screen); presentFresh()
            }
            updateRotation(); refreshEnvironment()
        }
        layout()
    }
    private func ensureProximityTimer() {
        guard allowsDisplay && behavior.edge != nil && edgeTravel == nil else {
            proximityTimer?.invalidate(); proximityTimer = nil; return
        }
        guard proximityTimer == nil else { return }
        proximityTimer = Timer.scheduledTimer(withTimeInterval:0.1,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleProximity(NSEvent.mouseLocation,at:ProcessInfo.processInfo.systemUptime) }
        }
        if let proximityTimer { RunLoop.main.add(proximityTimer,forMode:.common) }
    }
    private func sampleProximity(_ point: CGPoint,at now: Double) {
        guard allowsDisplay && behavior.edge != nil && edgeTravel == nil && !dragging, let anchor = foldedAnchor else { return }
        let nearEntry = anchor.insetBy(dx:-12,dy:-10).contains(point)
        if !peekArmed { if !nearEntry { peekArmed = true }; return }
        if hoverPeeking || peekReturning {
            let inside = nearEntry || cat.frame.insetBy(dx:-10,dy:-10).contains(point)
            if inside {
                peekLeaveAt = nil
                if peekReturning { beginHoverPeek() }
            } else if !catView.isPressed && !catView.hasPendingClick {
                if peekLeaveAt == nil { peekLeaveAt = now }
                if now-(peekLeaveAt ?? now)>0.45 && !peekReturning { returnHoverPeek() }
            }
        } else if nearEntry && !catView.isPressed && !catView.hasPendingClick && !catView.isAnimating { beginHoverPeek() }
    }
    private func beginHoverPeek() {
        guard let side = behavior.edge, let anchor = foldedAnchor, let screen = screenForCat() else { return }
        if peekReturning {
            peekGeneration += 1; peekReturning = false; hoverPeeking = true; peekLeaveAt = nil
            catView.resumeRetreat(); updateRotation(); ensureTimer(); publishState(); return
        }
        hoverPeeking = true; peekLeaveAt = nil; clearBubbleWindows()
        let area = screen.visibleFrame.insetBy(dx:8,dy:8)
        let frame = PetPlacement.clamp(CGRect(x:side == .left ? area.minX+10 : area.maxX-PetPlacement.companionSize.width-10,
            y:anchor.midY-PetPlacement.companionSize.height/2,width:PetPlacement.companionSize.width,height:PetPlacement.companionSize.height),to:area)
        catView.fullScreenCompact = false
        cat.setFrame(frame,display:true); catView.setExpanded(from:side,animated:!reduced)
        updateFacing(screen:screen); updateRotation(); ensureTimer(); publishState()
    }
    private func returnHoverPeek() {
        guard hoverPeeking, let side = behavior.edge, let anchor = foldedAnchor else { return }
        hoverPeeking = false; peekReturning = true; peekGeneration += 1
        let generation = peekGeneration
        let arrive: () -> Void = { [weak self] in
            guard let self, self.peekGeneration == generation else { return }
            self.peekReturning = false; self.peekLeaveAt = nil
            self.catView.fullScreenCompact = self.suppressed
            self.cat.setFrame(anchor,display:true)
            self.catView.setFolded(side,pose:self.behavior.pose,animated:!self.reduced && self.allowsDisplay && !self.suppressed)
            self.updateRotation(); self.ensureTimer(); self.publishState()
        }
        if reduced { arrive() } else { catView.retreat(side,completion:arrive); ensureTimer() }
    }
    private func cancelHoverPeek() {
        guard hoverPeeking || peekReturning else { return }
        peekGeneration += 1; hoverPeeking = false; peekReturning = false; peekLeaveAt = nil
        catView.finishAnimations()
        if let side = behavior.edge, let anchor = foldedAnchor {
            catView.fullScreenCompact = suppressed
            cat.setFrame(anchor,display:false); catView.setFolded(side,pose:behavior.pose,animated:false)
        }
    }
    private func pinHoverPeek() {
        guard hoverPeeking || peekReturning, behavior.edge != nil, let screen = screenForCat() else { return }
        peekGeneration += 1; hoverPeeking = false; peekReturning = false; peekLeaveAt = nil
        catView.resumeRetreat(); behavior.unfold(); foldedAnchor = nil
        if suppressed { fullScreenPinned = true; catView.fullScreenCompact = false; catView.breathes = enabled }
        manuallyShown = true; hidden = false
        defaults.set(true,forKey:"desktopPet.manuallyShown"); defaults.set(false,forKey:"desktopPet.hidden")
        expandedFrame = cat.frame; savePlacement(screen:screen)
        updateFacing(screen:screen); updateRotation(); ensureTimer(); presentFresh(); publishState()
    }
    private func capturePress(at point: CGPoint) {
        pressedPointer = point; pressedFrame = cat.frame
        pointerDrag = PetPointerDrag(pointer:point,origin:cat.frame.origin)
    }
    private func layout() {
        guard behavior.edge == nil, let screen = screenForCat() else { return }
        let area = screen.visibleFrame.insetBy(dx:6,dy:6)
        if lastCatFrame != cat.frame || lastArea != area { stableFrames = [:] }
        lastCatFrame = cat.frame; lastArea = area
        stableFrames = stableFrames.filter { order.contains($0.key) }
        let frames = PetPlacement.bubbles(around:cat.frame,sizes:order.compactMap { bubbles[$0]?.0.frame.size },in:area,seed:layoutSeed,preferred:order.map { stableFrames[$0] })
        for (id,frame) in zip(order,frames) {
            guard let (panel,view) = bubbles[id] else { continue }
            stableFrames[id] = frame; panel.setFrame(frame,display:true)
            let head = PetPlacement.headCenter(in:cat.frame); view.target = CGPoint(x:head.x-frame.minX,y:head.y-frame.minY)
        }
    }
    var snapshot: [String:Any] { ["catVisible":cat.isVisible,"bubbleCount":bubbles.count,"catFrame":NSStringFromRect(cat.frame),"hidden":hidden,"manuallyShown":manuallyShown,"edge":behavior.edge?.rawValue ?? "expanded","pose":behavior.pose.rawValue,"suppressed":suppressed,"hoverPeeking":hoverPeeking,"dragging":dragging] }
}

private final class CatCompanionView: NSView {
    var onClick: () -> Void = {}, onDoubleClick: () -> Void = {}
    var skin: CompanionSkin = .cat { didSet { needsDisplay = true } }
    var breathes = true
    var fullScreenCompact = false { didSet { updateHelp(); window?.invalidateCursorRects(for:self) } }
    var onMove: (NSPoint,Bool) -> Void = { _,_ in }
    var onPress: (NSPoint) -> Void = { _ in }
    var pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }
    var isPressed: Bool { pressed }
    var hasPendingClick: Bool { singleClickWork != nil }
    var onHide: (() -> Void)?
    var onInteraction: () -> Void = {}
    private var singleClickWork: DispatchWorkItem?
    private var down = NSPoint.zero
    private var dragging = false, hovered = false, pressed = false
    var isInteracting: Bool { hovered || pressed || dragging }
    private var tracking: NSTrackingArea?
    private var folded: PetEdge?
    private var pose = PetEdgePose.hand, pendingPose = PetEdgePose.hand
    private var poseStart = -Double.infinity, poseSwapped = false
    private var frozenAt: Double?
    private var appearStart = -Double.infinity
    private var retreatStart = -Double.infinity
    private var retreatSide = PetEdge.left
    private var retreated: (() -> Void)?
    private var flipStart = -Double.infinity
    private var facing = false, flipTo = false, desiredFacing = false
    private var unfoldFrom: PetEdge?
    var edgeHint: PetEdge? { didSet { if edgeHint != oldValue { needsDisplay = true } } }
    private static let original: CGImage? = {
        guard let url = Bundle.main.url(forResource:"Companion",withExtension:"png"),let image = NSImage(contentsOf:url) else { return nil }
        return image.cgImage(forProposedRect:nil,context:nil,hints:nil)
    }()
    private static func piece(_ rect: CGRect) -> CGImage? { original?.cropping(to:rect)?.copy(maskingColorComponents:[245,255,245,255,245,255]) }
    private let artwork = CatCompanionView.piece(CGRect(x:220,y:40,width:540,height:910))
    private static let artworkScale = (PetPlacement.companionSize.height-2*8*0.6)/910
    private static let edgeDetailMagnification: CGFloat = 1.44

    private func drawArtwork(_ art: CGImage, centeredAt center: CGPoint, in context: CGContext, magnification: CGFloat = 1) {
        let scale = Self.artworkScale*magnification
        let size = CGSize(width:CGFloat(art.width)*scale,height:CGFloat(art.height)*scale)
        context.draw(art,in:CGRect(x:center.x-size.width/2,y:center.y-size.height/2,width:size.width,height:size.height))
    }
    /// Inset the outside of the ink and let the gray fill advance inside it.
    /// This compensates for the increase in stroke width at edgeDetailMagnification.
    private static func compensateDetailInk(_ art: CGImage?) -> CGImage? {
        guard let art else { return nil }
        let width = art.width, height = art.height, rowBytes = width*4
        let format = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:rowBytes,
                                      space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:format), let data = context.data else { return art }
        context.draw(art,in:CGRect(x:0,y:0,width:width,height:height))
        let pixels = UnsafeMutableBufferPointer(start:data.assumingMemoryBound(to:UInt8.self),count:rowBytes*height)
        let source = Array(pixels)
        let radius = 2
        let offsets = (-radius...radius).flatMap { y in
            (-radius...radius).filter { x in x*x+y*y <= radius*radius }.map { x in (x,y) }
        }
        func brightness(at offset: Int) -> Int {
            let alpha = Int(source[offset+3])
            guard alpha > 0 else { return 0 }
            // Ignore the bright fringe left by the source image's white background.
            let gray = (Int(source[offset])+Int(source[offset+1])+Int(source[offset+2]))*255/(3*alpha)
            return min(gray,212)
        }
        for y in 0..<height {
            for x in 0..<width {
                let offset = y*rowBytes+x*4
                guard source[offset+3] > 0 else { continue }
                // Clamp at the crop edge so the seam can still meet the screen edge.
                var alpha = Int(source[offset+3])
                var innerLight = brightness(at:offset), outerLight = innerLight
                for (dx,dy) in offsets {
                    let sampleX = min(width-1,max(0,x+dx)), sampleY = min(height-1,max(0,y+dy))
                    let neighbor = sampleY*rowBytes+sampleX*4
                    let sampleLight = brightness(at:neighbor)
                    if dx*dx+dy*dy <= 1 {
                        alpha = min(alpha,Int(source[neighbor+3]))
                        innerLight = max(innerLight,sampleLight)
                    }
                    outerLight = max(outerLight,sampleLight)
                }
                // Blend the two radii for a fractional-pixel inset at the gray fill.
                let light = (innerLight+outerLight)/2
                for channel in 0..<3 {
                    pixels[offset+channel] = UInt8(light*alpha/255)
                }
                pixels[offset+3] = UInt8(alpha)
            }
        }
        return context.makeImage() ?? art
    }
    /// Original pixels, bounded by the source silhouette instead of a visible rectangular crop.
    private static func maskedPiece(_ rect: CGRect,contours: [[CGPoint]]) -> CGImage? {
        guard let source = piece(rect), let c = CGContext(data:nil,width:Int(rect.width),height:Int(rect.height),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let path = CGMutablePath()
        for points in contours {
            for (i,p) in points.enumerated() {
                let local = CGPoint(x:p.x-rect.minX,y:rect.maxY-p.y)
                if i == 0 { path.move(to:local) } else { path.addLine(to:local) }
            }
            path.closeSubpath()
        }
        c.addPath(path); c.clip()
        c.draw(source,in:CGRect(origin:.zero,size:rect.size)); return c.makeImage()
    }
    private static let faceArt = maskedPiece(CGRect(x:220,y:40,width:540,height:585),contours:[[
        CGPoint(x:220,y:40),CGPoint(x:760,y:40),CGPoint(x:760,y:625),CGPoint(x:740,y:540),
        CGPoint(x:680,y:562),CGPoint(x:650,y:582),CGPoint(x:620,y:592),CGPoint(x:590,y:599),
        CGPoint(x:560,y:604),CGPoint(x:530,y:605),CGPoint(x:500,y:606),CGPoint(x:470,y:607),
        CGPoint(x:440,y:606),CGPoint(x:410,y:599),CGPoint(x:380,y:597),CGPoint(x:350,y:592),
        CGPoint(x:320,y:574),CGPoint(x:300,y:556),CGPoint(x:280,y:540),CGPoint(x:250,y:520),CGPoint(x:220,y:520)
    ]])
    private static let earsCrop = CGRect(x:397,y:40,width:192,height:140)
    private static let earArt = compensateDetailInk(piece(earsCrop))
    private static let handArt: CGImage? = {
        guard let source = original?.cropping(to:CGRect(x:417,y:650,width:78,height:116)) else { return nil }
        var bytes = [UInt8](repeating:0,count:78*116*4)
        let image: CGImage? = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data:buffer.baseAddress,width:78,height:116,bitsPerComponent:8,bytesPerRow:78*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(source,in:CGRect(x:0,y:0,width:78,height:116))
            let p = buffer.bindMemory(to:UInt8.self)
            for y in 0..<116 {
                let xs = (0..<78).filter { x in let i = (y*78+x)*4; return p[i]<110 && p[i+1]<110 && p[i+2]<110 && p[i+3]>0 }
                for x in 0..<78 where xs.isEmpty || x < xs.first!-1 || x > xs.last!+1 {
                    let i = (y*78+x)*4; p[i] = 0; p[i+1] = 0; p[i+2] = 0; p[i+3] = 0
                }
            }
            return context.makeImage()
        }
        return compensateDetailInk(image)
    }()
    private var now: Double { ProcessInfo.processInfo.systemUptime }
    var isAnimating: Bool { retreated != nil || now-flipStart<0.18 || now-appearStart<0.55 || frozenAt == nil && now-poseStart<0.85 }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame:NSRect) {
        super.init(frame:frame)
        setAccessibilityLabel("CyberKuku 小灰猫，双击打开监控窗口，拖动到左右边缘收纳")
        updateHelp()
    }
    required init?(coder:NSCoder) { fatalError() }
    deinit { singleClickWork?.cancel() }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect:bounds,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(area); tracking = area; super.updateTrackingAreas()
        synchronizePointer()
    }
    func synchronizePointer() {
        guard let window else { return }
        let value = window.isVisible && bounds.contains(convert(window.mouseLocationOutsideOfEventStream,from:nil))
        if value != hovered { hovered = value; interactionChanged() }
    }
    private func interactionChanged() {
        if isInteracting && frozenAt == nil { frozenAt = now }
        else if !isInteracting, let start = frozenAt { poseStart += now-start; frozenAt = nil }
        needsDisplay = true; onInteraction()
    }
    override func mouseEntered(with event:NSEvent) { hovered = true; interactionChanged() }
    override func mouseExited(with event:NSEvent) { hovered = false; interactionChanged() }
    override func resetCursorRects() { addCursorRect(bounds,cursor:fullScreenCompact ? .arrow : dragging ? .closedHand : .openHand) }
    func cancelPendingClick() { singleClickWork?.cancel(); singleClickWork = nil }
    func cancelInteraction() {
        cancelPendingClick(); pressed = false; dragging = false; hovered = false; interactionChanged()
    }
    override func mouseDown(with event:NSEvent) {
        cancelPendingClick()
        if let window, event.window === window, let location = event.cgEvent?.location, let screen = NSScreen.screens.first {
            down = CGPoint(x:location.x,y:screen.frame.maxY-location.y)
        } else { down = pointerLocation() }
        dragging = false; pressed = true; onPress(down); interactionChanged()
    }
    override func mouseDragged(with event:NSEvent) {
        guard pressed && !fullScreenCompact else { return }
        let p = pointerLocation()
        if hypot(p.x-down.x,p.y-down.y)>4 { dragging = true }
        if dragging { onMove(p,false) }
    }
    override func mouseUp(with event:NSEvent) {
        guard pressed else { return }
        let p = pointerLocation()
        if !fullScreenCompact && !dragging && hypot(p.x-down.x,p.y-down.y)>4 { dragging = true; onMove(p,false) }
        let moved = dragging
        if moved { cancelPendingClick(); onMove(p,true) }
        else if event.clickCount>=2 { cancelPendingClick(); if event.clickCount == 2 { onDoubleClick() } }
        else {
            let work = DispatchWorkItem { [weak self] in self?.singleClickWork = nil; self?.onClick() }
            singleClickWork = work; DispatchQueue.main.asyncAfter(deadline:.now()+NSEvent.doubleClickInterval,execute:work)
        }
        pressed = false; dragging = false; interactionChanged()
    }
    override func rightMouseDown(with event:NSEvent) {
        guard onHide != nil else { return }
        cancelPendingClick(); pressed = true; interactionChanged()
        let menu = NSMenu(); let item = NSMenuItem(title:"隐藏" + skin.title + "（可从菜单栏找回）",action:#selector(hidePet),keyEquivalent:"")
        item.target = self; menu.addItem(item); NSMenu.popUpContextMenu(menu,with:event,for:self)
        pressed = false; interactionChanged()
    }
    @objc private func hidePet() { onHide?() }
    private func updateHelp() {
        if fullScreenCompact { toolTip = "靠近探出，单击展开固定；双击打开监控窗口"; return }
        toolTip = folded == nil ? "单击安静 30 秒；双击打开监控窗口；拖到左右边缘收纳" : "单击展开；双击打开监控窗口；可拖回桌面" }
    func face(_ mirrored: Bool,animated: Bool) {
        desiredFacing = mirrored
        guard now-flipStart>=0.18 else { return }
        if !animated { facing = mirrored; flipTo = mirrored; flipStart = -.infinity }
        else if facing != mirrored { flipTo = mirrored; flipStart = now }
        needsDisplay = true
    }
    func resumeRetreat() {
        guard retreated != nil else { return }
        let p = min(1,max(0,(now-retreatStart)/0.22))
        retreated = nil; folded = nil; unfoldFrom = retreatSide; appearStart = now-0.55*(1-p)
        needsDisplay = true
    }
    func retreat(_ side: PetEdge,completion: @escaping () -> Void) { retreatSide = side; retreatStart = now; retreated = completion; needsDisplay = true }
    func setFolded(_ side: PetEdge,pose: PetEdgePose,animated: Bool) {
        folded = side; self.pose = pose; pendingPose = pose; poseStart = -.infinity
        unfoldFrom = nil; appearStart = animated ? now : -.infinity; edgeHint = nil; updateHelp(); needsDisplay = true
    }
    func setExpanded(from side: PetEdge?,animated: Bool) {
        folded = nil; retreated = nil; poseStart = -.infinity; unfoldFrom = side
        appearStart = animated ? now : -.infinity; updateHelp(); needsDisplay = true
    }
    func changePose(_ value: PetEdgePose,animated: Bool) {
        if !animated { pose = value; poseStart = -.infinity }
        else { pendingPose = value; poseSwapped = false; poseStart = now }
        needsDisplay = true
    }
    func advanceAnimation() {
        if retreated != nil && now-retreatStart>=0.22 { let done = retreated; retreated = nil; done?() }
        if now-flipStart>=0.18 {
            facing = flipTo
            if desiredFacing != facing { flipTo = desiredFacing; flipStart = now }
        }
        if !poseSwapped && (frozenAt ?? now)-poseStart>=0.28 { pose = pendingPose; poseSwapped = true }
    }
    func finishAnimations() {
        let done = retreated; retreated = nil; done?()
        facing = desiredFacing; flipTo = desiredFacing; flipStart = -.infinity
        pose = pendingPose; poseStart = -.infinity; appearStart = -.infinity
        needsDisplay = true
    }
    func previewFlip(progress: Double) {
        folded = nil; retreated = nil; facing = false; flipTo = true; desiredFacing = true
        flipStart = now-0.18*progress
    }
    override func draw(_ dirtyRect:NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        c.saveGState(); defer { c.restoreGState() }; c.clip(to:bounds)
        c.interpolationQuality = .high
        if let side = folded {
            var exposure = min(1,max(0,(now-appearStart)/0.55)); exposure = exposure*exposure*(3-2*exposure)
            let t = (frozenAt ?? now)-poseStart
            if t<0.22 { exposure = 1-t/0.22 }
            else if t<0.3 { exposure = 0 }
            else if t<0.85 { let p = (t-0.3)/0.55; exposure = p*p*(3-2*p) }
            c.translateBy(x:side == .left ? 0 : bounds.width,y:bounds.midY)
            if side == .right { c.scaleBy(x:-1,y:1) }
            c.translateBy(x:-(1-exposure)*bounds.width,y:0)
            if skin == .boat { PaperBoat.draw(in: CGRect(x: -8, y: -11, width: 32, height: 23)); return }
            switch pose {
            case .face:
                if let art = Self.faceArt { drawArtwork(art,centeredAt:CGPoint(x:-9,y:0),in:c) }
            case .hand:
                // The open end stays at the edge; the rounded original hand reaches inward.
                c.translateBy(x:6.72,y:0); c.rotate(by:.pi/2)
                if let art = Self.handArt { drawArtwork(art,centeredAt:.zero,in:c,magnification:Self.edgeDetailMagnification) }
            case .ears:
                // Turn the original pair around the forehead, with the head behind the edge.
                c.rotate(by:-.pi*84/180)
                let scale = Self.artworkScale*Self.edgeDetailMagnification
                let center = CGPoint(x:0,y:(130-Self.earsCrop.midY)*scale)
                if let art = Self.earArt { drawArtwork(art,centeredAt:center,in:c,magnification:Self.edgeDetailMagnification) }
            }
            return
        }
        if let edgeHint {
            NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect:CGRect(x:edgeHint == .left ? 0 : bounds.width-2,y:bounds.midY-9,width:2,height:18),xRadius:1,yRadius:1).fill()
        }
        if retreated != nil { let p = min(1,(now-retreatStart)/0.22); c.translateBy(x:(retreatSide == .left ? -1 : 1)*bounds.width*p*p,y:0) }
        else if now-appearStart<0.55, let side = unfoldFrom { let p = min(1,(now-appearStart)/0.55); c.translateBy(x:(side == .left ? -1 : 1)*bounds.width*(1-p)*(1-p),y:2.5*sin(.pi*p)) }
        let p = min(1,max(0,(now-flipStart)/0.18))
        let sign: Double = p<0.5 ? (facing ? -1 : 1) : (flipTo ? -1 : 1)
        let width = p<1 ? 0.18+0.82*abs(cos(.pi*p)) : 1
        c.translateBy(x:bounds.midX,y:bounds.midY); c.scaleBy(x:sign*width,y:1+0.025*sin(.pi*p)); c.translateBy(x:-bounds.midX,y:-bounds.midY)
        if skin == .boat { PaperBoat.draw(in: bounds.insetBy(dx: 2, dy: bounds.height * 0.22)); return }
        guard let artwork else { return }
        let center = CGPoint(x:bounds.midX,y:bounds.midY)
        drawArtwork(artwork,centeredAt:center,in:c)
        guard breathes && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let scale = Self.artworkScale
        let origin = CGPoint(x:center.x-CGFloat(artwork.width)*scale/2,y:center.y+CGFloat(artwork.height)*scale/2)
        let phase = now.truncatingRemainder(dividingBy:5)/5, t = phase<0.4 ? phase/0.4 : (1-phase)/0.6
        let breath = (1-cos(.pi*t))/2
        for y in stride(from:570,to:752,by:2) {
            let v = Double(y-570)/182, shift = 5*breath*pow(sin(.pi*v),2)
            guard let strip = artwork.cropping(to:CGRect(x:260,y:y,width:220,height:2)) else { continue }
            c.draw(strip,in:CGRect(x:origin.x+260*scale,y:origin.y-CGFloat(y+2)*scale,width:CGFloat(220+shift)*scale,height:2*scale))
        }
    }
}

private final class ComicBubbleView: NSView {
    var onClick: () -> Void = {}
    var target = CGPoint.zero { didSet { if oldValue != target { needsDisplay = true } } }
    private var message: String
    private var lettering: Lettering
    var preferredSize: NSSize { lettering.size }
    private var recovering = false, resolved = false
    private let born: Double
    private let tilt = Double.random(in: -0.025...0.025)
    var finishedInflating: Bool { ProcessInfo.processInfo.systemUptime >= born+1.8 }
    init(message: String, delay: Double) {
        self.message = message
        let lettering = Lettering(message)
        self.lettering = lettering
        born = ProcessInfo.processInfo.systemUptime + delay
        super.init(frame: NSRect(origin: .zero, size: lettering.size))
        toolTip = "点击收起所有提示，30 秒内不再提醒"
    }
    required init?(coder: NSCoder) { fatalError() }

    private struct Lettering {
        private static let font = NSFont.systemFont(ofSize: 14, weight: .medium)
        private static let lineHeight = ceil(font.ascender - font.descender + font.leading)
        private static let lineGap: CGFloat = 4
        private static let ink: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor(white: 0.15, alpha: 1)
        ]
        let lines: [String]
        let size: NSSize

        init(_ text: String) {
            // Keep the instruction's subject and action intact in the common two-line messages.
            let preferred = ["头向左扶正": ["头向左", "扶正"],
                             "头向右扶正": ["头向右", "扶正"],
                             "手离开嘴唇": ["手离开", "嘴唇"],
                             "手离开嘴巴": ["手离开", "嘴巴"]]
            lines = preferred[text] ?? text.split(whereSeparator: \.isNewline).flatMap { line in
                let characters = Array(line.trimmingCharacters(in: .whitespaces))
                return stride(from: 0, to: characters.count, by: 8).map { start in
                    String(characters[start..<min(start + 8, characters.count)])
                }
            }
            let widest = lines.map { ($0 as NSString).size(withAttributes: Self.ink).width }.max() ?? 0
            let height = CGFloat(lines.count) * (Self.lineHeight + Self.lineGap) - Self.lineGap
            // Keep room for the recovery mark without changing the bubble size.
            size = NSSize(width: max(88, ceil(widest) + 64), height: max(68, height + 54))
        }

        func draw(in body: NSRect, resolved: Bool) {
            let advance = Self.lineHeight + Self.lineGap
            let textHeight = CGFloat(lines.count) * advance - Self.lineGap
            let top = body.midY + textHeight / 2
            for (index, line) in lines.enumerated() {
                let text = NSMutableAttributedString(string: line, attributes: Self.ink)
                if resolved && index == lines.count - 1 {
                    var attributes = Self.ink
                    attributes[.foregroundColor] = NSColor.systemGreen
                    text.append(NSAttributedString(string: " ✓", attributes: attributes))
                }
                let offset: CGFloat = lines.count == 2 ? (index == 0 ? -5 : 5) : 0
                let x = body.midX + offset - text.size().width / 2
                let y = top - Self.lineHeight - CGFloat(index) * advance
                text.draw(at: NSPoint(x: x, y: y))
            }
        }
    }
    func update(message: String, recovering: Bool, resolved: Bool) {
        guard self.message != message || self.recovering != recovering || self.resolved != resolved else { return }
        if self.message != message { lettering = Lettering(message) }
        self.message = message; self.recovering = recovering; self.resolved = resolved; needsDisplay = true
        setAccessibilityLabel(message + (resolved ? "，已恢复" : recovering ? "，正在恢复" : ""))
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with event: NSEvent) { onClick() }
    override func draw(_ dirtyRect: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        let elapsed = max(0,ProcessInfo.processInfo.systemUptime-born)
        guard ProcessInfo.processInfo.systemUptime >= born else { return }
        let p = min(1,elapsed/1.8), eased = p*p*(3-2*p)
        let scale = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0.35 + 0.65*eased
        c.saveGState(); defer { c.restoreGState() }
        c.translateBy(x: bounds.midX, y: bounds.midY); c.scaleBy(x: scale,y: scale); c.rotate(by: tilt)
        c.translateBy(x: -bounds.midX,y: -bounds.midY); c.setAlpha(min(1,elapsed/0.4))
        let b = bounds.insetBy(dx: 12,dy: 12), path = NSBezierPath()
        // Undo the playful tilt for targeting, so the drawn tail still aims at the head.
        let dx = target.x-b.midX, dy = target.y-b.midY
        let localTarget = CGPoint(x: b.midX+dx*cos(tilt)+dy*sin(tilt),y: b.midY-dx*sin(tilt)+dy*cos(tilt))
        let angle = atan2(localTarget.y-b.midY,localTarget.x-b.midX)
        let opening = 0.23
        for step in 0...96 {
            let a = angle+opening+Double(step)/96*(2 * .pi-2*opening)
            let radius = 1/sqrt(pow(cos(a)/(b.width/2),2)+pow(sin(a)/(b.height/2),2))
            let wobble = 1 + 0.012*sin(3*a)+0.009*cos(5*a)
            let point = CGPoint(x:b.midX+radius*cos(a)*wobble,y:b.midY+radius*sin(a)*wobble)
            if step == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.line(to: PetPlacement.tailTip(body:b,bounds:bounds,target:localTarget)); path.close()
        NSColor.white.setFill(); path.fill()
        (resolved ? NSColor.systemGreen : NSColor(white: recovering ? 0.4 : 0.25,alpha:1)).setStroke(); path.lineWidth = 1.15; path.stroke()
        lettering.draw(in: b, resolved: resolved)
    }
}

@MainActor enum DesktopPetChecks {
    static func run(directory: String) {
        _ = NSApplication.shared
        do {
            let folder = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1000,pixelsHigh:700,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
            NSColor(white:0.93,alpha:1).setFill(); NSRect(x:0,y:0,width:1000,height:700).fill()
            let c = NSGraphicsContext.current!.cgContext
            c.scaleBy(x:2,y:2)
            let cat = CatCompanionView(frame:NSRect(origin:.zero,size:PetPlacement.companionSize))
            c.saveGState(); c.translateBy(x:198,y:90); cat.draw(cat.bounds); c.restoreGState()
            let messages = ["头向左扶正","双肩放平","放松下颌","手离开嘴巴"]
            let views = messages.map { ComicBubbleView(message:$0,delay:-2) }
            let frames = PetPlacement.bubbles(around:CGRect(origin:CGPoint(x:198,y:90),size:PetPlacement.companionSize),sizes:views.map(\.frame.size),in:CGRect(x:0,y:0,width:500,height:350),seed:3)
            for (view,frame) in zip(views,frames) {
                let head = PetPlacement.headCenter(in:CGRect(origin:CGPoint(x:198,y:90),size:PetPlacement.companionSize))
                view.target = CGPoint(x:head.x-frame.minX,y:head.y-frame.minY)
                c.saveGState(); c.translateBy(x:frame.minX,y:frame.minY); view.draw(view.bounds); c.restoreGState()
            }
            NSGraphicsContext.restoreGraphicsState()
            try bitmap.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("desktop-pet.png"))
            print("Rendered original-art companion and four independent native comic bubbles")
        } catch { fputs("Pet render failed: \(error)\n",stderr); exit(1) }
    }
}

extension DesktopPetChecks {
    @MainActor static func clickInteractions() async throws -> [String] {
        let view = CatCompanionView(frame: NSRect(origin:.zero,size:PetPlacement.companionSize))
        var pointer = CGPoint(x:200,y:200)
        view.pointerLocation = { pointer }
        var singles = 0, doubles = 0
        view.onClick = { singles += 1 }; view.onDoubleClick = { doubles += 1 }
        func event(_ type: NSEvent.EventType, count: Int) -> NSEvent {
            NSEvent.mouseEvent(with:type,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                windowNumber:0,context:nil,eventNumber:count,clickCount:count,pressure:0)!
        }
        func waitForSingle() async throws { try await Task.sleep(nanoseconds:UInt64((NSEvent.doubleClickInterval+0.12)*1_000_000_000)) }
        view.mouseDown(with:event(.leftMouseDown,count:1)); view.mouseUp(with:event(.leftMouseUp,count:1))
        precondition(singles == 0)
        try await waitForSingle(); precondition(singles == 1 && doubles == 0)
        view.mouseDown(with:event(.leftMouseDown,count:1)); view.mouseUp(with:event(.leftMouseUp,count:1))
        view.mouseDown(with:event(.leftMouseDown,count:2))
        // Holding the second click past the interval must still cancel the first click.
        try await waitForSingle(); precondition(singles == 1)
        view.mouseUp(with:event(.leftMouseUp,count:2))
        try await waitForSingle(); precondition(singles == 1 && doubles == 1)
        view.mouseDown(with:event(.leftMouseDown,count:3)); view.mouseUp(with:event(.leftMouseUp,count:3))
        try await waitForSingle(); precondition(singles == 1 && doubles == 1)
        view.mouseDown(with:event(.leftMouseDown,count:1)); view.mouseUp(with:event(.leftMouseUp,count:1))
        view.cancelPendingClick()
        try await waitForSingle(); precondition(singles == 1)
        var moves: [(CGPoint,Bool)] = []
        view.onMove = { moves.append(($0,$1)) }
        view.mouseDown(with:event(.leftMouseDown,count:1))
        pointer = CGPoint(x:600,y:420)
        view.mouseUp(with:event(.leftMouseUp,count:1))
        try await waitForSingle()
        precondition(moves.count == 2 && moves[0].0 == pointer && moves[1].0 == pointer && moves[1].1 && singles == 1)
        return ["release with coalesced motion uses the final pointer and never becomes a click", "single click waits for system double-click interval", "double click opens once without muting", "holding second click cancels pending single", "triple click does not mute or reopen", "hide cancels pending single click"]
    }
}

extension DesktopPetChecks {
    @MainActor static func renderEdges(directory: String) throws {
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath:directory)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1600,pixelsHigh:1100,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
        NSColor(white:0.95,alpha:1).setFill(); CGRect(x:0,y:0,width:1600,height:1100).fill()
        let c = NSGraphicsContext.current!.cgContext; c.scaleBy(x:2,y:2)
        for (i,pair) in [PetEdge.left,.right].flatMap({ side in PetEdgePose.allCases.map { (side,$0) } }).enumerated() {
            let (side,pose) = pair
            let x = CGFloat(30+i*127)
            let view = CatCompanionView(frame:CGRect(origin:.zero,size:PetEdgeBehavior.foldedSize))
            view.setFolded(side,pose:pose,animated:false)
            let label = "\(side.rawValue) · \(pose)"
            (label as NSString).draw(at:CGPoint(x:x,y:500),withAttributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:NSColor.darkGray])
            c.saveGState(); c.translateBy(x:x,y:440); view.draw(view.bounds); c.restoreGState()
            c.saveGState(); c.translateBy(x:x,y:260); c.scaleBy(x:2.5,y:2.5)
            NSColor.gray.setStroke(); let line = NSBezierPath(); let edge: CGFloat = side == .left ? 0 : view.bounds.maxX
            line.move(to:CGPoint(x:edge,y:0)); line.line(to:CGPoint(x:edge,y:view.bounds.maxY)); line.lineWidth = 0.4; line.stroke()
            view.draw(view.bounds); c.restoreGState()
        }
        for (i,p) in [0.0,0.25,0.5,0.75,1.0].enumerated() {
            let view = CatCompanionView(frame:CGRect(origin:.zero,size:PetPlacement.companionSize))
            view.previewFlip(progress:p)
            c.saveGState(); c.translateBy(x:CGFloat(60+i*150),y:50); view.draw(view.bounds); c.restoreGState()
            ("\(Int(p*180)) ms" as NSString).draw(at:CGPoint(x:CGFloat(60+i*150),y:25),withAttributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:NSColor.darkGray])
        }
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("edge-poses-and-turn.png"))
        print("Rendered original-art edge poses, actual size, enlarged detail and 180 ms turn frames")
    }
}

extension DesktopPetController {
    @MainActor static func interactionChecks() -> [String] {
        let suite = "CyberKuku.Edge.Check.\(UUID())"
        let prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        let controller = DesktopPetController(defaults:prefs,presentsOnScreen:false,coveredDisplays:{ [] })
        defer { controller.shutdown() }
        guard let screen = NSScreen.screens.first else { return ["native display unavailable; controller checks skipped"] }
        controller.enabled = true; controller.placed = true
        controller.cat.setFrame(CGRect(origin:CGPoint(x:screen.visibleFrame.midX,y:screen.visibleFrame.midY),size:PetPlacement.companionSize),display:false)
        controller.expandedFrame = controller.cat.frame
        var muted = 0, opened = 0
        controller.onDismiss = { muted += 1 }; controller.onOpenMonitor = { opened += 1 }
        let alert = BubbleMessage(id:"fixture",title:"",message:"双肩放平",seconds:8,recovering:false)
        controller.present([alert],text:"")
        precondition(controller.bubbles.count == 1)
        controller.fold(.right,screen:screen); controller.catView.finishAnimations()
        precondition(controller.behavior.edge == .right && controller.bubbles.isEmpty)
        precondition(controller.cat.frame.size == PetEdgeBehavior.foldedSize)
        let anchor = controller.cat.frame
        controller.catView.onDoubleClick(); precondition(opened == 1 && muted == 0 && controller.behavior.edge == .right)
        let down = NSEvent.mouseEvent(with:.leftMouseDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:1,clickCount:1,pressure:0)!
        controller.catView.mouseDown(with:down)
        precondition(controller.catView.isInteracting)
        controller.applySuppression(true)
        precondition(!controller.catView.isInteracting)
        precondition(controller.behavior.nextChange == nil && controller.behavior.edge == .right)
        controller.applySuppression(false)
        precondition(controller.cat.frame == anchor && controller.behavior.edge == .right && controller.bubbles.isEmpty)
        controller.present([alert],text:"")
        controller.catView.onClick(); controller.catView.finishAnimations()
        precondition(controller.behavior.edge == nil && muted == 0 && controller.bubbles.count == 1)
        controller.catView.onClick(); precondition(muted == 1)
        controller.catView.onDoubleClick(); precondition(opened == 2 && muted == 1)
        precondition(prefs.string(forKey:"desktopPet.edge") == nil)
        return ["folded hit region matches the fixed edge entry", "folding hides bubbles without muting", "folded double click opens without expanding or muting", "full-screen suppression preserves folded intent and anchor", "full-screen exit does not replay bubbles", "interrupted press is cancelled without a stuck rotation pause", "folded single click unfolds and restores fresh alerts without muting", "expanded click gestures are preserved", "edge preference clears when unfolded (isolated preferences)"]
    }
}

extension DesktopPetController {
    @MainActor static func visibilityChecks() -> [String] {
        let suite = "CyberKuku.Visibility.Check.\(UUID())"
        let prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        prefs.set(true,forKey:"desktopPet.hidden")
        let controller = DesktopPetController(defaults:prefs,presentsOnScreen:false,coveredDisplays:{ [] })
        defer { controller.shutdown() }
        guard let screen = NSScreen.screens.first else { return ["no native display; visibility checks skipped"] }
        precondition(controller.menuPresentation.action == "显示小灰猫" && controller.menuPresentation.check == .off)
        controller.toggleVisibility() // Reproduces clicking Show while monitoring is paused.
        controller.catView.finishAnimations(); controller.tick()
        precondition(!controller.enabled && controller.manuallyShown && !controller.hidden && controller.placed)
        precondition(controller.behavior.edge == nil && controller.menuPresentation.action == "隐藏小灰猫")
        precondition(controller.menuPresentation.detail == "小灰猫：已显示（静止）")
        precondition(controller.menuPresentation.check == .on && controller.timer == nil)
        controller.setEnabled(false); precondition(controller.menuPresentation.canHide)
        controller.fold(.right,screen:screen); controller.catView.finishAnimations(); controller.tick()
        precondition(controller.menuPresentation.action == "展开小灰猫" && controller.menuPresentation.check == .mixed)
        controller.toggleVisibility(); controller.catView.finishAnimations(); controller.tick()
        precondition(controller.behavior.edge == nil && controller.menuPresentation.check == .on)
        controller.suspendAppearance(.screenLocked)
        precondition(!controller.allowsDisplay && controller.timer == nil && controller.environmentTimer == nil)
        controller.showByUser(); precondition(!controller.allowsDisplay)
        controller.resumeAppearance(.screenLocked); controller.catView.finishAnimations(); controller.tick()
        precondition(controller.allowsDisplay && controller.menuPresentation.canHide && controller.timer == nil)
        controller.applySuppression(true)
        precondition(controller.menuPresentation.check == .mixed && controller.menuPresentation.detail.contains("全屏"))
        controller.showByUser(); controller.catView.finishAnimations(); controller.tick()
        precondition(!controller.suppressed && controller.menuPresentation.check == .on)
        controller.hideByUser(); precondition(controller.hidden && controller.menuPresentation.check == .off && !controller.manuallyShown)
        controller.setEnabled(true); precondition(controller.hidden && !controller.allowsDisplay)
        controller.showByUser(); controller.catView.finishAnimations(); controller.tick(); controller.setEnabled(false)
        precondition(controller.manuallyShown && controller.menuPresentation.canHide)
        return ["paused monitoring: Show reveals the companion without starting capture", "paused companion is static and menu accurately reports static display", "show/hide menu state tracks visibility", "Show unfolds a stored edge companion", "manual Show cannot bypass lock/sleep blockers", "unlock restores manual visibility", "full-screen automatic collection has a distinct menu state", "explicit Show recovers from suppression on an available display", "manual Hide stays hidden when monitoring starts", "manual Show survives monitoring pause"]
    }
}

extension DesktopPetController {
    @MainActor static func hoverAndDragChecks() -> [String] {
        let suite = "CyberKuku.Pointer.Check.\(UUID())"
        let prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        let c = DesktopPetController(defaults:prefs,presentsOnScreen:false,coveredDisplays:{ [] })
        defer { c.shutdown() }
        guard let screen = NSScreen.screens.first else { return ["no native display; pointer checks skipped"] }
        c.enabled = true; c.placed = true
        let origin = CGPoint(x:screen.visibleFrame.midX-31,y:screen.visibleFrame.midY-52)
        c.cat.setFrame(CGRect(origin:origin,size:PetPlacement.companionSize),display:false)
        c.expandedFrame = c.cat.frame
        let offset = CGPoint(x:20,y:70), down = CGPoint(x:origin.x+20,y:origin.y+70)
        c.capturePress(at:down)
        var last = down
        for i in 0..<240 {
            last = CGPoint(x:down.x+(i.isMultiple(of:2) ? 145 : -145)+Double(i%7),y:down.y+Double(i%3-1)*30)
            // Simulate unrelated window corrections between queued pointer events.
            if i.isMultiple(of:7) { c.cat.setFrameOrigin(c.cat.frame.origin.applying(CGAffineTransform(translationX:11,y:-9))) }
            c.move(last,finished:false)
            precondition(abs(c.cat.frame.minX-(last.x-offset.x))<1 && abs(c.cat.frame.minY-(last.y-offset.y))<1)
        }
        c.move(last,finished:true)
        precondition(c.pointerDrag == nil && !c.dragging)
        precondition(abs(c.cat.frame.minX-(last.x-offset.x))<1 && abs(c.cat.frame.minY-(last.y-offset.y))<1)
        var muted = 0
        c.onDismiss = { muted += 1 }
        c.fold(.left,screen:screen); c.catView.finishAnimations()
        let anchor = c.cat.frame, inside = CGPoint(x:anchor.midX,y:anchor.midY)
        let outside = CGPoint(x:anchor.maxX+240,y:anchor.midY)
        c.sampleProximity(inside,at:0); precondition(!c.hoverPeeking)
        c.sampleProximity(outside,at:1); c.sampleProximity(inside,at:2)
        precondition(c.hoverPeeking && c.behavior.edge == .left && prefs.string(forKey:"desktopPet.edge") == "left")
        c.catView.finishAnimations()
        c.sampleProximity(outside,at:3); c.sampleProximity(outside,at:3.6)
        c.catView.finishAnimations()
        precondition(!c.hoverPeeking && !c.peekReturning && c.cat.frame == anchor && c.behavior.edge == .left)
        c.sampleProximity(inside,at:4); c.catView.finishAnimations()
        let expanded = c.cat.frame
        c.catView.onClick()
        precondition(c.behavior.edge == nil && c.cat.frame == expanded && muted == 0)
        c.sampleProximity(outside,at:100)
        precondition(c.behavior.edge == nil && !c.hoverPeeking && prefs.string(forKey:"desktopPet.edge") == nil)
        c.fold(.right,screen:screen); c.catView.finishAnimations()
        let right = c.cat.frame, point = CGPoint(x:right.midX,y:right.midY)
        c.sampleProximity(CGPoint(x:right.minX-200,y:right.midY),at:101); c.sampleProximity(point,at:102)
        precondition(c.hoverPeeking)
        c.applySuppression(true)
        precondition(!c.hoverPeeking && !c.peekReturning && c.behavior.edge == .right && c.cat.frame == right)
        c.applySuppression(false); c.sampleProximity(point,at:103)
        precondition(!c.hoverPeeking)
        return ["240 rapid direction reversals keep the original grab offset despite window corrections", "mouse-up uses the final absolute pointer location", "newly folded companion waits for the pointer to leave before hover preview", "proximity temporarily expands without changing the stored folded intent", "leaving preview restores the same fixed anchor", "clicking preview pins the expanded companion without muting", "pinned companion stays expanded after pointer exit", "full-screen interruption cancels preview and restores the original edge without replay"]
    }
}

extension DesktopPetController {
    @MainActor static func fullScreenChecks() -> [String] {
        let suite = "CyberKuku.FullScreen.Check.\(UUID())", prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        var coverage: Set<CGDirectDisplayID> = []
        let c = DesktopPetController(defaults:prefs,presentsOnScreen:false,coveredDisplays:{ coverage })
        defer { c.shutdown() }
        guard let screen = NSScreen.screens.first else { return ["no display; full-screen checks skipped"] }
        c.enabled = true; c.placed = true
        var muted = 0; c.onDismiss = { muted += 1 }
        prefs.set(0.42,forKey:"desktopPet.x"); prefs.set(0.37,forKey:"desktopPet.y")
        for side in [PetEdge.left,.right] {
            c.behavior.unfold(); c.foldedAnchor = nil
            let frame = CGRect(x:side == .left ? screen.visibleFrame.minX+80 : screen.visibleFrame.maxX-160,y:screen.visibleFrame.midY-50,width:62.4,height:104.4)
            c.cat.setFrame(frame,display:false); c.expandedFrame = frame; c.catView.setExpanded(from:nil,animated:false)
            c.applySuppression(true); c.settleFullScreenCompact(); c.ensureTimer()
            precondition(c.automaticEdge == side && c.cat.frame.size == PetEdgeBehavior.foldedSize)
            precondition(c.cat.collectionBehavior.contains(.fullScreenAuxiliary) && c.catView.fullScreenCompact)
            precondition(c.proximityTimer != nil && c.timer == nil)
            precondition(c.menuPresentation.detail.contains("自动收纳"))
            let anchor = c.cat.frame
            c.sampleProximity(CGPoint(x:anchor.midX+200,y:anchor.midY),at:0)
            c.sampleProximity(CGPoint(x:anchor.midX,y:anchor.midY),at:1)
            precondition(c.hoverPeeking && !c.catView.fullScreenCompact && muted == 0)
            c.cancelHoverPeek()
            precondition(prefs.double(forKey:"desktopPet.x") == 0.42 && prefs.double(forKey:"desktopPet.y") == 0.37 && prefs.string(forKey:"desktopPet.edge") == nil)
            c.applySuppression(false); c.catView.finishAnimations()
            let restored = c.cat.frame
            if abs(restored.minX-frame.minX)>0.51 || abs(restored.minY-frame.minY)>0.51 || abs(restored.width-frame.width)>1.01 || abs(restored.height-frame.height)>1.01 {
                fputs("Full-screen restore frame: \(NSStringFromRect(restored)); expected: \(NSStringFromRect(frame))\n",stderr)
            }
            precondition(abs(restored.minX-frame.minX)<0.51 && abs(restored.minY-frame.minY)<0.51 && abs(restored.width-frame.width)<1.01 && abs(restored.height-frame.height)<1.01 && c.behavior.edge == nil && !c.catView.fullScreenCompact)
            precondition(c.cat.collectionBehavior.contains(.fullScreenNone))
        }
        c.fold(.right,screen:screen); c.catView.finishAnimations()
        let manual = c.cat.frame
        c.applySuppression(true); c.settleFullScreenCompact(); c.applySuppression(false); c.catView.finishAnimations()
        precondition(c.behavior.edge == .right && c.cat.frame == manual && prefs.string(forKey:"desktopPet.edge") == "right")
        c.unfold(animate:false); c.catView.finishAnimations()
        let original = c.cat.frame
        c.applySuppression(true); c.applySuppression(false); c.advanceEdgeTravel(); c.tick(); c.catView.finishAnimations()
        precondition(c.cat.frame == original && c.fullScreenReturn == nil && c.edgeTravel == nil)
        c.applySuppression(true)
        coverage = [PetFullscreenMonitor.displayID(screen)]
        c.suspendAppearance(.screenLocked); c.resumeAppearance(.screenLocked)
        precondition(c.suppressed && c.cat.frame.size == PetEdgeBehavior.foldedSize)
        coverage = []; c.refreshEnvironment(); c.catView.finishAnimations()
        precondition(!c.suppressed && c.cat.frame == original)
        coverage = [PetFullscreenMonitor.displayID(screen)]
        c.applySuppression(true); c.settleFullScreenCompact(); c.peekArmed = true
        let anchor = c.cat.frame
        c.sampleProximity(CGPoint(x:anchor.midX,y:anchor.midY),at:200)
        c.catView.onClick(); c.catView.finishAnimations()
        precondition(c.fullScreenPinned && c.behavior.edge == nil && muted == 0)
        let pinned = c.cat.frame
        c.sampleProximity(.zero,at:300); c.refreshEnvironment()
        precondition(c.cat.frame == pinned && c.behavior.edge == nil && c.fullScreenPinned)
        c.applySuppression(false); c.catView.finishAnimations()
        precondition(c.cat.frame == pinned && !c.fullScreenPinned)
        let spaces: [[String:Any]] = [
            ["Display Identifier":"normal", "Current Space":["type":0], "Spaces":[["type":4]]],
            ["Display Identifier":"fullscreen", "Current Space":["type":4]],
            ["Display Identifier":"unknown", "Current Space":["type":99]]]
        precondition(PetFullscreenMonitor.fullScreenIdentifiers(spaces) == ["fullscreen"])
        return ["full-screen pin remains expanded across refresh and exit", "native full-screen Space type excludes ordinary and unknown Spaces", "full-screen collects to the nearest left or right edge", "full-screen edge uses native auxiliary-space behavior", "full-screen collection does not overwrite saved placement or manual fold intent", "full-screen edge supports proximity expansion without muting", "exit restores the original expanded position", "a previously manual fold stays folded after exit", "rapid full-screen reversal cancels stale edge travel", "sleep during edge travel resumes compactly and exits back to original placement"]
    }
    @MainActor static func liveFullScreenEdgeCheck() {
        let previousFront = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let coverage = PetFullscreenMonitor.coveredDisplays()
            guard let screen = NSScreen.screens.first(where:{ coverage.contains(PetFullscreenMonitor.displayID($0)) }) else {
                print("{\"skipped\":true,\"reason\":\"No existing full-screen display\"}"); app.terminate(nil); return
            }
            let suite = "CyberKuku.FullScreen.Live.\(UUID())", prefs = UserDefaults(suiteName:suite)!
            let c = DesktopPetController(defaults:prefs,presentsOnScreen:true,coveredDisplays:{ coverage })
            c.enabled = true; c.placed = true
            let origin = CGPoint(x:screen.frame.midX+120,y:screen.frame.midY)
            c.cat.setFrame(CGRect(origin:origin,size:PetPlacement.companionSize),display:false); c.expandedFrame = c.cat.frame
            let front = previousFront
            c.applySuppression(true)
            try? await Task.sleep(nanoseconds:1_500_000_000)
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
            let visible = windows.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == c.cat.windowNumber }
            let focus = front == NSWorkspace.shared.frontmostApplication?.processIdentifier && !c.cat.isKeyWindow
            let compact = c.cat.frame.size == PetEdgeBehavior.foldedSize
            c.cat.orderOut(nil); c.shutdown(); prefs.removePersistentDomain(forName:suite)
            print("{\"visibleOnExistingFullscreenDisplay\":\(visible),\"compact\":\(compact),\"focusPreserved\":\(focus)}")
            if !focus, let front { NSRunningApplication(processIdentifier:front)?.activate(options:[]) }
            if !visible || !compact || !focus { exit(1) }
            app.terminate(nil)
        }
        app.run()
    }
}
