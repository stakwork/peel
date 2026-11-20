import Foundation
import UniformTypeIdentifiers

/// Which pictures waiting in the agent chat's composer its model may look
/// at (docs/agent-on-strut.md, "Attachments"), per composer and file: on
/// for every picture until the person turns one off. Only a picture can be
/// on, and only the agent chat asks. The state is dropped with its file
/// (removed, or sent) and put back for a file the engine refused. The Mac's
/// tray and the phone's share it through `AppModel`.
public struct ModelSight: Equatable, Sendable {
    /// The toggle's words: what it offers and what each side means.
    public static let title = String(localized: "Let the model see this picture", table: "Shared")
    public static let help = String(localized: "Off: only the text read from it goes to the model. On: the picture is sent to your model provider.", table: "Shared")

    /// The pictures turned off; every other picture is on.
    private var off: [ComposerID: Set<URL>] = [:]

    public init() {}

    /// Whether `file` is a picture, by its name: the only kind the toggle is for.
    public static func offers(_ file: URL) -> Bool {
        UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) ?? false
    }

    public func allows(_ file: URL, in composer: ComposerID) -> Bool {
        Self.offers(file) && !(off[composer]?.contains(file) ?? false)
    }

    /// Turns `file` on or off; a file that is not a picture stays off.
    public mutating func set(_ on: Bool, for file: URL, in composer: ComposerID) {
        if on || !Self.offers(file) {
            drop(file, from: composer)
        } else {
            off[composer, default: []].insert(file)
        }
    }

    /// Forgets `file`'s state: it was removed from the tray.
    public mutating func drop(_ file: URL, from composer: ComposerID) {
        off[composer]?.remove(file)
        if off[composer]?.isEmpty == true { off[composer] = nil }
    }

    /// The files among `files` that are on, forgotten as they go with a send.
    public mutating func take(_ files: [URL], from composer: ComposerID) -> Set<URL> {
        let on = Set(files.filter { allows($0, in: composer) })
        off[composer] = nil
        return on
    }

    /// Puts back the switches of `refused`, files that did not go: on for
    /// those among `on` (what `take` returned), off for any other picture.
    public mutating func restore(_ refused: [URL], on: Set<URL>, in composer: ComposerID) {
        for file in refused where Self.offers(file) && !on.contains(file) {
            off[composer, default: []].insert(file)
        }
    }

    public mutating func removeAll() { off = [:] }
}
