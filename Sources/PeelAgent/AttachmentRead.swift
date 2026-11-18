import AgentKit
import Foundation
import PeelCore
import PeelDiagnostics

/// `sphinx/attachment` (device request `attachments.read`): the text of one
/// attachment in the agent's own DM, read on this Mac
/// (docs/agent-on-strut.md, "Attachments"). Only a message of the user's own
/// in that DM is read: any other chat's attachment, a message that is not an
/// attachment or one the agent sent is refused, so a model that is told a uuid
/// by someone in a tribe cannot open that file. The answer is framed as
/// `ChatData` frames the chats: someone else's words, never instructions.
public struct AttachmentReader: Sendable {
    public typealias Download = @Sendable (_ messageID: Int64) async throws -> DownloadedAttachment

    /// What a refusal says, whichever way the message failed it.
    static let refusal = "not an attachment of your agent chat"

    let storage: Storage
    /// The agent's DM: the only chat whose attachments are read.
    let agentChat: @Sendable () async -> String?
    /// The file of an attachment message, from the cache or downloaded (up to the send limit).
    let download: Download
    let transcriber: any AudioTranscribing
    let transcripts = TextCache()

    public init(
        storage: Storage, agentChat: @escaping @Sendable () async -> String?, download: @escaping Download,
        transcriber: any AudioTranscribing = SystemTranscriber()
    ) {
        self.storage = storage
        self.agentChat = agentChat
        self.download = download
        self.transcriber = transcriber
    }

    /// Over an engine: its agent's DM, and its attachments, cache first.
    public init(engine: Engine, transcriber: any AudioTranscribing = SystemTranscriber()) {
        self.init(
            storage: engine.storage, agentChat: { try? await engine.agentPubkey() },
            download: { try await engine.downloadAttachment(messageID: $0, upTo: Engine.sendLimit) },
            transcriber: transcriber
        )
    }

    var tool: Tool {
        Tool(
            name: "read_attachment",
            description: """
                Read the text of a file the user attached to a message to you: the words in a picture, a PDF, a \
                document, a text file or a recording of speech, read on their Mac.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "uuid": ["type": "string", "description": "The attachment message's uuid, from its [Attachment] line."],
                    "offset": ["type": "integer", "minimum": 0, "description": "Character to start from, to read the next part of a long file."],
                ],
                "required": ["uuid"],
                "additionalProperties": false,
            ],
            effect: .read
        ) { input in
            let uuid = try SphinxTools.required("uuid", in: input)
            let started = Date()
            var kind = DiagnosticEvent.AttachmentReadKind.unknown
            var outcome = DiagnosticEvent.AttachmentReadOutcome.failed
            defer {
                Diagnostics.recordAttachmentRead(
                    kind: kind, outcome: outcome, milliseconds: Int(Date().timeIntervalSince(started) * 1000)
                )
            }
            do {
                let text = try await read(uuid, offset: max(input["offset"]?.int ?? 0, 0), kind: &kind, outcome: &outcome)
                return .text(text)
            } catch let error as ToolFailure {
                if error.errorDescription == Self.refusal { outcome = .refused }
                throw error
            }
        }
    }

    /// The framed answer for `uuid`; `kind` and `outcome` say what it was and how it ended.
    func read(
        _ uuid: String, offset: Int, kind: inout DiagnosticEvent.AttachmentReadKind, outcome: inout DiagnosticEvent.AttachmentReadOutcome
    ) async throws -> String {
        guard let chat = await agentChat(), let message = try? storage.message(uuid: uuid, in: chat),
              message.type == MessageType.attachment, message.fromMe, !message.deleted, let id = message.id else {
            throw ToolFailure(errorDescription: Self.refusal)
        }
        let file: DownloadedAttachment
        do {
            file = try await download(id)
        } catch {
            throw ToolFailure(errorDescription: "Could not get the attachment: \(PeelError.readable(error)).")
        }
        let name = file.fileName ?? message.fileName ?? "file"
        let type = message.mediaType ?? ""
        let kindOfFile = AttachmentText.kind(file: file.file, mediaType: type)
        kind = Self.diagnosticKind(kindOfFile)
        let title = Self.title(name: name, type: type, size: file.size)
        do {
            let full: String
            if let cached = await transcripts.text(for: uuid) {
                full = cached
            } else {
                full = try await AttachmentText.fullText(file: file.file, mediaType: type, transcriber: transcriber)
                await transcripts.keep(full, for: uuid)
            }
            let part = AttachmentText.part(of: full, from: offset)
            outcome = .ok
            return Self.framed(title: title, part: part, from: min(offset, part.total))
        } catch let failure as AttachmentText.Failure {
            switch failure {
            case .unreadable, .unsupportedDocument: outcome = .unsupported
            case .cannotTranscribe: outcome = .cannotTranscribe
            case .tooLong, .failed: outcome = .failed
            }
            // The file is known, its words are not: said as the result, never as a crash of the read.
            return "\(title)\nThe file cannot be read: \(failure.localizedDescription)."
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ToolFailure(errorDescription: "Could not read the attachment: \(PeelError.readable(error)).")
        }
    }

    /// "[Attachment name, type, size]": what the model is told it is reading.
    static func title(name: String, type: String, size: Int) -> String {
        // "]" ends the title, so none is left in a name to fake another line.
        let cleaned = TextLine.clean(name, max: TextLine.maxName).replacingOccurrences(of: "]", with: ")")
        let kind = TextLine.clean(type, max: 60).replacingOccurrences(of: "]", with: ")")
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        return "[Attachment \(cleaned), \(kind.isEmpty ? "unknown type" : kind), \(bytes)]"
    }

    /// The part between `ChatData`'s markers under its title (characters a-b of n), and how to read on.
    static func framed(title: String, part: AttachmentText.Part, from start: Int) -> String {
        let end = start + part.text.count
        let range = part.total == 0 ? "no text"
            : part.text.isEmpty ? "nothing after character \(part.total)" : "characters \(start + 1)-\(end) of \(part.total)"
        var lines = ["\(title) (\(range))", ChatData.begin]
        if !part.text.isEmpty { lines.append(part.text) }
        lines.append(ChatData.end)
        if part.total == 0 { lines.append("No text was found in this file.") }
        if let next = part.next { lines.append("Read the next part with offset=\(next).") }
        return lines.joined(separator: "\n")
    }

    static func diagnosticKind(_ kind: AttachmentText.Kind) -> DiagnosticEvent.AttachmentReadKind {
        switch kind {
        case .image: .image
        case .pdf: .pdf
        case .audio: .audio
        case .document: .document
        case .text: .text
        case .unreadable: .unreadable
        }
    }
}

/// The text of the last few attachments read, by message uuid and in memory
/// only, so a long file or a transcript is made once and read on in parts.
actor TextCache {
    private let capacity = 6
    private var order: [String] = []
    private var texts: [String: String] = [:]

    func text(for uuid: String) -> String? { texts[uuid] }

    func keep(_ text: String, for uuid: String) {
        if texts[uuid] == nil { order.append(uuid) }
        texts[uuid] = text
        while order.count > capacity { texts[order.removeFirst()] = nil }
    }
}
