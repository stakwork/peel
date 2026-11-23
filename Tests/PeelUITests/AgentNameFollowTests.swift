import Testing
@testable import PeelUI

/// The Mac's agent name follows its contact's alias, and a rename here is
/// not undone by the older alias still stored.
struct AgentNameFollowTests {
    private let def = "Peel"

    @Test func aRenameLeadsToTheNewAliasOnTheNextAgentMessage() {
        var follow = AgentNameFollow()
        #expect(follow.name(forAlias: "Peel", current: "Peel", defaultName: def) == nil)
        follow.renamed(to: "Scout")
        // The Mac shows "Scout" now; the contact still says "Peel", which is not a change.
        #expect(follow.name(forAlias: "Peel", current: "Scout", defaultName: def) == nil)
        // The agent's next message carries "Scout": the wait ends, nothing to change.
        #expect(follow.name(forAlias: "Scout", current: "Scout", defaultName: def) == nil)
        // A later rename on another device is then followed.
        #expect(follow.name(forAlias: "Rex", current: "Scout", defaultName: def) == "Rex")
    }

    @Test func aFirstSightNamesOnlyAnAgentStillCalledByItsDefault() {
        var fresh = AgentNameFollow()
        #expect(fresh.name(forAlias: "Scout", current: "Peel", defaultName: def) == "Scout")
        var named = AgentNameFollow()
        #expect(named.name(forAlias: "Old", current: "Mine", defaultName: def) == nil)
    }

    @Test func aRenameBeforeAnyAliasWaitsForIt() {
        var follow = AgentNameFollow()
        follow.renamed(to: "Scout")
        #expect(follow.name(forAlias: "Peel", current: "Scout", defaultName: def) == nil)
        #expect(follow.name(forAlias: "Scout", current: "Scout", defaultName: def) == nil)
    }

    @Test func emptyAliasChangesNothing() {
        var follow = AgentNameFollow()
        #expect(follow.name(forAlias: nil, current: "Peel", defaultName: def) == nil)
        #expect(follow.name(forAlias: "  ", current: "Peel", defaultName: def) == nil)
    }
}
