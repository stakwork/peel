import PeelCore
import PeelUI
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The phone's composer (docs/design/iphone.md, decision 7 and screen 10):
/// attach (+) outside a glass capsule; inside it the text, growing to about
/// six lines then scrolling, the send-sats bolt in a direct message, and
/// the mic while it is empty, Send (filled blue) once something is typed.
/// `@` in a tribe lists who to mention above it. Its draft, what it replies
/// to and its files are the model's (`drafts`, `replyTargets`,
/// `pendingFiles`), per composer, so a thread's draft outlives its sheet.
struct PhoneComposer: View {
    @Environment(AppModel.self) private var model
    let composer: ComposerID
    let placeholder: String
    /// In a tribe: who `@` offers (`AppModel.mentionLoader`).
    var loadMentionable: (@MainActor @Sendable () async -> [TribeMember])?
    /// A direct message with someone (not the agent): the bolt shows.
    var paysTo: String?

    @State private var mention: String?
    @State private var mentionable: [TribeMember] = []
    @State private var insertion: MentionInsertion?
    @State private var recorder = VoiceRecorder()
    @Environment(\.scenePhase) private var scenePhase

    private var files: [URL] { model.pendingFiles[composer] ?? [] }

    private var draft: Binding<String> {
        Binding(get: { model.drafts[composer] ?? "" }, set: { model.drafts[composer] = $0 })
    }

    private var canSend: Bool {
        !(model.drafts[composer] ?? "").trimmed.isEmpty || !files.isEmpty
    }

    private var suggestions: [TribeMember] {
        guard let mention else { return [] }
        return MentionQuery.suggestions(mentionable, typed: mention)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            let shown = suggestions
            if !shown.isEmpty {
                MentionList(members: shown) { member in
                    insertion = MentionInsertion(id: (insertion?.id ?? 0) + 1, alias: member.alias)
                }
                .padding(.leading, Theme.touchTarget + Theme.Space.sm)
                .transition(.opacity)
            }
            HStack(alignment: .bottom, spacing: Theme.Space.sm) {
                if model.takesFiles(composer) {
                    AttachButton(composer: composer)
                }
                capsule
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.bottom, Theme.Space.sm)
        .animation(.easeOut(duration: 0.15), value: mention == nil)
        .task(id: mention != nil) {
            if mention != nil, let loadMentionable { mentionable = await loadMentionable() }
        }
    }

    private var capsule: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let target = model.replyTargets[composer] {
                ReplyingTo(message: target) { model.cancelReply(in: composer) }
            }
            if !files.isEmpty {
                FilesTray(files: files) { model.removeFile($0, from: composer) }
            }
            HStack(alignment: .bottom, spacing: 0) {
                if recorder.state.isRecording {
                    VoiceRecordingIndicator(state: recorder.state)
                } else {
                    ComposerTextField(
                        text: draft, placeholder: placeholder, focusRequest: model.composerFocus[composer] ?? 0,
                        mention: $mention, insertion: insertion
                    )
                    .padding(.leading, 16)
                }
                if let paysTo, composer.chat != nil, composer.thread == nil {
                    ComingButton(systemImage: "bolt", label: "Send sats",
                                 note: "Sending sats to \(paysTo) from here is coming. Send from the Mac for now.")
                        // Hidden while the mic is held, keeping its space so
                        // the mic does not move under the finger.
                        .opacity(recorder.state.isRecording ? 0 : 1)
                        .allowsHitTesting(!recorder.state.isRecording)
                        .accessibilityHidden(recorder.state.isRecording)
                }
                if canSend {
                    // A restore that settled with no name to recover leaves
                    // this empty until it is set (onboarding asks for one
                    // then; this is the backstop).
                    let hasName = model.myAlias?.nilIfEmpty != nil
                    SendButton(enabled: hasName) { Task { await model.sendDraft(from: composer) } }
                } else {
                    HoldToRecordButton(recorder: recorder) { file in sendVoice(file) }
                }
            }
            if recorder.denied {
                Text("Allow the microphone in Settings to record voice messages.")
                    .phoneFont(.secondary)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 16)
                    .padding(.bottom, Theme.Space.sm)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { recorder.cancel() }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.touchTarget / 2, style: .continuous))
    }
}

extension PhoneComposer {
    /// A recording goes as one voice message (an audio attachment) through
    /// the model's send path, to a contact or a tribe alike.
    fileprivate func sendVoice(_ file: URL) {
        model.addFiles([file], to: composer)
        Task { await model.sendDraft(from: composer) }
    }
}

/// Send: a 32 pt filled circle with an arrow, in a 44 pt target. Dimmed and
/// inert without a name to send under (`enabled`).
private struct SendButton: View {
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.buttonText)
                .frame(width: 32, height: 32)
                .background(Theme.button.opacity(enabled ? 1 : 0.4), in: Circle())
                .frame(width: Theme.touchTarget, height: Theme.touchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel("Send")
        .accessibilityHint(enabled ? "" : "Set your name first, in You")
    }
}

/// A button for what is not built on the phone yet: its menu says so
/// rather than pretending (the mic, the send-sats bolt).
private struct ComingButton: View {
    let systemImage: String
    let label: String
    let note: String

    var body: some View {
        Menu {
            Text(note)
        } label: {
            GlassSymbol(systemImage: systemImage, label: label, tint: Theme.secondaryText)
                .frame(width: Theme.touchTarget, height: Theme.touchTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .accessibilityHint(note)
    }
}

/// Attach (+), a round glass button left of the capsule: Photos, the
/// Camera (where there is one) or Files, each into the composer's tray
/// through the model's send path (`addFiles`, then `sendDraft`).
private struct AttachButton: View {
    @Environment(AppModel.self) private var model
    let composer: ComposerID

    @State private var picking: Picker?
    @State private var photos: [PhotosPickerItem] = []

    private enum Picker: Identifiable {
        case photos, camera, files
        var id: Self { self }
    }

    var body: some View {
        Menu {
            Button("Photos", systemImage: "photo.on.rectangle") { picking = .photos }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Camera", systemImage: "camera") { picking = .camera }
            }
            Button("Files", systemImage: "folder") { picking = .files }
        } label: {
            GlassSymbol(systemImage: "plus", label: "Attach", tint: nil)
                .frame(width: Theme.touchTarget, height: Theme.touchTarget)
                .contentShape(Circle())
        }
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel("Attach")
        .photosPicker(isPresented: binding(.photos), selection: $photos, maxSelectionCount: 10, matching: .images)
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            photos = []
            Task { add(await PickedFiles.photos(items)) }
        }
        .fileImporter(isPresented: binding(.files), allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            let urls = (try? result.get()) ?? []
            Task { add(await Task.detached { PickedFiles.copies(of: urls) }.value) }
        }
        .fullScreenCover(isPresented: binding(.camera)) {
            CameraPicker { image in
                Task { add(await Task.detached { PickedFiles.photo(image) }.value) }
            }
            .ignoresSafeArea()
        }
    }

    private func binding(_ picker: Picker) -> Binding<Bool> {
        Binding { picking == picker } set: { if !$0, picking == picker { picking = nil } }
    }

    private func add(_ picked: (files: [URL], refused: [String])) {
        model.addFiles(picked.files, to: composer)
        if !picked.refused.isEmpty, let chat = composer.chat {
            // The kind only: the refusals name files.
            Diagnostics.note(errorKind: .refused)
            model.conversationNotices[chat] = PeelError.problem(picked.refused.joined(separator: " "), couldNot: "attach")
        }
    }
}

/// Files picked on the phone, written into Peel's own attachment folder
/// (`IncomingFiles`), which the model releases once they are sent. Photos
/// are drawn again as JPEG (a GIF is kept as it is), so what goes carries
/// no location or other metadata, and HEIC reaches every client.
enum PickedFiles {
    static func photos(_ items: [PhotosPickerItem]) async -> (files: [URL], refused: [String]) {
        var files: [URL] = [], refused: [String] = []
        for (index, item) in items.enumerated() {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let isGIF = item.supportedContentTypes.contains { $0.conforms(to: .gif) }
                // Drawn again off the main thread: a camera photo is tens of megapixels.
                files.append(try await Task.detached { try write(data, isGIF: isGIF, index: index) }.value)
            } catch {
                refused.append(PeelError.readable(error))
            }
        }
        return (files, refused)
    }

    static func photo(_ image: UIImage) -> (files: [URL], refused: [String]) {
        do {
            guard let data = jpeg(image) else { throw PeelError("the photo could not be read") }
            return ([try IncomingFiles.write(data, type: .jpeg)], [])
        } catch {
            return ([], [PeelError.readable(error)])
        }
    }

    /// Copies of files picked in Files, each in its own folder of Peel's;
    /// one over the send limit, or not a plain file, is removed and
    /// refused (`IncomingFiles.accept`).
    static func copies(of urls: [URL]) -> (files: [URL], refused: [String]) {
        var files: [URL] = [], refused: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var copy: URL?
            do {
                let folder = try IncomingFiles.newFolder()
                let target = folder.appendingPathComponent(url.lastPathComponent)
                copy = target
                try FileManager.default.copyItem(at: url, to: target)
                // A plain file within the limit, or removed and refused.
                files.append(try IncomingFiles.accept(target, in: folder))
            } catch {
                // The copy, if any, and its folder.
                if let copy { IncomingFiles.discard(copy) }
                refused.append("\(url.lastPathComponent): \(PeelError.readable(error)).")
            }
        }
        return (files, refused)
    }

    private static func write(_ data: Data, isGIF: Bool, index: Int) throws -> URL {
        if isGIF { return try IncomingFiles.write(data, type: .gif, index: index) }
        guard let image = UIImage(data: data), let jpeg = jpeg(image) else {
            throw PeelError("a photo could not be read")
        }
        return try IncomingFiles.write(jpeg, type: .jpeg, index: index)
    }

    /// Drawn upright into new pixels: only the picture goes, never its metadata.
    private static func jpeg(_ image: UIImage) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let upright = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(at: .zero)
        }
        return upright.jpegData(compressionQuality: 0.85)
    }
}

/// The system camera, for a photo to attach.
private struct CameraPicker: UIViewControllerRepresentable {
    let take: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.take(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// "Replying to Name" and the start of what they said, over the text.
private struct ReplyingTo: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let cancel: () -> Void

    var body: some View {
        let sender = model.sender(of: message)
        HStack(spacing: Theme.Space.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to \(Text(message.fromMe ? "yourself" : sender.name).bold().foregroundColor(sender.hue.name))")
                Text(message.preview)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            .phoneFont(.secondary)
            .foregroundStyle(Theme.text)
            Spacer(minLength: 0)
            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: Theme.touchTarget, height: Theme.touchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop replying")
        }
        .padding(.leading, 16)
    }
}

/// The files waiting to go, each with its remove button.
private struct FilesTray: View {
    let files: [URL]
    let remove: (URL) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Space.sm) {
                ForEach(files, id: \.self) { file in
                    HStack(spacing: 4) {
                        Image(systemName: "doc").accessibilityHidden(true)
                        Text(file.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Button { remove(file) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Theme.secondaryText)
                                .frame(width: 32, height: Theme.touchTarget)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(file.lastPathComponent)")
                    }
                    .phoneFont(.secondary)
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: 200)
                    .padding(.leading, 10)
                    .background(Theme.quote, in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
        }
        .scrollIndicators(.hidden)
    }
}

/// Who an `@` can mention, above the composer: an opaque `menu` panel,
/// radius 14, a 44 pt row per person; tap to put them in.
private struct MentionList: View {
    @Environment(AppModel.self) private var model
    let members: [TribeMember]
    let choose: (TribeMember) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(members) { member in
                    Button { choose(member) } label: {
                        HStack(spacing: Theme.Space.md) {
                            Avatar(name: member.alias, url: member.photoURL, size: Theme.AvatarSize.md, hue: model.hue(of: member))
                            Text(member.alias)
                                .phoneFont(.row)
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Text("@\(member.alias)")
                                .phoneFont(.secondary)
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Theme.Space.md)
                        .frame(minHeight: Theme.touchTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Mention \(member.alias)")
                }
            }
            .padding(.vertical, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: Theme.touchTarget * 4.5 + 8)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.menu, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.divider))
        .shadow(color: Theme.popoverShadow, radius: 16, y: 6)
    }
}

/// An alias to put in place of the `@word` being typed; a new `id` each time.
struct MentionInsertion: Equatable {
    let id: Int
    let alias: String
}

// MARK: - The text

/// The composer's text: a `UITextView` (a field cannot grow line by line
/// and keep its cursor), with the placeholder over it, reporting the
/// `@word` before the cursor (`MentionQuery`) and putting in a chosen
/// alias. Return is a new line; Send sends.
private struct ComposerTextField: View {
    @Binding var text: String
    let placeholder: String
    let focusRequest: Int
    @Binding var mention: String?
    let insertion: MentionInsertion?

    var body: some View {
        ComposerTextView(text: $text, focusRequest: focusRequest, mention: $mention, insertion: insertion)
            .overlay(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .phoneFont(.row)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(placeholder)
    }
}

private struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    @Binding var mention: String?
    let insertion: MentionInsertion?

    /// About six lines, then it scrolls.
    static let maxLines: CGFloat = 6
    static let inset: CGFloat = 11

    static var font: UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: PhoneFont.row.size))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = Self.font
        view.adjustsFontForContentSizeCategory = true
        view.textColor = UIColor(Theme.text)
        view.tintColor = UIColor(Theme.accent)
        view.textContainerInset = UIEdgeInsets(top: Self.inset, left: 0, bottom: Self.inset, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = true
        view.showsVerticalScrollIndicator = false
        // Messages carry code and addresses; leave what was typed alone.
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.text = text
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Asked for before it was here (opening the chat): the keyboard waits for a tap.
        context.coordinator.focusedRequest = focusRequest
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.markedTextRange == nil, view.text != text {
            view.text = text
            context.coordinator.styleMentions(view)
            context.coordinator.findMention(view)
        }
        if let insertion, context.coordinator.insertedID != insertion.id {
            context.coordinator.insertedID = insertion.id
            context.coordinator.insert(insertion.alias, in: view)
        }
        if context.coordinator.focusedRequest != focusRequest {
            context.coordinator.focusedRequest = focusRequest
            DispatchQueue.main.async { view.becomeFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 200
        let fitted = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let line = (view.font ?? Self.font).lineHeight
        let most = line * Self.maxLines + Self.inset * 2
        return CGSize(width: width, height: max(Theme.touchTarget, min(fitted, most)))
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        var focusedRequest: Int?
        var insertedID: Int?
        private var mentionRange: NSRange?

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) {
            parent.text = view.text
            styleMentions(view)
            findMention(view)
            // Grows (or shrinks) a line as the text wraps.
            view.invalidateIntrinsicContentSize()
        }

        func textViewDidChangeSelection(_ view: UITextView) {
            findMention(view)
        }

        func findMention(_ view: UITextView) {
            let selection = view.selectedRange
            let found = MentionQuery.word(in: view.text, cursor: selection.location, selectionLength: selection.length)
            mentionRange = found?.range
            if parent.mention != found?.query {
                let query = found?.query
                Task { @MainActor in self.parent.mention = query }
            }
        }

        /// Replaces the `@word` with `@alias ` and leaves the cursor after it.
        func insert(_ alias: String, in view: UITextView) {
            guard let range = mentionRange,
                  let start = view.position(from: view.beginningOfDocument, offset: range.location),
                  let end = view.position(from: start, offset: range.length),
                  let textRange = view.textRange(from: start, to: end) else { return }
            view.replace(textRange, withText: "@\(alias) ")
        }

        /// Typed mentions in `link` blue, the rest in `text`; never while
        /// an input method is composing.
        func styleMentions(_ view: UITextView) {
            guard view.markedTextRange == nil else { return }
            let storage = view.textStorage
            let whole = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: UIColor(Theme.text), range: whole)
            // What the sent message will draw as a mention (`MessageMarkup`).
            let text = view.text ?? ""
            for span in MessageMarkup.spans(in: text) where span.kind == .mention {
                storage.addAttribute(.foregroundColor, value: UIColor(Theme.link), range: NSRange(span.range, in: text))
            }
            storage.endEditing()
        }
    }
}
