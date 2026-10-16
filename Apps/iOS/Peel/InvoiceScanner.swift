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
            title: "Scan an invoice", prompt: "Point the camera at an invoice's QR code.",
            pasteInstead: "paste the invoice", cancel: cancel
        ) { code in
            guard (try? Invoice(code)) != nil else { return "That code isn't an invoice." }
            found(code)
            return nil
        }
    }
}

/// The camera, looking for a QR code `accept` takes: an invoice, contact
/// info, a tribe link. What it reads is untrusted text; `accept` returns
/// why it passes over one, or nil once it took it. Without a camera or
/// with access refused, it says so, and to `pasteInstead`.
struct CodeScanner: View {
    let title: String
    let prompt: String
    /// "paste the invoice": the other way in, after "Allow it in Settings, or".
    let pasteInstead: String
    let cancel: () -> Void
    let accept: (String) -> String?
    @State private var note: String?

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
                    ScannerView { code in
                        if let refused = accept(code) { note = refused }
                    }
                    .ignoresSafeArea()
                    .overlay(alignment: .bottom) {
                        Text(note ?? prompt)
                            .phoneFont(.row)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(Theme.Space.md)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
                            .padding(Theme.phoneGutter)
                    }
                } else {
                    ContentUnavailableView(
                        "Can't scan here",
                        systemImage: "camera",
                        description: Text(DataScannerViewController.isSupported
                                          ? "Peel can't use the camera. Allow it in Settings, or \(pasteInstead)."
                                          : "This device has no camera Peel can scan with, so \(pasteInstead) instead.")
                    )
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
    }
}

/// VisionKit's scanner, QR codes only, reporting each code it recognises.
private struct ScannerView: UIViewControllerRepresentable {
    let recognised: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.recognised = recognised
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(recognised: recognised) }

    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var recognised: (String) -> Void

        init(recognised: @escaping (String) -> Void) {
            self.recognised = recognised
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in items {
                if let text = code.payloadStringValue { recognised(text) }
            }
        }

        func dataScanner(_ scanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            if case .barcode(let code) = item, let text = code.payloadStringValue { recognised(text) }
        }
    }
}
