import AgentKit
import Foundation
import PeelCore

/// Dictation's speech-to-text on a strut: its own recognizer (sherpa-onnx,
/// on this Mac's CPU), asked once per recording (strut's
/// `plans/native-dictation-client.md` §3 and §6). Nothing here is logged:
/// what was said is the user's.
public struct StrutSpeech: Sendable {
    /// The default speech model, kept on this Mac: strut transcribes with it
    /// until the user's pick (Account › Dictation › Speech model) is installed.
    public static let model = "zipformer-en-kroko"
    /// Its download, as the person is told it.
    public static let modelSize = "57 MB"

    /// Why there is no text, in words for the HUD. Strut's own words stay
    /// out of them: they can carry its paths and internals.
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// This strut was built without the speech engine (501).
        case noEngine
        /// The strut refused Peel's key (401).
        case keyRefused
        /// The model is not there and could not be fetched; strut's reason.
        case modelUnavailable(String)
        /// The strut is not running, or could not be reached.
        case unreachable
        /// It did not answer in time.
        case tookTooLong
        /// Strut refused the recording; its reason.
        case refused(String)

        public var description: String {
            switch self {
            case .noEngine: "This Peel's strut has no speech engine"
            case .keyRefused: "Peel's strut refused its key"
            case .modelUnavailable: "The speech model couldn't be downloaded"
            case .unreachable: "Peel's strut isn't running"
            case .tookTooLong: "Peel's strut took too long"
            case .refused: "Peel's strut couldn't transcribe that"
            }
        }
    }

    let server: MemoryServer

    public init(server: MemoryServer) { self.server = server }

    /// Whether the model is on this Mac.
    public func modelInstalled() async throws -> Bool {
        let models = try await call("GET", "audio/models")
        guard models["available"] == .bool(true) else { throw Failure.noEngine }
        return models["models"]?.array?.contains { $0["id"]?.string == Self.model && $0["installed"] == .bool(true) } == true
    }

    /// Fetches the model once; at once if it is already there. strut answers
    /// with server-sent events and ends on a `done` phase or an `error`.
    public func downloadModel() async throws {
        let (status, data) = try await request("POST", "audio/models/\(Self.model)/download", body: nil)
        try Self.check(status, data)
        switch Self.outcome(of: String(decoding: data, as: UTF8.self)) {
        case .done: return
        case .failed(let why): throw Failure.modelUnavailable(why)
        case nil: throw Failure.modelUnavailable("it stopped before it finished")
        }
    }

    /// The text of the WAV at `file`, cased and punctuated, with the user's
    /// vocabulary applied by strut (stakwork/strut#301); `heard`, what the
    /// recogniser wrote, only when the vocabulary changed it. Empty text
    /// when nothing was heard. Read here, off the main thread.
    public func transcribe(wavAt file: URL) async throws -> (text: String, heard: String?) {
        let wav = try Data(contentsOf: file)
        // No `model`: strut uses the user's pick (`dictation/use`) once it is
        // installed, its default until then; a model named here would win.
        let reply = try await call("POST", "audio/transcribe", body: (wav, "audio/wav"))
        guard let text = reply["text"]?.string else { throw Failure.refused("its reply had no text") }
        let heard = reply["heard"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), heard)
    }

    // MARK: HTTP

    private func call(_ method: String, _ path: String, body: (Data, String)? = nil) async throws -> AgentKit.JSONValue {
        let (status, data) = try await request(method, path, body: body)
        try Self.check(status, data)
        guard let value = Self.json(data) else { throw Failure.refused("its reply was unreadable") }
        return value
    }

    /// On the slow strut session: a download of tens of MB, or a long
    /// recording's decoding, outlasts the usual minute.
    private func request(_ method: String, _ path: String, body: (Data, String)?) async throws -> (Int, Data) {
        // Relative to the bare base, as `AutomationsClient.request` explains.
        guard let url = URL(string: path, relativeTo: server.base)?.absoluteURL else { throw Failure.unreachable }
        do {
            // The body goes as `json:` for the bytes; its type is set over the JSON one.
            return try await Web.requestStrut(
                method, url, json: body?.0, bearer: server.key, headers: body.map { ["Content-Type": $0.1] } ?? [:],
                limit: MemoryServer.replyLimit, what: "dictation", slow: true
            )
        } catch let error as URLError where error.code == .timedOut {
            throw Failure.tookTooLong
        } catch {
            throw Failure.unreachable
        }
    }

    static func check(_ status: Int, _ data: Data) throws {
        switch status {
        case 200..<300: return
        case 401: throw Failure.keyRefused
        case 501: throw Failure.noEngine
        default: throw Failure.refused(TextLine.clean(json(data)?["error"]?.string ?? "HTTP \(status)", max: 200))
        }
    }

    private static func json(_ data: Data) -> AgentKit.JSONValue? {
        try? AgentKit.JSONValue(parsing: String(decoding: data, as: UTF8.self))
    }

    enum Outcome: Equatable { case done, failed(String) }

    /// How a download's server-sent events ended: the first `error`, else a
    /// `done` phase; nil when neither came.
    static func outcome(of events: String) -> Outcome? {
        var done = false
        for line in events.split(separator: "\n") where line.hasPrefix("data:") {
            guard let data = try? AgentKit.JSONValue(parsing: String(line.dropFirst(5))) else { continue }
            if let error = data["error"]?.string { return .failed(TextLine.clean(error, max: 200)) }
            if data["phase"]?.string == "done" { done = true }
        }
        return done ? .done : nil
    }
}
