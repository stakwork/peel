import AgentKit
import Foundation

/// How a run on `peel-automation` ended, as Peel answered strut's step
/// before strut was the agent: still in the runs strut keeps.
public struct AutomationReply: Sendable, Equatable, Codable {
    public enum Status: String, Sendable, Codable {
        /// Something to say: `text` goes to the person.
        case delivered
        /// Nothing worth saying this time; the person sees nothing.
        case nothing
        /// The run did not finish; strut marks it an error.
        case failed
    }

    public var status: Status
    public var text: String?
    public var error: String?
}

/// Why a run never started, as the Automations view says it
/// (`AutomationRunRecord.failure`): a whole sentence, so the view adds no
/// "Didn't finish" before it.
public enum AutomationFailure {
    public static let noModel = "Didn't run: no model is connected. Connect one in Account."
    /// A run on `peel-automation` that found no Peel to hand it to: nothing
    /// listens for it since PR 11, so it waits to move to the assistant,
    /// which happens once its own account is set up.
    public static let notMoved = "Didn't run: it runs once your assistant is set up. Set it up in the agent chat."

    /// The provider refused the key (HTTP 401): an expired or revoked one.
    public static func keyRejected(by provider: AgentProvider?) -> String {
        "Didn't run: \(name(of: provider)) rejected the key. Replace it in Account."
    }

    /// Anthropic refused an organization-wide key's workspace: none given,
    /// or one the key can't use (`AgentCredential.workspaceID`).
    public static let noWorkspace = "Didn't run: Anthropic needs a workspace ID this key can use. Check it in Account."

    private static func name(of provider: AgentProvider?) -> String { provider?.name ?? "the model's provider" }

    /// Already a sentence of its own, not a reason to put after "Didn't finish".
    static func isSentence(_ text: String) -> Bool { text.hasPrefix("Didn't ") }
}
