import PeelCore
import SwiftUI
import VisionKit

/// The camera, looking for a QR code that holds an invoice
/// (`CodeScanner`). Only an invoice is taken: anything else it reads is
/// untrusted text and is passed over with a word. Paste is the other way in.
struct InvoiceScanner: View {
    let found: (String) -> Void
    let cancel: () -> Void

    var body: some View {
        CodeScanner(
            title: String(localized: "Scan an invoice"), prompt: String(localized: "Point the camera at an invoice's QR code."),
            pasteInstead: String(localized: "paste the invoice"), cancel: cancel
        ) { code in
            guard (try? Invoice(code)) != nil else { return String(localized: "That code isn't an invoice.") }
            found(code)
            return nil
        }
    }
}

/// A code the camera sees now: its text and its four corners in the
/// scanner view's own space (VisionKit has already handled rotation, crop
/// and orientation), in order around it.
struct ScanTarget: Equatable {
    let text: String
    let corners: [CGPoint]
}

/// The camera, looking for a QR code `accept` takes: an invoice, contact
/// info, a tribe link. As in the system Camera, nothing happens on sight:
/// yellow brackets close in on the code and a pill under it says what it
/// is, and only a tap on the pill acts. What it reads is untrusted text;
/// `accept` returns why it passes over one, or nil once it took it. A link
/// `accept` refuses is Peel's own (opened in the app, closing the scanner)
/// or a web or payment link (opened outside); anything else is a note.
/// Without a camera or with access refused, it says so, and to `pasteInstead`.
struct CodeScanner: View {
    let title: String
    let prompt: String
    /// "paste the invoice": the other way in, after "Allow it in Settings, or".
    let pasteInstead: String
    let cancel: () -> Void
    let accept: (String) -> String?
    @State private var note: String?
    /// The code last seen; kept while the brackets and pill fade.
    @State private var target: ScanTarget?
    @State private var bracketsShown = false
    @State private var pillShown = false
    @State private var fading: Task<Void, Never>?
    @Environment(\.openURL) private var openURL

    /// The system's yellow, #FFD60A in dark: the Camera app's.
    private static let yellow = Color(uiColor: .systemYellow)
    /// How long a code may go unseen before its brackets fade, and its pill goes.
    private static let bracketGrace: Duration = .milliseconds(600)
    private static let pillGrace: Duration = .milliseconds(1000)
    /// Schemes a refused code may open outside Peel, after the person's tap.
    private static let outside: Set<String> = ["http", "https", "lightning"]

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
                    ScannerView(tracked: tracked)
                        .ignoresSafeArea()
                        .overlay {
                            ScanBracketsShape(
                                tl: target?.corners[0] ?? .zero, tr: target?.corners[1] ?? .zero,
                                br: target?.corners[2] ?? .zero, bl: target?.corners[3] ?? .zero,
                                scale: bracketsShown ? 1 : 1.25)
                                .stroke(Self.yellow, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                                .opacity(bracketsShown ? 1 : 0)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                                .ignoresSafeArea()
                        }
                        .overlay(alignment: .bottom) {
                            VStack(spacing: Theme.Space.sm) {
                                if pillShown, let target {
                                    pill(for: target)
                                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                                }
                                Text(note ?? prompt)
                                    .phoneFont(.row)
                                    .foregroundStyle(.white)
                                    .multilineTextAlignment(.center)
                                    .padding(Theme.Space.md)
                                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
                            }
                            .padding(Theme.phoneGutter)
                        }
                } else {
                    ContentUnavailableView {
                        Label("Can't scan here", systemImage: "camera")
                    } description: {
                        Text(DataScannerViewController.isSupported
                             ? String(localized: "Peel can't use the camera. Allow it in Settings, or \(pasteInstead).")
                             : String(localized: "This device has no camera Peel can scan with, so \(pasteInstead) instead."))
                    } actions: {
                        if DataScannerViewController.isSupported,
                           let settings = URL(string: UIApplication.openSettingsURLString) {
                            Button("Open Settings") { UIApplication.shared.open(settings) }
                        }
                    }
                    .background(Theme.background.ignoresSafeArea())
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", action: cancel)
                }
            }
        }
        .onDisappear { fading?.cancel() }
    }

    /// The yellow capsule: what the code is, and a tap acts on it.
    private func pill(for target: ScanTarget) -> some View {
        let label = ScanLabel(target.text)
        return Button { act(on: target.text) } label: {
            Label(label.text, systemImage: Self.icon(label.kind))
                .phoneFont(.row)
                .foregroundStyle(.black)
                .lineLimit(1)
                .padding(.horizontal, Theme.Space.md)
                .frame(minHeight: Theme.touchTarget)
                .background(Self.yellow, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label.text)
        .accessibilityHint("Opens it")
    }

    private static func icon(_ kind: ScanLabel.Kind) -> String {
        switch kind {
        case .web: "safari"
        case .peel: "arrow.up.forward.app"
        case .invoice: "bolt.fill"
        case .contact: "person.crop.circle"
        case .tribe: "person.3"
        case .invite: "envelope"
        case .text: "text.alignleft"
        }
    }

    /// What the scanner sees now, or nil with nothing in view. A code
    /// snaps its brackets in; one that goes keeps them a moment, then the
    /// pill a moment longer, so a lost frame does not flicker.
    private func tracked(_ seen: ScanTarget?) {
        if let seen {
            fading?.cancel()
            fading = nil
            if !bracketsShown {
                // Appearing: land on the code, then scale in.
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { target = seen }
            } else {
                withAnimation(.spring(duration: 0.25, bounce: 0.15)) { target = seen }
            }
            withAnimation(.spring(duration: 0.3, bounce: 0.3)) {
                bracketsShown = true
                pillShown = true
            }
        } else if fading == nil, bracketsShown || pillShown {
            fading = Task { @MainActor in
                try? await Task.sleep(for: Self.bracketGrace)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.25)) { bracketsShown = false }
                try? await Task.sleep(for: Self.pillGrace - Self.bracketGrace)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) { pillShown = false }
                fading = nil
            }
        }
    }

    /// The pill's tap: `accept` as always. A refusal that is a link opens
    /// where it belongs; otherwise it is the note.
    private func act(on code: String) {
        guard let refused = accept(code) else { return }
        let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: text), let scheme = url.scheme?.lowercased() {
            if scheme == "peel", ScanLabel(text).kind == .peel {
                // Peel's own scheme comes back through `onOpenURL`.
                openURL(url)
                cancel()
                return
            }
            if Self.outside.contains(scheme) {
                openURL(url)
                return
            }
        }
        note = refused
    }
}

/// The four brackets of `ScanBrackets` as one path, scaled about the code's
/// centre; its corners and scale animate, so the brackets follow the code.
private struct ScanBracketsShape: Shape {
    var tl: CGPoint
    var tr: CGPoint
    var br: CGPoint
    var bl: CGPoint
    var scale: CGFloat

    typealias Pair = AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData>

    var animatableData: AnimatablePair<AnimatablePair<Pair, Pair>, CGFloat> {
        get {
            .init(.init(.init(tl.animatableData, tr.animatableData),
                        .init(br.animatableData, bl.animatableData)), scale)
        }
        set {
            tl.animatableData = newValue.first.first.first
            tr.animatableData = newValue.first.first.second
            br.animatableData = newValue.first.second.first
            bl.animatableData = newValue.first.second.second
            scale = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let corners = [tl, tr, br, bl]
        let centre = ScanBrackets(topLeft: tl, topRight: tr,
                                  bottomRight: br, bottomLeft: bl).center
        let k = scale
        let scaled = corners.map {
            CGPoint(x: centre.x + ($0.x - centre.x) * k, y: centre.y + ($0.y - centre.y) * k)
        }
        let shape = ScanBrackets(topLeft: scaled[0], topRight: scaled[1],
                                 bottomRight: scaled[2], bottomLeft: scaled[3])
        var path = Path()
        for bracket in shape.brackets {
            path.move(to: bracket.start)
            path.addLine(to: bracket.corner)
            path.addLine(to: bracket.end)
        }
        return path
    }
}

/// VisionKit's scanner, QR codes only, with its own highlight off (the
/// brackets are drawn above it). It reports the code to show, one at a
/// time: the one tapped while it is in view, else the largest.
private struct ScannerView: UIViewControllerRepresentable {
    let tracked: (ScanTarget?) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: false
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.tracked = tracked
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(tracked: tracked) }

    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var tracked: (ScanTarget?) -> Void
        private var seen: [UUID: ScanTarget] = [:]
        private var chosen: UUID?

        init(tracked: @escaping (ScanTarget?) -> Void) {
            self.tracked = tracked
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            take(items)
        }

        func dataScanner(_ scanner: DataScannerViewController, didUpdate items: [RecognizedItem], allItems: [RecognizedItem]) {
            take(items)
        }

        func dataScanner(_ scanner: DataScannerViewController, didRemove items: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in items {
                seen[item.id] = nil
                if chosen == item.id { chosen = nil }
            }
            report()
        }

        /// A tap on a code in the preview picks it for the pill; it does nothing else.
        func dataScanner(_ scanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            if seen[item.id] != nil {
                chosen = item.id
                report()
            }
        }

        private func take(_ items: [RecognizedItem]) {
            for case .barcode(let code) in items {
                guard let text = code.payloadStringValue else { continue }
                let b = code.bounds
                seen[code.id] = ScanTarget(text: text, corners: [b.topLeft, b.topRight, b.bottomRight, b.bottomLeft])
            }
            report()
        }

        private func report() {
            if let chosen, let target = seen[chosen] { return tracked(target) }
            tracked(seen.values.max { ScanBrackets.area($0.corners) < ScanBrackets.area($1.corners) })
        }
    }
}
