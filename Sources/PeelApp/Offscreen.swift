#if os(macOS)
import AppKit
import ObjectiveC

/// Development only: `-profile <dev> -offscreen YES` runs Peel where nobody
/// sees it, so agents can check the app without touching the person's
/// screens. No Dock icon and never active; every window Peel orders in is
/// placed beyond all screens, never full screen or minimised; its own
/// clipboard; no notifications, no beeps; and nothing that would bring
/// another app or a system panel forward (links, the Finder and System
/// Settings through NSWorkspace, file panels, device prompts, the share
/// picker and menu, Services).
/// `-drive <file>` then runs a script against Peel's own windows
/// (`OffscreenDriver`). See AGENTS.md, "Checking the app".
///
/// Read from the launch arguments only, never the defaults database.
/// Refused, quitting before any window opens, for the app's own profile,
/// for `default` and `throwaway`, and outside the check bundle
/// (`scripts/check-app.sh`), so the daily app's preferences and saved
/// windows are never touched; the check bundle in turn runs only in this
/// mode.
enum Offscreen {
    nonisolated static let checkBundleID = "dev.peel.mac.check"

    nonisolated static let isOn: Bool = {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        let asked = (arguments["offscreen"] as? String).map { ["yes", "true", "1"].contains($0.lowercased()) } ?? false
        let isCheckBundle = Bundle.main.bundleIdentifier == checkBundleID
        guard asked || arguments["drive"] != nil else {
            // Opened by hand it would be a visible Peel on the app's own profile.
            if isCheckBundle { refuse("\(checkBundleID) runs only offscreen") }
            return false
        }
        guard asked else { refuse("-drive needs -offscreen YES") }
        // Its own preferences and saved windows, never the daily Peel's.
        guard isCheckBundle else { refuse("runs only as \(checkBundleID): scripts/check-app.sh") }
        guard let profile = arguments["profile"] as? String else { refuse("needs -profile <development profile>") }
        // Profile directories are case-insensitive on APFS.
        guard !["default", "throwaway"].contains(profile.lowercased()) else { refuse("refused for \"\(profile)\"") }
        return true
    }()

    /// The script and the folder its snapshots go to, offscreen only.
    nonisolated static var drive: (script: URL, output: URL)? {
        guard isOn else { return nil }
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        guard let script = arguments["drive"] as? String else { return nil }
        guard let output = arguments["driveOut"] as? String else { refuse("-drive needs -driveOut <folder>") }
        return (URL(fileURLWithPath: script), URL(fileURLWithPath: output, isDirectory: true))
    }

    private static func refuse(_ reason: String) -> Never {
        log("offscreen: \(reason); quitting")
        exit(2)
    }

    /// Unbuffered, so `open --stderr` keeps every line however the run ends.
    nonisolated static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// True offscreen, with a log line: the caller then leaves `what` undone.
    nonisolated static func refuses(_ what: String) -> Bool {
        if isOn { log("offscreen: not opening \(what)") }
        return isOn
    }

    /// Peel's own clipboard while offscreen, so a drive never reads, writes
    /// or clears the person's; released at quit.
    nonisolated(unsafe) fileprivate static var pasteboard: NSPasteboard?

    /// Before the first window: no Dock icon, windows kept off the screens,
    /// a private clipboard, and nothing handed to another app.
    @MainActor static func start() {
        guard isOn else { return }
        // Background priority, as builds and tests run: the person's work first.
        setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG)
        NSApp.setActivationPolicy(.accessory)
        let board = NSPasteboard.withUniqueName()
        pasteboard = board
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            board.releaseGlobally()
        }
        // The Services menu would hand a selection to another app. AppKit
        // installs one in the app menu without the setter, so the app reads
        // none, and the menu's item is taken out whenever it comes back.
        replace(NSApplication.self, NSSelectorFromString("servicesMenu"), #selector(NSApplication.offscreenServicesMenu))
        // Never to the front, whoever asks (a notification's click among them).
        replace(NSApplication.self, NSSelectorFromString("activate"), #selector(NSApplication.offscreenActivate as (NSApplication) -> () -> Void))
        replace(NSApplication.self, NSSelectorFromString("activateIgnoringOtherApps:"),
                #selector(NSApplication.offscreenActivate(ignoringOtherApps:)))
        NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { removeServices() }
        }
        Task {
            // `open -j` launches it hidden, and hidden windows are never drawn.
            for _ in 0..<200 where !NSApp.isHidden { try? await Task.sleep(for: .milliseconds(50)) }
            guard NSApp.isHidden else { return }
            Offscreen.log("offscreen: hidden at launch; shown off the screens")
            NSApp.unhideWithoutActivation()
        }
        exchange(NSWindow.self, #selector(NSWindow.setFrame(_:display:)), #selector(NSWindow.offscreenSetFrame(_:display:)))
        exchange(NSWindow.self, #selector(NSWindow.constrainFrameRect(_:to:)), #selector(NSWindow.offscreenConstrain(_:to:)))
        exchange(NSWindow.self, #selector(NSWindow.order(_:relativeTo:)), #selector(NSWindow.offscreenOrder(_:relativeTo:)))
        replace(NSWindow.self, #selector(NSWindow.toggleFullScreen(_:)), #selector(NSWindow.offscreenRefuse(_:)))
        replace(NSWindow.self, #selector(NSWindow.miniaturize(_:)), #selector(NSWindow.offscreenRefuse(_:)))
        replace(NSResponder.self, #selector(NSResponder.noResponder(for:)), #selector(NSResponder.offscreenNoResponder(for:)))
        // The general pasteboard by either route (WebKit names it).
        let pasteboards: AnyClass = object_getClass(NSPasteboard.self)!
        replace(pasteboards, NSSelectorFromString("generalPasteboard"), #selector(NSPasteboard.offscreenGeneral))
        exchange(pasteboards, NSSelectorFromString("pasteboardWithName:"), #selector(NSPasteboard.offscreenPasteboard(withName:)))
        // The one way out to another app: links, System Settings, the Finder.
        replace(NSWorkspace.self, NSSelectorFromString("openURL:"), #selector(NSWorkspace.offscreenOpen(_:)))
        replace(NSWorkspace.self, NSSelectorFromString("openURL:configuration:completionHandler:"),
                #selector(NSWorkspace.offscreenOpen(_:configuration:completionHandler:)))
        replace(NSWorkspace.self, NSSelectorFromString("activateFileViewerSelectingURLs:"), #selector(NSWorkspace.offscreenReveal(_:)))
        let isPrivate = NSPasteboard.general === board && NSPasteboard(name: .general) === board
        log("offscreen: on; clipboard \(isPrivate ? "private" : "NOT private")")
    }

    /// `replacement` takes `original`'s place and calls it by its own name.
    private static func exchange(_ type: AnyClass, _ original: Selector, _ replacement: Selector) {
        let (a, b) = methods(type, original, replacement)
        method_exchangeImplementations(a, b)
    }

    /// `replacement` takes `original`'s place for good.
    private static func replace(_ type: AnyClass, _ original: Selector, _ replacement: Selector) {
        let (a, b) = methods(type, original, replacement)
        method_setImplementation(a, method_getImplementation(b))
    }

    private static func methods(_ type: AnyClass, _ original: Selector, _ replacement: Selector) -> (Method, Method) {
        guard let a = class_getInstanceMethod(type, original), let b = class_getInstanceMethod(type, replacement) else {
            refuse("cannot hook \(original)")
        }
        return (a, b)
    }

    /// Takes the Services item out of the main menu's submenus.
    @MainActor static func removeServices() {
        for menu in NSApp.mainMenu?.items.compactMap(\.submenu) ?? [] {
            for item in menu.items where item.submenu?.title == "Services" { menu.removeItem(item) }
        }
    }

    /// `frame` unchanged when it is off every screen, else moved past them all.
    @MainActor static func place(_ frame: NSRect) -> NSRect {
        let screens = NSScreen.screens.map(\.frame)
        guard screens.contains(where: { $0.intersects(frame) }) else { return frame }
        let all = screens.reduce(NSRect.null) { $0.union($1) }
        return NSRect(origin: CGPoint(x: all.maxX + 2000, y: all.minY), size: frame.size)
    }
}

// Installed by `Offscreen.start` only; each calls the original, exchanged,
// or refuses with a log line.
extension NSWindow {
    @objc fileprivate func offscreenSetFrame(_ frame: NSRect, display: Bool) {
        offscreenSetFrame(Offscreen.place(frame), display: display)
    }

    /// AppKit would pull a window back onto a screen.
    @objc fileprivate func offscreenConstrain(_ frame: NSRect, to screen: NSScreen?) -> NSRect { frame }

    /// Off the screens before it is ordered in, then never activated.
    @objc fileprivate func offscreenOrder(_ place: NSWindow.OrderingMode, relativeTo other: Int) {
        if place != .out { setFrame(frame, display: false) }
        offscreenOrder(place, relativeTo: other)
    }

    /// Full screen takes a Space; minimising goes to the Dock.
    @objc fileprivate func offscreenRefuse(_ sender: Any?) {
        Offscreen.log("offscreen: not taking full screen or the Dock")
    }
}

extension NSResponder {
    /// A key nothing handled: no beep.
    @objc fileprivate func offscreenNoResponder(for event: Selector) {}
}

extension NSPasteboard {
    @objc fileprivate class func offscreenGeneral() -> NSPasteboard {
        Offscreen.pasteboard!
    }

    @objc fileprivate class func offscreenPasteboard(withName name: NSPasteboard.Name) -> NSPasteboard {
        name == .general ? Offscreen.pasteboard! : offscreenPasteboard(withName: name)
    }
}

extension NSApplication {
    @objc fileprivate func offscreenServicesMenu() -> NSMenu? { nil }
    @objc fileprivate func offscreenActivate() { Offscreen.log("offscreen: not coming to the front") }
    @objc fileprivate func offscreenActivate(ignoringOtherApps: Bool) { offscreenActivate() }
}

extension NSWorkspace {
    @objc fileprivate func offscreenOpen(_ url: URL) -> Bool {
        Offscreen.log("offscreen: not opening a \(url.scheme ?? "file") link")
        return false
    }

    @objc fileprivate func offscreenOpen(
        _ url: URL, configuration: NSWorkspace.OpenConfiguration,
        completionHandler: ((NSRunningApplication?, (any Error)?) -> Void)?
    ) {
        Offscreen.log("offscreen: not opening a \(url.scheme ?? "file") link")
        completionHandler?(nil, CocoaError(.userCancelled))
    }

    @objc fileprivate func offscreenReveal(_ urls: [URL]) {
        Offscreen.log("offscreen: not opening the Finder")
    }
}
#endif
