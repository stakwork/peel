import SwiftUI
import PeelCore

/// A picture chosen from this Mac, never typed: the picture as it is now,
/// Choose picture… (or a picture dropped on it) and Remove. The upload is
/// the caller's (`AppModel.uploadPhoto`, `uploadPicture`); the link it
/// makes is never shown. The spinner and the problem are the field's own.
struct PictureField<Label: View>: View {
    /// What Remove does: at once (a form's draft, kept only on Save), or
    /// after a second click in place, named by `confirm`.
    enum Removal {
        case now(() -> Void)
        case confirmed(_ confirm: String, () async throws -> Void)
    }

    @Environment(AppModel.self) private var model
    let picture: Avatar
    /// Uploads the chosen file and puts the picture in place.
    let upload: (URL) async throws -> Void
    /// Nil while there is nothing to remove.
    var remove: Removal?
    /// Hands out whether an upload runs, so a form can hold its Save.
    var uploading: Binding<Bool>?
    /// Beside the picture, before the buttons (the Account's name and key).
    @ViewBuilder var label: Label

    @State private var uploadRuns = false
    @State private var problem: String?
    @State private var dropTargeted = false
    @State private var confirmingRemove = false

    private var working: Bool {
        get { uploading?.wrappedValue ?? uploadRuns }
        nonmutating set { if let uploading { uploading.wrappedValue = newValue } else { uploadRuns = newValue } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                picture
                    .overlay {
                        if working {
                            picture.outline.fill(.black.opacity(0.45)).overlay { ProgressView().controlSize(.small) }
                        }
                    }
                    .overlay {
                        if dropTargeted { picture.outline.stroke(Theme.accent, lineWidth: 2) }
                    }
                    .accessibilityLabel(working ? "Uploading the picture" : "Picture")
                label
                if !confirmingRemove {
                    Button { Task { await choose() } } label: {
                        Text("Choose picture…").buttonProgress(working)
                    }
                    .buttonStyle(.peel(.outline))
                    .disabled(working)
                }
                removeButton.disabled(working)
            }
            if let problem {
                Text(problem)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        #if os(macOS)
        .onDrop(of: PasteboardFiles.dropTypes, delegate: PictureDrop(targeted: $dropTargeted, enabled: !working) { items in
            Task { await dropped(items) }
        })
        #endif
    }

    @ViewBuilder private var removeButton: some View {
        switch remove {
        case .now(let action):
            Button("Remove") {
                problem = nil
                action()
            }
            .buttonStyle(.peel(.outline))
        case .confirmed(let confirm, let action):
            InlineConfirm(trigger: "Remove", confirm: confirm, confirming: $confirmingRemove) {
                problem = nil
                do {
                    try await action()
                } catch {
                    problem = "Could not remove the picture: \(PeelError.readable(error))"
                }
            }
        case nil:
            EmptyView()
        }
    }

    private func choose() async {
        guard !working, let file = model.choosePicture() else { return }
        await send(file)
    }

    #if os(macOS)
    /// The first file of a drop; one Peel wrote for it is removed after.
    private func dropped(_ items: [PasteboardFiles.Item]) async {
        let (files, refused) = await PasteboardFiles.files(from: items)
        defer { files.forEach { IncomingFiles.discard($0) } }
        guard let file = files.first else {
            problem = refused.first.map { "Could not use that picture: \($0)" } ?? "That is not a picture."
            return
        }
        await send(file)
    }
    #endif

    private func send(_ file: URL) async {
        guard !working else { return }
        working = true
        defer { working = false }
        problem = nil
        do {
            try await upload(file)
        } catch {
            problem = "Could not upload the picture: \(PeelError.readable(error))"
        }
    }
}

extension PictureField where Label == EmptyView {
    init(
        picture: Avatar, upload: @escaping (URL) async throws -> Void, remove: Removal?, uploading: Binding<Bool>? = nil
    ) {
        self.init(picture: picture, upload: upload, remove: remove, uploading: uploading) { EmptyView() }
    }
}

#if os(macOS)
/// A picture dragged onto the field: read at once, since a drag's
/// pasteboard is gone after the drop.
private struct PictureDrop: DropDelegate {
    @Binding var targeted: Bool
    let enabled: Bool
    let drop: ([PasteboardFiles.Item]) -> Void

    func validateDrop(info: DropInfo) -> Bool { enabled }
    func dropEntered(info: DropInfo) { targeted = enabled }
    func dropExited(info: DropInfo) { targeted = false }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        let items = PasteboardFiles.items(on: NSPasteboard(name: .drag), promises: true)
        guard enabled, !items.isEmpty else { return false }
        drop(items)
        return true
    }
}
#endif
