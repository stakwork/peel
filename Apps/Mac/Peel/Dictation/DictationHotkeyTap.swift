import AppKit
import Carbon.HIToolbox
import CoreGraphics
import PeelUI

/// Watches the keyboard system-wide with a CGEventTap on its own thread's run
/// loop and feeds `DictationStateMachine`. The tap is an active one, since
/// swallowing the Space that locks needs it; every event but that Space (and
/// the Escape that cancels, and the Return that finishes) goes on untouched. Without the permission an
/// active tap needs it falls back to a listen-only one, where nothing can
/// be swallowed. Never started before Input Monitoring is granted. While
/// Settings waits for a new key the tap records it instead (`record`),
/// swallowing each press (an active tap only); releases go on.
final class DictationHotkeyTap: @unchecked Sendable {
    /// What the tap says about an event: the machine's answer is made here, on
    /// the tap's thread, since swallowing must be decided before it returns.
    typealias Handler = @Sendable (DictationStateMachine.Input) -> Bool
    /// The key is down according to the system, for the watchdog's stuck-key check.
    typealias IsActive = @Sendable () -> Bool
    /// What was pressed while choosing a key, told from the tap's thread.
    typealias Recorder = @Sendable (HotkeyRecording.Outcome) -> Void

    private static let spaceKey = Int64(kVK_Space)
    private static let escapeKey = Int64(kVK_Escape)
    private static let returnKeys: Set<Int64> = [Int64(kVK_Return), Int64(kVK_ANSI_KeypadEnter)]
    private static let watchdogInterval: TimeInterval = 2

    private let handler: Handler
    private let isActive: IsActive
    private let lock = NSLock()
    private var hotkey: HotkeyConfig
    private var recorder: Recorder?
    private var recording = HotkeyRecording()
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var activeTap = false

    init(hotkey: HotkeyConfig, isActive: @escaping IsActive, handler: @escaping Handler) {
        self.hotkey = hotkey
        self.isActive = isActive
        self.handler = handler
    }

    /// Whether the tap can swallow events (Accessibility granted); a
    /// listen-only tap lets the locking Space through.
    var swallows: Bool { lock.withLock { activeTap } }

    var isRunning: Bool { lock.withLock { thread != nil } }

    func setHotkey(_ new: HotkeyConfig) { lock.withLock { hotkey = new } }

    /// Until a key is chosen or Escape is pressed, or `record(nil)`: each
    /// key press goes to `recorder` and is swallowed, never to the machine.
    func record(_ recorder: Recorder?) {
        lock.withLock {
            self.recorder = recorder
            recording = HotkeyRecording()
        }
    }

    func start() {
        guard !isRunning else { return }
        let started = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in self?.run(started: started) }
        thread.name = "peel.dictation.hotkey"
        thread.qualityOfService = .userInteractive
        lock.withLock { self.thread = thread }
        thread.start()
        started.wait()
    }

    func stop() {
        let (loop, tap): (CFRunLoop?, CFMachPort?) = lock.withLock {
            defer { thread = nil; runLoop = nil; self.tap = nil }
            return (runLoop, self.tap)
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let loop { CFRunLoopStop(loop) }
    }

    // MARK: - The thread

    private func run(started: DispatchSemaphore) {
        let mask: CGEventMask = [CGEventType.flagsChanged, .keyDown, .keyUp]
            .reduce(0) { $0 | (1 << CGEventMask($1.rawValue)) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<DictationHotkeyTap>.fromOpaque(refcon).takeUnretainedValue()
            return tap.receive(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
        }
        var created = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback, userInfo: refcon
        )
        let isActiveTap = created != nil
        if created == nil {
            created = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                eventsOfInterest: mask, callback: callback, userInfo: refcon
            )
        }
        guard let created else {
            lock.withLock { thread = nil }
            started.signal()
            return
        }
        let loop = CFRunLoopGetCurrent()
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(loop, source, .commonModes)
        lock.withLock { runLoop = loop; tap = created; activeTap = isActiveTap }
        CGEvent.tapEnable(tap: created, enable: true)

        // The system turns a slow or disturbed tap off without telling anyone
        // else; this notices when the callback's own notice was missed.
        let watchdog = Timer(timeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            self?.watch()
        }
        RunLoop.current.add(watchdog, forMode: .common)
        started.signal()

        CFRunLoopRun()

        watchdog.invalidate()
        CFRunLoopRemoveSource(loop, source, .commonModes)
        CFMachPortInvalidate(created)
    }

    private func watch() {
        if let tap = lock.withLock({ self.tap }), !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        releaseIfStuck()
    }

    /// The key went up while the tap was off, or its release was never seen:
    /// the system's flags say it is not down, so end it.
    private func releaseIfStuck() {
        guard isActive() else { return }
        let key = lock.withLock { hotkey }
        let down = key.isDown(flags: CGEventSource.flagsState(.combinedSessionState).rawValue)
            ?? CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(key.keyCode))
        if !down { _ = handler(.hotkeyUp) }
    }

    // MARK: - Events

    /// Returns whether to swallow the event.
    private func receive(type: CGEventType, event: CGEvent) -> Bool {
        // Peel's own ⌘V, typing dictated text: not the user's key.
        if event.getIntegerValueField(.eventSourceUserData) == DictationTextInserter.eventMarker { return false }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = lock.withLock({ self.tap }) { CGEvent.tapEnable(tap: tap, enable: true) }
            releaseIfStuck()
            return false
        }
        // One read per event: this runs for every key on the Mac.
        let (key, recorder) = lock.withLock { (hotkey, self.recorder) }
        // A dictation under way keeps its key until it ends, so its release
        // is never taken for a choice.
        if let recorder, !isActive() { return record(type: type, event: event, to: recorder) }
        switch type {
        case .flagsChanged:
            guard key.isModifier, Int64(key.keyCode) == event.getIntegerValueField(.keyboardEventKeycode),
                  let down = key.isDown(flags: event.flags.rawValue) else { return false }
            return handler(down ? .hotkeyDown(isRepeat: false) : .hotkeyUp)
        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if code == Self.spaceKey { return handler(.spaceDown(isRepeat: isRepeat)) }
            if code == Self.escapeKey { return handler(.escapeDown) }
            if Self.returnKeys.contains(code) { return isRepeat ? false : handler(.returnDown) }
            if !key.isModifier, code == Int64(key.keyCode) { return handler(.hotkeyDown(isRepeat: isRepeat)) }
            return isRepeat ? false : handler(.otherKeyDown)
        case .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == Self.spaceKey { return handler(.spaceUp) }
            if !key.isModifier, code == Int64(key.keyCode) { return handler(.hotkeyUp) }
            return false
        default:
            return false
        }
    }

    /// Choosing a key: presses are swallowed, and what they mean is told;
    /// a choice or Escape ends it.
    private func record(type: CGEventType, event: CGEvent, to recorder: Recorder) -> Bool {
        let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let character = type == .keyDown ? Self.character(of: event) : nil
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let outcome: HotkeyRecording.Outcome = lock.withLock {
            let outcome: HotkeyRecording.Outcome = switch type {
            case .flagsChanged: recording.flagsChanged(code: code, flags: event.flags.rawValue)
            case .keyDown: recording.keyDown(code: code, character: character, isRepeat: isRepeat)
            default: .pass
            }
            switch outcome {
            case .chosen, .cancel: self.recorder = nil
            default: break
            }
            return outcome
        }
        switch outcome {
        case .pass: return false
        case .swallow: return true
        case .refused, .chosen, .cancel:
            recorder(outcome)
            return true
        }
    }

    /// What a key types, to name it.
    private static func character(of event: CGEvent) -> String? {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
        return length > 0 ? String(utf16CodeUnits: chars, count: length) : nil
    }
}

/// Another process has asked the system for secure keyboard input (a
/// password field, a terminal's Secure Keyboard Entry): taps then see no
/// key presses, so the hotkey may not work.
enum SecureInput {
    static var isEnabled: Bool { IsSecureEventInputEnabled() }
}
