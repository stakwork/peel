import AppKit
import CoreMedia
import LiveKit
@preconcurrency import ScreenCaptureKit
import Synchronization

/// A screen, window or app you share on a call. macOS's own picker chooses
/// it, so Peel needs no standing Screen Recording permission and sees only
/// what was picked. Frames go from a ScreenCaptureKit stream into a LiveKit
/// buffer track. While it runs, Peel's own windows are left out of every
/// capture, so a shared display never shows your chats or the call itself.
@MainActor
final class ScreenShare {
    /// What the picker chose.
    enum Content {
        case display, window, application

        /// The line under the control bar while it is shared.
        var note: String {
            switch self {
            case .display: "You're sharing your screen, without Peel's windows"
            case .window: "You're sharing a window"
            case .application: "You're sharing an app"
            }
        }
    }

    let content: Content
    /// The screen share track, publishable once the first frame is in.
    let track: LocalVideoTrack
    private let stream: SCStream
    private let output: ShareOutput

    private init(content: Content, track: LocalVideoTrack, stream: SCStream, output: ShareOutput) {
        self.content = content
        self.track = track
        self.stream = stream
        self.output = output
    }

    // MARK: The picker

    private static let picker = PickerObserver()

    /// Shows macOS's sharing picker; nil when it was cancelled or could
    /// not open. Peel's own windows and apps are not offered.
    static func pick() async -> SCContentFilter? {
        let shared = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        if let peel = Bundle.main.bundleIdentifier { configuration.excludedBundleIDs = [peel] }
        // A change of content from the menu bar would bypass this code.
        configuration.allowsChangingSelectedContent = false
        shared.defaultConfiguration = configuration
        let filter = await picker.pick {
            shared.add(picker)
            // Active only while Peel asks, so nothing reaches Peel from the
            // system's own sharing menu unasked.
            shared.isActive = true
            shared.present()
        }
        shared.isActive = false
        shared.remove(picker)
        return filter
    }

    // MARK: Capture

    /// The longest side sent: enough for text, light on the encoder.
    private static let maxSide: CGFloat = 1920
    private static let fps: Int32 = 15

    /// Starts capturing `filter`, after hiding Peel's windows from capture.
    /// `stopped` runs when macOS ends the capture (the menu bar's Stop, a
    /// closed window).
    static func start(_ filter: SCContentFilter, stopped: @escaping @MainActor () -> Void) async throws -> ScreenShare {
        let content: Content = switch filter.style {
        case .window: .window
        case .application: .application
        default: .display
        }
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
        configuration.queueDepth = 5
        configuration.showsCursor = true
        configuration.capturesAudio = false

        let track = LocalVideoTrack.createBufferTrack(
            options: BufferCaptureOptions(dimensions: Dimensions(width: Int32(configuration.width), height: Int32(configuration.height)), fps: Int(fps))
        )
        guard let capturer = track.capturer as? BufferCapturer else { throw ShareError.noCapturer }
        let output = ShareOutput(capturer: capturer) { Task { @MainActor in stopped() } }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        // Only a display can show Peel: the picker never offers its windows.
        if content == .display { WindowCloak.hide() }
        do {
            try await stream.startCapture()
        } catch {
            WindowCloak.show()
            throw error
        }
        output.startResending()
        return ScreenShare(content: content, track: track, stream: stream, output: output)
    }

    /// macOS ended the capture on its own.
    var ended: Bool { output.ended }

    /// Stops the capture and lets Peel's windows be captured again.
    func stop() async {
        output.stop()
        try? await stream.stopCapture()
        WindowCloak.show()
    }

    enum ShareError: Error { case noCapturer }
}

/// Waits for one answer from the system picker.
private final class PickerObserver: NSObject, SCContentSharingPickerObserver, Sendable {
    /// The picker hands over a filter it no longer touches.
    private struct Picked: @unchecked Sendable { let filter: SCContentFilter? }
    private let waiting = Mutex<CheckedContinuation<Picked, Never>?>(nil)

    @MainActor
    func pick(present: () -> Void) async -> SCContentFilter? {
        await withCheckedContinuation { continuation in
            waiting.withLock { $0 = continuation }
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

/// Leaves Peel's windows out of every screen capture while a share runs:
/// `sharingType = .none`, which ScreenCaptureKit honours for display
/// captures (checked on macOS 26.6), applied again after each event so a
/// window opened mid-share is covered too.
/// Only windows it hid are shown again, so one hidden for its own reasons
/// stays hidden.
@MainActor
private enum WindowCloak {
    private static var observer: (any NSObjectProtocol)?
    private static let hidden = NSHashTable<NSWindow>.weakObjects()

    static func hide() {
        hideAll()
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { hideAll() }
        }
    }

    static func show() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        for window in hidden.allObjects { window.sharingType = .readOnly }
        hidden.removeAllObjects()
    }

    private static func hideAll() {
        for window in NSApp.windows where window.sharingType == .readOnly {
            window.sharingType = .none
            hidden.add(window)
        }
    }
}
