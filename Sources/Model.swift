// nEXUSWATCH — données suivies et état local (lu / suivi des bugs / historique des stats).
import Foundation

struct ModConfig: Codable, Equatable {
    var domain = "skyrimspecialedition"
    var modId = 0
    var id: String { "\(domain)/\(modId)" }
    var pageURL: URL { URL(string: "https://www.nexusmods.com/\(domain)/mods/\(modId)")! }

    /// Accepte une URL de page Nexus ou un simple identifiant.
    mutating func parse(_ input: String) -> Bool {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = Int(s) { modId = id; return true }
        // www., next. ou sans sous-domaine ; ancien format /<jeu>/mods/<id> ou nouveau /games/<jeu>/mods/<id>
        guard let r = s.range(of: #"nexusmods\.com/(games/)?[a-z0-9]+/mods/\d+"#, options: [.regularExpression, .caseInsensitive])
        else { return false }
        let parts = s[r].lowercased().split(separator: "/").filter { $0 != "games" }
        guard parts.count >= 4, let id = Int(parts[3]) else { return false }
        domain = String(parts[1]); modId = id
        return true
    }
}

struct ModFileStat: Codable, Identifiable {
    var id: Int
    var name, version, category, scan: String
    var total, unique: Int
    var date: Date
}

struct ModStats: Codable {
    var name = "", version = "", author = "", status = ""
    var gameId = 0, endorsements = 0, downloads = 0
    var updatedAt: Date?
    var files: [ModFileStat] = []
    var uniqueDownloads: Int { files.reduce(0) { $0 + $1.unique } }
}

struct Message: Codable, Identifiable, Hashable {
    var id: String
    var author: String
    var role: String
    var date: Date
    var text: String
}

struct Post: Codable, Identifiable {
    var id: String
    var author, role, text: String
    var date: Date
    var sticky: Bool
    var replies: [Message]
    var lastActivity: Date { replies.map(\.date).max().map { max($0, date) } ?? date }
}

struct Bug: Codable, Identifiable {
    var id: String
    var title, status, priority, version: String
    var replies: Int
    var lastPost: Date
    var messages: [Message]
    /// Change quand le bug reçoit une réponse : sert à le remettre en « non lu ».
    var signature: String { "\(replies):\(Int(lastPost.timeIntervalSince1970))" }
}

/// Suivi local d'un bug, indépendant du statut affiché sur Nexus.
enum Follow: String, Codable, CaseIterable, Identifiable {
    case triage, reproduce, testing, fixed, released
    var id: String { rawValue }
}

struct Snapshot: Codable {
    var date: Date
    var endorsements, downloads, unique: Int
}

/// État d'un mod suivi.
struct ModState: Codable, Identifiable {
    var config = ModConfig()
    var id: String { config.id }
    var stats: ModStats?
    var posts: [Post] = []
    var postCount = 0
    var postsEnabled = true
    var bugs: [Bug] = []
    var bugsEnabled = true
    var seen: Set<String> = []
    var follow: [String: Follow] = [:]
    var notes: [String: String] = [:]
    var history: [Snapshot] = []
    var lastCheck: Date?
    var aiReport: AIReport?
    /// Audits IA par bug (identifiant du bug → rapport).
    var bugAudits: [String: AIReport]?
    /// Tri des posts par Jev (identifiant du post → conclusions).
    var postTags: [String: PostTag]?
}

/// Dernier rapport produit par l'agent IA pour un mod.
struct AIReport: Codable {
    var text: String
    var date: Date
    var model: String
}

/// Ensemble de l'état enregistré : mods suivis et réglages communs.
struct AppData: Codable {
    var mods: [ModState] = []
    var selected: String?
    var intervalMinutes = 15
    var notifications = true
    var ai: AISettings?
    /// Réponses de Jev déjà obtenues (empreinte de la question → probabilité « oui »).
    var jevCache: [String: Double]?
}

/// Ancien format (un seul mod, réglages dans la config) : lu une fois pour migrer.
private struct LegacyData: Decodable {
    struct Config: Decodable { var intervalMinutes: Int; var notifications: Bool }
    var config: Config
}

enum Storage {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nEXUSWATCH", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }()

    static func load() -> AppData {
        guard let data = try? Data(contentsOf: url) else { return AppData() }
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        if let app = try? d.decode(AppData.self, from: data) { return app }
        guard let mod = try? d.decode(ModState.self, from: data), let legacy = try? d.decode(LegacyData.self, from: data)
        else { return AppData() }
        return AppData(mods: [mod], selected: mod.id,
                       intervalMinutes: legacy.config.intervalMinutes, notifications: legacy.config.notifications)
    }

    static func save(_ p: AppData) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970
        if let data = try? e.encode(p) { try? data.write(to: url, options: .atomic) }
    }
}
