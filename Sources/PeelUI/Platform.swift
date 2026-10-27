import Foundation
import PeelCore
import UniformTypeIdentifiers

// What the model asks of the platform it runs on, as small protocols the
// app supplies when it makes the model (`AppModel.init(platform:)`); the
// Mac's are in `MacPlatform.swift`. The model itself imports no AppKit,
// UIKit or LiveKit (docs/phases/07-iphone.md, batch 17).

/// One of each service, from the app.
@MainActor
public struct Platform {
    public var presence: any AppPresence
    public var files: any FilePicking
    public var pasteboard: any Pasteboard
    public var playback: any Playback
    /// The web pane over a profile's own website data, made when first used.
    public var web: (Profile?) -> any WebPresenting
    public var calls: any CallProvider
    /// The agent's tools, memory and automations; nil where there are none.
    public var agent: (any AgentHost)?
    /// Whether the first chat opens while nothing is open: the Mac's detail
    /// pane is never empty; the iPhone's Chats list is a screen of its own.
    public var opensFirstChat: Bool

    public init(
        presence: any AppPresence, files: any FilePicking, pasteboard: any Pasteboard, playback: any Playback,
        web: @escaping (Profile?) -> any WebPresenting, calls: any CallProvider, agent: (any AgentHost)?,
        opensFirstChat: Bool = true
    ) {
        self.presence = presence
        self.files = files
        self.pasteboard = pasteboard
        self.playback = playback
        self.web = web
        self.calls = calls
        self.agent = agent
        self.opensFirstChat = opensFirstChat
    }
}

/// Peel among the other apps: whether it is in front, bringing it there,
/// and what it shows outside its windows.
@MainActor
public protocol AppPresence {
    /// Whether Peel is the app in front, where the open chat is being read.
    var isFrontmost: Bool { get }
    /// Whether local notifications may be posted at all: not outside an app
    /// bundle, where the notification center is not available, nor offscreen.
    var postsNotifications: Bool { get }
    /// Peel to the front: a click on a notification.
    func activate()
    /// The unread count on Peel's icon (the Dock's, on the Mac); none for 0.
    func showBadge(_ count: Int)
    /// Peel's page in the system's notification settings.
    func openNotificationSettings()
}

/// The main window's menus and panels, as `AppModel.takesCommands` asks
/// about them (`MenuPresenter`, on the Mac).
@MainActor
public protocol MenuHosting: AnyObject {
    /// A Peel menu or panel is up.
    var anythingOpen: Bool { get }
    /// Its window is the one a key press goes to.
    var hostsKeyWindow: Bool { get }
}

/// The system's file panels and the file browser: picking files to open,
/// where to save one, and showing one.
@MainActor
public protocol FilePicking {
    /// Files picked beside the window, of the given types if any; nil when
    /// cancelled.
    func open(prompt: String?, multiple: Bool, directories: Bool, types: [UTType]) -> [URL]?
    /// Where to save a file, starting with `name`; nil when cancelled.
    func saveLocation(named name: String) -> URL?
    /// Shows a file in the file browser, selected. Never opens it.
    func reveal(_ file: URL)
}

/// The clipboard, as the model uses it.
@MainActor
public protocol Pasteboard {
    /// Puts the picture in a file on the clipboard; false when it cannot be read.
    func copyImage(at file: URL) -> Bool
    /// Clears a secret copied earlier if it is still on the clipboard.
    func clearSecret()
}

/// The one video or recording playing at a time.
@MainActor
public protocol Playback {
    func play(_ id: Int64, file: URL)
    /// The viewer closed: what it showed pauses.
    func closeFullScreen()
    func stop()
}

/// The web pane beside the chat.
@MainActor
public protocol WebPresenting: AnyObject {
    /// Shows an HTML attachment offline, as a clicked link would.
    func openDocument(_ file: URL, named name: String) async throws
    /// Before the profile is removed: the pane's website data goes.
    func forgetWebsiteData() async
}

/// Joins a call's room. The media (LiveKit) stays in the app: a target that
/// imports both it and PeelCore inherits the `RustBuffer` header clash.
@MainActor
public protocol CallProvider {
    /// Why this device cannot join calls at all (the iPhone, until I6);
    /// nil where it can. Asked before a call is started or joined, so
    /// nothing is posted or fetched for a call that cannot happen.
    var unavailable: String? { get }
    /// Throws where this device cannot join calls (the iPhone, until I6).
    func join(_ ticket: CallTicket, link: CallLink, chat: String, title: String, camera: Bool) throws -> any OngoingCall
}

extension CallProvider {
    public var unavailable: String? { nil }
}

/// The call this device is on.
@MainActor
public protocol OngoingCall: AnyObject {
    var link: CallLink { get }
    var chat: String { get }
    /// "#tribe" or the contact, as the call began.
    var title: String { get }
    /// This side's identity on the call, to tell you apart in the presence feed.
    var identity: String { get }
    /// Connecting or connected; false once the connection is lost.
    var isOn: Bool { get }
    /// Whether it was joined with the camera on, for a rejoin.
    var wantsCamera: Bool { get }
    /// Everyone on the call, for the sidebar's count.
    var people: [CallParticipant] { get }
    /// Whether the call server is recording the call: only an indicator, Peel
    /// neither starts nor stops it.
    var isRecording: Bool { get }
    /// Leaves the room, saying goodbye.
    func leave() async
}

/// The agent's side that needs PeelAgent, which only the Mac builds: its
/// tools, Peel's strut (the memory) and the automations. Opened and closed
/// with the account.
@MainActor
public protocol AgentHost: AnyObject {
    func open(_ profile: Profile, engine: Engine, in model: AppModel)
    /// What answers the agent's device requests on `engine`
    /// (`Engine.answerDeviceRequests`), set before it starts; nil, none.
    func deviceRequests(for engine: Engine) -> DeviceRequestHandler?
    func close(in model: AppModel)
    /// Escape in the agent's composer: closes a memory open beside the
    /// chat. Returns whether one was.
    func closeMemory(in model: AppModel) -> Bool
    /// Peel is quitting.
    func stop()
    /// The account is being forgotten: what the agent remembered goes too.
    func forget(_ profile: Profile) throws
}
