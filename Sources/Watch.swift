// nEXUSWATCH — Veille : dernières versions de produits suivis (releases GitHub, fiches Nexus), reprise de hERALD.
// Lecture publique uniquement : API GitHub sans jeton, API GraphQL de Nexus sans clé, pages web lues comme un navigateur.
import CryptoKit
import SwiftUI
import UserNotifications

enum WatchKind: String, Codable, CaseIterable, Identifiable {
    case github, nexus, web
    var id: String { rawValue }
    var label: String { L.t("watch.kind.\(rawValue)") }
}

/// Relevé d'un produit surveillé : un par nouvelle version repérée.
struct WatchSnapshot: Codable, Hashable {
    var date = Date()
    var version = ""
    var published: Date?
    var title = ""
    var downloads: Int?
    var endorsements: Int?
}

struct WatchItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = ""
    var kind: WatchKind = .github
    /// « propriétaire/dépôt » pour GitHub, « jeu/identifiant » pour Nexus, adresse complète pour une page web.
    var ref = ""
    var notes = ""
    var lastChecked: Date?
    var error: String?
    var history: [WatchSnapshot] = []

    var latest: WatchSnapshot? { history.last }

    var pageURL: URL? {
        switch kind {
        case .github: return URL(string: "https://github.com/\(ref)/releases")
        case .nexus:
            let p = ref.split(separator: "/")
            return p.count == 2 ? URL(string: "https://www.nexusmods.com/\(p[0])/mods/\(p[1])") : nil
        case .web: return URL(string: ref)
        }
    }

    /// Version affichée : une page web sans numéro de version n'a que sa date de changement.
    static func label(_ s: WatchSnapshot) -> String { s.version.isEmpty ? L.t("watch.web.changed", L.day(s.date)) : s.version }

    /// Lit une URL GitHub ou Nexus (ou « a/b ») et en déduit le type et la référence.
    static func parse(_ input: String) -> (WatchKind, String)? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let u = URL(string: s), let host = u.host?.lowercased() {
            let parts = u.path.split(separator: "/").map(String.init).filter { $0 != "games" }
            if host.hasSuffix("github.com"), parts.count >= 2 { return (.github, "\(parts[0])/\(parts[1])") }
            if host.hasSuffix("nexusmods.com"), parts.count >= 3, parts[1] == "mods", Int(parts[2]) != nil {
                return (.nexus, "\(parts[0])/\(parts[2])")
            }
            // Toute autre adresse : page web suivie telle quelle (version relevée dans le texte, sinon changement de contenu).
            return ["http", "https"].contains(u.scheme?.lowercased() ?? "") ? (.web, s) : nil
        }
        let parts = s.split(separator: "/").map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return Int(parts[1]) != nil ? (.nexus, s) : (.github, s)
    }
}

struct WatchError: Error { let message: String }

enum Watcher {
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

    static func fetch(_ item: WatchItem) async -> Result<WatchSnapshot, WatchError> {
        switch item.kind {
        case .github: return await github(item.ref)
        case .nexus: return await nexus(item.ref)
        case .web: return await web(item.ref)
        }
    }

    static func send(_ r: URLRequest) async -> Result<Data, WatchError> {
        var r = r
        r.timeoutInterval = 20
        r.setValue("nEXUSWATCH/\(version)", forHTTPHeaderField: "User-Agent")
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { return .failure(WatchError(message: L.t("watch.http", code))) }
            return .success(d)
        } catch let e as URLError where e.code == .appTransportSecurityRequiresSecureConnection {
            return .failure(WatchError(message: L.t("watch.web.insecure")))  // site en http seulement (ou redirigé vers http)
        } catch {
            return .failure(WatchError(message: error.localizedDescription))
        }
    }

    private static func github(_ ref: String) async -> Result<WatchSnapshot, WatchError> {
        guard let url = URL(string: "https://api.github.com/repos/\(ref)/releases?per_page=1") else {
            return .failure(WatchError(message: L.t("watch.invalid")))
        }
        var r = URLRequest(url: url)
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        switch await send(r) {
        case .failure(let e): return .failure(e)
        case .success(let d):
            struct Rel: Decodable { let tag_name: String; let name: String?; let published_at: String? }
            guard let rels = try? JSONDecoder().decode([Rel].self, from: d) else { return .failure(WatchError(message: L.t("watch.parse"))) }
            guard let rel = rels.first else { return .success(WatchSnapshot(version: L.t("watch.norelease"))) }
            return .success(WatchSnapshot(version: rel.tag_name, published: rel.published_at.flatMap { ISO8601DateFormatter().date(from: $0) },
                                          title: rel.name ?? ""))
        }
    }

    private static func nexus(_ ref: String) async -> Result<WatchSnapshot, WatchError> {
        let p = ref.split(separator: "/")
        guard p.count == 2, let id = Int(p[1]) else { return .failure(WatchError(message: L.t("watch.invalid"))) }
        var r = URLRequest(url: URL(string: "https://api.nexusmods.com/v2/graphql")!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("nEXUSWATCH", forHTTPHeaderField: "Application-Name")
        r.setValue(version, forHTTPHeaderField: "Application-Version")
        let query = """
        query($d: String!, $m: Int!) { legacyModsByDomain(ids: [{gameDomain: $d, modId: $m}]) {
          nodes { name version updatedAt endorsements downloads } } }
        """
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query, "variables": ["d": String(p[0]), "m": id]])
        switch await send(r) {
        case .failure(let e): return .failure(e)
        case .success(let d):
            guard let json = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let node = (((json["data"] as? [String: Any])?["legacyModsByDomain"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first
            else { return .failure(WatchError(message: L.t("watch.parse"))) }
            return .success(WatchSnapshot(version: node["version"] as? String ?? "—",
                                          published: (node["updatedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) },
                                          title: node["name"] as? String ?? "",
                                          downloads: node["downloads"] as? Int, endorsements: node["endorsements"] as? Int))
        }
    }
}

extension Watcher {
    /// Page web : le plus haut numéro de version écrit dans le texte (« Version 0.505 », « v0.505 »), sinon une empreinte
    /// du texte, qui ne signale qu'un changement de contenu.
    static func web(_ ref: String) async -> Result<WatchSnapshot, WatchError> {
        // Une adresse http est lue en https : macOS refuse les connexions non chiffrées (App Transport Security).
        guard var parts = URLComponents(string: ref) else { return .failure(WatchError(message: L.t("watch.invalid"))) }
        if parts.scheme?.lowercased() == "http" { parts.scheme = "https" }
        guard let url = parts.url else { return .failure(WatchError(message: L.t("watch.invalid"))) }
        var r = URLRequest(url: url)
        // Requête de lecteur ordinaire, sous le nom de l'appli : certains serveurs refusent une demande sans type de contenu accepté.
        r.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        r.setValue("en", forHTTPHeaderField: "Accept-Language")
        switch await send(r) {
        case .failure(let e): return .failure(e)
        case .success(let d):
            guard let raw = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) else {
                return .failure(WatchError(message: L.t("watch.parse")))
            }
            let text = raw.replacingOccurrences(of: "(?is)<(script|style)\\b.*?</\\1>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            let title = raw.range(of: "(?is)<title[^>]*>(.*?)</title>", options: .regularExpression)
                .map { String(raw[$0]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            let pattern = try! NSRegularExpression(pattern: #"(?i)\b(?:version|ver\.?|v)\s*:?\s*(\d+(?:\.\d+){1,3})\b"#)
            let ns = text as NSString
            let found = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
            if let best = found.max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) {
                return .success(WatchSnapshot(version: best, title: title))
            }
            let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
            return .success(WatchSnapshot(version: "", title: String(digest)))
        }
    }
}

// MARK: État

extension Store {
    static let watchID = "watch"
    var watchItems: [WatchItem] { data.watch ?? [] }
    var showWatch: Bool { data.selected == Self.watchID }
    /// Un module (Discord, Veille) occupe la zone principale à la place d'un mod.
    var showModule: Bool { showDiscord || showWatch }

    func selectWatch() { data.selected = Self.watchID; save() }

    func addWatch(_ input: String, name: String) -> String? {
        guard let (kind, ref) = WatchItem.parse(input) else { return L.t("watch.invalid") }
        guard !watchItems.contains(where: { $0.kind == kind && $0.ref.lowercased() == ref.lowercased() }) else {
            return L.t("watch.duplicate")
        }
        let n = name.trimmingCharacters(in: .whitespaces)
        let fallback = kind == .web ? (URL(string: ref)?.host ?? ref) : ref
        let item = WatchItem(name: n.isEmpty ? fallback : n, kind: kind, ref: ref)
        data.watch = watchItems + [item]
        save()
        Task { await checkWatch([item.id]) }
        return nil
    }

    func removeWatch(_ id: UUID) { data.watch?.removeAll { $0.id == id }; save() }

    func setWatchNotes(_ notes: String, for id: UUID) {
        guard let i = data.watch?.firstIndex(where: { $0.id == id }) else { return }
        data.watch?[i].notes = notes
        save()
    }

    /// Relevé périodique : au plus un toutes les 6 heures (limite de 60 requêtes par heure de l'API GitHub sans jeton).
    func checkWatchIfStale() async {
        let limit = Date().addingTimeInterval(-6 * 3600)
        let stale = watchItems.filter { ($0.lastChecked ?? .distantPast) < limit }.map(\.id)
        if !stale.isEmpty { await checkWatch(stale) }
    }

    /// Une version n'entre dans l'historique que si elle change ; une nouvelle version déjà connue est notifiée.
    func checkWatch(_ ids: [UUID]? = nil) async {
        guard !watchBusy else { return }
        watchBusy = true
        for item in watchItems where ids?.contains(item.id) ?? true {
            let result = await Watcher.fetch(item)
            guard let i = data.watch?.firstIndex(where: { $0.id == item.id }), var w = data.watch?[i] else { continue }
            w.lastChecked = Date()
            switch result {
            case .success(let snap):
                w.error = nil
                // Page sans numéro de version : c'est l'empreinte du texte (title) qui dit si elle a changé.
                if let last = w.latest, last.version == snap.version, !snap.version.isEmpty || last.title == snap.title {
                    w.history[w.history.count - 1].downloads = snap.downloads
                    w.history[w.history.count - 1].endorsements = snap.endorsements
                } else {
                    if w.latest != nil, data.notifications { notifyRelease(w.name, WatchItem.label(snap)) }
                    w.history.append(snap)
                    if w.history.count > 200 { w.history.removeFirst() }
                }
            case .failure(let e):
                w.error = e.message
            }
            data.watch?[i] = w
        }
        watchBusy = false
        save()
    }

    private func notifyRelease(_ name: String, _ version: String) {
        let content = UNMutableNotificationContent()
        content.title = L.t("watch.notif.title", name)
        content.body = L.t("watch.notif.body", version)
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

// MARK: Vues

struct WatchView: View {
    @EnvironmentObject var store: Store
    @State private var selected: UUID?
    @State private var input = ""
    @State private var name = ""
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Socle.M.space2) {
                Text(branded: "nEXUSWATCH").socle(Socle.T.title).foregroundStyle(Socle.C.textStrong)
                Text(L.t("watch.subtitle")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted).lineLimit(1)
                Spacer(minLength: Socle.M.space4)
                if store.watchBusy { ProgressView().controlSize(.small) }
                Button(L.t("watch.check")) { Task { await store.checkWatch() } }
                    .buttonStyle(SocleButtonStyle(.primary, height: Socle.M.sizeControl)).fixedSize()
                    .disabled(store.watchBusy || store.watchItems.isEmpty)
            }
            .padding(.horizontal, Socle.M.space3)
            .frame(minHeight: Socle.M.sizeBar + 8)
            .background(Socle.C.surfaceRaised)
            Divider().overlay(Socle.C.border)
            SplitLayout {
                VStack(alignment: .leading, spacing: Socle.M.space1_5) {
                    TextField(L.t("watch.add.placeholder"), text: $input).socleField()
                    HStack(spacing: Socle.M.space1_5) {
                        TextField(L.t("watch.add.name"), text: $name).socleField()
                        Button(L.t("action.add")) {
                            problem = store.addWatch(input, name: name)
                            if problem == nil { input = ""; name = "" }
                        }
                        .buttonStyle(SocleButtonStyle(.secondary)).fixedSize()
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let problem { Text(problem).socle(Socle.T.meta).foregroundStyle(Socle.C.danger) }
                }
                .padding(Socle.M.space3)
                Divider().overlay(Socle.C.borderSubtle)
                if store.watchItems.isEmpty { EmptyState(text: L.t("watch.empty")).frame(height: 160) }
                ForEach(store.watchItems) { w in
                    ListRow(selected: w.id == selected, unread: false) { selected = w.id } content: {
                        HStack(spacing: Socle.M.space1_5) {
                            Text(w.name).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textStrong).lineLimit(1)
                            Spacer(minLength: 0)
                            Badge(text: w.kind.label)
                        }
                        HStack(spacing: Socle.M.space1_5) {
                            Text(w.latest.map(WatchItem.label) ?? L.t("watch.unchecked")).socle(Socle.T.mono).foregroundStyle(Socle.C.accentText).lineLimit(1)
                            Spacer(minLength: 0)
                            if w.error != nil { Image(systemName: "exclamationmark.triangle").foregroundStyle(Socle.C.warning) }
                        }
                    }
                }
            } detail: {
                if let id = selected, let w = store.watchItems.first(where: { $0.id == id }) {
                    WatchDetail(item: w, selected: $selected).id(w.id)
                } else {
                    EmptyState(text: L.t(store.watchItems.isEmpty ? "watch.intro" : "watch.select"))
                }
            }
        }
    }
}

struct WatchDetail: View {
    @EnvironmentObject var store: Store
    let item: WatchItem
    @Binding var selected: UUID?
    @State private var notes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space3) {
            HStack(spacing: Socle.M.space2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong)
                    Text("\(item.kind.label) · \(item.ref)").socle(Socle.T.monoSm).foregroundStyle(Socle.C.textSubtle)
                }
                Spacer()
                if let u = item.pageURL {
                    Button(L.t("watch.open")) { NSWorkspace.shared.open(u) }
                        .buttonStyle(SocleButtonStyle(.secondary, height: Socle.M.sizeControl)).fixedSize()
                }
                Button(L.t("watch.remove")) { store.removeWatch(item.id); selected = nil }
                    .buttonStyle(SocleButtonStyle(.tertiary, height: Socle.M.sizeControl)).fixedSize()
            }
            if let e = item.error { Callout(kind: .warning, text: e) }
            Text(item.lastChecked.map { L.t("watch.checked", L.date($0)) } ?? L.t("watch.unchecked"))
                .socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
            VStack(alignment: .leading, spacing: Socle.M.space1_5) {
                Text(L.t("watch.notes")).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted)
                TextField("", text: $notes).socleField()
                    .onSubmit { store.setWatchNotes(notes, for: item.id) }
                    .onChange(of: notes) { _, v in store.setWatchNotes(v, for: item.id) }
            }
            Text(L.t("watch.history").uppercased()).socle(Socle.T.eyebrow).foregroundStyle(Socle.C.textSubtle)
            if item.history.isEmpty { EmptyState(text: L.t("watch.history.empty")) }
            else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(item.history.enumerated().reversed()), id: \.offset) { _, s in
                            HStack(spacing: Socle.M.space3) {
                                Text(L.date(s.date)).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle).frame(width: 150, alignment: .leading)
                                Text(WatchItem.label(s)).socle(Socle.T.mono).foregroundStyle(Socle.C.accentText).lineLimit(1)
                                    .frame(width: 140, alignment: .leading)
                                Text(s.published.map { L.t("watch.published", L.day($0)) } ?? "")
                                    .socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
                                if let d = s.downloads {
                                    Label(L.number(d), systemImage: "arrow.down.circle").socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
                                }
                                if let e = s.endorsements {
                                    Label(L.number(e), systemImage: "hand.thumbsup").socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, Socle.M.space1_5)
                            Divider().overlay(Socle.C.borderSubtle)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Socle.M.space4)
        .onAppear { notes = item.notes }
    }
}
