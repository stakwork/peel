import Foundation
import CoreGraphics
import PeelCore
import UniformTypeIdentifiers

/// How attachments read in a row, shared by the Mac and the phone.
public enum AttachmentFormat {
    /// Why a downloaded picture that did not decode is not drawn: "Too large
    /// to show" when it holds more pixels than are decoded
    /// (`ImageDecoding.isTooLarge`); nil otherwise. Read off the main actor.
    public static func notShown(_ file: URL) async -> String? {
        await Task.detached(priority: .utility) { ImageDecoding.isTooLarge(file) ? "Too large to show" : nil }.value
    }

    /// "48 KB".
    public static func size(_ bytes: Int64?) -> String? {
        bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    /// "2.1 of 3.4 MB", "0.28 of 1.11 GB": what has come, in the total's unit.
    public static func progress(_ bytes: Int64, of total: Int64) -> String {
        let whole = ByteCountFormatter()
        whole.countStyle = .file
        let done = ByteCountFormatter()
        done.countStyle = .file
        done.allowedUnits = unit(of: total)
        done.includesUnit = false
        return "\(done.string(fromByteCount: bytes)) of \(whole.string(fromByteCount: total))"
    }

    /// The unit `ByteCountFormatter` shows `bytes` in (1000 to a KB, as `.file` counts).
    private static func unit(of bytes: Int64) -> ByteCountFormatter.Units {
        switch abs(bytes) {
        case ..<1_000: .useBytes
        case ..<1_000_000: .useKB
        case ..<1_000_000_000: .useMB
        case ..<1_000_000_000_000: .useGB
        default: .useTB
        }
    }

    /// What a file is, from its name: "PDF document", "Markdown".
    public static func kind(_ name: String?) -> String? {
        let ext = ((name ?? "") as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        return UTType(filenameExtension: ext)?.localizedDescription ?? ext.uppercased()
    }

    /// What a file says it is, before its name is known: "PDF document".
    public static func kind(mediaType: String?) -> String? {
        mediaType.flatMap { UTType(mimeType: $0)?.localizedDescription }
    }

    /// A picture `width` by `height` pixels drawn at its own shape on a
    /// Retina screen: its long side at most `maxSide`, and small ones not tiny.
    public static func fitted(width: CGFloat, height: CGFloat, maxSide: CGFloat) -> CGSize {
        guard width > 0, height > 0 else { return CGSize(width: 240, height: 180) }
        let longest = max(width, height) / 2
        let scale = min(maxSide, max(longest, 160)) / longest
        return CGSize(width: width / 2 * scale, height: height / 2 * scale)
    }

    /// The short label on a file's icon: "PDF", "LOG"; from the declared
    /// type until a download gives the name.
    public static func badge(_ name: String?, mediaType: String? = nil) -> String {
        var ext = ((name ?? "") as NSString).pathExtension
        if ext.isEmpty { ext = AttachmentKind.fileExtension(mediaType: mediaType) ?? "" }
        return ext.isEmpty ? "FILE" : String(ext.uppercased().prefix(4))
    }
}
