import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PeelCore

/// A picture to the agent's DM goes as a real JPEG, whatever it was
/// (`AgentPicture`, docs/agent-on-strut.md, "Attachments").
struct AgentPictureTests {
    /// A `width`×`height` picture in `type`, half of it transparent.
    private func picture(_ type: UTType, width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let image = try #require(context.makeImage())
        let out = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return out as Data
    }

    private func type(of data: Data) -> String? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap(CGImageSourceGetType).map { $0 as String }
    }

    @Test func pngAndTiffBecomeJPEG() throws {
        for kind in [UTType.png, .tiff] {
            let jpeg = try #require(AgentPicture.jpeg(from: try picture(kind, width: 40, height: 30)))
            #expect(type(of: jpeg) == UTType.jpeg.identifier)
            let size = try #require(ImageDecoding.thumbnail(CGImageSourceCreateWithData(jpeg as CFData, nil)!, maxPixels: 100))
            #expect((size.width, size.height) == (40, 30), "a small picture is not enlarged")
        }
    }

    @Test func aBigPictureComesDownToTheLongSide() throws {
        let jpeg = try #require(AgentPicture.jpeg(from: try picture(.png, width: 5000, height: 1000)))
        let image = try #require(ImageDecoding.thumbnail(CGImageSourceCreateWithData(jpeg as CFData, nil)!, maxPixels: 10_000))
        #expect(image.width == AgentPicture.maxPixels && image.height == 819)
    }

    @Test func whatIsNoPictureIsLeftAlone() {
        #expect(AgentPicture.jpeg(from: Data("just some words".utf8)) == nil)
        #expect(AgentPicture.jpeg(from: Data()) == nil)
    }
}
