import Foundation
import Testing
@testable import AgentKit

struct ModelErrorTests {
    private func error(_ status: Int, _ body: String = "", retryAfter: String? = nil, secret: String = "sk-test-secret") -> ModelError {
        ModelError(status: status, retryAfter: retryAfter, body: Data(body.utf8), secret: secret)
    }

    @Test func statusesMapToPlainCases() {
        let anthropic = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
        #expect(error(401, anthropic) == .invalidKey("invalid x-api-key"))
        #expect(error(403) == .invalidKey(nil))
        #expect(error(429, retryAfter: "17") == .rateLimited(retryAfter: 17))
        #expect(error(408).isRetryable)
        #expect(error(429, retryAfter: "Wed, 21 Oct 2026 07:28:00 GMT") == .rateLimited(retryAfter: nil))
        #expect(error(529, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#) == .unavailable(status: 529, "Overloaded"))
        #expect(error(503, "<html>bad gateway</html>") == .unavailable(status: 503, nil))
        let openAI = #"{"error":{"message":"Unknown model gpt-x","type":"invalid_request_error","code":"model_not_found"}}"#
        #expect(error(404, openAI) == .badRequest(status: 404, "Unknown model gpt-x"))
        #expect(error(400) == .badRequest(status: 400, "bad request"))
    }

    @Test func messagesNeverCarryTheKey() {
        let quoted = #"{"error":{"message":"Incorrect API key provided: sk-proj-abc1****wxyz. You can find your API key at https://platform.openai.com.","type":"invalid_request_error"}}"#
        guard case .invalidKey(let message?) = error(401, quoted) else { Issue.record("not invalidKey"); return }
        #expect(!message.contains("sk-proj"))
        #expect(!message.contains("abc1"))

        let echoed = #"{"error":{"message":"bad key my-own-secret-value here"}}"#
        let failure = error(400, echoed, secret: "my-own-secret-value")
        #expect(failure == .badRequest(status: 400, "bad key [key] here"))
        #expect(failure.localizedDescription.contains("[key]"))
    }

    @Test func longMessagesAreCut() {
        let body = #"{"error":{"message":""# + String(repeating: "a", count: 2000) + #""}}"#
        guard case .badRequest(_, let message) = error(400, body) else { Issue.record("not badRequest"); return }
        #expect(message.count == 301)
    }

    @Test func streamErrorsMapByTypeOrCode() {
        #expect(ModelError(streamError: ["type": "rate_limit_error", "message": "slow"], secret: "") == .rateLimited(retryAfter: nil))
        #expect(ModelError(streamError: ["type": "api_error", "message": "oops"], secret: "") == .unavailable(status: 500, "oops"))
        #expect(ModelError(streamError: ["code": 401, "message": "no"], secret: "") == .invalidKey("no"))
        #expect(ModelError(streamError: ["code": "400", "message": "bad"], secret: "") == .badRequest(status: 400, "bad"))
        #expect(
            ModelError(streamError: ["code": "rate_limit_exceeded", "type": "tokens", "message": "slow"], secret: "")
                == .rateLimited(retryAfter: nil))
    }

    @Test func transportErrors() {
        #expect(ModelError(URLError(.notConnectedToInternet)) == .network("Not connected to the internet."))
        #expect(ModelError(URLError(.cancelled)) == .cancelled)
        #expect(ModelError(CancellationError()) == .cancelled)
        #expect(ModelError(URLError(.timedOut)).isRetryable)
        #expect(!ModelError.invalidKey(nil).isRetryable)
    }
}
