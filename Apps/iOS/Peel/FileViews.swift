import PeelCore
import PeelUI
import QuickLook
import SwiftUI
import UIKit

// PDFs and other files on the phone, as the Mac's `FileCard`: the file's
// type, name and size; a tap downloads it and shows it in Quick Look, and
// the share button hands it to the share sheet (Save to Files, AirDrop…).
// Nothing is opened by another app unless the person shares it.

/// A file attachment's card. Ours still uploading shows its progress; a
/// failed download says why and a tap tries again.
struct FileCard: View {
    @Environment(AppModel.self) private var model
    let message: Message

    @State private var previewing: URL?
    @State private var sharing: SharedFileItem?
    @State private var notice: String?

    var body: some View {
        let handle = message.id.map(model.attachment)
        let name = handle?.downloaded?.fileName ?? message.fileName
        let size = handle?.downloaded.map { Int64($0.size) } ?? message.fileSize
        PhoneCard {
            HStack(spacing: Theme.Space.md) {
                Button(action: open) {
                    HStack(spacing: Theme.Space.md) {
                        mark(name)
                        VStack(alignment: .leading, spacing: 2) {
                            // The name comes with the download; until then, what it says it is.
                            Text(name ?? AttachmentFormat.kind(mediaType: message.mediaType) ?? "File")
                                .phoneFont(.row)
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text([AttachmentFormat.size(size), AttachmentFormat.kind(name)]
                                .compactMap { $0 }.joined(separator: " · "))
                                .phoneFont(.time)
                                .monospacedDigit()
                                .foregroundStyle(Theme.secondaryText)
                            FileStatus(message: message, handle: handle, notice: notice)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canOpen(handle))
                .accessibilityLabel([name ?? "File", AttachmentFormat.size(size)].compactMap { $0 }.joined(separator: ", "))
                .accessibilityHint(canOpen(handle) ? "Opens a preview" : "")
                if canOpen(handle) {
                    Button(action: share) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: Theme.touchTarget, height: Theme.touchTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Share \(name ?? "file")")
                }
            }
            .padding(.leading, Theme.Space.md)
            .padding(.trailing, canOpen(handle) ? 0 : Theme.Space.md)
            .padding(.vertical, 6)
        }
        .frame(maxWidth: 320, alignment: .leading)
        .quickLookPreview($previewing)
        .sheet(item: $sharing) { shared in
            FileShareSheet(url: shared.url).presentationDetents([.medium, .large])
        }
    }

    /// Not while ours uploads or when its upload failed (nothing to fetch),
    /// nor while a download runs.
    private func canOpen(_ handle: AttachmentHandle?) -> Bool {
        if message.uploadState == .pending { return false }
        if message.fromMe, message.uploadState == .failed { return false }
        if case .downloading? = handle?.state { return false }
        return true
    }

    private func mark(_ name: String?) -> some View {
        Theme.selection
            .overlay {
                Text(AttachmentFormat.badge(name, mediaType: message.mediaType))
                    .phoneFont(.badge)
                    .foregroundStyle(Theme.selectionText)
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }

    /// Downloads it, then shows it.
    private func open() {
        Task {
            if let url = await prepared() { previewing = url }
        }
    }

    private func share() {
        Task {
            if let url = await prepared() { sharing = SharedFileItem(url: url) }
        }
    }

    /// The downloaded file under its real name, or nil (and a note) when
    /// it did not download or could not be copied.
    private func prepared() async -> URL? {
        notice = nil
        await model.download(message)
        guard let id = message.id, let file = model.attachment(id).file else { return nil }
        let handle = model.attachment(id)
        do {
            return try await FileCopy.named(file, name: handle.downloaded?.fileName ?? message.fileName, mediaType: message.mediaType)
        } catch {
            notice = PeelError.noted(error, couldNot: "open the file")
            return nil
        }
    }
}

/// Under a file: its upload or download with a bar, or why it failed.
struct FileStatus: View {
    let message: Message
    let handle: AttachmentHandle?
    var notice: String?

    var body: some View {
        if message.fromMe, message.uploadState == .pending {
            TransferLine(label: "Uploading", progress: handle?.progress)
        } else if case .downloading? = handle?.state {
            TransferLine(label: "Downloading", progress: handle?.progress)
        } else if message.fromMe, message.uploadState == .failed {
            note("Not uploaded")
        } else if let reason = notice ?? handle?.failureReason {
            note(handle?.failureReason != nil ? "\(reason) Tap to try again." : reason)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .phoneFont(.time)
            .foregroundStyle(Theme.secondaryText)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
    }
}

/// "Uploading · 2.1 of 3.4 MB" with a bar, from the engine's transfer events.
struct TransferLine: View {
    let label: String
    let progress: (bytes: Int64, total: Int64)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(progress.map { "\(label) · \(AttachmentFormat.progress($0.bytes, of: $0.total))" } ?? "\(label)…")
                .phoneFont(.time)
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
            if let progress, progress.total > 0 {
                ProgressView(value: Double(progress.bytes), total: Double(progress.total))
                    .tint(Theme.accent)
            }
        }
    }
}

/// A file ready to share: a copy under its real name.
struct SharedFileItem: Identifiable {
    let url: URL
    var id: URL { url }
}

enum FileCopy {
    /// The cache keeps a download under no name, which Quick Look and the
    /// share sheet need: a copy (a hard link when it can be) in its own
    /// folder of the temporary directory, named `name`, with the extension
    /// the declared type gives when the name has none. The system clears
    /// the temporary directory.
    static func named(_ file: URL, name: String?, mediaType: String?) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            var clean = ((name ?? "") as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty || clean == "." || clean == ".." { clean = "file" }
            if (clean as NSString).pathExtension.isEmpty, let ext = AttachmentKind.fileExtension(mediaType: mediaType) {
                clean += ".\(ext)"
            }
            let fileManager = FileManager.default
            let folder = fileManager.temporaryDirectory.appendingPathComponent("Shared-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(clean)
            do {
                try fileManager.linkItem(at: file, to: target)
            } catch {
                try fileManager.copyItem(at: file, to: target)
            }
            return target
        }.value
    }
}

/// The system share sheet for one file.
struct FileShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
