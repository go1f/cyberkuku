import AppKit
import SwiftUI
import AVFoundation

// AVFoundation presents camera buffers directly. Model initialization and Vision requests
// cannot block this path; no CGImage is copied into the SwiftUI observation model.
final class CameraPreviewNSView: NSView {
    var onDoubleClick: (() -> Void)?
    let preview = AVCaptureVideoPreviewLayer()
    private let sessionQueue: DispatchQueue
    private weak var requestedSession: AVCaptureSession?
    private var mirrored = false
    private var previewEnabled = false
    private var sessionObservers: [NSObjectProtocol] = []

    func configure(session: AVCaptureSession, mirrored: Bool, enabled: Bool) {
        self.mirrored = mirrored
        previewEnabled = enabled
        if requestedSession !== session {
            sessionObservers.forEach(NotificationCenter.default.removeObserver)
            sessionObservers = [NotificationCenter.default.addObserver(
                forName: AVCaptureSession.didStartRunningNotification, object: session, queue: nil
            ) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.applyPreferences() }
            }]
            requestedSession = session
        }
        applyPreferences()
    }

    // Preview connections share the session queue with configuration and capture start/stop.
    private func applyPreferences() {
        guard let session = requestedSession else { return }
        sessionQueue.async { [preview, mirrored, previewEnabled] in
            if preview.session !== session { preview.session = session }
            Self.applyPreferences(to: preview, mirrored: mirrored, enabled: previewEnabled)
        }
    }

    nonisolated private static func applyPreferences(to preview: AVCaptureVideoPreviewLayer, mirrored: Bool, enabled: Bool) {
        guard let connection = preview.connection else { return }
        connection.isEnabled = enabled
        if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }

    func detach() {
        sessionObservers.forEach(NotificationCenter.default.removeObserver)
        sessionObservers = []
        requestedSession = nil
        sessionQueue.async { [preview] in preview.session = nil }
    }

    deinit { sessionObservers.forEach(NotificationCenter.default.removeObserver) }
    init(frame frameRect: NSRect, sessionQueue: DispatchQueue) {
        self.sessionQueue = sessionQueue
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        preview.videoGravity = .resizeAspect
        layer?.addSublayer(preview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { onDoubleClick == nil && super.mouseDownCanMoveWindow }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { onDoubleClick != nil }
    override func mouseDown(with event: NSEvent) {
        guard let onDoubleClick, let window else { super.mouseDown(with: event); return }
        if event.clickCount == 2 { onDoubleClick() }
        else { window.performDrag(with: event) }
    }

    override func layout() { super.layout(); preview.frame = bounds }
}
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let sessionQueue: DispatchQueue
    let mirrored: Bool
    let enabled: Bool
    func makeNSView(context: Context) -> NSView {
        let view = CameraPreviewNSView(frame: .zero, sessionQueue: sessionQueue)
        view.configure(session: session, mirrored: mirrored, enabled: enabled)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? CameraPreviewNSView else { return }
        view.configure(session: session, mirrored: mirrored, enabled: enabled)
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? CameraPreviewNSView)?.detach()
    }
}
