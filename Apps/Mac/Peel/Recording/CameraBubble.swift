import AppKit
@preconcurrency import AVFoundation

/// A screen recording's camera: a round, floating window with the camera's
/// picture, mirrored as a mirror is, that you drag where you like. It is a
/// window on the display, so the recording takes it in (`ShownInCaptures`).
/// The camera runs only while it is shown.
@MainActor
final class CameraBubblePanel: HUDPanel, ShownInCaptures {
    private let session = AVCaptureSession()
    private let preview: AVCaptureVideoPreviewLayer
    /// Starting and stopping block until the camera answers: off the main
    /// thread, in the order asked.
    private let sessionQueue = DispatchQueue(label: "peel.camera-bubble")

    private static let diameter: CGFloat = 200
    /// From the display's bottom-left corner.
    private static let inset: CGFloat = 32

    override init() {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init()
        setContentSize(NSSize(width: Self.diameter, height: Self.diameter))
        hasShadow = true
        // Dragged anywhere, so not pinned to its place on the screen.
        collectionBehavior.remove(.stationary)
        isMovableByWindowBackground = true

        let view = NSView(frame: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        view.wantsLayer = true
        let layer = view.layer!
        layer.cornerRadius = Self.diameter / 2
        layer.masksToBounds = true
        layer.backgroundColor = NSColor.black.cgColor
        layer.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        layer.borderWidth = 3
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        layer.insertSublayer(preview, at: 0)
        contentView = view
    }

    /// Shows the bubble at the bottom left of `screen`, the camera on.
    /// False when there is no camera to show.
    func show(on screen: NSScreen?) -> Bool {
        guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera) else {
            return false
        }
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        // The bubble is 400 px across at most: more would only be scaled away.
        session.sessionPreset = .vga640x480
        session.commitConfiguration()
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        let session = session
        sessionQueue.async { session.startRunning() }
        if let area = (screen ?? NSScreen.main)?.visibleFrame {
            setFrameOrigin(NSPoint(x: area.minX + Self.inset, y: area.minY + Self.inset))
        }
        orderFrontRegardless()
        return true
    }

    func hide() {
        orderOut(nil)
        let session = session
        sessionQueue.async { session.stopRunning() }
    }
}
