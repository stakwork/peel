#if os(macOS)
import PeelAgent
import AppKit
import PeelCore

/// Runs a check script against Peel's own windows, offscreen only
/// (`Offscreen.drive`): events go into this app's own queue for its own
/// windows, never to the system; snapshots are drawn from the window's
/// views, never captured from the screen. Quits when the script ends, or
/// fails after `deadline` in all.
///
/// The script is JSON lines, one step each (blank and `//` lines skipped):
/// `{"select": "a chat's name"}` (sets the destination a click on its
/// sidebar row sets), `{"open": "send-sats"}` (what a button with no
/// shortcut opens), `{"key": "f", "mods": ["cmd"]}`, `{"type": "text"}`, `{"wait": 0.5}`,
/// `{"snapshot": "name"}`, `{"notification": "a chat's name"}` (a click on
/// the notification for its newest message from someone else).
@MainActor
final class OffscreenDriver {
    private struct Step: Decodable {
        var select, open, notification, key, type, snapshot: String?
        var mods: [String]?
        var wait: Double?
    }

    private struct Failure: Error, CustomStringConvertible { let description: String }

    /// The whole script's limit; `check-app.sh` stops the app a little after.
    static let deadline: Duration = .seconds(300)

    private let output: URL
    private let model: @MainActor () -> AppModel?
    /// See `offerKeyEquivalents`.
    private var keyEquivalents: Any?

    private init(output: URL, model: @escaping @MainActor () -> AppModel?) {
        self.output = output
        self.model = model
    }

    static func start(_ model: @escaping @MainActor () -> AppModel?) {
        guard let drive = Offscreen.drive else { return }
        let driver = OffscreenDriver(output: drive.output, model: model)
        let run = Task { await driver.run(drive.script) }
        Task {
            try? await Task.sleep(for: deadline)
            run.cancel()
        }
    }

    private func run(_ script: URL) async {
        var line = 0
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let lines = try String(contentsOf: script, encoding: .utf8).components(separatedBy: .newlines)
            try await until("the app to load", timeout: 30) { (self.model()?.phase).map { $0 != .loading } ?? false && self.main != nil }
            for text in lines {
                line += 1
                let text = text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty, !text.hasPrefix("//") else { continue }
                Offscreen.log("drive: \(line): \(text)")
                let step = try JSONDecoder().decode(Step.self, from: Data(text.utf8))
                try await perform(step)
                try await Task.sleep(for: .milliseconds(300))
                if step.key != nil || step.type != nil { Offscreen.log("drive: \(line): focus \(focus)") }
            }
            let services = NSApp.mainMenu?.items.contains { $0.submenu?.items.contains { $0.submenu?.title == "Services" } ?? false }
            Offscreen.log("drive: Services menu \(services == true ? "present" : "none")")
            Offscreen.log("drive: done; snapshots in \(output.path)")
        } catch is CancellationError {
            Offscreen.log("drive: failed at line \(line): over the \(Self.deadline) deadline")
        } catch {
            Offscreen.log("drive: failed at line \(line): \(error)")
        }
        NSApp.terminate(nil)
    }

    private var main: NSWindow? { NSApp.windows.first { $0.isVisible && $0.canBecomeMain } }

    /// Where keys go now and the text there, so a key that did nothing shows.
    /// An open panel or menu that takes keys, as after the click that opened it.
    private var keyPanel: NSWindow? {
        NSApp.windows.first { $0 is FloatingWindow && $0.isVisible && $0.canBecomeKey }
    }

    private var focus: String {
        guard let responder = (keyPanel ?? NSApp.keyWindow ?? main)?.firstResponder else { return "none" }
        // Never what a secure field holds.
        if "\(type(of: responder))".contains("Secure") { return "\(type(of: responder))" }
        let text = (responder as? NSText)?.string ?? (responder as? NSControl)?.stringValue
        return "\(type(of: responder))" + (text.map { " \"\($0.prefix(60))\"" } ?? "")
    }

    private func perform(_ step: Step) async throws {
        if let seconds = step.wait {
            try await Task.sleep(for: .seconds(min(seconds, 60)))
        } else if let name = step.select {
            try select(name)
        } else if let name = step.open {
            try open(name)
        } else if let name = step.notification {
            try await notification(name)
        } else if let key = step.key {
            try post(key, modifiers: try modifiers(step.mods ?? []))
        } else if let text = step.type {
            for character in text { try post(String(character), modifiers: []) }
        } else if let name = step.snapshot {
            try snapshot(name)
        } else {
            throw Failure(description: "no action in this step")
        }
    }

    /// The selection a click on the chat's sidebar row makes.
    private func select(_ name: String) throws {
        if let model = model(), name == model.agent?.name {
            // The agent's own row in Direct messages.
            model.destination = .agent
            Offscreen.log("drive: selected the agent chat")
            return
        }
        let (model, chat) = try chat(named: name)
        model.destination = .chat(chat)
        Offscreen.log("drive: selected \(chat.prefix(12))")
    }

    /// The open account and the chat with this name, as its sidebar row shows it.
    private func chat(named name: String) throws -> (AppModel, String) {
        guard let model = model() else { throw Failure(description: "no account open") }
        guard let chat = model.conversations.first(where: { $0.name == name })?.chat else {
            throw Failure(description: "no chat named \(name)")
        }
        return (model, chat)
    }

    /// A click on the notification for the newest message someone else sent
    /// in the chat's timeline, as `Notifier` passes it on (offscreen, Peel
    /// does not come to the front).
    private func notification(_ name: String) async throws {
        let (model, chat) = try chat(named: name)
        guard let storage = model.engine?.storage else { throw Failure(description: "no account open") }
        var newest: Message?
        for try await timeline in storage.timeline(in: chat) {
            newest = timeline.messages.last { !$0.fromMe }
            break
        }
        model.openFromNotification(chat, messageID: newest?.id)
        Offscreen.log("drive: notification for \(chat.prefix(12)), message \(newest?.id.map(String.init) ?? "none")")
    }

    /// What a click on a button with no shortcut opens: `send-sats`, the
    /// open chat's Send sats panel (its composer's bolt); `account`, the
    /// Account screen (the menu's Account…); `payments`, the Payments screen;
    /// `agent-connect`, the agent chat's Connect panel; `agent-settings`,
    /// its gear (Account at Peel agent); `agent-retry`, its
    /// Retry; `agent-view`, the first View in its newest reply;
    /// `agent-remove-key`, Account's Remove key once confirmed;
    /// `check-words`, the words check (the sidebar's reminder).
    private func open(_ name: String) throws {
        guard let model = model() else { throw Failure(description: "no account open") }
        switch name {
        case "send-sats":
            guard case .chat(let chat) = model.destination else { throw Failure(description: "no chat open") }
            model.sendingSats = .chat(chat)
        case "account":
            // What Account… (⌘,) sets; a menu's key equivalent does not reach an app never active.
            model.destination = .account
        case "payments":
            // What the sidebar's Payments row sets.
            model.destination = .payments
        case "agent-connect":
            // The agent chat's Connect, on its card or its error row.
            model.agentConnectFrom = .chat
        case "agent-settings":
            // The agent chat header's gear.
            model.openAgentSettings()
        case "agent-retry":
            // The agent chat's Retry under a failed reply.
            model.agent?.retry()
        case "agent-view":
            // A click on the first View in the agent's newest reply.
            let reply = model.agent?.turns.last { $0.author == .agent }?.text ?? ""
            let link = MessageMarkup.spans(in: reply).lazy.compactMap { span -> URL? in
                guard case .namedLink(let url) = span.kind, AgentMessageLink(url) != nil else { return nil }
                return url
            }.first
            guard let link else { throw Failure(description: "no View link in the agent's reply") }
            _ = model.openAgentLink(link)
        case "agent-remove-key":
            // Account › Peel agent: Remove, then its confirm.
            try model.agent?.removeKey()
        case "check-words":
            // A click on the sidebar's reminder to check the twelve words.
            model.checkWords()
        default:
            throw Failure(description: "nothing to open named \(name)")
        }
    }

    // MARK: Keys

    /// US-layout key codes by index, so handlers that read `keyCode` see the
    /// real one for these keys; any other character is sent with code 0.
    private static let keyCodes = Array("asdfhgzxcv\u{0}bqweryt123465=97-80]ou[ip\u{0}lj'k;\\,/nm.\u{0} `")
    private static let named: [String: (code: UInt16, character: Int)] = [
        "return": (KeyCode.return, 0x0D), "tab": (KeyCode.tab, 0x09), "space": (KeyCode.space, 0x20),
        "delete": (KeyCode.delete, 0x7F), "escape": (KeyCode.escape, 0x1B),
        "left": (KeyCode.left, NSLeftArrowFunctionKey), "right": (KeyCode.right, NSRightArrowFunctionKey),
        "down": (KeyCode.down, NSDownArrowFunctionKey), "up": (KeyCode.up, NSUpArrowFunctionKey),
    ]

    private func modifiers(_ names: [String]) throws -> NSEvent.ModifierFlags {
        try names.reduce(into: []) { flags, name in
            switch name.lowercased() {
            case "cmd", "command": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "opt", "option", "alt": flags.insert(.option)
            case "ctrl", "control": flags.insert(.control)
            default: throw Failure(description: "unknown modifier \(name)")
            }
        }
    }

    /// Keys go where they would with Peel in front: its key window, else a
    /// menu or panel it has open, else the main window, made key within Peel.
    private func post(_ key: String, modifiers: NSEvent.ModifierFlags) throws {
        let panel = keyPanel
        if NSApp.keyWindow == nil { (panel ?? main)?.makeKey() }
        guard let window = panel ?? NSApp.keyWindow ?? main else { throw Failure(description: "no window") }
        var modifiers = modifiers
        let characters: String
        let code: UInt16
        if let special = Self.named[key.lowercased()] {
            characters = String(Character(UnicodeScalar(UInt16(special.character))!))
            code = special.code
            if special.character >= 0xF700 { modifiers.formUnion([.function, .numericPad]) }
        } else if key.count == 1, let character = key.first {
            characters = key
            code = Self.keyCodes.firstIndex(of: Character(character.lowercased())).map(UInt16.init) ?? 0
            if character.isUppercase { modifiers.insert(.shift) }
        } else {
            throw Failure(description: "unknown key \(key)")
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: modifiers.contains(.shift) ? characters : characters.lowercased(),
                isARepeat: false, keyCode: code
            ) else { throw Failure(description: "cannot make key \(key)") }
            // Only a panel: an open menu takes its keys through Peel's key monitor.
            if let panel, NSApp.keyWindow !== panel, model()?.mainPresenter?.isOpen != true {
                // Never active, Peel gets no key window, and a posted key goes
                // to the main window: the panel is handed its keys itself.
                panel.sendEvent(event)
                continue
            }
            if type == .keyDown { offerKeyEquivalents() }
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// AppKit offers a key with ⌘ to the key window's views
    /// (`performKeyEquivalent`) before the menu bar and the view with the
    /// keyboard. Offscreen, Peel is never active, so no window is key and
    /// that pass never runs: a shortcut on a view (`.hiddenShortcut`, such
    /// as ⌘I) then reached only the focused view's `keyDown`, and a text
    /// field or the composer took it as nothing. So the driver offers it,
    /// as the key window would have, after Peel's own key monitors: they
    /// run in the order they started, so this one starts again for each key.
    private func offerKeyEquivalents() {
        if let keyEquivalents { NSEvent.removeMonitor(keyEquivalents) }
        keyEquivalents = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.command), let window = event.window else { return event }
            return MainActor.assumeIsolated { !window.isKeyWindow && window.performKeyEquivalent(with: event) } ? nil : event
        }
    }

    // MARK: Snapshots

    /// The main window as `name.png`, any other window Peel shows (a menu,
    /// a panel) as `name-1.png` and on, front to back. At the screen's
    /// scale: on a Retina Mac a point is two pixels.
    private func snapshot(_ name: String) throws {
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else {
            throw Failure(description: "a snapshot's name is a plain file name")
        }
        // `NSApp.windows`, not `orderedWindows`, which leaves out panels (`FloatingWindow`).
        let windows = NSApp.windows.filter(\.isVisible).sorted { $0.canBecomeMain && !$1.canBecomeMain }
        for (index, window) in windows.enumerated() {
            guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            try png.write(to: output.appendingPathComponent(index == 0 ? "\(name).png" : "\(name)-\(index).png"))
        }
    }

    private func until(_ what: String, timeout: Double, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition() {
            guard Date.now < deadline else { throw Failure(description: "timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
#endif
