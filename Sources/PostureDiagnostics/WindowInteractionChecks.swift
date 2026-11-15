import AppKit

@MainActor enum WindowInteractionChecks {
    private final class CloseObserver: NSObject, NSWindowDelegate {
        var closed = false
        func windowWillClose(_ notification: Notification) { closed = true }
    }
    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let model = DiagnosticModel(demo:true)
            let desktop = DesktopCoordinator(model:model)
            do {
                var checks = try await DesktopPetChecks.clickInteractions()
                checks += DesktopPetController.interactionChecks()
                checks += DesktopPetController.visibilityChecks()
                checks += DesktopPetController.hoverAndDragChecks()
                checks += DesktopPetController.fullScreenChecks()
                checks += try IconChecks.run()
                let status = desktop.presentationSnapshot["statusPanel"] as! [String:Any]
                precondition(["显示小灰猫","隐藏小灰猫","展开小灰猫","固定小灰猫"].contains(status["petActionTitle"] as! String))
                precondition((status["petDetail"] as! String).hasPrefix("小灰猫："))
                checks.append("native menu exposes an explicit companion action, check state and fixed status row")
                let file = app.mainMenu!.item(withTitle:"文件")!.submenu!
                let close = file.items.first { $0.keyEquivalent == "w" }!
                precondition(close.keyEquivalentModifierMask == [.command] && close.target == nil)
                let previousStatus = model.status
                for window in [NSWindow(contentRect:NSRect(x:0,y:0,width:100,height:100),styleMask:[.titled,.closable],backing:.buffered,defer:false),
                               MonitorPanel(contentRect:NSRect(x:0,y:0,width:100,height:100),styleMask:[.titled,.closable,.nonactivatingPanel],backing:.buffered,defer:false)] {
                    window.isReleasedWhenClosed = false
                    let observer = CloseObserver(); window.delegate = observer
                    // Supply the offscreen fixture as target: an invisible application cannot
                    // acquire a real key window without interfering with the user's focus.
                    close.target = window
                    file.update()
                    let key = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[.command],timestamp:0,
                        windowNumber:window.windowNumber,context:nil,characters:"w",charactersIgnoringModifiers:"w",isARepeat:false,keyCode:13)!
                    precondition(app.mainMenu!.performKeyEquivalent(with:key))
                    precondition(observer.closed)
                    close.target = nil
                }
                precondition(model.status == previousStatus)
                checks.append("native command-W binding closes ordinary window and PiP via NSWindow action (explicit offscreen targets)")
                checks.append("closing a window leaves monitoring state unchanged")
                print(String(data:try JSONSerialization.data(withJSONObject:["passed":true,"input":"synthetic clicks and offscreen native windows; no camera or desktop capture","checks":checks],options:[.sortedKeys]),encoding:.utf8)!)
                desktop.shutdown(); model.shutdown(); app.terminate(nil)
            } catch { desktop.shutdown(); model.shutdown(); fputs("Window interaction check failed: \(error)\n",stderr); exit(1) }
        }
        app.run()
    }
}
