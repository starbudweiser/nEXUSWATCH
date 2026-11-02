// nEXUSWATCH — module Discord (lecture seule) : état local, synchronisation, non-lus, notification discrète.
// L'état vit dans `discord.json`, à part de `state.json` ; le jeton du robot reste dans le Trousseau (compte « discord »).
import AppKit
import UserNotifications

struct DiscordForum: Codable, Identifiable {
    var id, name: String
    var tags: [String: String] = [:]
    var enabled = true
    var archivedSynced = false
}

struct DiscordFile: Codable, Hashable {
    var name: String
    var size: Int
}

struct DiscordMessage: Codable, Identifiable {
    var id, authorId, author: String
    var isBot: Bool
    var date: Date
    var text: String
    var files: [DiscordFile]
}

struct DiscordThread: Codable, Identifiable {
    var id, forumId, title, authorId, author: String
    var created: Date
    var lastMessageId: String
    var tagIds: [String]
    var archived, locked: Bool
    var messages: [DiscordMessage]
    var lastActivity: Date { messages.last?.date ?? created }
}

struct DiscordState: Codable {
    var applicationId = ""
    var guildId = "", guildName = "", ownerId = ""
    var forums: [DiscordForum] = []
    var threads: [DiscordThread] = []
    var seen: Set<String> = []
    var lastCheck: Date?

    func forum(_ t: DiscordThread) -> DiscordForum? { forums.first { $0.id == t.forumId } }
    func tagNames(_ t: DiscordThread) -> [String] {
        let f = forum(t)
        return t.tagIds.compactMap { f?.tags[$0] }
    }

    // MARK: Non lus

    func keys(_ t: DiscordThread) -> [String] { ["d:\(t.id)"] + t.messages.map { "m:\($0.id)" } }
    func isUnread(_ t: DiscordThread) -> Bool { keys(t).contains { !seen.contains($0) } }
    func isUnread(_ m: DiscordMessage) -> Bool { !seen.contains("m:\(m.id)") }
    var unreadKeys: Set<String> { Set(threads.flatMap(keys)).subtracting(seen) }
    var unreadThreads: Int { threads.filter(isUnread).count }

    mutating func markRead(_ t: DiscordThread) { seen.formUnion(keys(t)) }
    mutating func markAllRead() { seen.formUnion(unreadKeys) }

    /// Ce que le propriétaire du serveur écrit lui-même n'est jamais « non lu ».
    mutating func markOwnAsRead() {
        guard !ownerId.isEmpty else { return }
        for t in threads {
            if t.authorId == ownerId { seen.insert("d:\(t.id)") }
            t.messages.filter { $0.authorId == ownerId }.forEach { seen.insert("m:\($0.id)") }
        }
    }

    // MARK: Réponse du support

    func isResolved(_ t: DiscordThread) -> Bool {
        tagNames(t).contains { n in ["solved", "resolved", "résolu", "resuelto", "risolto"].contains { n.lowercased().contains($0) } }
    }
    func supportReplied(_ t: DiscordThread) -> Bool { !ownerId.isEmpty && t.messages.contains { $0.authorId == ownerId } }
    /// Fil ouvert par quelqu'un d'autre, sans aucune réponse du propriétaire, ni résolu ni verrouillé.
    func awaitingSupport(_ t: DiscordThread) -> Bool {
        !ownerId.isEmpty && !t.archived && !t.locked && t.authorId != ownerId && !supportReplied(t) && !isResolved(t)
    }
    var awaiting: [DiscordThread] { threads.filter(awaitingSupport) }
    var enabledThreads: [DiscordThread] { threads.filter { t in forum(t)?.enabled ?? true } }
}

enum DiscordStorage {
    static let url: URL = Storage.url.deletingLastPathComponent().appendingPathComponent("discord.json")

    static func load() -> DiscordState {
        guard let data = try? Data(contentsOf: url) else { return DiscordState() }
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        return (try? d.decode(DiscordState.self, from: data)) ?? DiscordState()
    }

    static func save(_ s: DiscordState) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970
        if let data = try? e.encode(s) { try? data.write(to: url, options: .atomic) }
    }
}

struct DiscordCheck: Identifiable {
    let id = UUID()
    let ok: Bool
    let text: String
}

// MARK: Synchronisation

extension Store {
    static let discordID = "discord"
    nonisolated static let discordPermissions = 66560   // View Channel + Read Message History
    nonisolated static let purgeDays = 90.0

    /// Module visible seulement quand un jeton est enregistré.
    var discordVisible: Bool { hasDiscordToken }
    var showDiscord: Bool { discordVisible && data.selected == Self.discordID }
    var discordUnread: Int { discordVisible ? discord.unreadThreads : 0 }

    static func inviteURL(_ applicationId: String) -> URL? {
        let id = applicationId.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
        return URL(string: "https://discord.com/oauth2/authorize?client_id=\(id)&scope=bot&permissions=\(discordPermissions)")
    }

    func selectDiscord() { data.selected = Self.discordID; save() }

    func saveDiscord() { DiscordStorage.save(discord) }

    /// Enregistre l'Application ID et, s'il est fourni, le nouveau jeton (vide = on garde l'ancien).
    func updateDiscord(applicationId: String, newToken: String) {
        discord.applicationId = applicationId.trimmingCharacters(in: .whitespaces)
        if !newToken.isEmpty { Keychain.set(newToken.trimmingCharacters(in: .whitespacesAndNewlines), "discord") }
        hasDiscordToken = !Keychain.get("discord").isEmpty
        if !newToken.isEmpty { discordError = nil }
        saveDiscord()
        if hasDiscordToken { Task { await refreshDiscord() } }
    }

    /// Retire le jeton et toutes les données Discord de ce Mac.
    func removeDiscord() {
        Keychain.set("", "discord")
        hasDiscordToken = false
        discord = DiscordState(applicationId: discord.applicationId)
        discordError = nil
        if data.selected == Self.discordID { data.selected = data.mods.first?.id }
        saveDiscord(); save(); updateBadge()
    }

    func setForum(_ id: String, enabled: Bool) {
        guard let i = discord.forums.firstIndex(where: { $0.id == id }) else { return }
        discord.forums[i].enabled = enabled
        saveDiscord()
    }

    func markRead(_ t: DiscordThread) {
        guard discord.isUnread(t) else { return }
        discord.markRead(t); saveDiscord(); updateBadge()
    }
    func markAllDiscordRead() { discord.markAllRead(); saveDiscord(); updateBadge() }

    func discordMessage(_ error: Error) -> String {
        switch error as? DiscordError {
        case .badToken: return L.t("discord.err.token")
        case .forbidden: return L.t("discord.err.forbidden")
        case .notBot: return L.t("discord.err.notbot")
        case .noContentIntent: return L.t("discord.err.intent")
        case .noGuild: return L.t("discord.err.noguild")
        case .http(let c): return L.t("discord.err.http", c)
        case .network(let m): return L.t("discord.err.network", m)
        case nil: return error.localizedDescription
        }
    }

    private var discordClient: DiscordClient? {
        let token = Keychain.get("discord")
        guard !token.isEmpty else { return nil }
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        return DiscordClient(token: token, version: v)
    }

    func refreshDiscord() async {
        guard hasDiscordToken, !discordBusy, let client = discordClient else { return }
        discordBusy = true
        defer { discordBusy = false }
        let firstLoad = discord.lastCheck == nil
        let before = discord.unreadKeys
        do {
            try await syncDiscord(client)
            discord.lastCheck = Date()
            discordError = nil
        } catch {
            discordError = discordMessage(error)
        }
        discord.markOwnAsRead()
        saveDiscord(); updateBadge()
        if !firstLoad, data.notifications { notifyDiscord(discord.unreadKeys.subtracting(before)) }
    }

    /// Premier serveur où le robot est invité (il n'est normalement que dans un seul).
    private func discoverGuild(_ c: DiscordClient) async throws {
        guard let g = try await c.guilds().first else { throw DiscordError.noGuild }
        if g.id != discord.guildId { discord = DiscordState(applicationId: discord.applicationId, guildId: g.id, guildName: g.name) }
    }

    private func mergeForums(_ raw: [DiscordRawChannel]) {
        let old = Dictionary(discord.forums.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        discord.forums = raw.map { r in
            var f = old[r.id] ?? DiscordForum(id: r.id, name: r.name ?? r.id)
            f.name = r.name ?? f.name
            f.tags = Dictionary((r.available_tags ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            return f
        }
    }

    private func syncDiscord(_ c: DiscordClient) async throws {
        if discord.guildId.isEmpty { try await discoverGuild(c) }
        let g = try await c.guild(discord.guildId)
        discord.guildName = g.name
        discord.ownerId = g.owner_id ?? ""
        mergeForums(try await c.forums(guild: discord.guildId))

        let enabled = Set(discord.forums.filter(\.enabled).map(\.id))
        var incoming = try await c.activeThreads(guild: discord.guildId).filter { $0.parent_id.map(enabled.contains) ?? false }
        for i in discord.forums.indices where discord.forums[i].enabled && !discord.forums[i].archivedSynced {
            incoming += try await c.archivedThreads(forum: discord.forums[i].id)
                .filter { $0.parent_id == discord.forums[i].id }
            discord.forums[i].archivedSynced = true
        }
        var seenIds = Set<String>()
        incoming = incoming.filter { seenIds.insert($0.id).inserted }

        // Les fils connus qui ne sont plus actifs ont été archivés depuis.
        let activeIds = Set(incoming.map(\.id))
        for i in discord.threads.indices where !activeIds.contains(discord.threads[i].id) { discord.threads[i].archived = true }

        var fetched = 0
        for raw in incoming {
            let known = discord.threads.firstIndex { $0.id == raw.id }
            let last = raw.last_message_id ?? raw.id
            let cursor = known.flatMap { discord.threads[$0].messages.last?.id }
            let needs = known == nil || cursor != last
            var thread = known.map { discord.threads[$0] } ?? DiscordThread(
                id: raw.id, forumId: raw.parent_id ?? "", title: raw.name, authorId: raw.owner_id ?? "", author: "—",
                created: DiscordClient.isoDate(raw.thread_metadata?.create_timestamp) ?? DiscordClient.date(of: raw.id),
                lastMessageId: last, tagIds: [], archived: false, locked: false, messages: [])
            thread.title = raw.name
            thread.tagIds = raw.applied_tags ?? []
            thread.archived = raw.thread_metadata?.archived ?? false
            thread.locked = raw.thread_metadata?.locked ?? false
            thread.lastMessageId = last
            if needs, fetched < 60 {
                fetched += 1
                let msgs = try await c.messages(thread: raw.id, after: cursor)
                thread.messages += msgs.map(Self.convert)
                if thread.messages.first?.id == thread.id, let first = thread.messages.first {
                    thread.author = first.author; thread.authorId = first.authorId
                }
            } else if needs, known == nil {
                continue   // plafond atteint : ce fil sera lu au prochain cycle
            }
            if let known { discord.threads[known] = thread } else { discord.threads.append(thread) }
        }

        let limit = Date().addingTimeInterval(-Self.purgeDays * 86_400)
        discord.threads.removeAll { $0.archived && $0.lastActivity < limit }
        discord.threads.sort { $0.lastActivity > $1.lastActivity }
    }

    nonisolated private static func convert(_ m: DiscordRawMessage) -> DiscordMessage {
        DiscordMessage(id: m.id, authorId: m.author.id, author: m.author.name, isBot: m.author.bot == true,
                       date: DiscordClient.isoDate(m.timestamp) ?? DiscordClient.date(of: m.id),
                       text: String((m.content ?? "").prefix(4000)),
                       files: (m.attachments ?? []).map { DiscordFile(name: $0.filename, size: $0.size ?? 0) })
    }

    // MARK: Test de connexion

    /// Vérifie le jeton (celui saisi, sinon l'enregistré), l'intention de contenu, le serveur et les forums.
    func testDiscord(token typed: String) async -> [DiscordCheck] {
        let token = typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Keychain.get("discord")
            : typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return [DiscordCheck(ok: false, text: L.t("discord.test.notoken"))] }
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        let c = DiscordClient(token: token, version: v)
        var out: [DiscordCheck] = []
        do {
            let me = try await c.me()
            out.append(DiscordCheck(ok: true, text: L.t("discord.test.bot", me.name)))
            guard try await c.hasMessageContentIntent() else { throw DiscordError.noContentIntent }
            out.append(DiscordCheck(ok: true, text: L.t("discord.test.intent")))
            guard let g = try await c.guilds().first else { throw DiscordError.noGuild }
            if g.id != discord.guildId { discord = DiscordState(applicationId: discord.applicationId, guildId: g.id, guildName: g.name) }
            discord.guildName = g.name
            out.append(DiscordCheck(ok: true, text: L.t("discord.test.guild", g.name)))
            let forums = try await c.forums(guild: g.id)
            mergeForums(forums)
            saveDiscord()
            out.append(DiscordCheck(ok: !forums.isEmpty, text: L.t(forums.isEmpty ? "discord.test.noforum" : "discord.test.forums", forums.count)))
        } catch {
            out.append(DiscordCheck(ok: false, text: discordMessage(error)))
        }
        return out
    }

    // MARK: Notification récapitulative

    private func notifyDiscord(_ keys: Set<String>) {
        let newThreads = Set(keys.filter { $0.hasPrefix("d:") }.map { String($0.dropFirst(2)) })
        var replies = 0
        for t in discord.threads where !newThreads.contains(t.id) {
            replies += t.messages.filter { keys.contains("m:\($0.id)") }.count
        }
        var lines: [String] = []
        if !newThreads.isEmpty { lines.append(L.t("discord.notif.threads", newThreads.count)) }
        if replies > 0 { lines.append(L.t("discord.notif.replies", replies)) }
        guard !lines.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = L.t("discord.notif.title", discord.guildName)
        content.body = lines.joined(separator: " · ")
        content.interruptionLevel = .passive   // discrète : sans son, sans interrompre
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
