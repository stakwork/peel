import Testing
@testable import PeelUI

/// How the agent's tools read in its chat, as the bridge names them.
struct AgentToolTitleTests {
    @Test func strutsGraphReadsReadAsMemory() {
        #expect(AgentToolTitle.of("graph_graph-search") == "Searched memory")
        #expect(AgentToolTitle.of("graph_graph-get") == "Read memory")
        #expect(AgentToolTitle.of("graph_graph-get-batched") == "Read memory")
        #expect(AgentToolTitle.of("graph_graph-neighbors") == "Followed links in memory")
        #expect(AgentToolTitle.of("graph_get-ontology") == "Read memory's vocabulary")
        #expect(AgentToolTitle.of("graph_get-ontology-type") == "Read memory's vocabulary")
        #expect(AgentToolTitle.of("graph/graph-search") == "Searched memory", "a step's own name reads the same")
    }

    @Test func oldChatsMemoryReadsKeepTheirTitles() {
        #expect(AgentToolTitle.of("memory_recall") == "Searched memory")
        #expect(AgentToolTitle.of("memory_get") == "Read memory")
        #expect(AgentToolTitle.of("memory_ontology") == "Read memory's vocabulary")
        #expect(AgentToolTitle.of("memory_remember") == "Remembered")
    }
}
