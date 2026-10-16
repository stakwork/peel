import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A QR code on white, 132 pt unless told; faint and empty while `text` is nil.
struct QRCodeTile: View {
    let text: String?
    let label: String
    var size: CGFloat = 132
    /// The white margin round the code.
    var inset: CGFloat = 8
    @State private var code: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(.white)
            if let code, text != nil {
                Image(decorative: code, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .padding(inset)
            }
        }
        .frame(width: size, height: size)
        .opacity(text == nil ? 0.3 : 1)
        .accessibilityLabel(label)
        .task(id: text) { code = text.flatMap(QRCode.image) }
    }
}

enum QRCode {
    private static let context = CIContext()

    /// One module per pixel; draw it with `.interpolation(.none)`.
    static func image(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return context.createCGImage(output, from: output.extent)
    }

    /// Puts the code on the clipboard as an image, large enough to scan.
    /// Returns whether it is there.
    static func copyImage(_ text: String) -> Bool {
        #if os(macOS)
        guard let code = image(text) else { return false }
        let scale = 8
        let size = NSSize(width: code.width * scale, height: code.height * scale)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSImage(cgImage: code, size: NSSize(width: code.width, height: code.height))
            .draw(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()
        return Clipboard.copy(image)
        #else
        return false
        #endif
    }
}
