import CoreGraphics
import Foundation
import ImageIO
import Vision

/// QR codes in a picture (a screenshot, a saved code, a photo of a phone),
/// read with Vision. What they say is untrusted text: `ContactCode.read`
/// decides what, if anything, it is.
public enum QRImage {
    /// Larger files are refused before decoding.
    public static let maxBytes = 40_000_000
    /// Pictures are decoded at most this large on the long side, which keeps
    /// a huge one from taking the memory a full decode would; a code on a
    /// screenshot still reads.
    static let maxPixels = 4096

    /// The codes in an image file, each once, in Vision's order.
    public static func codes(inFile file: URL) throws -> [String] {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maxBytes else { throw PeelError("\(file.lastPathComponent) is too large to look for a code in") }
        guard !ImageDecoding.isTooLarge(file) else {
            throw PeelError("\(file.lastPathComponent) is too large to look for a code in")
        }
        guard let image = ImageDecoding.thumbnail(file, maxPixels: maxPixels) else {
            throw PeelError("\(file.lastPathComponent) is not a picture")
        }
        return try codes(in: image)
    }

    /// The codes in image bytes, such as a pasted picture.
    public static func codes(in data: Data) throws -> [String] {
        guard data.count <= maxBytes else { throw PeelError("that picture is too large to look for a code in") }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw PeelError("that is not a picture")
        }
        guard !ImageDecoding.isTooLarge(source) else { throw PeelError("that picture is too large to look for a code in") }
        guard let image = ImageDecoding.thumbnail(source, maxPixels: maxPixels) else {
            throw PeelError("that is not a picture")
        }
        return try codes(in: image)
    }

    public static func codes(in image: CGImage) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        var seen: Set<String> = []
        return (request.results ?? []).compactMap(\.payloadStringValue).filter { seen.insert($0).inserted }
    }
}
