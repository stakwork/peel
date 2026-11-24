import Foundation

/// How the agent's tools read in its chat: "Read the time · 0.1 s".
enum AgentToolTitle {
    private static let titles = [
        "current_time": String(localized: "Read the time", table: "Shared"),
        "get_contacts_and_tribes": String(localized: "Read contacts and tribes", table: "Shared"),
        "read_recent_messages": String(localized: "Read recent messages", table: "Shared"),
        "read_unseen_messages": String(localized: "Read unseen messages", table: "Shared"),
        "read_threads": String(localized: "Read threads", table: "Shared"),
        "read_attachment": String(localized: "Read an attachment", table: "Shared"),
        "search_messages": String(localized: "Searched messages", table: "Shared"),
        "send_sphinx_message": String(localized: "Send a message", table: "Shared"),
        // The old memory database's tools, still named in chats from before memory moved to the graph.
        "remember": String(localized: "Remembered", table: "Shared"),
        "recall": String(localized: "Searched memory", table: "Shared"),
        "read_memory": String(localized: "Read memory", table: "Shared"),
        "memory_ontology": String(localized: "Read memory's vocabulary", table: "Shared"),
        "forget_memory": String(localized: "Forgot", table: "Shared"),
        "merge_memory": String(localized: "Merged", table: "Shared"),
        // strut's graph tools, which hold memory, as strut names them: the step's type with "/" and "-" as "_".
        "graph_resolve": String(localized: "Searched memory", table: "Shared"),
        "graph_graph_search": String(localized: "Searched memory", table: "Shared"),
        "graph_graph_get": String(localized: "Read memory", table: "Shared"),
        "graph_graph_neighbors": String(localized: "Read related memories", table: "Shared"),
        "graph_find": String(localized: "Searched memory", table: "Shared"),
        "graph_assert": String(localized: "Remembered", table: "Shared"),
        "graph_create_node": String(localized: "Remembered", table: "Shared"),
        "graph_edit_node": String(localized: "Updated memory", table: "Shared"),
        "graph_create_triplet": String(localized: "Remembered", table: "Shared"),
        "graph_get_ontology": String(localized: "Read memory's vocabulary", table: "Shared"),
        "graph_get_ontology_type": String(localized: "Read memory's vocabulary", table: "Shared"),
        "graph_create_schema": String(localized: "Added to memory's vocabulary", table: "Shared"),
        "graph_delete_edge": String(localized: "Forgot", table: "Shared"),
        "graph_delete_node": String(localized: "Forgot", table: "Shared"),
        "graph_merge": String(localized: "Merged", table: "Shared"),
        "graph_unmerge": String(localized: "Undid a merge", table: "Shared"),
        "list_automations": String(localized: "Read automations", table: "Shared"),
        "preview_schedule": String(localized: "Checked a schedule", table: "Shared"),
        "create_automation": String(localized: "Create an automation", table: "Shared"),
        "update_automation": String(localized: "Change an automation", table: "Shared"),
        "delete_automation": String(localized: "Delete an automation", table: "Shared"),
        "run_automation_now": String(localized: "Run an automation", table: "Shared"),
        // strut's own job steps, on the orchestrator.
        "job_start": String(localized: "Started a task", table: "Shared"),
        "job_continue": String(localized: "Answered a task's question", table: "Shared"),
        "job_list": String(localized: "Looked at your tasks", table: "Shared"),
        "job_get": String(localized: "Checked on a task", table: "Shared"),
        "job_read": String(localized: "Read a task's file", table: "Shared"),
        // Hive workspaces, paired as peers.
        "strut_list_peers": String(localized: "Looked at your Hive workspaces", table: "Shared"),
        "strut_run_workflow": String(localized: "Asked a Hive workspace", table: "Shared"),
    ]

    /// strut's orchestrator's tools, as the bridge names them (`sphinx/unseen`
    /// as `sphinx_unseen`), by the tool of Peel's earlier loop that did the
    /// same, so both read alike.
    private static let strutNames = [
        "sphinx_chats": "get_contacts_and_tribes", "sphinx_read": "read_recent_messages",
        "sphinx_unseen": "read_unseen_messages", "sphinx_attachment": "read_attachment", "sphinx_threads": "read_threads", "sphinx_search": "search_messages",
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
        // An attachment by nothing: its uuid says nothing to a person.
        if let tool, strutNames[tool.replacingOccurrences(of: "[/-]", with: "_", options: .regularExpression)] == "read_attachment" { return "" }
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
        if object["owner"] as? Bool == true { return String(localized: "you", table: "Shared") }
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
