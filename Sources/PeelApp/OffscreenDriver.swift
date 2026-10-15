#if os(macOS)
import AgentKit
import PeelAgent
import AppKit
import PeelCore
import PeelUI

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
///
/// For the list journeys (`scripts/journeys`): `{"probe": "name", "for": 2}`
/// records every message list each frame for that long while the steps
/// after it run, into `name.probe.json` (`ListProbe`); `{"thread":
/// "newest"}` (or `"visible"`, `"visible2"` for the second row in view, or
/// a row's index) opens a thread as its "N replies" does, `"from-threads"`
/// the first in the Threads list as its card does (`{"open": "threads"}`
/// shows that list), `{"close": "thread"}` closes it as its X does;
/// `{"note": "thread"}` (or `"focus"`) logs the thread open (or where the
/// keys go); `{"reveal": "replies"}` scrolls the chat up until its
/// middle "N replies" row is in view, a few rows below the top;
/// `{"appearance": "light"}` (or `"dark"`) sets the app's appearance;
/// `{"scroll": 600}` scrolls the chat's list up 600 points as a live scroll
/// by hand (`"in": "thread"` for the thread's, negative for down; `"steps":
/// 1` in one frame, a flick),
/// `{"overscroll": -80, "over": 0.3}` pushes the chat's list 80 points
/// past its end (positive past its top) over that long as a live scroll,
/// as an elastic drag does, then lets go and eases it back as AppKit's
/// rubber band does; `{"hover": 0}` puts the pointer on the chat's top
/// row in view, whole or in part (1 the next down, -1 the bottom one), as a mouse moved there
/// does; `{"scrollTo": 40}` until row 40 is at its top; `{"width": 760, "over":
/// 0.3}` resizes the window, as a drag would over that long; `{"jump": 150}`
/// goes to the 150th newest message, as a search match does (`{"jump":
/// {"older": 200, "below": "image"}}`: to the message under the newest
/// image older than the newest 200, a window made with the image not yet
/// loaded, so it sizes itself after the list is placed);
/// `{"expect": "search"}` notes the first search match as where a probe
/// should land; `{"signal": "send"}` writes `signal-send` in the out dir for
/// the script running the drive; `{"type": "text", "return": true}` types
/// and presses Return with no pause between. Each step is followed by
/// 0.3 s, or `"next"` seconds.
@MainActor
final class OffscreenDriver {
    private struct Step: Decodable {
        var select, open, notification, key, type, snapshot, link: String?
        var probe, thread, close, expect, signal, list, note, reveal, appearance: String?
        var mods: [String]?
        var wait, duration, scroll, overscroll, width, over, next: Double?
        var scrollTo, steps, hover: Int?
        var jump: JumpTarget?
        var submit: Bool?

        enum CodingKeys: String, CodingKey {
            case select, open, notification, key, type, snapshot, link, probe, thread, close, expect, signal, note, reveal
            case appearance
            case mods, wait, scroll, overscroll, width, over, scrollTo, jump, steps, next, hover
            case list = "in", duration = "for", submit = "return"
        }
    }

    /// A `probe` running: its samples, a frame each, and the steps taken
    /// meanwhile, by seconds since it started.
    private struct Probe {
        /// A frame as read (`ListProbe.Capture`), with the model's rows and
        /// the target then; what the file holds is made from it at the end.
        struct Sample {
            let t: Double
            let width: Double
            let lists: [ListProbe.Capture]
            let chatRows: [ChatRow]
            let threadRows: [ChatRow]
            let target: String?
        }
        struct Event: Encodable {
            let t: Double
            let step: String
        }
        let name: String
        let start: Date
        let end: Date
        var samples: [Sample] = []
        var events: [Event] = []
    }

    private struct Failure: Error, CustomStringConvertible { let description: String }

    /// The whole script's limit; `check-app.sh` stops the app a little after.
    static let deadline: Duration = .seconds(300)

    private let output: URL
    private let model: @MainActor () -> AppModel?
    /// See `offerKeyEquivalents`.
    private var keyEquivalents: Any?
    private var probe: Probe?
    private var probeTimer: Timer?
    /// Held while a probe runs: the app is never active offscreen, and App
    /// Nap would otherwise stretch its timers to a few a second.
    private var probeActivity: NSObjectProtocol?
    /// The message a jump or search went to (its uuid), which a probe
    /// reports the place of.
    private var target: String?

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
                // A pairing link's key never reaches the log or a probe.
                let redacted = text.replacing(/key=[^&"\s]*/, with: "key=[redacted]")
                Offscreen.log("drive: \(line): " + redacted)
                let step = try JSONDecoder().decode(Step.self, from: Data(text.utf8))
                if let probe {
                    // As the log has it, and never what is typed.
                    let event = Probe.Event(t: Date.now.timeIntervalSince(probe.start), step: step.type == nil ? redacted : "type")
                    self.probe?.events.append(event)
                }
                try await perform(step)
                try await Task.sleep(for: .seconds(min(step.next ?? 0.3, 60)))
                if step.key != nil || step.type != nil { Offscreen.log("drive: \(line): focus \(focus)") }
            }
            // A probe still running records to its end.
            while let probe, Date.now < probe.end { try await Task.sleep(for: .milliseconds(50)) }
            try finishProbe()
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
        } else if let link = step.link {
            // As macOS hands Peel a `peel://` link it was opened with.
            // Through SwiftUI's own delegate, which hands it to `AppDelegate`.
            guard let url = URL(string: link), let open = NSApp.delegate?.application(_:open:) else {
                throw Failure(description: "no link to open")
            }
            open(NSApp, [url])
            Offscreen.log("drive: opened a \(url.scheme ?? "") link")
        } else if let text = step.type {
            for character in text { try post(String(character), modifiers: []) }
            if step.submit == true { try post("return", modifiers: []) }
        } else if let name = step.snapshot {
            try snapshot(name)
        } else if let name = step.probe {
            try startProbe(name, for: step.duration ?? 1)
        } else if let which = step.thread {
            try openThread(which)
        } else if step.close == "thread" {
            // As the thread's X and Escape do.
            ThreadPanel.closing { model()?.closeThread() }
        } else if let points = step.scroll {
            try await scroll(by: points, in: step.list ?? "chat", steps: step.steps)
        } else if let points = step.overscroll {
            try await overscroll(by: points, in: step.list ?? "chat", over: step.over ?? 0.3)
        } else if let index = step.hover {
            try hover(row: index, in: step.list ?? "chat")
        } else if let row = step.scrollTo {
            try await scroll(toRow: row, in: step.list ?? "chat")
        } else if let width = step.width {
            try await resize(to: width, over: step.over ?? 0)
        } else if let target = step.jump {
            try await jump(target)
        } else if step.expect == "search" {
            try await until("search matches", timeout: 10) { !(self.model()?.search?.matches.isEmpty ?? true) }
            target = model()?.search?.matches.first?.uuid
        } else if let name = step.appearance {
            // The whole app's, as System Settings' Appearance would change it.
            guard let appearance = NSAppearance(named: name == "light" ? .aqua : .darkAqua) else {
                throw Failure(description: "no appearance \(name)")
            }
            NSApp.appearance = appearance
            Offscreen.log("drive: appearance \(name)")
        } else if step.reveal == "replies" {
            guard let rows = model()?.chatRows else { throw Failure(description: "no account open") }
            let threads = rows.indices.filter { rows[$0].summary != nil }
            guard !threads.isEmpty else { throw Failure(description: "no N replies row") }
            let row = threads[threads.count / 2]
            try await scroll(toRow: max(row - 3, 0), in: "chat")
            Offscreen.log("drive: replies row \(row) in view")
        } else if let what = step.note {
            switch what {
            case "thread":
                let open = model()?.openThread.map { "open in \($0.chat.prefix(12))" } ?? "none open"
                Offscreen.log("drive: thread \(open)")
            default:
                Offscreen.log("drive: focus \(focus)")
            }
        } else if let name = step.signal {
            guard !name.isEmpty, !name.contains("/") else { throw Failure(description: "a signal's name is a plain word") }
            try Data().write(to: output.appendingPathComponent("signal-\(name)"))
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
    /// Account screen (the menu's Account…); `message-menu`, the ••• menu of
    /// the open chat's newest row from someone else; `payments`, the Payments screen;
    /// `automations`, the Automations page; `automations-setup`, its Set up
    /// (the Connect panel) while no model is connected; `automations-system`,
    /// its System tab; `system-open`, `system-switch` and `system-run-now`,
    /// the first system automation's row, its switch and its Run now; `agent-connect`, the agent chat's Connect panel; `agent-settings`,
    /// its gear (Account at Peel agent); `agent-retry`, its
    /// Retry; `agent-view`, the first View in its newest reply;
    /// `agent-sent-view`, View on its newest send row; `agent-always`, the
    /// waiting card's Always allow; `agent-revoke`, Account's first Revoke;
    /// `agent-remove-key`, Account's Remove key once confirmed;
    /// `agent-rows`, every tool row's chevron; `agent-memory`, the first fact
    /// in the newest memory row (its panel beside the chat); `resume-history`,
    /// Resume on the sidebar's paused restore; `brain-form`, Account ›
    /// Brain's "Connect a home server…" (or Change); `brain-use`, Connect on
    /// a pairing link's callout there; `brain-leave`, its Use this Mac
    /// (asking first); `brain-this-mac`, Use this Mac once confirmed;
    /// `brain-check`, Check.
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
        case "threads":
            // What the sidebar's Threads row sets.
            model.destination = .threads
        case "automations":
            // What the sidebar's Automations row sets.
            model.destination = .automations
        case "automations-setup":
            // The Automations page's Set up, while no model is connected.
            model.agentConnectFrom = .automations
        case "automations-system":
            // The Automations page's System tab.
            model.automationsTab = .system
        case "system-open", "system-switch", "system-run-now":
            guard let automation = model.automations.system.first else { throw Failure(description: "no system automation") }
            switch name {
            case "system-open": model.openedAutomation = automation.id
            case "system-switch": Task { await model.setAutomation(automation, enabled: !automation.enabled) }
            default: Task { await model.runAutomationNow(automation) }
            }
        case "message-menu":
            // A click on More over the open chat's newest row from someone else.
            guard case .chat(let chat) = model.destination, let presenter = model.mainPresenter as? MenuPresenter, let window = main,
                  let row = model.chatRows.last(where: { $0.kind == .message && !$0.message.fromMe && !$0.message.deleted })
            else { throw Failure(description: "no message from someone else in an open chat") }
            let entries = MessageMenu.entries(for: row, composer: .chat(chat), model: model, offersBoost: row.canBoost)
            presenter.show(entries, at: CGPoint(x: window.frame.midX, y: window.frame.midY), in: window, source: row.id)
        case "agent-connect":
            // The agent chat's Connect, on its card or its error row.
            model.agentConnectFrom = .chat
        case "agent-settings":
            // The agent chat header's gear.
            model.openAgentSettings()
        case "agent-retry":
            // The agent chat's Retry under a failed reply.
            model.agent?.retry()
        case "resume-history":
            // Resume on the sidebar's "Restore paused".
            Task { await model.resumeHistory() }
        case "agent-view":
            // A click on the first View in the agent's newest reply.
            let reply = model.agent?.turns.last { $0.author == .agent }?.text ?? ""
            let link = MessageMarkup.spans(in: reply).lazy.compactMap { span -> URL? in
                guard case .namedLink(let url) = span.kind, AgentMessageLink(url) != nil else { return nil }
                return url
            }.first
            guard let link else { throw Failure(description: "no View link in the agent's reply") }
            _ = model.openAgentLink(link)
        case "agent-sent-view":
            // A click on View in the newest tool row that sent a message.
            let summaries = model.agent?.turns.flatMap(\.tools).compactMap(\.summary) ?? []
            guard let url = summaries.lazy.reversed().compactMap({ AgentMessageLink(summary: $0)?.url }).first else {
                throw Failure(description: "no sent message in the agent chat")
            }
            _ = model.openAgentLink(url)
        case "agent-always":
            // A click on the waiting card's "Always allow for …".
            guard model.agent?.waiting != nil else { throw Failure(description: "no card waiting") }
            model.agent?.answer(.alwaysAllow)
        case "agent-revoke":
            // Account › Peel agent: the first "Always allowed" row's Revoke.
            guard let agent = model.agent, let rule = agent.approvalRules.first else {
                throw Failure(description: "no always-allowed rule")
            }
            try agent.revoke(rule)
        case "agent-remove-key":
            // Account › Peel agent: Remove, then its confirm.
            try model.agent?.removeKey()
        case "brain-form":
            model.brainFormOpened += 1
        case "brain-leave":
            model.brainLeaveOpened += 1
        case "brain-use":
            guard let pairing = model.pairing else { throw Failure(description: "no pairing link waiting") }
            try model.setBrain(.homeServer(pairing))
        case "brain-this-mac":
            try model.setBrain(.thisMac)
        case "brain-check":
            model.checkBrain()
        case "agent-rows":
            // A click on every tool row's chevron.
            model.agentRowsOpened += 1
        case "agent-memory":
            // A click on the first fact the newest Remembered row shows.
            let rows = model.agent?.turns.flatMap(\.tools).compactMap { tool in
                tool.row.flatMap { MemoryResult(tool: tool.name, row: $0) }
            } ?? []
            guard case .remembered(let remembered)? = rows.last(where: { if case .remembered = $0 { true } else { false } }),
                  let fact = remembered.facts.first?.fact
            else { throw Failure(description: "no Remembered row with a fact") }
            model.openMemory(fact)
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
            if let panel, NSApp.keyWindow !== panel, (model()?.mainPresenter as? MenuPresenter)?.isOpen != true {
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

    // MARK: List journeys

    /// Samples every list each frame (as near as a 120 Hz timer comes)
    /// until `seconds` have passed.
    private func startProbe(_ name: String, for seconds: Double) throws {
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else {
            throw Failure(description: "a probe's name is a plain file name")
        }
        try finishProbe()
        let start = Date.now
        probe = Probe(name: name, start: start, end: start.addingTimeInterval(min(seconds, 60)))
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        probeTimer = timer
        probeActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "list probe")
        // Out of the background band `Offscreen.start` puts it in, whose
        // timers are coalesced too, for the probe's few seconds.
        setpriority(PRIO_DARWIN_PROCESS, 0, 0)
        sample()
    }

    private func sample() {
        guard let probe, let model = model() else { return }
        guard Date.now < probe.end else {
            do { try finishProbe() } catch { Offscreen.log("drive: probe \(probe.name) not written: \(error)") }
            return
        }
        let sample = Probe.Sample(
            t: Date.now.timeIntervalSince(probe.start), width: Double(main?.frame.width ?? 0), lists: ListProbe.capture(),
            chatRows: model.chatRows, threadRows: model.threadRows, target: target
        )
        self.probe?.samples.append(sample)
    }

    private func finishProbe() throws {
        probeTimer?.invalidate()
        probeTimer = nil
        if let probeActivity {
            ProcessInfo.processInfo.endActivity(probeActivity)
            setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG)
        }
        probeActivity = nil
        guard let probe else { return }
        self.probe = nil
        struct Sample: Encodable {
            let t: Double
            let width: Double
            let lists: [ListProbe.List]
        }
        struct File: Encodable {
            let name: String
            let events: [Probe.Event]
            let samples: [Sample]
        }
        // Each list's rows by index, and each row's tag, made once.
        var indices: [[String]: [String: Int]] = [:]
        var tags: [String: String] = [:]
        func tag(_ id: String) -> String {
            if let tag = tags[id] { return tag }
            let tag = ListProbe.tag(id)
            tags[id] = tag
            return tag
        }
        let samples = probe.samples.map { sample in
            Sample(t: sample.t, width: sample.width, lists: sample.lists.map { capture in
                let rows = capture.kind == "chat" ? sample.chatRows : capture.kind == "thread" ? sample.threadRows : []
                let index = indices[capture.ids] ?? Dictionary(capture.ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
                indices[capture.ids] = index
                let target = sample.target.flatMap { uuid in rows.first { $0.holds(uuid) }?.id }
                return ListProbe.list(capture, divider: rows.first(where: \.startsNew)?.id, target: target, index: index, tag: tag)
            })
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try encoder.encode(File(name: probe.name, events: probe.events, samples: samples))
            .write(to: output.appendingPathComponent("\(probe.name).probe.json"))
        Offscreen.log("drive: probe \(probe.name), \(probe.samples.count) frames")
    }

    /// As a click on a row's "N replies" opens its thread: `newest`, the
    /// newest row with one (else the newest message); `visible`, the newest in view with one, else
    /// the top message in view (the thread it would start); or a row's index.
    private func openThread(_ which: String) throws {
        guard let model = model() else { throw Failure(description: "no account open") }
        if which == "from-threads" {
            // As a card in the Threads list: at its first new reply, if any.
            guard let summary = model.threads.first else { throw Failure(description: "no threads") }
            ThreadPanel.opening { model.openThread(summary) }
            return Offscreen.log("drive: thread from Threads in \(summary.chat.prefix(12))")
        }
        guard case .chat = model.destination else { throw Failure(description: "no chat open") }
        let rows = model.chatRows.enumerated().filter { $0.element.kind == .message }
        let row: ChatRow?
        switch which {
        case "newest":
            // A direct message's threads are not folded: its newest message.
            row = (rows.last { $0.element.summary != nil } ?? rows.last)?.element
        case "visible":
            let inView = Set(ListProbe.inView(kind: "chat"))
            let shown = rows.filter { inView.contains($0.element.id) }
            row = (shown.last { $0.element.summary != nil } ?? shown.first)?.element
        case "visible2":
            let inView = Set(ListProbe.inView(kind: "chat"))
            row = rows.filter { inView.contains($0.element.id) }.dropFirst().first?.element
        default:
            guard let index = Int(which) else { throw Failure(description: "no thread \(which)") }
            row = rows.first { $0.offset == index }?.element
        }
        guard let row else { throw Failure(description: "no row for thread \(which)") }
        ThreadPanel.opening {
            if let summary = row.summary {
                model.openThread(ThreadRef(chat: summary.chat, uuid: summary.uuid))
            } else {
                model.openThread(of: row.message)
            }
        }
        Offscreen.log("drive: thread on row \(model.chatRows.firstIndex { $0.id == row.id } ?? -1)")
    }

    /// Up (positive) or down by `points`, as a live scroll by hand: the
    /// list's own scroll view says a live scroll started, moves a step a
    /// frame and says it ended, as it does for a trackpad. (Wheel events
    /// cannot be aimed at a window off the screens: their place is held to
    /// the displays.)
    private func scroll(by points: Double, in kind: String, steps: Int? = nil) async throws {
        let view = try scrollView(kind)
        let steps = max(1, steps ?? Int((abs(points) / 40).rounded(.up)))
        let delta = points / Double(steps)
        let center = NotificationCenter.default
        center.post(name: NSScrollView.willStartLiveScrollNotification, object: view)
        for _ in 0..<steps {
            let clip = view.contentView
            let height = (view.documentView?.frame.height ?? 0) - clip.bounds.height
            // Up is towards the document's top.
            let y = min(max(clip.bounds.origin.y + (clip.isFlipped ? -delta : delta), 0), max(height, 0))
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            view.reflectScrolledClipView(clip)
            center.post(name: NSScrollView.didLiveScrollNotification, object: view)
            try await Task.sleep(for: .milliseconds(16))
        }
        center.post(name: NSScrollView.didEndLiveScrollNotification, object: view)
    }

    /// Past the list's end (down, negative) or its top by `points` over
    /// `seconds`, a frame at a time, as a live scroll whose position runs
    /// out of the content's range; then, the gesture ended, back to that
    /// end over 0.4 s, easing out, as AppKit's rubber band returns.
    private func overscroll(by points: Double, in kind: String, over seconds: Double) async throws {
        let view = try scrollView(kind)
        guard let clip = view.contentView as? ListClipView else { throw Failure(description: "the \(kind) list has no rubber band") }
        let center = NotificationCenter.default
        let range = max((view.documentView?.frame.height ?? 0) - clip.bounds.height, 0)
        // Up is towards the document's top.
        let dy = clip.isFlipped ? -points : points
        let edge = dy < 0 ? 0 : range
        let start = clip.bounds.origin.y
        let far = edge + dy
        func set(_ y: Double) {
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
            view.reflectScrolledClipView(clip)
        }
        // AppKit lets the clip past the content only for a trackpad's
        // gesture, which cannot be made off the screens: its stand-in.
        clip.elastic = true
        defer { clip.elastic = false }
        let push = max(1, Int((seconds * 60).rounded()))
        center.post(name: NSScrollView.willStartLiveScrollNotification, object: view)
        for step in 1...push {
            set(start + (far - start) * Double(step) / Double(push))
            center.post(name: NSScrollView.didLiveScrollNotification, object: view)
            try await Task.sleep(for: .milliseconds(16))
        }
        center.post(name: NSScrollView.didEndLiveScrollNotification, object: view)
        let back = 24
        for step in 1...back {
            let t = Double(step) / Double(back)
            set(far + (edge - far) * (1 - pow(1 - t, 3)))
            try await Task.sleep(for: .milliseconds(16))
        }
        Offscreen.log("drive: overscroll \(Int(points)) pt, back at \(Int(clip.bounds.origin.y)) of \(Int(range))")
    }

    /// The row the last `hover` step put the pointer on.
    private weak var hovered: HostCell?

    /// The pointer moved onto the `index`th row in view, from the top
    /// (negative from the bottom), whole or in part: its cell's tracking area entered at
    /// its middle, and the row hovered before left, as AppKit sends them.
    /// A window off the screens gets no tracking events of its own.
    private func hover(row index: Int, in kind: String) throws {
        let view = try scrollView(kind)
        guard let window = view.window, let table = view.documentView else { throw Failure(description: "no \(kind) list") }
        let clip = view.contentView
        let visible = clip.convert(clip.bounds, to: nil)
        let cells = table.subviews.compactMap { ($0 as? NSTableRowView)?.view(atColumn: 0) as? HostCell }
            .map { ($0, $0.convert($0.bounds, to: nil)) }
            .filter { $0.1.intersects(visible) && $0.1.height > 0 }
            .sorted { $0.1.maxY > $1.1.maxY }
        let at = index < 0 ? cells.count + index : index
        guard cells.indices.contains(at) else { throw Failure(description: "no row \(index) in view of \(cells.count)") }
        let (cell, whole) = cells[at]
        let frame = whole.intersection(visible)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            guard let event = NSEvent.enterExitEvent(
                with: type, location: NSPoint(x: frame.midX, y: frame.midY), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, trackingNumber: 0, userData: nil
            ) else { throw Failure(description: "no mouse event") }
            return event
        }
        if let last = hovered, last !== cell { last.mouseExited(with: try event(.mouseExited)) }
        hovered = cell
        cell.mouseEntered(with: try event(.mouseEntered))
        Offscreen.log("drive: hover row \(index) of \(cells.count) in view, \(Int(visible.maxY - whole.maxY)) pt below the top")
    }

    /// Scrolls until row `index` is laid out, then puts its top at the list's top.
    private func scroll(toRow index: Int, in kind: String) async throws {
        for _ in 0..<40 {
            guard let end = ListProbe.geometry(kind: kind), end.ids.indices.contains(index) else {
                throw Failure(description: "no row \(index) in the \(kind) list")
            }
            let height = end.view.upperBound - end.view.lowerBound
            if let frame = end.frames[end.ids[index]] {
                let distance = Double(end.view.lowerBound - frame.minY)
                if abs(distance) > 0.5 { try await scroll(by: distance, in: kind) }
                return
            }
            let laid = end.ids.indices.filter { end.frames[end.ids[$0]] != nil }
            let up = laid.min().map { index < $0 } ?? true
            try await scroll(by: Double(height) * 0.8 * (up ? 1 : -1), in: kind)
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure(description: "row \(index) never laid out")
    }

    /// The scroll view showing the list, found by what the list last
    /// reported: its content's height, its own height and its offset.
    private func scrollView(_ kind: String) throws -> NSScrollView {
        guard let end = ListProbe.geometry(kind: kind), let root = main?.contentView else {
            throw Failure(description: "no \(kind) list")
        }
        if let view = end.scrollView { return view }
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(root)
        // The one whose content, height and place in it are all the list's;
        // two lists matching on all three would be refused, not guessed.
        let height = end.view.upperBound - end.view.lowerBound
        let matches = found.filter { scroll in
            abs((scroll.documentView?.frame.height ?? 0) - end.content) < 1
                && abs(scroll.contentView.bounds.height - height) < 1
                && abs(scroll.contentView.bounds.minY - end.view.lowerBound) < 1
        }
        guard matches.count == 1, let view = matches.first else {
            throw Failure(description: "\(matches.count) scroll views match the \(kind) list among \(found.count)")
        }
        return view
    }

    /// The window's width, in steps a frame apart over `seconds`, as a drag.
    private func resize(to width: Double, over seconds: Double) async throws {
        guard let window = main else { throw Failure(description: "no window") }
        let start = Double(window.frame.width)
        let steps = max(1, Int(seconds * 60))
        for step in 1...steps {
            var frame = window.frame
            frame.size.width = start + (width - start) * Double(step) / Double(steps)
            window.setFrame(frame, display: true)
            if step < steps { try await Task.sleep(for: .milliseconds(16)) }
        }
        Offscreen.log("drive: window \(Int(window.frame.width)) wide")
    }

    /// A jump step: the `back`th newest message, or the one under the
    /// newest image older than the newest `older`.
    private struct JumpTarget: Decodable {
        var back: Int?
        var older: Int?
        var below: String?

        private enum CodingKeys: String, CodingKey { case older, below }

        init(from decoder: Decoder) throws {
            if let back = try? decoder.singleValueContainer().decode(Int.self) {
                self.back = back
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            older = try container.decodeIfPresent(Int.self, forKey: .older)
            below = try container.decodeIfPresent(String.self, forKey: .below)
        }
    }

    /// To a message of the open chat, as a search match or a notification
    /// goes (`focus(on:)`).
    private func jump(_ to: JumpTarget) async throws {
        guard let model = model(), case .chat(let chat) = model.destination, let storage = model.engine?.storage else {
            throw Failure(description: "no chat open")
        }
        var messages: [Message] = []
        for try await timeline in storage.timeline(in: chat, limit: to.back.map { max(Storage.pageSize, $0) } ?? 1_000) {
            messages = timeline.messages
            break
        }
        let message: Message
        if let back = to.back {
            guard back >= 1, messages.count >= back else { throw Failure(description: "fewer than \(back) messages") }
            message = messages[messages.count - back]
        } else {
            guard to.below == "image" else { throw Failure(description: "a jump below \(to.below ?? "nothing")") }
            let older = messages.dropLast(to.older ?? 0)
            guard let index = older.indices.last(where: { older[$0].attachmentKind == .image && $0 + 1 < older.endIndex }) else {
                throw Failure(description: "no image older than the newest \(to.older ?? 0)")
            }
            message = messages[index + 1]
            Offscreen.log("drive: to the message under image \(index) of \(messages.count)")
        }
        target = message.uuid
        model.focus(on: message)
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
