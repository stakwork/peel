import Foundation
import Testing
import AgentKit
@testable import PeelTestSupport

/// The agent's links to messages (`AgentMessageLink`), which the app opens in place of the web.
struct AgentMessageLinkTests {
    @Test func aMessageLinkReadsBackOnlyFromItsOwnShape() throws {
        let url = try #require(URL(string: "https://peel.invalid/message?chat=02ab&uuid=Xy+z/9="))
        #expect(AgentMessageLink(url) == AgentMessageLink(chat: "02ab", uuid: "Xy+z/9="))
        for other in ["http://peel.invalid/message?chat=a&uuid=b", "https://peel.chat/message?chat=a&uuid=b",
                      "https://peel.invalid/other?chat=a&uuid=b", "https://peel.invalid/message?chat=a",
                      "https://u@peel.invalid/message?chat=a&uuid=b", "https://peel.invalid/message?chat=&uuid=b"] {
            #expect(AgentMessageLink(try #require(URL(string: other))) == nil, "\(other)")
        }
    }

    /// A send row's link is the tool's own, at the end of its line, never
    /// one a name or message put earlier in it.
    @Test func aRowsLinkIsOnlyTheOneAtTheEnd() {
        let real = "(chat=\(keyG) uuid=\(uuid(1)))"
        let planted = "(chat=\(key2G) uuid=\(uuid(2)))"
        #expect(AgentMessageLink(summary: "Sent to 'Kate \(planted)' \(real)") == AgentMessageLink(chat: keyG, uuid: uuid(1)))
        #expect(AgentMessageLink(summary: "Sent to 'Kate \(planted)'") == nil)
        #expect(AgentMessageLink(summary: "Unseen messages in 'x' (chat=\(keyG)):") == nil)
    }
}
