import PeelCore
import PeelUI
import PhotosUI
import SwiftUI
import UIKit

// The pieces the phone's contacts, invites and tribes share: the actions
// at the end of a Chats section, a pending invite's row, a code typed,
// pasted, scanned or read from a photo, the in-place confirm, and a QR
// code to share. The Mac's are in `Sidebar.swift`, `ContactsViews.swift`
// and `FormKit.swift`.

/// What Chats opens over its list as a sheet: the forms at the end of its
/// sections and a pending invite.
enum PeopleSheet: Identifiable, Hashable {
    case addContact, inviteSomeone, joinTribe, createTribe
    /// A pending invite, by its code.
    case invite(String)

    var id: Self { self }

    @MainActor var screen: some View {
        SheetStack {
            switch self {
            case .addContact: AddContactSheet()
            case .inviteSomeone: InviteSheet()
            case .joinTribe: JoinTribeSheet()
            case .createTribe: TribeSettingsSheet(editing: nil)
            case .invite(let code): InviteDetailScreen(code: code)
            }
        }
    }
}

/// A sheet's own stack, whose pages close it (`dismissSheet`, which
/// `SheetPage`'s Close calls).
struct SheetStack<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack { content }
            .environment(\.dismissSheet, { dismiss() })
    }
}

/// A "+" row at the end of a Chats section (Join a tribe, Add contact),
/// as the Mac's `SidebarActionLink`: the plus in the avatars' 30 pt
/// column, the words in `secondaryText`, 44 pt tall.
struct ActionRow: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: "plus")
                    .phoneFont(PhoneFont(size: 17, weight: .medium, style: .body))
                    .frame(width: 30)
                    .accessibilityHidden(true)
                Text(title).phoneFont(.row)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.secondaryText)
            .padding(.vertical, 7)
            .frame(minHeight: Theme.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// An invite waiting to be used, at the end of Direct messages as on the
/// Mac: the dashed envelope ring, its nickname, and the amount (or
/// "Sending…", "Cancelling…") where a chat's count goes. A tap opens it.
struct PendingInviteRow: View {
    let invite: InviteRecord
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: Theme.Space.md) {
                InviteIcon(size: 30)
                    .accessibilityHidden(true)
                Text(invite.nickname ?? "Invite")
                    .phoneFont(.row)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.sm)
                Text(invite.shortStatus)
                    .phoneFont(.time)
                    .monospacedDigit()
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.vertical, 7)
            .frame(minHeight: Theme.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Invite, \(invite.nickname ?? "no nickname")")
        .accessibilityValue(invite.statusLine)
        .accessibilityAddTraits(.isButton)
    }
}

/// A code typed or pasted into a box, scanned with the camera, or read
/// from a photo of a QR code (a screenshot of someone's code). What any of
/// them gives is untrusted text: `accept` says why a scanned one is passed
/// over (nil takes it), and `choose` picks the code a photo's are read for.
struct CodeEntry: View {
    let label: String
    let prompt: String
    @Binding var text: String
    /// The scanner's title and line ("Scan their code").
    let scanTitle: String
    let scanPrompt: String
    let accept: (String) -> String?
    let choose: ([String]) -> String?
    /// Set to the text a scan, a photo or Paste gave, so why it adds
    /// nothing can show at once (the Mac's rule).
    var picked: (String) -> Void = { _ in }

    @State private var scanning = false
    @State private var photo: PhotosPickerItem?
    @State private var reading = false
    @State private var problem: String?
    @State private var clipboardChanges = 0
    @FocusState private var focused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Side by side, or stacked at accessibility sizes rather than clipped.
        let buttons = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.sm))
            : AnyLayout(HStackLayout(spacing: Theme.Space.sm))
        FieldLabel(label) {
            TextField(label, text: $text, prompt: Text(prompt), axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(1...5)
                .focused($focused)
                .padding(Theme.Space.md)
                .frame(minHeight: 48)
                .fieldBox(focused: focused)
            buttons {
                PasteButton(payloadType: String.self) { texts in
                    if let first = texts.first { take(first.trimmed) }
                }
                .buttonBorderShape(.capsule)
                .labelStyle(.iconOnly)
                .accessibilityLabel("Paste")
                // It decides whether it is enabled only as it appears: looked
                // at again when the clipboard may have changed (`WordEntry`'s way).
                .id(clipboardChanges)
                .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
                    clipboardChanges += 1
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    clipboardChanges += 1
                }
                Button { scanning = true } label: {
                    Label("Scan", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(.peel(.outline, size: .touch))
                PhotosPicker(selection: $photo, matching: .images) {
                    Label(reading ? "Reading…" : "Photo", systemImage: "photo")
                }
                .buttonStyle(.peel(.outline, size: .touch))
                .disabled(reading)
                .accessibilityHint("Reads a QR code in a photo or screenshot")
            }
            if let problem { ProblemText(problem) }
        }
        .onChange(of: text) { problem = nil }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task { await read(item) }
        }
        .fullScreenCover(isPresented: $scanning) {
            CodeScanner(title: scanTitle, prompt: scanPrompt, pasteInstead: "paste the code",
                        cancel: { scanning = false }) { code in
                if let refused = accept(code) { return refused }
                take(code)
                scanning = false
                return nil
            }
        }
    }

    private func take(_ code: String) {
        text = code
        picked(code)
    }

    /// The photo's QR codes, read off the main thread; the one `choose`
    /// picks goes in the box.
    private func read(_ item: PhotosPickerItem) async {
        reading = true
        defer { reading = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let codes = try await Task.detached { try QRImage.codes(in: data) }.value
            guard let chosen = choose(codes) else {
                problem = codes.isEmpty ? "No QR code found in that photo." : "That photo's code isn't one Peel can use here."
                return
            }
            take(chosen)
        } catch {
            problem = PeelError.problem(error)
        }
    }
}

/// The one in-place confirm on the phone's details and forms, never a
/// system alert: the trigger, then what it does, Cancel and the confirm
/// (red only when `destructive`), each 44 pt tall.
struct ConfirmInPlace: View {
    let trigger: String
    var explanation: String?
    let confirm: String
    var destructive = true
    let action: () async -> Void

    @State private var confirming = false
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            if confirming {
                if let explanation {
                    Text(explanation)
                        .phoneFont(.row)
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ConfirmPair(confirm: confirm, destructive: destructive, working: working,
                            cancel: { confirming = false }, run: run)
            } else {
                Button { confirming = true } label: {
                    Text(trigger).frame(maxWidth: .infinity)
                }
                .buttonStyle(.peel(.outline, size: .touch))
                .foregroundStyle(destructive ? Theme.destructive : Theme.text)
            }
        }
        .animation(.easeOut(duration: 0.2), value: confirming)
    }

    private func run() {
        guard !working else { return }
        working = true
        Task {
            await action()
            working = false
            confirming = false
        }
    }
}

/// Cancel and the confirm side by side, 44 pt tall: `ConfirmInPlace`'s
/// second step, and the one a swipe opens (Remove a member).
struct ConfirmPair: View {
    let confirm: String
    var destructive = true
    var working = false
    let cancel: () -> Void
    let run: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Button(action: cancel) { Text("Cancel").frame(maxWidth: .infinity) }
                .buttonStyle(.peel(.outline, size: .touch))
                .disabled(working)
            Button(role: destructive ? .destructive : nil, action: run) {
                Text(confirm).lineLimit(1).frame(maxWidth: .infinity).buttonProgress(working)
            }
            .buttonStyle(.peel(destructive ? .destructive : .primary, size: .touch))
            .disabled(working)
        }
    }
}

/// A key or a link to share with its QR code: the code, then Copy and
/// Share (the text) and Share QR (the code as a picture).
struct ShareableCode: View {
    let text: String
    /// "QR code of their public key".
    let label: String
    /// "Copy key", "Copy link".
    let copyTitle: String
    var showsText = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Side by side, or stacked at accessibility sizes rather than clipped.
        let buttons = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: Theme.Space.sm)) : AnyLayout(HStackLayout(spacing: Theme.Space.sm))
        VStack(spacing: Theme.Space.md) {
            QRCodeTile(text: text, label: label, size: 220, inset: 12)
            if showsText {
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons {
                CopyButton(copyTitle, text: text)
                    .buttonStyle(.peel(.outline, size: .touch))
                ShareLink(item: text) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.peel(.outline, size: .touch))
                if let picture {
                    ShareLink(item: picture, preview: SharePreview(label, image: picture)) {
                        Label("QR", systemImage: "qrcode")
                    }
                    .buttonStyle(.peel(.outline, size: .touch))
                    .accessibilityLabel("Share QR code")
                }
            }
        }
        .frame(maxWidth: .infinity)
        // Drawn once per text, not on every redraw.
        .task(id: text) { picture = QRCode.picture(text) }
    }

    @State private var picture: Image?
}

extension AppModel {
    /// A photo from Photos for a tribe's image or your photo in a tribe:
    /// drawn again as JPEG in Peel's own folder (no metadata, `PickedFiles`),
    /// uploaded, its link returned; the file goes either way.
    func uploadPicture(_ item: PhotosPickerItem) async throws -> String {
        let picked = await PickedFiles.photos([item])
        guard let file = picked.files.first else {
            throw PeelError(picked.refused.first ?? "the photo could not be read")
        }
        defer { IncomingFiles.discard(file) }
        return try await uploadPicture(file)
    }
}

extension QRCode {
    /// The code on white, large enough to scan, as a picture to share.
    static func picture(_ text: String) -> Image? {
        guard let code = image(text) else { return nil }
        let scale: CGFloat = 8, margin: CGFloat = 4 * scale
        let side = CGFloat(code.width) * scale + margin * 2
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let picture = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            context.cgContext.interpolationQuality = .none
            // UIKit's context is flipped against Core Graphics'; a QR code
            // drawn upside down reads the same, but it is drawn the right way up.
            context.cgContext.translateBy(x: 0, y: side)
            context.cgContext.scaleBy(x: 1, y: -1)
            context.cgContext.draw(code, in: CGRect(x: margin, y: margin, width: side - margin * 2, height: side - margin * 2))
        }
        return Image(uiImage: picture)
    }
}
