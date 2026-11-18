import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Word, RTF and HTML documents as text, through the system's own reader
/// (`NSAttributedString(url:options:documentAttributes:)`, which AppKit and
/// UIKit add to Foundation, so this is the one file of PeelAgent that
/// imports them). Word's formats are the Mac's alone; the phone says so.
enum DocumentReader {
    /// `file`'s text, or `AttachmentText.Failure` when it cannot be read.
    /// On the main actor: the HTML importer needs it.
    @MainActor
    static func text(of file: URL) throws -> String {
        #if canImport(AppKit) || canImport(UIKit)
        guard let type = documentType(of: file) else { throw AttachmentText.Failure.unsupportedDocument }
        do {
            let text = try NSAttributedString(url: file, options: [.documentType: type, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
            return text.string
        } catch {
            throw AttachmentText.Failure.failed("the document could not be read")
        }
        #else
        throw AttachmentText.Failure.unsupportedDocument
        #endif
    }

    #if canImport(AppKit) || canImport(UIKit)
    /// The reader's document type for `file`'s extension; nil where this device has none.
    static func documentType(of file: URL) -> NSAttributedString.DocumentType? {
        switch file.pathExtension.lowercased() {
        case "rtf": .rtf
        case "html", "htm": .html
        #if os(macOS)
        case "docx": .officeOpenXML
        case "doc": .docFormat
        #endif
        default: nil
        }
    }
    #endif
}
