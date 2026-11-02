// nEXUSWATCH — client REST Discord (v10), lecture seule et autonome (aucune dépendance au reste de l'appli).
// Robot officiel uniquement (« Authorization: Bot <jeton> »), jamais de passerelle ni d'écriture.
import Foundation

enum DiscordError: LocalizedError {
    case badToken          // 401 : jeton refusé ou révoqué
    case forbidden         // 403 : le robot n'a plus accès
    case notBot            // jeton valide mais ce n'est pas un robot
    case noContentIntent   // Message Content Intent désactivé
    case noGuild           // le robot n'est dans aucun serveur
    case http(Int)
    case network(String)

    /// Une erreur d'accès : inutile de réessayer tant que l'utilisateur n'a pas corrigé le jeton.
    var stops: Bool {
        switch self { case .badToken, .forbidden, .notBot: true; default: false }
    }
}

// MARK: Réponses de l'API

struct DiscordAuthor: Decodable { var id: String; var username: String?; var global_name: String?; var bot: Bool?
    var name: String { global_name ?? username ?? "—" } }
struct DiscordRawAttachment: Decodable { var id: String; var filename: String; var size: Int? }
struct DiscordRawMessage: Decodable {
    var id: String; var content: String?; var timestamp: String
    var author: DiscordAuthor; var attachments: [DiscordRawAttachment]?
}
struct DiscordRawTag: Decodable { var id: String; var name: String }
struct DiscordRawChannel: Decodable {
    var id: String; var type: Int; var name: String?; var available_tags: [DiscordRawTag]?
}
struct DiscordRawThread: Decodable {
    struct Meta: Decodable { var archived: Bool?; var locked: Bool?; var create_timestamp: String?; var archive_timestamp: String? }
    var id: String; var parent_id: String?; var name: String; var owner_id: String?
    var last_message_id: String?; var message_count: Int?; var applied_tags: [String]?
    var thread_metadata: Meta?
}
struct DiscordGuildRef: Decodable { var id: String; var name: String; var owner_id: String? }
private struct ThreadList: Decodable { var threads: [DiscordRawThread]; var has_more: Bool? }

// MARK: Client

struct DiscordClient {
    let token: String
    let version: String
    static let base = "https://discord.com/api/v10"
    static let forumType = 15

    /// Date d'un identifiant Discord (« snowflake »).
    static func date(of snowflake: String) -> Date {
        guard let n = UInt64(snowflake) else { return Date() }
        return Date(timeIntervalSince1970: Double((n >> 22) + 1_420_070_400_000) / 1000)
    }
    static func isoDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:], as: T.Type = T.self) async throws -> T {
        var comps = URLComponents(string: Self.base + path)!
        if !query.isEmpty { comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 30
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("DiscordBot (https://github.com/starbudweiser/nEXUSWATCH, \(version))", forHTTPHeaderField: "User-Agent")
        for attempt in 0..<3 {
            let data: Data, resp: URLResponse
            do { (data, resp) = try await URLSession.shared.data(for: req) }
            catch { throw DiscordError.network(error.localizedDescription) }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200..<300:
                do { return try JSONDecoder().decode(T.self, from: data) }
                catch { throw DiscordError.http(code) }
            case 401: throw DiscordError.badToken
            case 403: throw DiscordError.forbidden
            case 429 where attempt < 2:
                let wait = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 2
                try? await Task.sleep(nanoseconds: UInt64(min(max(wait, 0.5), 30) * 1_000_000_000))
            default: throw DiscordError.http(code)
            }
        }
        throw DiscordError.http(429)
    }

    /// Le jeton doit être celui d'un robot.
    func me() async throws -> DiscordAuthor {
        let u: DiscordAuthor = try await get("/users/@me")
        guard u.bot == true else { throw DiscordError.notBot }
        return u
    }

    /// Drapeau GATEWAY_MESSAGE_CONTENT_LIMITED (1 << 19) : sans lui, le texte des messages revient vide.
    func hasMessageContentIntent() async throws -> Bool {
        struct App: Decodable { var flags: Int? }
        let a: App = try await get("/applications/@me")
        return ((a.flags ?? 0) & (1 << 19)) != 0
    }

    func guilds() async throws -> [DiscordGuildRef] { try await get("/users/@me/guilds") }
    func guild(_ id: String) async throws -> DiscordGuildRef { try await get("/guilds/\(id)") }

    func forums(guild: String) async throws -> [DiscordRawChannel] {
        let all: [DiscordRawChannel] = try await get("/guilds/\(guild)/channels")
        return all.filter { $0.type == Self.forumType }
    }

    func activeThreads(guild: String) async throws -> [DiscordRawThread] {
        let l: ThreadList = try await get("/guilds/\(guild)/threads/active")
        return l.threads
    }

    /// Fils archivés d'un forum (première synchronisation) ; au plus `pages` pages de 100.
    func archivedThreads(forum: String, pages: Int = 3) async throws -> [DiscordRawThread] {
        var out: [DiscordRawThread] = []
        var before: String?
        for _ in 0..<pages {
            var q = ["limit": "100"]
            if let before { q["before"] = before }
            let l: ThreadList = try await get("/channels/\(forum)/threads/archived/public", q)
            out += l.threads
            guard l.has_more == true, let last = l.threads.last?.thread_metadata?.archive_timestamp else { break }
            before = last
        }
        return out
    }

    /// Messages d'un fil postérieurs à `after` (du plus ancien au plus récent), 500 au plus.
    func messages(thread: String, after: String?) async throws -> [DiscordRawMessage] {
        var out: [DiscordRawMessage] = []
        var cursor = after ?? "0"
        for _ in 0..<5 {
            let page: [DiscordRawMessage] = try await get("/channels/\(thread)/messages", ["limit": "100", "after": cursor])
            let sorted = page.sorted { (UInt64($0.id) ?? 0) < (UInt64($1.id) ?? 0) }
            out += sorted
            guard page.count == 100, let last = sorted.last else { break }
            cursor = last.id
        }
        return out
    }
}
