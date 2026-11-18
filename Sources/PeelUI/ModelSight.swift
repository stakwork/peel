import Foundation
import UniformTypeIdentifiers

/// Which pictures waiting in the agent chat's composer its model may look
/// at (docs/agent-on-strut.md, "Attachments"), per composer and file, off
/// until the person turns one on. Only a picture can be on, and only the
/// agent chat asks. The state is dropped with its file (removed, or sent)
/// and put back for a file the engine refused. The Mac's tray and the
/// phone's share it through `AppModel`.
public struct ModelSight: Equatable, Sendable {
    /// The toggle's words: what it offers and what each side means.
    public static let title = "Let the model see this picture"
    public static let help = "Off: only the text read from it goes to the model. On: the picture is sent to your model provider."

    private var allowed: [ComposerID: Set<URL>] = [:]

    public init() {}

    /// Whether `file` is a picture, by its name: the only kind the toggle is for.
    public static func offers(_ file: URL) -> Bool {
        UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) ?? false
    }

    public func allows(_ file: URL, in composer: ComposerID) -> Bool {
        allowed[composer]?.contains(file) ?? false
    }

    /// Turns `file` on or off; a file that is not a picture stays off.
    public mutating func set(_ on: Bool, for file: URL, in composer: ComposerID) {
        if on, Self.offers(file) {
            allowed[composer, default: []].insert(file)
        } else {
            drop(file, from: composer)
        }
    }

    /// Forgets `file`'s state: it was removed from the tray.
    public mutating func drop(_ file: URL, from composer: ComposerID) {
        allowed[composer]?.remove(file)
        if allowed[composer]?.isEmpty == true { allowed[composer] = nil }
    }

    /// The files among `files` that are on, forgotten as they go with a send.
    public mutating func take(_ files: [URL], from composer: ComposerID) -> Set<URL> {
        let on = Set(files).intersection(allowed[composer] ?? [])
        allowed[composer] = nil
        return on
    }

    /// Puts back what `take` returned for the files that did not go.
    public mutating func restore(_ files: Set<URL>, in composer: ComposerID) {
        guard !files.isEmpty else { return }
        allowed[composer, default: []].formUnion(files)
    }

    public mutating func removeAll() { allowed = [:] }
}
