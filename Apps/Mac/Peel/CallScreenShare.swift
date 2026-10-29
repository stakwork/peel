import AppKit
import CoreMedia
import LiveKit
@preconcurrency import ScreenCaptureKit
import Synchronization

/// A screen, window or app you share on a call. macOS's own picker chooses
/// it, so Peel needs no standing Screen Recording permission and sees only
/// what was picked. Frames go from a ScreenCaptureKit stream into a LiveKit
/// buffer track. Unless asked to include them, Peel's own windows are left out
/// of every capture, so a shared display never shows your chats or the call
/// itself.
@MainActor
final class ScreenShare {
    /// What the picker chose.
    enum Content {
        case display, window, application

        /// The line under the control bar while it is shared.
        func note(includingPeel: Bool) -> String {
            switch self {
            case .display:
                includingPeel ? "You're sharing your screen, with Peel's windows" : "You're sharing your screen, without Peel's windows"
            case .window: "You're sharing a window"
            case .application: "You're sharing an app"
            }
        }

        /// The picker's modes for this kind, one or several of it.
        var pickerModes: SCContentSharingPickerMode {
            switch self {
            case .display: .singleDisplay
            case .window: [.singleWindow, .multipleWindows]
            case .application: [.singleApplication, .multipleApplications]
            }
        }

        /// The style the picker opens on.
        var style: SCShareableContentStyle {
            switch self {
            case .display: .display
            case .window: .window
            case .application: .application
            }
        }
    }

    let content: Content
    /// Whether Peel's own windows are part of the capture.
    let includesPeel: Bool
    /// The screen share track, publishable once the first frame is in.
    let track: LocalVideoTrack
    private let stream: SCStream
    private let output: ShareOutput
    /// Peel's windows hidden for this share, until it ends.
    private let cloak: WindowCloak.Hold?

    private init(content: Content, includesPeel: Bool, track: LocalVideoTrack, stream: SCStream, output: ShareOutput, cloak: WindowCloak.Hold?) {
        self.content = content
        self.includesPeel = includesPeel
        self.track = track
        self.stream = stream
        self.output = output
        self.cloak = cloak
    }

    // MARK: The picker

    private static let picker = PickerObserver()

    /// Shows macOS's sharing picker for one kind of content, so it opens in
    /// that mode; nil when it was cancelled or could not open. Peel's own
    /// windows and apps are not offered, unless `includePeel`.
    static func pick(_ kind: Content, includePeel: Bool = false) async -> SCContentFilter? {
        guard !Offscreen.refuses("the share picker") else { return nil }
        let shared = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        if !includePeel, let peel = Bundle.main.bundleIdentifier { configuration.excludedBundleIDs = [peel] }
        // A change of content from the menu bar would bypass this code.
        configuration.allowsChangingSelectedContent = false
        configuration.allowedPickerModes = kind.pickerModes
        shared.defaultConfiguration = configuration
        let filter = await picker.pick {
            shared.add(picker)
            // Active only while Peel asks, so nothing reaches Peel from the
            // system's own sharing menu unasked.
            shared.isActive = true
            shared.present(using: kind.style)
        }
        shared.isActive = false
        shared.remove(picker)
        return filter
    }

    // MARK: Capture

    /// The longest side sent: enough for text, light on the encoder.
    private static let maxSide: CGFloat = 1920
    private static let fps: Int32 = 15

    /// Starts capturing `filter`, after hiding Peel's windows from capture,
    /// unless `includePeel`.
    /// `stopped` runs when macOS ends the capture (the menu bar's Stop, a
    /// closed window).
    static func start(_ filter: SCContentFilter, includePeel: Bool = false, stopped: @escaping @MainActor () -> Void) async throws -> ScreenShare {
        let content: Content = switch filter.style {
        case .window: .window
        case .application: .application
        default: .display
        }
        let configuration = SCStreamConfiguration.fitting(filter, maxSide: maxSide, fps: fps)
        configuration.queueDepth = 5

        let track = LocalVideoTrack.createBufferTrack(
            options: BufferCaptureOptions(dimensions: Dimensions(width: Int32(configuration.width), height: Int32(configuration.height)), fps: Int(fps))
        )
        guard let capturer = track.capturer as? BufferCapturer else { throw ShareError.noCapturer }
        let output = ShareOutput(capturer: capturer) { Task { @MainActor in stopped() } }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        // Only a display can show Peel: the picker never offers its windows.
        let cloak = content == .display && !includePeel ? WindowCloak.hold() : nil
        do {
            try await stream.startCapture()
        } catch {
            cloak?.release()
            throw error
        }
        output.startResending()
        return ScreenShare(content: content, includesPeel: includePeel, track: track, stream: stream, output: output, cloak: cloak)
    }

    /// macOS ended the capture on its own.
    var ended: Bool { output.ended }

    /// Stops the capture and lets Peel's windows be captured again.
    func stop() async {
        output.stop()
        try? await stream.stopCapture()
        cloak?.release()
    }

    /// The screen a display's filter shows, for what goes on it while it
    /// is captured (a recording's bar and camera bubble).
    static func screen(of filter: SCContentFilter) -> NSScreen? {
        guard let display = filter.includedDisplays.first?.displayID else { return nil }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }
    }

    enum ShareError: Error { case noCapturer }
}

extension SCStreamConfiguration {
    /// `filter`'s content at up to `maxSide` pixels on its longer side and
    /// `fps`, in the encoder's own pixel format, with the cursor and no
    /// system audio: what a share and a recording both start from.
    static func fitting(_ filter: SCContentFilter, maxSide: CGFloat, fps: Int32) -> SCStreamConfiguration {
        let size = filter.contentRect.size
        let scale = CGFloat(filter.pointPixelScale)
        let fit = min(1, maxSide / max(1, max(size.width, size.height) * scale))
        let configuration = SCStreamConfiguration()
        // Even sizes, which the encoder needs.
        configuration.width = max(2, Int(size.width * scale * fit) & ~1)
        configuration.height = max(2, Int(size.height * scale * fit) & ~1)
        configuration.scalesToFit = true
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: fps)
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = true
        configuration.capturesAudio = false
        return configuration
    }
}

/// Waits for one answer from the system picker.
private final class PickerObserver: NSObject, SCContentSharingPickerObserver, Sendable {
    /// The picker hands over a filter it no longer touches.
    private struct Picked: @unchecked Sendable { let filter: SCContentFilter? }
    private let waiting = Mutex<CheckedContinuation<Picked, Never>?>(nil)

    @MainActor
    func pick(present: () -> Void) async -> SCContentFilter? {
        await withCheckedContinuation { continuation in
            // One picker at a time: a pick still open (a call's share,
            // a recording's) gets nothing, rather than waiting for ever.
            waiting.withLock {
                $0?.resume(returning: Picked(filter: nil))
                $0 = continuation
            }
            present()
        }.filter
    }

    private func finish(_ filter: SCContentFilter?) {
        waiting.withLock {
            $0?.resume(returning: Picked(filter: filter))
            $0 = nil
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        finish(nil)
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        finish(filter)
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        finish(nil)
    }
}

/// Hands each complete frame to LiveKit. ScreenCaptureKit sends frames only
/// when the picture changes, so the last one is sent again each second: a
/// still screen keeps flowing and someone joining late still sees it.
private final class ShareOutput: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    let queue = DispatchQueue(label: "peel.screen-share")
    private let capturer: BufferCapturer
    private let stopped: @Sendable () -> Void
    private struct Last: @unchecked Sendable {
        var frame: CVPixelBuffer?
        var at = ContinuousClock.now
    }
    private let last = Mutex(Last())
    private let resend = Mutex<Task<Void, Never>?>(nil)
    private let endedByMacOS = Mutex(false)
    var ended: Bool { endedByMacOS.withLock { $0 } }

    init(capturer: BufferCapturer, stopped: @escaping @Sendable () -> Void) {
        self.capturer = capturer
        self.stopped = stopped
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let frame = sampleBuffer.imageBuffer
        else { return }
        last.withLock { $0 = Last(frame: frame, at: .now) }
        capturer.capture(frame)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        stop()
        endedByMacOS.withLock { $0 = true }
        stopped()
    }

    func startResending() {
        let task = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                let stale = self.last.withLock { $0.at.duration(to: .now) >= .seconds(1) ? $0.frame : nil }
                if let stale { self.capturer.capture(stale) }
            }
        }
        resend.withLock { $0 = task }
    }

    func stop() {
        resend.withLock {
            $0?.cancel()
            $0 = nil
        }
    }
}

/// A window of Peel's meant to be in the picture: a screen recording's
/// camera bubble. `sharingType` is the window's, not a capture's, so it is
/// in every capture under way, a call's shared screen as well.
protocol ShownInCaptures: NSWindow {}

/// Leaves Peel's windows out of every screen capture while a share or a
/// recording runs: `sharingType = .none`, which ScreenCaptureKit honours for
/// display captures (checked on macOS 26.6), applied again after each event
/// so a window opened mid-share is covered too. A `ShownInCaptures` window
/// stays in. Only windows it hid are shown again, so one hidden for its own
/// reasons stays hidden. Each capture takes a `Hold`, and the windows come
/// back once every hold is released (a recording made while a call shares
/// the screen).
@MainActor
enum WindowCloak {
    private static var observer: (any NSObjectProtocol)?
    private static let hidden = NSHashTable<NSWindow>.weakObjects()
    private static var holders = 0

    /// One capture's hiding of Peel's windows, released once.
    @MainActor final class Hold {
        private var held = true

        fileprivate init() {}

        func release() {
            guard held else { return }
            held = false
            WindowCloak.show()
        }
    }

    /// Hides Peel's windows until the hold is released.
    static func hold() -> Hold {
        hide()
        return Hold()
    }

    private static func hide() {
        holders += 1
        hideAll()
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { hideAll() }
        }
    }

    private static func show() {
        holders -= 1
        guard holders == 0 else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        for window in hidden.allObjects { window.sharingType = .readOnly }
        hidden.removeAllObjects()
    }

    private static func hideAll() {
        for window in NSApp.windows where window.sharingType == .readOnly && !(window is any ShownInCaptures) {
            window.sharingType = .none
            hidden.add(window)
        }
    }
}
