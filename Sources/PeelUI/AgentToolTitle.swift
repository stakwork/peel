import Foundation

/// How the agent's tools read in its chat: "Read the time · 0.1 s".
public enum AgentToolTitle {
    private static let titles = [
        "current_time": "Read the time",
        "get_contacts_and_tribes": "Read contacts and tribes",
        "read_recent_messages": "Read recent messages",
        "read_unseen_messages": "Read unseen messages",
        "read_threads": "Read threads",
        "search_messages": "Searched messages",
        "send_sphinx_message": "Send a message",
        "remember": "Remembered",
        // memory/recall, get and ontology, which older chats show.
        "recall": "Searched memory",
        "read_memory": "Read memory",
        "memory_ontology": "Read memory's vocabulary",
        "forget_memory": "Forgot",
        "merge_memory": "Merged",
        // strut's graph reads, which read memory on Peel.
        "graph_graph-search": "Searched memory",
        "graph_graph-get": "Read memory",
        "graph_graph-get-batched": "Read memory",
        "graph_graph-neighbors": "Followed links in memory",
        "graph_get-ontology": "Read memory's vocabulary",
        "graph_get-ontology-type": "Read memory's vocabulary",
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
        "strut_list-peers": "Looked at your Stadeum workspaces",
        "strut_run-workflow": "Asked a Stadeum workspace",
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
        "automation_delete": "delete_automation", "automation_run-now": "run_automation_now",
    ]

    public static func of(_ name: String) -> String {
        let name = name.replacingOccurrences(of: "/", with: "_")
        if let title = titles[strutNames[name] ?? name] { return title }
        let words = name.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// A result's first line as a row shows it: without chat ids, which
    /// the model needs and a person does not, or the colon before the data.
    public static func summary(_ line: String) -> String {
        line.replacingOccurrences(of: #" \(chat=[^)]*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
    }

    /// What a tool in the agent's DM was asked, from the bridge's one line
    /// of its input: an object's values ("pr6-peer, hello"), else the line.
    public static func asked(_ line: String) -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            // The bridge cuts a long input short: its title if one shows, never half an object.
            guard line.hasPrefix("{") else { return summary(line) }
            return line.firstMatch(of: /"title":"([^"\\]{1,200})"/).map { String($0.1) } ?? ""
        }
        // A job by its title, not the whole prompt it was given.
        if let title = object["title"] as? String { return title }
        return object.keys.sorted().compactMap { key in
            switch object[key] {
            case let text as String: text
            case let number as NSNumber: number.stringValue
            default: nil
            }
        }.joined(separator: ", ")
    }
}
