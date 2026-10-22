// nEXUSWATCH — état de l'appli : mods suivis, actualisation périodique, non lus, notifications, badge du Dock.
import AppKit
import UserNotifications

@MainActor
final class Store: ObservableObject {
    @Published var data = Storage.load()
    /// Identifiant du mod en cours de vérification (une seule à la fois : le lecteur de page est partagé).
    @Published var refreshing: String?
    @Published var errors: [String: String] = [:]
    /// Identifiant du mod en cours d'analyse par l'agent IA.
    @Published var analyzing: String?
    @Published var aiErrors: [String: String] = [:]
    let fetcher = NexusFetcher()
    private var timer: Timer?
    private var queue: [String] = []

    init() {
        schedule()
        if data.notifications { requestNotifications() }
        updateBadge()
    }

    // MARK: Mods suivis

    private var selectedIndex: Int? {
        data.mods.firstIndex { $0.id == data.selected } ?? (data.mods.isEmpty ? nil : 0)
    }

    /// Mod affiché ; les vues lisent et modifient son état par ce raccourci.
    var state: ModState {
        get { selectedIndex.map { data.mods[$0] } ?? ModState() }
        set { if let i = selectedIndex { data.mods[i] = newValue } }
    }
    var config: ModConfig { state.config }
    var hasMods: Bool { !data.mods.isEmpty }
    var loading: Bool { refreshing != nil && refreshing == state.id }
    var busy: Bool { refreshing != nil }
    var error: String? { errors[state.id] }

    func select(_ id: String) { data.selected = id; save() }

    /// Ajoute un mod à partir d'une URL ou d'un identifiant ; renvoie un message d'erreur sinon.
    func addMod(_ input: String) -> String? {
        var c = ModConfig()
        if let current = hasMods ? config : nil { c.domain = current.domain }
        guard c.parse(input) else { return L.t("settings.mod.invalid") }
        guard !data.mods.contains(where: { $0.id == c.id }) else { return L.t("mods.duplicate") }
        data.mods.append(ModState(config: c))
        data.selected = c.id
        save()
        Task { await refresh([c.id]) }
        return nil
    }

    func removeMod(_ id: String) {
        data.mods.removeAll { $0.id == id }
        errors[id] = nil; aiErrors[id] = nil
        if data.selected == id { data.selected = data.mods.first?.id }
        save(); updateBadge()
    }

    func updateSettings(interval: Int, notifications: Bool) {
        data.intervalMinutes = interval; data.notifications = notifications
        if notifications { requestNotifications() }
        save(); schedule()
    }

    var ai: AISettings { data.ai ?? AISettings() }

    func updateAI(_ s: AISettings, openAIKey: String, anthropicKey: String) {
        data.ai = s
        Keychain.set(openAIKey, "openai")
        Keychain.set(anthropicKey, "anthropic")
        save()
    }

    func schedule() {
        timer?.invalidate()
        let interval = Double(max(5, data.intervalMinutes)) * 60
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.refreshAll() }
        }
    }

    private func update(_ id: String, _ change: (inout ModState) -> Void) {
        guard let i = data.mods.firstIndex(where: { $0.id == id }) else { return }
        change(&data.mods[i])
    }

    // MARK: Actualisation

    func refreshAll() async { await refresh(data.mods.map(\.id)) }
    func refreshCurrent() async { if hasMods { await refresh([state.id]) } }

    /// Met les mods en file : la page de chaque mod est lue l'un après l'autre.
    func refresh(_ ids: [String]) async {
        queue += ids.filter { !queue.contains($0) && $0 != refreshing }
        guard refreshing == nil else { return }
        while !queue.isEmpty {
            let id = queue.removeFirst()
            refreshing = id
            await refreshMod(id)
            updateBadge()
        }
        refreshing = nil
    }

    private func refreshMod(_ id: String) async {
        guard let mod = data.mods.first(where: { $0.id == id }) else { return }
        let cfg = mod.config
        let firstLoad = mod.lastCheck == nil
        let before = mod.unreadKeys
        var failure: String?

        do {
            let stats = try await fetcher.stats(cfg)
            update(id) { $0.stats = stats; $0.recordHistory(stats) }
        } catch {
            failure = error.localizedDescription
        }

        do {
            let bugs = data.mods.first { $0.id == id }?.bugs ?? []
            let known = Dictionary(bugs.filter { !$0.messages.isEmpty }.map { ($0.id, $0.signature) },
                                   uniquingKeysWith: { a, _ in a })
            let gameId = data.mods.first { $0.id == id }?.stats?.gameId ?? 0
            let page = try await fetcher.page(cfg, gameId: gameId, knownBugs: known)
            update(id) { m in
                let old = Dictionary(m.bugs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                m.bugs = page.bugs.map { b in
                    var b = b
                    if !page.freshBugs.contains(b.id), let o = old[b.id] { b.messages = o.messages }
                    return b
                }
                m.posts = page.posts.sorted { ($0.sticky ? 1 : 0, $0.lastActivity) > ($1.sticky ? 1 : 0, $1.lastActivity) }
                m.postCount = page.postCount
                m.postsEnabled = page.postsEnabled
                m.bugsEnabled = page.bugsEnabled
                m.lastCheck = Date()
                m.markOwnAsRead()
            }
        } catch {
            failure = error.localizedDescription
        }
        errors[id] = failure
        save()

        guard let after = data.mods.first(where: { $0.id == id }) else { return }
        let added = after.unreadKeys.subtracting(before)
        if !firstLoad, !added.isEmpty, data.notifications { notify(added, mod: after) }
        // Un nouveau bug, un bug relancé ou un nouveau post relance l'audit.
        if !firstLoad, ai.enabled, ai.auto, ai.method.usesAPI, !added.isEmpty {
            Task { await analyze(id, notifyWhenDone: true) }
        }
    }

    // MARK: Agent IA

    func bugAudit(_ b: Bug) -> AIReport? { state.bugAudits?[b.id] }
    func auditKey(_ b: Bug) -> String { "\(state.id)#\(b.id)" }

    /// Audit approfondi d'un seul bug, gardé avec le mod.
    func audit(_ b: Bug) async {
        let id = state.id, key = auditKey(b), settings = ai
        guard analyzing == nil, let mod = data.mods.first(where: { $0.id == id }) else { return }
        analyzing = key; aiErrors[key] = nil
        defer { analyzing = nil }
        do {
            let text = try await AIClient.analyze(AIDigest.bugData(b, in: mod), settings: settings, instructions: AIDigest.bugInstructions)
            update(id) { m in
                var audits = m.bugAudits ?? [:]
                audits[b.id] = AIReport(text: text, date: Date(), model: settings.model)
                m.bugAudits = audits
            }
            save()
        } catch {
            aiErrors[key] = error.localizedDescription
        }
    }

    /// Envoie les données du mod à l'API choisie et garde le rapport obtenu.
    func analyze(_ id: String, notifyWhenDone: Bool = false) async {
        guard analyzing == nil, let mod = data.mods.first(where: { $0.id == id }) else { return }
        let settings = ai
        analyzing = id; aiErrors[id] = nil
        defer { analyzing = nil }
        do {
            let text = try await AIClient.analyze(AIDigest.markdown(mod), settings: settings)
            update(id) { $0.aiReport = AIReport(text: text, date: Date(), model: settings.model) }
            save()
            if notifyWhenDone, data.notifications {
                let content = UNMutableNotificationContent()
                content.title = L.t("ai.notif")
                content.body = mod.displayName
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil), withCompletionHandler: nil)
            }
        } catch {
            aiErrors[id] = error.localizedDescription
        }
    }

    /// Progression sur environ 24 h du mod affiché.
    func delta(_ value: KeyPath<Snapshot, Int>) -> Int? { state.delta(value) }

    // MARK: Non lus (mod affiché)

    func isUnread(_ p: Post) -> Bool { state.isUnread(p) }
    func isUnread(_ r: Message) -> Bool { state.isUnread(r) }
    func isUnread(_ b: Bug) -> Bool { state.isUnread(b) }
    func isOwnMessage(_ m: Message) -> Bool { state.isOwn(m.author) }
    func isOwnPost(_ p: Post) -> Bool { state.isOwn(p.author) }

    var unreadPosts: Int { state.unreadPosts }
    var unreadBugs: Int { state.unreadBugs }
    var openBugs: Int { state.bugs.filter { !Self.isClosed($0) }.count }

    func markRead(_ p: Post) {
        guard isUnread(p) else { return }
        state.seen.insert("p:\(p.id)")
        p.replies.forEach { state.seen.insert("r:\($0.id)") }
        save(); updateBadge()
    }

    func markRead(_ b: Bug) {
        guard isUnread(b) else { return }
        state.seen.insert(state.key(b)); save(); updateBadge()
    }

    func markAllRead() {
        state.seen.formUnion(state.unreadKeys)
        save(); updateBadge()
    }

    // MARK: Suivi local des bugs

    func follow(_ b: Bug) -> Follow { state.follow[b.id] ?? .triage }
    func setFollow(_ f: Follow, for b: Bug) { state.follow[b.id] = f; save() }
    func note(_ b: Bug) -> String { state.notes[b.id] ?? "" }
    func setNote(_ n: String, for b: Bug) { state.notes[b.id] = n.isEmpty ? nil : n; save() }

    nonisolated static let closedStatuses = ["fixed", "not a bug", "won't fix", "duplicate", "corrigé"]
    nonisolated static func isClosed(_ b: Bug) -> Bool { closedStatuses.contains { b.status.lowercased().contains($0) } }

    /// Rapport prêt à coller (ticket, note ou demande de correctif).
    func report(_ b: Bug) -> String {
        var s = "# \(L.t("copy.header")) — \(state.stats?.name ?? "") (\(config.pageURL.absoluteString)?tab=bugs)\n\n"
        s += "## \(b.title)\n\nStatus: \(b.status) · Priority: \(b.priority) · Version: \(b.version)\n"
        for m in b.messages { s += "\n### \(m.author) — \(L.date(m.date))\n\n\(m.text)\n" }
        if !note(b).isEmpty { s += "\n## Notes\n\n\(note(b))\n" }
        return s
    }

    // MARK: Système

    func save() { Storage.save(data) }

    func updateBadge() {
        let n = data.mods.reduce(0) { $0 + $1.unreadPosts + $1.unreadBugs }
        NSApp?.dockTile.badgeLabel = n > 0 ? String(n) : nil
    }

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func notify(_ keys: Set<String>, mod: ModState) {
        let posts = keys.filter { $0.hasPrefix("p:") || $0.hasPrefix("r:") }.count
        let bugs = keys.filter { $0.hasPrefix("b:") }.count
        var lines: [String] = []
        if posts > 0 { lines.append(L.t("notif.posts", posts)) }
        if bugs > 0 { lines.append(L.t("notif.bugs", bugs)) }
        let content = UNMutableNotificationContent()
        content.title = L.t("notif.title", mod.stats?.name ?? "Nexus Mods")
        content.body = lines.joined(separator: " · ")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

// MARK: Calculs propres à un mod

extension ModState {
    var author: String { stats?.author ?? "" }
    var displayName: String { stats?.name ?? "\(config.domain) · \(config.modId)" }

    func isOwn(_ name: String) -> Bool { !author.isEmpty && name.caseInsensitiveCompare(author) == .orderedSame }
    func key(_ b: Bug) -> String { "b:\(b.id):\(b.signature)" }

    var unreadKeys: Set<String> {
        var keys = Set<String>()
        for p in posts {
            keys.insert("p:\(p.id)")
            p.replies.forEach { keys.insert("r:\($0.id)") }
        }
        bugs.forEach { keys.insert(key($0)) }
        return keys.subtracting(seen)
    }

    mutating func markOwnAsRead() {
        for p in posts {
            if isOwn(p.author) { seen.insert("p:\(p.id)") }
            p.replies.filter { isOwn($0.author) }.forEach { seen.insert("r:\($0.id)") }
        }
        for b in bugs where b.messages.last.map({ isOwn($0.author) }) == true { seen.insert(key(b)) }
    }

    func isUnread(_ p: Post) -> Bool {
        !seen.contains("p:\(p.id)") || p.replies.contains { !seen.contains("r:\($0.id)") }
    }
    func isUnread(_ r: Message) -> Bool { !seen.contains("r:\(r.id)") }
    func isUnread(_ b: Bug) -> Bool { !seen.contains(key(b)) }

    var unreadPosts: Int { posts.filter(isUnread).count }
    var unreadBugs: Int { bugs.filter(isUnread).count }

    mutating func recordHistory(_ s: ModStats) {
        let snap = Snapshot(date: Date(), endorsements: s.endorsements, downloads: s.downloads, unique: s.uniqueDownloads)
        if let last = history.last, last.endorsements == snap.endorsements, last.downloads == snap.downloads,
           last.unique == snap.unique, snap.date.timeIntervalSince(last.date) < 6 * 3600 { return }
        history.append(snap)
        if history.count > 2000 { history.removeFirst(history.count - 2000) }
    }

    /// Valeur d'il y a environ 24 h (ou la plus ancienne connue) pour afficher la progression.
    func delta(_ value: KeyPath<Snapshot, Int>) -> Int? {
        guard let now = history.last else { return nil }
        let ref = history.last { $0.date <= Date().addingTimeInterval(-86_400) } ?? history.first
        guard let ref, ref.date < now.date else { return nil }
        return now[keyPath: value] - ref[keyPath: value]
    }
}
