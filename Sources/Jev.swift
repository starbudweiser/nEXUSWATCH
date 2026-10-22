// nEXUSWATCH — tri des posts par Jev (TypeSafe, https://docs.typesafe.ai) : questions oui/non avec probabilité.
// Rapport de bug ? demande de fonction ? déjà dans le tracker ? Réponses mises en cache ; toute panne ramène au tri sans Jev.
import CryptoKit
import Foundation

/// Ce que Jev a conclu d'un post.
struct PostTag: Codable, Equatable {
    var bug: Double?
    var feature: Double?
    /// Bug du tracker qui décrit le même problème.
    var trackedAs: String?

    var isBug: Bool { (bug ?? 0) >= Jev.keep }
    var isFeature: Bool { (feature ?? 0) >= Jev.keep }
}

enum Jev {
    static let keep = 0.7
    private static let url = URL(string: "https://api.typesafe.ai/v1/systemone")!
    private static let model = "jev-latest"
    private static let batch = 10, excerpt = 1500, recentBugs = 25, maxPairs = 400

    private static let bugCriteria = [
        "true": "The message reports something in the mod that does not work as expected: crash, error, broken or missing "
            + "behaviour, conflict, installation or performance problem.",
        "false": "Question, thanks, opinion, feature request or discussion, without describing a malfunction."]
    private static let featureCriteria = [
        "true": "The message asks for something the mod does not do yet: a new feature, an option, a change or support for "
            + "another game, tool or setup.",
        "false": "No request for something new: bug report, question, thanks or discussion."]
    private static let sameCriteria = [
        "true": "Both describe the same malfunction: same symptom in the same part of the mod, even with other words or setups.",
        "false": "Different problems, or only a vague resemblance."]

    struct Question {
        let id: String
        let criteria: [String: String]
        let items: [String: [String: String]]
        let instructions: String
    }

    /// Classe les posts d'un mod ; `nil` si Jev n'a rien pu dire (clé absente, panne).
    static func tags(for m: ModState, apiKey: String, cache: inout [String: Double]) async -> [String: PostTag]? {
        let posts = m.posts.filter { !m.isOwn($0.author) }
        guard !posts.isEmpty else { return [:] }
        func text(_ p: Post) -> String {
            String(([p.text] + p.replies.filter { $0.author == p.author }.map(\.text)).joined(separator: "\n").prefix(excerpt))
        }
        func item(_ p: Post) -> [String: [String: String]] { ["p\(p.id)": ["author": p.author, "text": text(p)]] }

        var asked: [Question] = []
        for p in posts {
            asked.append(Question(id: hash("bug", text(p)), criteria: bugCriteria, items: item(p),
                                  instructions: "Is the message `reports.p\(p.id)` a bug report about the mod?"))
            asked.append(Question(id: hash("feature", text(p)), criteria: featureCriteria, items: item(p),
                                  instructions: "Is the message `reports.p\(p.id)` a feature request for the mod?"))
        }
        guard var scores = await ask(asked, apiKey: apiKey, cache: &cache) else { return nil }

        var tags: [String: PostTag] = [:]
        for p in posts {
            tags[p.id] = PostTag(bug: scores[hash("bug", text(p))], feature: scores[hash("feature", text(p))])
        }

        // Bugs signalés dans les posts : sont-ils déjà dans le tracker ? Comparés aux bugs ouverts les plus récents,
        // là où se trouvent les doublons ; les plus récents des posts passent d'abord.
        let bugPosts = posts.filter { tags[$0.id]?.isBug == true }.sorted { $0.lastActivity > $1.lastActivity }
        let candidates = m.bugs.filter { !Store.isClosed($0) }.sorted { $0.lastPost > $1.lastPost }.prefix(recentBugs)
        var pairs: [(post: Post, bug: Bug, id: String)] = []
        for p in bugPosts {
            for b in candidates {
                let report = b.title + "\n" + (b.messages.first?.text ?? "")
                pairs.append((p, b, hash("same", text(p), String(report.prefix(excerpt)))))
            }
        }
        pairs = Array(pairs.prefix(maxPairs))
        if !pairs.isEmpty {
            let questions = pairs.map { pair in
                let report = pair.bug.title + "\n" + (pair.bug.messages.first?.text ?? "")
                return Question(id: pair.id, criteria: sameCriteria,
                                items: item(pair.post).merging(["b\(pair.bug.id)": ["title": pair.bug.title,
                                                                                     "text": String(report.prefix(excerpt))]]) { a, _ in a },
                                instructions: "Do the post `reports.p\(pair.post.id)` and the tracker bug `reports.b\(pair.bug.id)` "
                                    + "describe the same problem?")
            }
            if let same = await ask(questions, apiKey: apiKey, cache: &cache) { scores.merge(same) { a, _ in a } }
            for p in bugPosts {
                let best = pairs.filter { $0.post.id == p.id }.compactMap { pair in scores[pair.id].map { (pair.bug, $0) } }
                    .max { $0.1 < $1.1 }
                if let best, best.1 >= keep { tags[p.id]?.trackedAs = best.0.title }
            }
        }
        return tags
    }

    /// Pose les questions absentes du cache, par lots ; `nil` si l'API n'a répondu à aucun lot.
    static func ask(_ questions: [Question], apiKey: String, cache: inout [String: Double]) async -> [String: Double]? {
        var found: [String: Double] = [:]
        for q in questions { if let v = cache[q.id] { found[q.id] = v } }
        let todo = questions.filter { cache[$0.id] == nil }
        var failed = false
        for start in stride(from: 0, to: todo.count, by: batch) {
            let chunk = Array(todo[start..<min(start + batch, todo.count)])
            var items: [String: [String: String]] = [:]
            chunk.forEach { items.merge($0.items) { a, _ in a } }
            var qs: [String: Any] = [:]
            for (i, q) in chunk.enumerated() {
                qs["q\(i)"] = ["type": "noul", "criteria": q.criteria, "instructions": q.instructions]
            }
            guard let answers = try? await post(["model": model, "state": ["reports": items], "questions": qs], apiKey: apiKey)
            else { failed = true; break }
            for (i, q) in chunk.enumerated() {
                if let v = (answers["q\(i)"] as? [String: Any])?["noul"] as? Double { found[q.id] = v; cache[q.id] = v }
            }
        }
        return failed && found.isEmpty ? nil : found
    }

    /// POST avec reprise espacée sur 429/529 (limite de débit, surcharge).
    private static func post(_ body: [String: Any], apiKey: String) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        for attempt in 0..<3 {
            let (d, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if [429, 529].contains(code), attempt < 2 {
                try await Task.sleep(nanoseconds: UInt64(1 << attempt) * 2_000_000_000)
                continue
            }
            guard code == 200, let json = try JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let answers = json["answers"] as? [String: Any] else { throw URLError(.badServerResponse) }
            return answers
        }
        throw URLError(.badServerResponse)
    }

    private static func hash(_ parts: String...) -> String {
        Insecure.SHA1.hash(data: Data(([model] + parts).joined(separator: "\u{1f}").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
