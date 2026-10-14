import PeelCore
import SwiftUI
import VisionKit

/// The camera, looking for a QR code that holds an invoice
/// (`DataScannerViewController`). Only an invoice is taken: anything else
/// it reads is untrusted text and is passed over with a word. Without a
/// camera (the simulator) or with access refused, it says so; Paste is the
/// other way in.
struct InvoiceScanner: View {
    let found: (String) -> Void
    let cancel: () -> Void
    @State private var note: String?

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
                    ScannerView { code in
                        if (try? Invoice(code)) != nil {
                            found(code)
                        } else {
                            note = "That code isn't an invoice."
                        }
                    }
                    .ignoresSafeArea()
                    .overlay(alignment: .bottom) {
                        Text(note ?? "Point the camera at an invoice's QR code.")
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
                                          ? "Peel can't use the camera. Allow it in Settings, or paste the invoice."
                                          : "This device has no camera Peel can scan with. Paste the invoice instead.")
                    )
                    .background(Theme.background.ignoresSafeArea())
                }
            }
            .navigationTitle("Scan an invoice")
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
