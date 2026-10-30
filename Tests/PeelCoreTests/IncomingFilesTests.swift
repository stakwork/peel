import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PeelCore
@testable import PeelTestSupport

/// A 1×1 PNG.
private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

private func tiff(from png: Data) throws -> Data {
    let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let out = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(out, UTType.tiff.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return out as Data
}

private func scratch() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("peel-incoming-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

struct IncomingFilesTests {
    private let text = "public.utf8-plain-text", fileURL = "public.file-url"

    @Test func aFileWinsOverItsNameAndIcon() {
        // Finder's copy: the file, its name as text and its icon as a TIFF.
        #expect(IncomingFiles.source(types: [fileURL, text, "public.tiff"], promised: false, plainText: "a.pdf") == .file)
    }

    @Test func aPromiseIsTakenWhenThereIsNoFile() {
        #expect(IncomingFiles.source(types: ["public.png"], promised: true, plainText: nil) == .promise)
        #expect(IncomingFiles.source(types: [fileURL], promised: true, plainText: nil) == .file)
    }

    @Test func theSourcesOwnEncodingBeforeTIFF() {
        // A screenshot to the clipboard carries PNG and TIFF.
        #expect(IncomingFiles.source(types: ["public.tiff", "public.png"], promised: false, plainText: nil)
            == .image(.png))
        #expect(IncomingFiles.source(types: ["public.tiff"], promised: false, plainText: nil) == .image(.tiff))
        #expect(IncomingFiles.source(types: ["public.tiff", "public.jpeg"], promised: false, plainText: nil)
            == .image(.jpeg))
        #expect(IncomingFiles.source(types: ["public.heic"], promised: false, plainText: nil) == .image(.heic))
    }

    @Test func wordsPasteAsText() {
        // Rich text with a picture of itself, as Pages or a web page copy it.
        #expect(IncomingFiles.source(types: ["public.rtf", text, "public.tiff"], promised: false,
                                     plainText: "Some words") == nil)
        #expect(IncomingFiles.source(types: [text], promised: false, plainText: "hello") == nil)
        #expect(IncomingFiles.source(types: [], promised: false, plainText: nil) == nil)
    }

    @Test func anImageWithOnlyALinkIsTheImage() {
        // Copy Image in a browser: the picture and where it came from.
        #expect(IncomingFiles.source(types: ["public.tiff", "public.url", text], promised: false,
                                     plainText: " https://example.com/a.png\n") == .image(.tiff))
        #expect(IncomingFiles.source(types: ["public.png", text], promised: false, plainText: "") == .image(.png))
        #expect(IncomingFiles.source(types: ["public.png", text], promised: false,
                                     plainText: "see https://example.com") == nil)
    }

    @Test func imageNames() {
        let date = Date(timeIntervalSince1970: 1_791_468_300)  // 2026-10-08 14:05 UTC
        let utc = TimeZone(identifier: "UTC")!
        #expect(IncomingFiles.imageName(at: date, ext: "png", timeZone: utc) == "Image 2026-10-08 at 14.05.png")
        #expect(IncomingFiles.imageName(at: date, index: 1, ext: "jpeg", timeZone: utc)
            == "Image 2026-10-08 at 14.05 (2).jpeg")
    }

    @Test func writesPNGAsItIsAndTIFFAsPNG() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try IncomingFiles.write(png, type: .png, in: root)
        #expect(try Data(contentsOf: first) == png)
        #expect(first.pathExtension == "png")
        #expect(IncomingFiles.owns(first, root: root))

        let second = try IncomingFiles.write(try tiff(from: png), type: .tiff, index: 1, in: root)
        let written = try Data(contentsOf: second)
        #expect(second.pathExtension == "png")
        #expect(written.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(second.deletingLastPathComponent() != first.deletingLastPathComponent())
    }

    @Test func refusesBytesThatAreNotAnImage() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: (any Error).self) { try IncomingFiles.write(Data("nope".utf8), type: .tiff, in: root) }
    }

    /// Pasted bytes and a promised file over the send limit are refused as
    /// they arrive, by name, and nothing of theirs is kept.
    @Test func refusesOverTheSendLimit() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let big = Data(count: Engine.sendLimit + 1)
        let date = Date(timeIntervalSince1970: 0)
        let name = IncomingFiles.imageName(at: date, ext: "png")
        #expect(throws: Engine.Failure.tooLargeToSend(name)) {
            try IncomingFiles.write(big, type: .png, date: date, in: root)
        }
        // A TIFF is refused before it is decoded, under the PNG name it would have.
        #expect(throws: Engine.Failure.tooLargeToSend(name)) {
            try IncomingFiles.write(big, type: .tiff, date: date, in: root)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)

        let folder = try IncomingFiles.newFolder(in: root)
        let promised = try sparseFile(folder.appendingPathComponent("Recording.mov"), size: big.count)
        #expect(throws: Engine.Failure.tooLargeToSend("Recording.mov")) {
            try IncomingFiles.accept(promised, in: folder)
        }
        #expect(!FileManager.default.fileExists(atPath: promised.path))
    }

    @Test func acceptsOnlyAPlainFileInItsFolder() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try IncomingFiles.newFolder(in: root)
        let good = folder.appendingPathComponent("Screenshot.png")
        try png.write(to: good)
        #expect(try IncomingFiles.accept(good, in: folder) == good)

        // Somewhere else: refused, and not touched.
        let outside = root.appendingPathComponent("elsewhere.png")
        try png.write(to: outside)
        #expect(throws: (any Error).self) { try IncomingFiles.accept(outside, in: folder) }
        #expect(FileManager.default.fileExists(atPath: outside.path))
        let dotted = folder.appendingPathComponent("../elsewhere.png")
        #expect(throws: (any Error).self) { try IncomingFiles.accept(dotted, in: folder) }
        #expect(FileManager.default.fileExists(atPath: outside.path))

        // A link in the folder to a file outside it: refused and removed.
        let link = folder.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try IncomingFiles.accept(link, in: folder) }
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil)
        #expect(FileManager.default.fileExists(atPath: outside.path))

        // A folder.
        let directory = folder.appendingPathComponent("dir")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try IncomingFiles.accept(directory, in: folder) }
    }

    @Test func discardsOnlyItsOwn() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let mine = try IncomingFiles.write(png, type: .png, in: root)
        let theirs = root.appendingPathComponent("theirs.png")
        try png.write(to: theirs)

        IncomingFiles.discard(theirs, root: root)
        #expect(FileManager.default.fileExists(atPath: theirs.path))
        #expect(!IncomingFiles.owns(theirs, root: root))

        IncomingFiles.discard(mine, root: root)
        #expect(!FileManager.default.fileExists(atPath: mine.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: theirs.path))
    }
}
