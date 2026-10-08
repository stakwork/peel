import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Attachments that arrive by drag or paste rather than as a file on disk:
/// what a pasteboard item gives the composer, and the files Peel writes for
/// image data and file promises. Those live in a folder of their own under
/// the temporary directory, one subfolder each so a file keeps a readable
/// name (the tray shows it, and a file other than an image goes under it),
/// and are removed once uploaded or taken out of the composer.
public enum IncomingFiles {
    /// What one pasteboard item gives the composer.
    public enum Source: Equatable, Sendable {
        /// A file on disk (Finder, the open panel's kin).
        case file
        /// A file the source writes on request (the screenshot thumbnail, Photos).
        case promise
        /// Image bytes of this type (a screenshot to the clipboard, Copy Image).
        case image(UTType)
    }

    /// Image encodings taken from a pasteboard, best first: the source's
    /// own encoding before the TIFF that macOS adds beside it.
    static let imageTypes: [UTType] = [.png, .jpeg, .heic, .tiff]

    /// What an item with these pasteboard `types` gives, or nil when it is
    /// text (or nothing Peel attaches). `promised` says the item carries a
    /// file promise. Image bytes give way to words: rich text copied from a
    /// page or a document often carries a picture of itself too, and should
    /// still paste as text. Text that is only a link (Copy Image in a
    /// browser) does not count.
    public static func source(types: [String], promised: Bool, plainText: @autoclosure () -> String?) -> Source? {
        if types.contains(UTType.fileURL.identifier) { return .file }
        if promised { return .promise }
        guard let image = imageTypes.first(where: { types.contains($0.identifier) }) else { return nil }
        if let text = plainText()?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, !isLink(text) {
            return nil
        }
        return .image(image)
    }

    private static func isLink(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace), let scheme = URL(string: text)?.scheme?.lowercased() else {
            return false
        }
        return ["http", "https", "file", "data", "blob"].contains(scheme)
    }

    /// "Image 2026-10-08 at 14.05.png", in the shape macOS gives a
    /// screenshot's name (the bytes may come from anywhere, so not
    /// "Screenshot"); the second and later of one paste get " (2)" and so on.
    public static func imageName(at date: Date, index: Int = 0, ext: String, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm"
        let number = index > 0 ? " (\(index + 1))" : ""
        return "Image \(formatter.string(from: date))\(number).\(ext)"
    }

    /// Where Peel keeps them; `root` is for tests.
    public static let defaultRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("Peel Attachments", isDirectory: true)

    /// A new, empty folder of Peel's for one incoming file, readable only by this user.
    public static func newFolder(in root: URL = defaultRoot) throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        return folder
    }

    /// Writes image bytes as a file to attach, a TIFF as PNG (smaller, and
    /// what every client draws). Refuses bytes over the attachment limit
    /// (before any conversion, so nothing larger is decoded) and a TIFF that
    /// does not decode; the engine checks every file's kind by its bytes
    /// when it sends.
    public static func write(
        _ data: Data, type: UTType, index: Int = 0, date: Date = Date(), in root: URL = defaultRoot
    ) throws -> URL {
        let limit = Engine.attachmentLimit
        guard data.count <= limit else { throw MemesServer.Failure.tooLarge(limit) }
        var bytes = data, type = type
        if type == .tiff {
            bytes = try png(fromTIFF: data)
            type = .png
        }
        let file = try newFolder(in: root)
            .appendingPathComponent(imageName(at: date, index: index, ext: type.preferredFilenameExtension ?? "png"))
        try bytes.write(to: file, options: .atomic)
        return file
    }

    static func png(fromTIFF data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PeelError("the pasted image could not be read")
        }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)
        else { throw PeelError("could not make a PNG") }
        // Keep the orientation and resolution the TIFF declared.
        CGImageDestinationAddImage(destination, image, CGImageSourceCopyPropertiesAtIndex(source, 0, nil))
        guard CGImageDestinationFinalize(destination) else { throw PeelError("could not make a PNG") }
        return out as Data
    }

    /// A promised file the source says it wrote: only a plain file (no
    /// link, no folder) directly in the folder Peel gave it, and within the
    /// attachment limit. Anything else is removed if it is ours and refused.
    public static func accept(_ file: URL, in folder: URL) throws -> URL {
        let name = file.lastPathComponent
        let inside = file.deletingLastPathComponent().resolvingSymlinksInPath().path
            == folder.resolvingSymlinksInPath().path
        guard inside else { throw PeelError("\(name) was not written where Peel asked") }
        do {
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else {
                throw PeelError("\(name) is not a file")
            }
            guard (values.fileSize ?? 0) <= Engine.attachmentLimit else {
                throw MemesServer.Failure.tooLarge(Engine.attachmentLimit)
            }
            return file
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    /// Whether `file` is one of Peel's, in its own folder under `root`.
    public static func owns(_ file: URL, root: URL = defaultRoot) -> Bool {
        file.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath().path
            == root.resolvingSymlinksInPath().path
    }

    /// Removes one of Peel's files, and its folder once nothing else is in
    /// it (a promise may write several files into one); leaves any other
    /// file alone.
    public static func discard(_ file: URL, root: URL = defaultRoot) {
        guard owns(file, root: root) else { return }
        let manager = FileManager.default, folder = file.deletingLastPathComponent()
        try? manager.removeItem(at: file)
        if (try? manager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? manager.removeItem(at: folder)
        }
    }
}
