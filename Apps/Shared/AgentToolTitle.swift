import Foundation

/// How the agent's tools read in its chat: "Read the time · 0.1 s".
enum AgentToolTitle {
    private static let titles = [
        "current_time": "Read the time",
        "get_contacts_and_tribes": "Read contacts and tribes",
        "read_recent_messages": "Read recent messages",
        "read_unseen_messages": "Read unseen messages",
        "read_threads": "Read threads",
        "search_messages": "Searched messages",
        "send_sphinx_message": "Send a message",
        "remember": "Remembered",
        "recall": "Searched memory",
        "read_memory": "Read memory",
        "memory_ontology": "Read memory's vocabulary",
        "forget_memory": "Forgot",
        "merge_memory": "Merged",
        // strut's graph tools, which hold memory when it is on the graph (`graphMemory`),
        // as strut names them: the step's type with "/" and "-" as "_".
        "graph_resolve": "Searched memory",
        "graph_graph_search": "Searched memory",
        "graph_graph_get": "Read memory",
        "graph_graph_neighbors": "Read related memories",
        "graph_find": "Searched memory",
        "graph_assert": "Remembered",
        "graph_create_node": "Remembered",
        "graph_edit_node": "Updated memory",
        "graph_create_triplet": "Remembered",
        "graph_get_ontology": "Read memory's vocabulary",
        "graph_get_ontology_type": "Read memory's vocabulary",
        "graph_create_schema": "Added to memory's vocabulary",
        "graph_delete_edge": "Forgot",
        "graph_delete_node": "Forgot",
        "graph_merge": "Merged",
        "graph_unmerge": "Undid a merge",
        "list_automations": "Read automations",
        "preview_schedule": "Checked a schedule",
        "create_automation": "Create an automation",
        "update_automation": "Change an automation",
        "delete_automation": "Delete an automation",
        "run_automation_now": "Run an automation",
        // strut's own job steps, on the orchestrator.
        "job_start": "Started a job",
        "job_continue": "Sent a job your answer",
        "job_list": "Looked for a job",
        "job_get": "Checked on a job",
        "job_read": "Read a job's file",
        // Hive workspaces, paired as peers.
        "strut_list_peers": "Looked at your Stadeum workspaces",
        "strut_run_workflow": "Asked a Stadeum workspace",
    ]

    /// strut's orchestrator's tools, as the bridge names them (`sphinx/unseen`
    /// as `sphinx_unseen`), by the tool of Peel's earlier loop that did the
    /// same, so both read alike.
    private static let strutNames = [
        "sphinx_chats": "get_contacts_and_tribes", "sphinx_read": "read_recent_messages",
        "sphinx_unseen": "read_unseen_messages", "sphinx_threads": "read_threads", "sphinx_search": "search_messages",
        "sphinx_send": "send_sphinx_message", "memory_remember": "remember", "memory_recall": "recall",
        "memory_get": "read_memory", "memory_forget": "forget_memory", "memory_merge": "merge_memory",
        "automation_list": "list_automations", "automation_preview": "preview_schedule",
        "automation_create": "create_automation", "automation_update": "update_automation",
        "automation_delete": "delete_automation", "automation_run_now": "run_automation_now",
    ]

    static func of(_ name: String) -> String {
        let name = name.replacingOccurrences(of: "[/-]", with: "_", options: .regularExpression)
        if let title = titles[strutNames[name] ?? name] { return title }
        let words = name.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// A result's first line as a row shows it: without chat ids, which
    /// the model needs and a person does not, or the colon before the data.
    static func summary(_ line: String) -> String {
        line.replacingOccurrences(of: #" \(chat=[^)]*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
    }

    /// What a tool in the agent's DM was asked, from the bridge's one line
    /// of its input: an object's values ("pr6-peer, hello"), else the line.
    static func asked(_ line: String, tool: String? = nil) -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            // The bridge cuts a long input short: its title if one shows, never half an object.
            guard line.hasPrefix("{") else { return summary(line) }
            return line.firstMatch(of: /"title":"([^"\\]{1,200})"/).map { String($0.1) } ?? ""
        }
        // A job by its title, not the whole prompt it was given.
        if let title = object["title"] as? String { return title }
        // Memory on the graph: what was looked for or remembered, never its ids, types or flags.
        if let tool, tool.replacingOccurrences(of: "[/-]", with: "_", options: .regularExpression).hasPrefix("graph_") {
            return memoryAsked(object)
        }
        return object.keys.sorted().compactMap { key in
            switch object[key] {
            case let text as String: text
            case let number as NSNumber: number.stringValue
            default: nil
            }
        }.joined(separator: ", ")
    }

    /// A graph memory call in a person's words: the user as "you", a fact by
    /// its sentence, a search by its words, a thing by its name; else nothing.
    private static func memoryAsked(_ object: [String: Any]) -> String {
        if object["owner"] as? Bool == true { return "you" }
        if let text = object["text"] as? String { return text }
        if let facts = object["facts"] as? [[String: Any]] {
            return facts.compactMap { $0["text"] as? String }.joined(separator: "; ")
        }
        for key in ["q", "name"] { if let text = object[key] as? String, !text.isEmpty { return text } }
        for key in ["node_data", "data", "source_data"] {
            if let name = (object[key] as? [String: Any])?["name"] as? String { return name }
        }
        if let names = object["aliases"] as? [String], !names.isEmpty { return names.joined(separator: ", ") }
        return ""
    }
}
