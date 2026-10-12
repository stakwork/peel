import Foundation
import Testing
import PeelAgent

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
}
