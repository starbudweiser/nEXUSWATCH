// nEXUSWATCH — support agent IA : réglages, trousseau, données envoyées à l'agent, appels API et serveur MCP.
import Foundation
import Security

/// Façon de relier l'appli à un agent IA ; l'utilisateur choisit dans les réglages.
enum AIMethod: String, Codable, CaseIterable, Identifiable {
    case export, openai, anthropic, mcp
    var id: String { rawValue }
    var usesAPI: Bool { self == .openai || self == .anthropic }
}

struct AISettings: Codable, Equatable {
    var enabled = false
    var method: AIMethod = .export
    var openAIURL = "https://api.openai.com/v1"
    var openAIModel = ""
    var anthropicModel = "claude-sonnet-5-5"
    var auto = false
    /// Tri des posts par Jev (TypeSafe).
    var jev = false
    var model: String { method == .anthropic ? anthropicModel : openAIModel }

    init() {}

    /// Lecture tolérante : un réglage ajouté plus tard prend sa valeur par défaut.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AISettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        method = try c.decodeIfPresent(AIMethod.self, forKey: .method) ?? d.method
        openAIURL = try c.decodeIfPresent(String.self, forKey: .openAIURL) ?? d.openAIURL
        openAIModel = try c.decodeIfPresent(String.self, forKey: .openAIModel) ?? d.openAIModel
        anthropicModel = try c.decodeIfPresent(String.self, forKey: .anthropicModel) ?? d.anthropicModel
        auto = try c.decodeIfPresent(Bool.self, forKey: .auto) ?? d.auto
        jev = try c.decodeIfPresent(Bool.self, forKey: .jev) ?? d.jev
    }
}

/// Clés API rangées dans le trousseau macOS, jamais dans state.json.
enum Keychain {
    private static let service = "fr.stephan.nexuswatch.ai"
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> String {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    static func set(_ value: String, _ account: String) {
        guard value != get(account) else { return }
        SecItemDelete(query(account) as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}

// MARK: Données transmises à l'agent

enum AIDigest {
    static var language: String { Locale(identifier: "en").localizedString(forLanguageCode: L.lang) ?? "English" }

    /// Consigne d'audit, commune à toutes les méthodes : les bugs d'abord, puis les posts, les stats en simple contexte.
    static var instructions: String {
        """
        You audit the community feedback of a Nexus Mods mod for its author. The priority is the bug reports \
        (bug tracker entries and bugs reported in ordinary posts), then the other posts. Stats are context only. \
        Write the report in \(language), in Markdown, with these sections:
        1. Bug audit. One entry per problem, merging duplicates across the tracker and the posts. For each: title, \
        sources (tracker or post, authors, dates), Nexus status, symptoms, setup given (game version, mod manager, \
        other mods, OS…), reproduction steps if any, information still missing to reproduce it, whether the author \
        already answered, likely cause or area of the mod to check, severity (critical, major, minor) and the next \
        action. Put open, unanswered and critical bugs first.
        2. Post audit. Classify every post: bug, feature request, question, compatibility, feedback. For each post \
        that needs action: author, date, one-line summary, whether the author answered, and a suggested reply.
        3. Feature requests, grouped, with who asked and how many people want each one.
        4. Action plan: what to fix or answer first, as an ordered list.
        5. Stats: one line.
        Messages marked [author] were written by the mod author: they are answers and context, not reports. \
        Skip empty sections, stay factual, quote the users' own words when useful and never invent details.
        """
    }

    /// Consigne et données réunies, à coller dans n'importe quel agent.
    static func prompt(_ m: ModState) -> String { instructions + "\n\n---\n\n" + markdown(m) }

    /// Consigne d'audit approfondi d'un seul rapport de bug.
    static var bugInstructions: String {
        """
        You audit one bug report of a Nexus Mods mod for its author, who must decide how to fix it. \
        Write in \(language), in Markdown, with these sections:
        1. Summary: the problem in two sentences.
        2. Environment: game version, mod version, mod manager, OS and hardware, other mods, as reported. Say what is missing.
        3. Reproduction: the steps as reported, then your best reconstruction, and whether it looks reproducible.
        4. Missing information: precise questions to ask the reporter (logs, crash files, load order, settings…).
        5. Likely causes: ranked hypotheses, each with what to check in the mod to confirm or rule it out.
        6. Duplicates and related reports among the other bugs and posts given.
        7. Severity (critical, major, minor) and next action.
        8. Suggested reply to the reporter, ready to post, in the reporter's language.
        Messages marked [author] were written by the mod author. Stay factual and never invent details.
        """
    }

    /// Un bug à auditer, suivi des autres rapports et des posts pour repérer les doublons.
    static func bugData(_ b: Bug, in m: ModState) -> String {
        var s = "# \(m.displayName)\n\n\(m.config.pageURL.absoluteString)?tab=bugs\n\n## Bug to audit\n"
        s += bugSection(b, m)
        let others = m.bugs.filter { $0.id != b.id }
        if !others.isEmpty {
            s += "\n## Other bug reports\n\n"
            s += others.map { "- \($0.title) — \($0.status) · \($0.replies) replies · last post \(L.date($0.lastPost))" }.joined(separator: "\n") + "\n"
        }
        s += postsSection(m)
        if let v = m.stats?.version { s += "\nCurrent mod version: \(v)\n" }
        return s
    }

    /// Plusieurs bugs à auditer : le contexte (autres bugs, posts) n'est donné qu'une fois.
    static func bugsData(_ bugs: [Bug], in m: ModState, totalOpen: Int) -> String {
        var s = "# \(m.displayName)\n\n\(m.config.pageURL.absoluteString)?tab=bugs\n"
        s += "\n## Bugs to audit (\(bugs.count) most recent of \(totalOpen) open)\n"
        for b in bugs { s += bugSection(b, m) }
        let others = m.bugs.filter { o in !bugs.contains { $0.id == o.id } }.sorted { $0.lastPost > $1.lastPost }
        if !others.isEmpty {
            s += "\n## Other bug reports (titles only, for duplicates)\n\n"
            s += others.prefix(150).map { "- \($0.title) — \($0.status)" }.joined(separator: "\n") + "\n"
            if others.count > 150 { s += "- … and \(others.count - 150) older reports\n" }
        }
        s += postsSection(m)
        if let v = m.stats?.version { s += "\nCurrent mod version: \(v)\n" }
        return s
    }

    static func markdown(_ m: ModState) -> String {
        func delta(_ k: KeyPath<Snapshot, Int>) -> String { m.delta(k).map { " (\($0 >= 0 ? "+" : "")\($0) in 24 h)" } ?? "" }

        var s = "# \(m.displayName)\n\n\(m.config.pageURL.absoluteString)\n"
        if let check = m.lastCheck { s += "\nLast check: \(L.date(check))\n" }

        s += "\n## Bug tracker (\(m.bugs.count) reports)\n"
        if !m.bugsEnabled { s += "\nThe bug tracker is disabled on this mod.\n" }
        for b in m.bugs { s += bugSection(b, m) }
        s += postsSection(m)

        if let st = m.stats {
            s += "\n## Stats (context)\n\n"
            s += "- Version: \(st.version)\(st.updatedAt.map { " (updated \(L.date($0)))" } ?? "")\n"
            s += "- Endorsements: \(st.endorsements)\(delta(\.endorsements)) · Downloads: \(st.downloads)\(delta(\.downloads))"
            s += " · Unique downloads: \(st.uniqueDownloads)\(delta(\.unique))\n"
            let quarantined = st.files.filter { $0.scan == "QUARANTINED" }
            if !quarantined.isEmpty { s += "- Files quarantined by the Nexus virus scan: \(quarantined.map(\.name).joined(separator: ", "))\n" }
        }
        return s
    }

    private static func who(_ name: String, _ m: ModState) -> String { m.isOwn(name) ? "\(name) [author]" : name }
    private static func quote(_ t: String) -> String { "> " + t.replacingOccurrences(of: "\n", with: "\n> ") }
    private static func answered(_ msgs: [Message], _ m: ModState) -> String { msgs.contains { m.isOwn($0.author) } ? "yes" : "no" }

    private static func bugSection(_ b: Bug, _ m: ModState) -> String {
        var s = "\n### \(b.title)\n\nStatus: \(b.status) · Priority: \(b.priority) · Version: \(b.version) · "
        s += "Replies: \(b.replies) · Last post: \(L.date(b.lastPost)) · Answered by author: \(answered(b.messages, m))\n"
        if b.messages.isEmpty { s += "\n(Messages not loaded yet.)\n" }
        for msg in b.messages { s += "\n\(who(msg.author, m)) — \(L.date(msg.date)):\n\n\(quote(msg.text))\n" }
        return s
    }

    /// Conclusions de Jev sur un post, pour orienter l'agent.
    private static func jevNote(_ p: Post, _ m: ModState) -> String {
        guard let t = m.postTags?[p.id] else { return "" }
        var parts: [String] = []
        if t.isBug { parts.append("likely bug report (\(Int((t.bug ?? 0) * 100)) %)") }
        if t.isFeature { parts.append("likely feature request (\(Int((t.feature ?? 0) * 100)) %)") }
        if let tracked = t.trackedAs { parts.append("same problem as tracker bug \"\(tracked)\"") }
        return parts.isEmpty ? "" : " · Jev: " + parts.joined(separator: ", ")
    }

    private static func postsSection(_ m: ModState) -> String {
        var s = "\n## Posts (\(m.posts.count) shown of \(m.postCount))\n"
        if !m.postsEnabled { s += "\nPosts are disabled on this mod.\n" }
        for p in m.posts {
            s += "\n### \(who(p.author, m)) — \(L.date(p.date))\(p.sticky ? " — sticky" : "") · Answered by author: \(answered(p.replies, m))\(jevNote(p, m))\n\n\(quote(p.text))\n"
            for r in p.replies { s += "\nReply from \(who(r.author, m)) — \(L.date(r.date)):\n\n\(quote(r.text))\n" }
        }
        return s
    }
}

// MARK: Appels API

enum AIClient {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func analyze(_ data: String, settings: AISettings, instructions: String = AIDigest.instructions) async throws -> String {
        var req: URLRequest
        let body: [String: Any]
        let model = settings.model.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { throw Failure(message: L.t("ai.error.nomodel")) }

        switch settings.method {
        case .anthropic:
            let key = Keychain.get("anthropic")
            guard !key.isEmpty else { throw Failure(message: L.t("ai.error.nokey")) }
            req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": model, "max_tokens": 8000, "system": instructions,
                    "messages": [["role": "user", "content": data]]]
        default:
            let base = settings.openAIURL.trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: base), url.scheme?.hasPrefix("http") == true
            else { throw Failure(message: L.t("ai.error.url")) }
            req = URLRequest(url: url.appendingPathComponent("chat/completions"))
            let key = Keychain.get("openai")
            if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            body = ["model": model, "messages": [["role": "system", "content": instructions],
                                                 ["role": "user", "content": data]]]
        }
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (d, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: d.prefix(300), as: UTF8.self)
            throw Failure(message: "HTTP \(code) : \(msg)")
        }
        let text: String? = settings.method == .anthropic
            ? (json["content"] as? [[String: Any]])?.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            : ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        guard let text, !text.isEmpty else { throw Failure(message: L.t("ai.error.empty")) }
        return text
    }
}

// MARK: Serveur MCP (lancé par l'agent avec « NexusWatch --mcp », dialogue JSON-RPC sur stdin/stdout)

enum MCPServer {
    static var executable: String { Bundle.main.executablePath ?? "/Applications/nEXUSWATCH.app/Contents/MacOS/NexusWatch" }
    static var configJSON: String {
        """
        {
          "mcpServers": {
            "nexuswatch": { "command": "\(executable)", "args": ["--mcp"] }
          }
        }
        """
    }
    static var claudeCommand: String { "claude mcp add nexuswatch -- \"\(executable)\" --mcp" }

    private static let tools: [[String: Any]] = [
        ["name": "list_mods",
         "description": "List the Nexus Mods pages watched in nEXUSWATCH, with unread posts and bugs and the last check date.",
         "inputSchema": ["type": "object", "properties": [String: Any]()]],
        ["name": "get_mod_report",
         "description": "Audit material for a watched mod: its bug tracker reports and community posts with every reply, "
             + "then the stats as context, preceded by the audit instructions (bugs first, then posts, feature requests, action plan).",
         "inputSchema": ["type": "object", "properties": [
            "mod": ["type": "string",
                    "description": "Mod to report on: id such as 'skyrimspecialedition/196272', numeric mod id or part of its name. All mods if omitted."]]]],
        ["name": "get_fix_prompt",
         "description": "Ready-to-use brief for the agent that will fix a watched mod: open bugs ranked by priority with the "
             + "players' messages, the expected method and the final report to write.",
         "inputSchema": ["type": "object", "properties": [
            "mod": ["type": "string",
                    "description": "Mod: id such as 'skyrimspecialedition/196272', numeric mod id or part of its name. All mods if omitted."]]]],
        ["name": "get_bug_reports",
         "description": "Bug reports of a watched mod to audit, with every message, the other posts for spotting duplicates, "
             + "and the bug audit instructions (environment, reproduction, missing information, likely causes, severity, reply).",
         "inputSchema": ["type": "object", "properties": [
            "mod": ["type": "string",
                    "description": "Mod: id such as 'skyrimspecialedition/196272', numeric mod id or part of its name. All mods if omitted."],
            "bug": ["type": "string", "description": "Part of a bug title. All open bugs if omitted."],
            "include_closed": ["type": "boolean", "description": "Also include fixed or closed bugs when no bug is named."],
            "limit": ["type": "integer", "description": "Maximum number of bugs per mod, most recent first (default 30)."]]]],
    ]

    static func run() {
        while let line = readLine() {
            guard let req = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let method = req["method"] as? String, let id = req["id"] else { continue }
            let params = req["params"] as? [String: Any] ?? [:]
            switch method {
            case "initialize":
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                reply(id, ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                           "capabilities": ["tools": [String: Any]()],
                           "serverInfo": ["name": "nexuswatch", "version": version],
                           "instructions": "Read-only access to the Nexus Mods pages watched in nEXUSWATCH. "
                               + "Data is refreshed by the nEXUSWATCH app, which must run to keep it up to date."])
            case "ping": reply(id, [:])
            case "tools/list": reply(id, ["tools": tools])
            case "tools/call":
                let (text, failed) = call(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:])
                reply(id, ["content": [["type": "text", "text": text]], "isError": failed])
            default:
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
            }
        }
    }

    private static func call(_ name: String, _ args: [String: Any]) -> (String, Bool) {
        let mods = Storage.load().mods
        switch name {
        case "list_mods":
            if mods.isEmpty { return ("No mod watched yet: add one in nEXUSWATCH.", false) }
            return (mods.map { m in
                "- \(m.id) — \(m.displayName): \(m.unreadPosts) unread posts, \(m.unreadBugs) unread bugs, "
                    + "last check \(m.lastCheck.map(L.date) ?? "never")"
            }.joined(separator: "\n"), false)
        case "get_mod_report", "get_bug_reports", "get_fix_prompt":
            let wanted = (args["mod"] as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            let picked = wanted.isEmpty ? mods : mods.filter {
                $0.id == wanted || String($0.config.modId) == wanted || $0.displayName.lowercased().contains(wanted)
            }
            if picked.isEmpty { return ("No watched mod matches '\(wanted)'. Call list_mods to see them.", true) }
            if name == "get_fix_prompt" { return (picked.map { LocalAudit.agentPrompt($0) }.joined(separator: "\n\n---\n\n"), false) }
            if name == "get_mod_report" {
                return (AIDigest.instructions + "\n\n---\n\n" + picked.map(AIDigest.markdown).joined(separator: "\n\n---\n\n"), false)
            }
            let title = (args["bug"] as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            let closed = args["include_closed"] as? Bool ?? false
            let limit = max(1, args["limit"] as? Int ?? 30)
            let parts: [String] = picked.compactMap { m in
                let open = m.bugs.filter { closed || !Store.isClosed($0) }
                let bugs = (title.isEmpty ? open : m.bugs.filter { $0.title.lowercased().contains(title) })
                    .sorted { $0.lastPost > $1.lastPost }.prefix(limit)
                if bugs.isEmpty { return nil }
                return bugs.count == 1 ? AIDigest.bugData(bugs[bugs.startIndex], in: m)
                    : AIDigest.bugsData(Array(bugs), in: m, totalOpen: open.count)
            }
            if parts.isEmpty { return (title.isEmpty ? "No open bug report on these mods." : "No bug title matches '\(title)'.", false) }
            return (AIDigest.bugInstructions + "\nAudit each bug below separately.\n\n---\n\n" + parts.joined(separator: "\n\n---\n\n"), false)
        default:
            return ("Unknown tool: \(name)", true)
        }
    }

    private static func reply(_ id: Any, _ result: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": result]) }

    private static func send(_ obj: [String: Any]) {
        guard var d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        d.append(0x0A)
        FileHandle.standardOutput.write(d)
    }
}
