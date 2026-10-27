import AppKit
import CoreMedia
import LiveKit
@preconcurrency import ScreenCaptureKit
import Synchronization

/// A screen, window or app you share on a call. macOS's own picker chooses
/// it, so Peel needs no standing Screen Recording permission and sees only
/// what was picked. Frames go from a ScreenCaptureKit stream into a LiveKit
/// buffer track. Unless asked to include them, Peel's own windows are left out
/// of a shared display, so it never shows your chats or the call itself. For a
/// display Peel builds the content filter itself (the picked display, minus
/// Peel's app unless included), so the choice can change live with
/// `SCStream.updateContentFilter`; the windows are also cloaked.
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
    /// Whether Peel's own windows are part of the capture. Changed while
    /// sharing through `setIncludesPeel`.
    private(set) var includesPeel: Bool
    /// The screen share track, publishable once the first frame is in.
    let track: LocalVideoTrack
    private var stream: SCStream
    /// What the stream captures now.
    private var filter: SCContentFilter
    /// Kept so a restarted stream captures the same way.
    private let configuration: SCStreamConfiguration
    private let output: ShareOutput
    /// The latest value asked of `setIncludesPeel`, applied one change at a time.
    private var wantsPeel: Bool
    private var applying = false
    private var stopping = false

    private init(content: Content, includesPeel: Bool, track: LocalVideoTrack, stream: SCStream, filter: SCContentFilter, configuration: SCStreamConfiguration, output: ShareOutput) {
        self.content = content
        self.includesPeel = includesPeel
        self.wantsPeel = includesPeel
        self.track = track
        self.stream = stream
        self.filter = filter
        self.configuration = configuration
        self.output = output
    }

    /// The filter for a picked display, built here so Peel can be left in or
    /// out of it. Keeps `picked` when the display or the shareable content
    /// cannot be found.
    static func displayFilter(from picked: SCContentFilter, includePeel: Bool) async -> SCContentFilter {
        guard let content = try? await SCShareableContent.current,
              let id = picked.includedDisplays.first?.displayID,
              let display = content.displays.first(where: { $0.displayID == id })
        else { return picked }
        let peel = includePeel ? [] : content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        return SCContentFilter(display: display, excludingApplications: peel, exceptingWindows: [])
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

    /// Starts capturing `filter`, leaving Peel's windows out of a display
    /// (by filter and by cloak), unless `includePeel`.
    /// `stopped` runs when macOS ends the capture (the menu bar's Stop, a
    /// closed window).
    static func start(_ filter: SCContentFilter, includePeel: Bool = false, stopped: @escaping @MainActor () -> Void) async throws -> ScreenShare {
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
        // A display is captured through a filter of our own, so Peel can be
        // included later; sized from the picked one above.
        let capture = content == .display ? await displayFilter(from: filter, includePeel: includePeel) : filter
        let stream = SCStream(filter: capture, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        // The picker offers Peel's windows and apps only when asked, so only
        // a display needs the cloak.
        if content == .display, !includePeel { WindowCloak.hide() }
        do {
            try await stream.startCapture()
        } catch {
            WindowCloak.show()
            throw error
        }
        output.startResending()
        return ScreenShare(content: content, includesPeel: includePeel, track: track, stream: stream, filter: capture, configuration: configuration, output: output)
    }

    /// macOS ended the capture on its own.
    var ended: Bool { output.ended }

    /// Includes or leaves out Peel's own windows, live. For a display the
    /// capture's filter is replaced (and the cloak follows), so viewers see the
    /// change; if macOS refuses the update the stream is restarted with the new
    /// filter, keeping the track and its publication. Window and app shares
    /// just record the flag. Changes are applied one at a time; a call made
    /// during one only records the latest value, which the running call applies.
    func setIncludesPeel(_ include: Bool) async {
        wantsPeel = include
        guard content == .display else {
            includesPeel = include
            return
        }
        guard !applying else { return }
        applying = true
        defer { applying = false }
        while includesPeel != wantsPeel, !stopping, !output.ended {
            await apply(wantsPeel)
        }
    }

    private func apply(_ include: Bool) async {
        // Leaving Peel out: cloak first, so nothing shows while the filter changes.
        if !include { WindowCloak.hide() }
        let new = await Self.displayFilter(from: filter, includePeel: include)
        guard !stopping, !output.ended else { return }
        do {
            try await stream.updateContentFilter(new)
        } catch {
            do {
                try await restart(with: new)
            } catch {
                // The capture could not go on: report the share as ended.
                WindowCloak.show()
                output.end()
                return
            }
        }
        filter = new
        includesPeel = include
        if include { WindowCloak.show() }
    }

    /// Replaces the stream with a new one on `new`, same configuration, output
    /// and queue. The output ignores the old stream's stop, so the share is
    /// not reported as ended.
    private func restart(with new: SCContentFilter) async throws {
        output.restarting(true)
        defer { output.restarting(false) }
        let old = stream
        try? await old.stopCapture()
        let replacement = SCStream(filter: new, configuration: configuration, delegate: output)
        try replacement.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        try await replacement.startCapture()
        stream = replacement
    }

    /// Stops the capture and lets Peel's windows be captured again.
    func stop() async {
        stopping = true
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
    private let isRestarting = Mutex(false)
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
        // The old stream of a restart stops on purpose; the share goes on.
        guard !isRestarting.withLock({ $0 }) else { return }
        end()
    }

    /// Whether the stream is being replaced, so its stop is not the share's end.
    func restarting(_ value: Bool) {
        isRestarting.withLock { $0 = value }
    }

    /// The capture is over for good: report it once.
    func end() {
        stop()
        let first = endedByMacOS.withLock { ended in
            defer { ended = true }
            return !ended
        }
        if first { stopped() }
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
