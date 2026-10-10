import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PeelCore

struct GiphyTests {
    /// A message as the Mac app writes one (`GiphyHelper.getMessageStringFrom`):
    /// every value a string, `aspect_ratio` included.
    private func content(_ fields: [String: Any]) throws -> String {
        "giphy::" + (try JSONSerialization.data(withJSONObject: fields)).base64EncodedString()
    }

    private let sent: [String: Any] = [
        "id": "3o7TKSjRrfIPjeiVyM", "aspect_ratio": "1.7777777777777777", "text": "**on my way**",
        "url": "https://media2.giphy.com/media/3o7TKSjRrfIPjeiVyM/giphy.gif?cid=abc&rid=giphy.gif&ct=g",
    ]

    @Test func readsTheOfficialFormat() throws {
        let giphy = try #require(Giphy(content: try content(sent)))
        // The 200 px variant, every `giphy.gif` replaced as the app does.
        #expect(giphy.url?.absoluteString == "https://media2.giphy.com/media/3o7TKSjRrfIPjeiVyM/200.gif?cid=abc&rid=200.gif&ct=g")
        #expect(abs(giphy.aspectRatio - 16.0 / 9) < 0.0001)
        #expect(giphy.text == "**on my way**")
    }

    @Test func oddFieldsFallBackAsTheAppDoes() throws {
        var fields = sent
        fields["aspect_ratio"] = 0.5
        #expect(Giphy(content: try content(fields))?.aspectRatio == 0.5)
        for odd: Any in ["wide", "-2", 0, NSNull(), "nan", "inf"] {
            fields["aspect_ratio"] = odd
            #expect(Giphy(content: try content(fields))?.aspectRatio == 1)
        }
        fields.removeValue(forKey: "aspect_ratio")
        fields.removeValue(forKey: "text")
        let bare = try #require(Giphy(content: try content(fields)))
        #expect(bare.aspectRatio == 1)
        #expect(bare.text == "")
        fields.removeValue(forKey: "url")
        #expect(Giphy(content: try content(fields))?.url == nil)
    }

    @Test(arguments: [
        "hello", "giphy:", "giphy::", "giphy::not base64!", " giphy::e30=",
        // base64 of `[1]`, of `"x"` and of bytes that are not UTF-8
        "giphy::WzFd", "giphy::Ingi", "giphy::/w==",
    ])
    func anythingElseIsText(content: String) {
        #expect(Giphy(content: content) == nil)
    }

    @Test(arguments: [
        "https://media.giphy.com/media/a/giphy.gif", "https://media0.giphy.com/media/a/giphy.gif",
        "https://media4.giphy.com/media/a/giphy.gif", "https://i.giphy.com/media/a/giphy.gif",
        "https://MEDIA1.GIPHY.COM/media/a/giphy.gif", "https://media3.giphy.com:443/media/a/giphy.gif",
    ])
    func giphysMediaHostsAreFetched(string: String) throws {
        #expect(Giphy.isAllowed(try #require(URL(string: string))))
    }

    @Test(arguments: [
        "http://media.giphy.com/media/a/giphy.gif", "https://giphy.com/media/a/giphy.gif",
        "https://api.giphy.com/v1/gifs/a", "https://media5.giphy.com/media/a/giphy.gif",
        "https://media.giphy.com.evil.example/a.gif", "https://evilmedia.giphy.com/a.gif",
        "https://media.giphy.com./a.gif", "https://media.giphy.com:8443/a.gif",
        "https://user@media.giphy.com/a.gif", "https://127.0.0.1/media.giphy.com/a.gif",
        "https://example.com/?u=https://media.giphy.com/a.gif", "file:///media.giphy.com/a.gif",
        "https://media%2Egiphy.com/a.gif",
    ])
    func anyOtherHostIsRefused(string: String) throws {
        let url = try #require(URL(string: string))
        #expect(!Giphy.isAllowed(url))
        var fields = sent
        fields["url"] = string
        let giphy = try #require(Giphy(content: try content(fields)))
        #expect(giphy.url == nil)
    }

    @Test func redirectsStayOnGiphy() throws {
        let to = { (string: String) in URLRequest(url: URL(string: string)!) }
        #expect(Giphy.onGiphy(to("https://media1.giphy.com/a/200.gif"), from: nil) != nil)
        #expect(Giphy.onGiphy(to("https://cdn.example.net/a.gif"), from: nil) == nil)
        #expect(Giphy.onGiphy(to("http://media1.giphy.com/a/200.gif"), from: nil) == nil)
    }

    @Test func refusedHostsAreNeverFetched() async throws {
        #expect(try await Giphy.data(at: try #require(URL(string: "https://127.0.0.1:1/a.gif"))) == nil)
    }

    @Test func messagesShowTheCaption() throws {
        var message = Message.fixture(content: try content(sent))
        #expect(message.giphy != nil)
        #expect(message.shownText == "**on my way**")
        #expect(message.preview == "GIF: on my way")
        #expect(!message.hasNoWords)

        var bare = sent
        bare["text"] = "  "
        message.content = try content(bare)
        #expect(message.shownText == "")
        #expect(message.preview == "GIF")
        // Still a row: the GIF shows without words.
        #expect(!message.hasNoWords)
        #expect(!message.isBlank)

        message.type = MessageType.attachment
        #expect(message.giphy == nil)
        message.type = MessageType.text
        message.deleted = true
        #expect(message.giphy == nil)
    }

    @Test func animationsKeepEveryFrameAndItsDelay() throws {
        let gif = try animatedGIF(delays: [0.05, 0.25, 0])
        let animation = try #require(ImageDecoding.animation(gif, maxPixels: 64))
        #expect(animation.isAnimated)
        #expect(animation.frames.count == 3)
        // Under 11 ms plays at 100 ms, as browsers do.
        #expect(animation.delays.map { ($0 * 100).rounded() / 100 } == [0.05, 0.25, 0.1])
        #expect(animation.frames.allSatisfy { max($0.width, $0.height) <= 64 })
    }

    @Test func stillPicturesAreOneFrame() throws {
        let animation = try #require(ImageDecoding.animation(try animatedGIF(delays: [0.1]), maxPixels: 64))
        #expect(!animation.isAnimated)
        #expect(ImageDecoding.animation(Data("not a picture".utf8), maxPixels: 64) == nil)
    }

    @Test func largeAnimationsAreDecodedSmaller() throws {
        // 20 frames of 200 px at 200 px would hold about 3.2 MB.
        let gif = try animatedGIF(delays: Array(repeating: 0.1, count: 20), side: 200)
        let budget = 512 * 1024
        let animation = try #require(ImageDecoding.animation(gif, maxPixels: 200, budget: budget))
        #expect(animation.frames.count == 20)
        #expect(animation.frames.allSatisfy { $0.width < 200 })
        // Its own size, which tiles are drawn by, is kept.
        #expect(animation.size == CGSize(width: 200, height: 200))
        #expect(animation.cost <= budget * 11 / 10)
    }

    @Test func tooManySourcePixelsPlayAsAStill() throws {
        // 1000 × 1000 × 101 frames: over 100 million pixels to read, however small it is drawn.
        let gif = try animatedGIF(delays: Array(repeating: 0.1, count: 101), side: 1000)
        let still = try #require(ImageDecoding.animation(gif, maxPixels: 64))
        #expect(!still.isAnimated)
        #expect(still.size == CGSize(width: 1000, height: 1000))
        // The same cap, smaller.
        let small = try animatedGIF(delays: [0.1, 0.1, 0.1], side: 32)
        #expect(ImageDecoding.animation(small, maxPixels: 64, pixels: 3 * 32 * 32)?.isAnimated == true)
        #expect(ImageDecoding.animation(small, maxPixels: 64, pixels: 3 * 32 * 32 - 1)?.isAnimated == false)
    }

    /// A GIF of `delays.count` frames, `side` pixels square, made here.
    private func animatedGIF(delays: [Double], side: Int = 32) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, delays.count, nil))
        for (index, delay) in delays.enumerated() {
            let context = try #require(CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(CGColor(red: CGFloat(index) / CGFloat(delays.count), green: 0.5, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), properties)
        }
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
