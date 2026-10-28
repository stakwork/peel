import PeelCore
import PeelUI
import SwiftUI
import UIKit

// The full-size image viewer on the phone, over the whole screen from a
// tapped image tile (`ImageTile`): the Mac's `ImageViewer` idea (download
// through the model, decode large with `ImageCache`) with the phone's
// gestures. Pinch zooms (1x to 6x, springing back below 1x), a double tap
// toggles, a drag pans when zoomed, and a drag down when not zoomed pulls
// the picture away and closes past a threshold. A run's images page.

/// The images to show and the one to open at.
struct ImageViewerRequest: Identifiable {
    let id = UUID()
    let messages: [Message]
    let start: Int
}

struct ImageViewer: View {
    @Environment(\.dismiss) private var dismiss
    let request: ImageViewerRequest

    @State private var index: Int
    @State private var zoomed = false
    @State private var pull: CGFloat = 0

    /// How far down a drag closes the viewer.
    private static let closeDistance: CGFloat = 120

    init(request: ImageViewerRequest) {
        self.request = request
        _index = State(initialValue: min(max(request.start, 0), max(request.messages.count - 1, 0)))
    }

    var body: some View {
        let fade = 1 - min(abs(pull) / 400, 0.7)
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(fade).ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(request.messages.enumerated()), id: \.offset) { offset, message in
                    ViewerPage(message: message, zoomed: offset == index ? $zoomed : .constant(false))
                        .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .offset(y: pull)
            .simultaneousGesture(dismissDrag)
            Button { dismiss() } label: {
                GlassSymbol(systemImage: "xmark", label: "Close", tint: nil)
                    .frame(width: Theme.touchTarget, height: Theme.touchTarget)
                    .contentShape(Circle())
            }
            .glassEffect(.regular.interactive(), in: Circle())
            .accessibilityLabel("Close")
            .padding(Theme.Space.md)
            .opacity(pull == 0 ? 1 : 0)
        }
        .preferredColorScheme(.dark)
        .onChange(of: index) { zoomed = false }
        .accessibilityAddTraits(.isModal)
    }

    /// Down when not zoomed: the picture follows the finger, the black
    /// fades, and letting go far enough (or fast enough) closes.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { drag in
                guard !zoomed else { return }
                if pull == 0, abs(drag.translation.height) <= abs(drag.translation.width) { return }
                pull = max(drag.translation.height, 0)
            }
            .onEnded { drag in
                guard !zoomed, pull > 0 else { return }
                if pull > Self.closeDistance || drag.predictedEndTranslation.height > 400 {
                    dismiss()
                } else {
                    withAnimation(.spring(duration: 0.3)) { pull = 0 }
                }
            }
    }
}

/// One image: downloaded if need be, decoded large, then zoomable.
private struct ViewerPage: View {
    @Environment(AppModel.self) private var model
    let message: Message
    @Binding var zoomed: Bool

    @State private var image: CGImage?
    /// Why the image is not drawn, once it did not decode or download.
    @State private var notShown: String?

    /// Larger than a tile's, as the Mac's viewer decodes.
    private static let pixels = 4096

    var body: some View {
        Group {
            if let image {
                ZoomableImage(image: UIImage(cgImage: image), zoomed: $zoomed)
                    .accessibilityElement()
                    .accessibilityLabel("Image")
                    .accessibilityAddTraits(.isImage)
            } else if let notShown {
                Text(notShown)
                    .phoneFont(.secondary)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(Theme.Space.xl)
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: message.id) {
            image = nil
            notShown = nil
            await model.download(message)
            let handle = model.attachment(message.id ?? 0)
            guard let file = handle.file else {
                if !Task.isCancelled { notShown = handle.failureReason ?? "The image could not be opened." }
                return
            }
            let decoded = await ImageCache.shared.image(file, maxPixels: Self.pixels)
            guard !Task.isCancelled else { return }
            image = decoded
            if decoded == nil { notShown = await AttachmentFormat.notShown(file) ?? "The image could not be drawn." }
        }
    }
}

/// A picture in a scroll view that zooms 1x to 6x (bouncing back below
/// 1x), pans when zoomed and zooms by double tap.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    @Binding var zoomed: Bool

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.bouncesZoom = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .clear
        scroll.delegate = context.coordinator
        let picture = UIImageView(image: image)
        picture.contentMode = .scaleAspectFit
        picture.isUserInteractionEnabled = true
        scroll.addSubview(picture)
        context.coordinator.picture = picture
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap))
        double.numberOfTapsRequired = 2
        picture.addGestureRecognizer(double)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.picture?.image !== image {
            context.coordinator.picture?.image = image
        }
        // The picture fills the page at 1x, aspect-fitted; zoom scales that frame.
        if scroll.zoomScale == 1, context.coordinator.picture?.frame != CGRect(origin: .zero, size: scroll.bounds.size) {
            context.coordinator.picture?.frame = CGRect(origin: .zero, size: scroll.bounds.size)
            scroll.contentSize = scroll.bounds.size
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableImage
        weak var picture: UIImageView?
        init(_ parent: ZoomableImage) { self.parent = parent }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let zoomed = scrollView.zoomScale > 1.01
            if parent.zoomed != zoomed { parent.zoomed = zoomed }
        }

        @objc func doubleTap(_ tap: UITapGestureRecognizer) {
            guard let scroll = tap.view?.superview as? UIScrollView else { return }
            if scroll.zoomScale > 1.01 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let scale: CGFloat = 3
                let point = tap.location(in: picture)
                let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
            }
        }
    }
}
