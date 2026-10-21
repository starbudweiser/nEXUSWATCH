// nEXUSWATCH — état de l'appli : actualisation périodique, éléments non lus, notifications, badge du Dock.
import AppKit
import UserNotifications

@MainActor
final class Store: ObservableObject {
    @Published var state = Storage.load()
    @Published var loading = false
    @Published var error: String?
    let fetcher = NexusFetcher()
    private var timer: Timer?

    var config: ModConfig { state.config }
    var author: String { state.stats?.author ?? "" }

    init() {
        schedule()
        if state.config.notifications { requestNotifications() }
        updateBadge()
    }

    func schedule() {
        timer?.invalidate()
        let interval = Double(max(5, state.config.intervalMinutes)) * 60
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    func updateConfig(_ c: ModConfig) {
        let changedMod = c.domain != state.config.domain || c.modId != state.config.modId
        state.config = c
        if changedMod {
            state.stats = nil; state.posts = []; state.bugs = []; state.history = []
            state.postCount = 0; state.lastCheck = nil
        }
        if c.notifications { requestNotifications() }
        save(); schedule()
        Task { await refresh() }
    }

    // MARK: Actualisation

    func refresh() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false; updateBadge() }
        let firstLoad = state.lastCheck == nil
        let before = unreadKeys()

        do {
            let stats = try await fetcher.stats(config)
            state.stats = stats
            recordHistory(stats)
        } catch {
            self.error = error.localizedDescription
        }

        do {
            let known = Dictionary(state.bugs.filter { !$0.messages.isEmpty }.map { ($0.id, $0.signature) },
                                   uniquingKeysWith: { a, _ in a })
            let page = try await fetcher.page(config, gameId: state.stats?.gameId ?? 0, knownBugs: known)
            let old = Dictionary(state.bugs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            state.bugs = page.bugs.map { b in
                var b = b
                if !page.freshBugs.contains(b.id), let o = old[b.id] { b.messages = o.messages }
                return b
            }
            state.posts = page.posts.sorted { ($0.sticky ? 1 : 0, $0.lastActivity) > ($1.sticky ? 1 : 0, $1.lastActivity) }
            state.postCount = page.postCount
            state.postsEnabled = page.postsEnabled
            state.bugsEnabled = page.bugsEnabled
            state.lastCheck = Date()
            markOwnAsRead()
        } catch {
            self.error = error.localizedDescription
        }
        save()

        let added = unreadKeys().subtracting(before)
        if !firstLoad, !added.isEmpty, config.notifications { notify(added) }
    }

    private func recordHistory(_ s: ModStats) {
        let snap = Snapshot(date: Date(), endorsements: s.endorsements, downloads: s.downloads, unique: s.uniqueDownloads)
        if let last = state.history.last, last.endorsements == snap.endorsements, last.downloads == snap.downloads,
           last.unique == snap.unique, snap.date.timeIntervalSince(last.date) < 6 * 3600 { return }
        state.history.append(snap)
        if state.history.count > 2000 { state.history.removeFirst(state.history.count - 2000) }
    }

    /// Valeur d'il y a environ 24 h (ou la plus ancienne connue) pour afficher la progression.
    func delta(_ value: KeyPath<Snapshot, Int>) -> Int? {
        guard let now = state.history.last else { return nil }
        let ref = state.history.last { $0.date <= Date().addingTimeInterval(-86_400) } ?? state.history.first
        guard let ref, ref.date < now.date else { return nil }
        return now[keyPath: value] - ref[keyPath: value]
    }

    // MARK: Non lus

    private func isOwn(_ name: String) -> Bool { !author.isEmpty && name.caseInsensitiveCompare(author) == .orderedSame }
    private func key(_ b: Bug) -> String { "b:\(b.id):\(b.signature)" }

    private func unreadKeys() -> Set<String> {
        var keys = Set<String>()
        for p in state.posts {
            keys.insert("p:\(p.id)")
            p.replies.forEach { keys.insert("r:\($0.id)") }
        }
        state.bugs.forEach { keys.insert(key($0)) }
        return keys.subtracting(state.seen)
    }

    private func markOwnAsRead() {
        for p in state.posts {
            if isOwn(p.author) { state.seen.insert("p:\(p.id)") }
            p.replies.filter { isOwn($0.author) }.forEach { state.seen.insert("r:\($0.id)") }
        }
        for b in state.bugs where b.messages.last.map({ isOwn($0.author) }) == true { state.seen.insert(key(b)) }
    }

    func isUnread(_ p: Post) -> Bool {
        !state.seen.contains("p:\(p.id)") || p.replies.contains { !state.seen.contains("r:\($0.id)") }
    }
    func isUnread(_ r: Message) -> Bool { !state.seen.contains("r:\(r.id)") }
    func isUnread(_ b: Bug) -> Bool { !state.seen.contains(key(b)) }
    func isOwnMessage(_ m: Message) -> Bool { isOwn(m.author) }
    func isOwnPost(_ p: Post) -> Bool { isOwn(p.author) }

    var unreadPosts: Int { state.posts.filter(isUnread).count }
    var unreadBugs: Int { state.bugs.filter(isUnread).count }

    func markRead(_ p: Post) {
        guard isUnread(p) else { return }
        state.seen.insert("p:\(p.id)")
        p.replies.forEach { state.seen.insert("r:\($0.id)") }
        save(); updateBadge()
    }

    func markRead(_ b: Bug) {
        guard isUnread(b) else { return }
        state.seen.insert(key(b)); save(); updateBadge()
    }

    func markAllRead() {
        state.posts.forEach { p in state.seen.insert("p:\(p.id)"); p.replies.forEach { state.seen.insert("r:\($0.id)") } }
        state.bugs.forEach { state.seen.insert(key($0)) }
        save(); updateBadge()
    }

    // MARK: Suivi local des bugs

    func follow(_ b: Bug) -> Follow { state.follow[b.id] ?? .triage }
    func setFollow(_ f: Follow, for b: Bug) { state.follow[b.id] = f; save() }
    func note(_ b: Bug) -> String { state.notes[b.id] ?? "" }
    func setNote(_ n: String, for b: Bug) { state.notes[b.id] = n.isEmpty ? nil : n; save() }

    static let closedStatuses = ["fixed", "not a bug", "won't fix", "duplicate", "corrigé"]
    static func isClosed(_ b: Bug) -> Bool { closedStatuses.contains { b.status.lowercased().contains($0) } }
    var openBugs: Int { state.bugs.filter { !Self.isClosed($0) }.count }

    /// Rapport prêt à coller (ticket, note ou demande de correctif).
    func report(_ b: Bug) -> String {
        var s = "# \(L.t("copy.header")) — \(state.stats?.name ?? "") (\(config.pageURL.absoluteString)?tab=bugs)\n\n"
        s += "## \(b.title)\n\nStatus: \(b.status) · Priority: \(b.priority) · Version: \(b.version)\n"
        for m in b.messages { s += "\n### \(m.author) — \(L.date(m.date))\n\n\(m.text)\n" }
        if !note(b).isEmpty { s += "\n## Notes\n\n\(note(b))\n" }
        return s
    }

    // MARK: Système

    func save() { Storage.save(state) }

    func updateBadge() {
        let n = unreadPosts + unreadBugs
        NSApp?.dockTile.badgeLabel = n > 0 ? String(n) : nil
    }

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func notify(_ keys: Set<String>) {
        let posts = keys.filter { $0.hasPrefix("p:") || $0.hasPrefix("r:") }.count
        let bugs = keys.filter { $0.hasPrefix("b:") }.count
        var lines: [String] = []
        if posts > 0 { lines.append(L.t("notif.posts", posts)) }
        if bugs > 0 { lines.append(L.t("notif.bugs", bugs)) }
        let content = UNMutableNotificationContent()
        content.title = L.t("notif.title", state.stats?.name ?? "Nexus Mods")
        content.body = lines.joined(separator: " · ")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
