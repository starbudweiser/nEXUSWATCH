// nEXUSWATCH — récupération des données Nexus Mods.
// Stats et fichiers : API GraphQL publique (sans clé). Posts et bugs : la page du mod est chargée dans
// un WKWebView invisible (franchit la protection Cloudflare comme Safari), puis ses widgets sont lus en JS.
import Foundation
import WebKit

enum FetchError: LocalizedError {
    case timeout, unpublished, notFound, api(String), script(String)
    var errorDescription: String? {
        switch self {
        case .timeout: L.t("err.timeout")
        case .unpublished: L.t("err.unpublished")
        case .notFound: L.t("err.notfound")
        case .api(let m): L.t("err.api") + " " + m
        case .script(let m): L.t("err.script") + " " + m
        }
    }
}

struct PageData {
    var posts: [Post]
    var postCount: Int
    var postsEnabled: Bool
    var bugs: [Bug]
    var freshBugs: Set<String>
    var bugsEnabled: Bool
}

@MainActor
final class NexusFetcher: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private var navigation: CheckedContinuation<Void, Error>?

    override init() {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .default()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: c)
        // Se présente comme Safari : Nexus refuse certains navigateurs « inconnus ».
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        super.init()
        webView.navigationDelegate = self
    }

    // MARK: GraphQL

    func stats(_ cfg: ModConfig) async throws -> ModStats {
        let query = """
        query($d: String!, $m: Int!) { legacyModsByDomain(ids: [{gameDomain: $d, modId: $m}]) {
          nodes { name version endorsements downloads updatedAt status gameId uploader { name } } } }
        """
        let mod = try await graphQL(query, ["d": cfg.domain, "m": cfg.modId])
        guard let node = ((mod["legacyModsByDomain"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first else {
            throw FetchError.notFound
        }
        var s = ModStats()
        s.name = node["name"] as? String ?? ""
        s.version = node["version"] as? String ?? ""
        s.status = node["status"] as? String ?? ""
        s.endorsements = node["endorsements"] as? Int ?? 0
        s.downloads = node["downloads"] as? Int ?? 0
        s.gameId = node["gameId"] as? Int ?? 0
        s.author = (node["uploader"] as? [String: Any])?["name"] as? String ?? ""
        s.updatedAt = (node["updatedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }

        let filesQuery = """
        query($m: ID!, $g: ID!) { modFiles(modId: $m, gameId: $g) {
          fileId name version category date totalDownloads uniqueDownloads scannedV2 } }
        """
        let files = try await graphQL(filesQuery, ["m": String(cfg.modId), "g": String(s.gameId)])
        s.files = (files["modFiles"] as? [[String: Any]] ?? []).map { f in
            ModFileStat(id: f["fileId"] as? Int ?? 0, name: f["name"] as? String ?? "",
                        version: f["version"] as? String ?? "", category: f["category"] as? String ?? "",
                        scan: f["scannedV2"] as? String ?? "", total: f["totalDownloads"] as? Int ?? 0,
                        unique: f["uniqueDownloads"] as? Int ?? 0,
                        date: Date(timeIntervalSince1970: f["date"] as? Double ?? 0))
        }
        return s
    }

    private func graphQL(_ query: String, _ variables: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.nexusmods.com/v2/graphql")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // En-têtes demandés par la politique d'usage de l'API Nexus : nom fixe, version de la release.
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        req.setValue("nEXUSWATCH", forHTTPHeaderField: "Application-Name")
        req.setValue(version, forHTTPHeaderField: "Application-Version")
        req.setValue("nEXUSWATCH/\(version)", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FetchError.api("HTTP \(code)") }
        if let errors = json["errors"] as? [[String: Any]], let m = errors.first?["message"] as? String { throw FetchError.api(m) }
        guard code == 200, let d = json["data"] as? [String: Any] else { throw FetchError.api("HTTP \(code)") }
        return d
    }

    // MARK: Page du mod

    func page(_ cfg: ModConfig, gameId: Int, knownBugs: [String: String], maxPostPages: Int = 3) async throws -> PageData {
        try await load(cfg.pageURL)
        // Attend la fin d'un éventuel contrôle Cloudflare (la page réelle contient les onglets du mod).
        var ready = false
        for _ in 0..<50 {
            let r = try? await webView.evaluateJavaScript("!!document.querySelector('#mod-page-tab-description, .stats')")
            if r as? Bool == true { ready = true; break }
            // Mod non publié : la page reste accessible mais n'a aucun onglet à lire.
            let hidden = try? await webView.evaluateJavaScript("[...document.querySelectorAll('h1, h2, h3')].some(e => e.textContent.trim() === 'Not published')")
            if hidden as? Bool == true { throw FetchError.unpublished }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        guard ready else { throw FetchError.timeout }

        let args: [String: Any] = ["gameId": gameId, "modId": cfg.modId, "known": knownBugs, "maxPages": maxPostPages]
        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(Self.script, arguments: args, in: nil, contentWorld: .defaultClient)
        } catch {
            throw FetchError.script(error.localizedDescription)
        }
        guard let json = (result as? String)?.data(using: .utf8),
              let raw = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw FetchError.script("JSON")
        }
        let posts = (raw["posts"] as? [[String: Any]] ?? []).map { p in
            Post(id: p.s("id"), author: p.s("author"), role: p.s("role"), text: p.s("text"), date: p.date("date"),
                 sticky: p["sticky"] as? Bool ?? false, replies: (p["replies"] as? [[String: Any]] ?? []).map(Self.message))
        }
        let bugs = (raw["bugs"] as? [[String: Any]] ?? []).map { b in
            Bug(id: b.s("id"), title: b.s("title"), status: b.s("status"), priority: b.s("priority"), version: b.s("version"),
                replies: b["replies"] as? Int ?? 0, lastPost: b.date("lastPost"),
                messages: (b["messages"] as? [[String: Any]])?.map(Self.message) ?? [])
        }
        // « messages » absent = bug inchangé depuis la dernière lecture : l'appelant garde les messages connus.
        let fresh = Set((raw["bugs"] as? [[String: Any]] ?? []).compactMap { $0["messages"] != nil ? $0["id"] as? String : nil })
        return PageData(posts: posts, postCount: raw["postCount"] as? Int ?? posts.count,
                        postsEnabled: raw["postsEnabled"] as? Bool ?? true,
                        bugs: bugs, freshBugs: fresh, bugsEnabled: raw["bugsEnabled"] as? Bool ?? true)
    }

    private static func message(_ m: [String: Any]) -> Message {
        Message(id: m.s("id"), author: m.s("author"), role: m.s("role"), date: m.date("date"), text: m.s("text"))
    }

    private func load(_ url: URL) async throws {
        navigation?.resume(throwing: CancellationError())
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            navigation = c
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45))
        }
    }

    private func finish(_ error: Error?) {
        guard let c = navigation else { return }
        navigation = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.finish(nil) }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finish(error) }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finish(error) }
    }

    /// Exécuté dans la page du mod (même origine que les widgets Nexus). Renvoie une chaîne JSON.
    private static let script = #"""
    const X = {headers: {'X-Requested-With': 'XMLHttpRequest'}};
    const P = s => new DOMParser().parseFromString(s, 'text/html');
    const get = async u => { const r = await fetch(u, X); if (!r.ok) throw new Error('HTTP ' + r.status); return r.text(); };
    const txt = e => {
      if (!e) return '';
      const c = e.cloneNode(true);
      c.querySelectorAll('script, style, time, .locked, .sticky').forEach(n => n.remove());
      c.querySelectorAll('br').forEach(n => n.replaceWith('\n'));
      c.querySelectorAll('p, div, li, blockquote').forEach(n => n.append('\n'));
      return c.textContent.replace(/ /g, ' ').replace(/[ \t]+/g, ' ').replace(/ *\n */g, '\n').replace(/\n{3,}/g, '\n\n').trim();
    };
    const when = t => !t ? 0 : (+t.dataset.date || (Date.parse((t.getAttribute('datetime') || '').replace(' ', 'T')) / 1000) || 0);
    const msg = li => {
      const head = li.querySelector(':scope > .comment-head');
      const content = li.querySelector(':scope > .comment-content');
      const body = content && content.querySelector('.comment-content-text');
      const role = head && head.querySelector('[class^="status-"]');
      return {id: li.id.replace(/^\D+/, ''), author: txt(head && head.querySelector('.comment-name')),
              role: role ? role.textContent.trim() : '', date: when(content && content.querySelector('time')),
              text: txt(body || content)};
    };
    const html = document.documentElement.outerHTML;
    const gid = gameId || +((html.match(/game_id=(\d+)/) || [])[1] || 0);
    const tid = (html.match(/thread_id=(\d+)/) || [])[1];
    const out = {posts: [], postCount: 0, postsEnabled: !!tid, bugs: [], bugsEnabled: true};

    if (tid) {
      const ids = new Set();
      for (let p = 1; p <= maxPages; p++) {
        const d = P(await get(`/Core/Libs/Common/Widgets/CommentContainer?RH_CommentContainer=game_id:${gid},object_id:${modId},object_type:1,thread_id:${tid},skip_opening_post:0,page_size:10,page:${p}`));
        if (p === 1) out.postCount = +((d.querySelector('#comment-count') || {dataset: {}}).dataset.commentCount || 0);
        const lis = [...d.querySelectorAll('#comment-container > ol > li.comment')];
        let added = 0;
        for (const li of lis) {
          const m = msg(li);
          if (!m.id || ids.has(m.id)) continue;
          ids.add(m.id); added++;
          m.sticky = li.classList.contains('comment-sticky');
          m.replies = [...li.querySelectorAll(':scope li.comment')].map(msg);
          out.posts.push(m);
        }
        if (!added || lis.length < 10) break;
      }
    }

    for (let p = 1; p <= 30; p++) {
      const s = await get(`/Core/Libs/Common/Widgets/ModBugsTab?id=${modId}&game_id=${gid}&page=${p}`);
      if (/Bug reporting disabled/i.test(s)) { out.bugsEnabled = false; break; }
      const d = P(s);
      let added = 0;
      for (const r of d.querySelectorAll('tr.mod-issue-row')) {
        const id = r.dataset.issueId;
        if (out.bugs.some(b => b.id === id)) continue;
        added++;
        const cell = c => r.querySelector('td.table-bug-' + c);
        out.bugs.push({id, title: txt(r.querySelector('.issue-title')), status: txt(cell('status')),
                       replies: +txt(cell('replies')) || 0, version: txt(cell('version')),
                       priority: txt(cell('priority')), lastPost: when(cell('post') && cell('post').querySelector('time'))});
      }
      const pages = (s.match(/\{id: '\d+', text: '\d+'\}/g) || []).length;
      if (!added || p >= pages) break;
    }

    for (const b of out.bugs) {
      if (known[b.id] === `${b.replies}:${Math.floor(b.lastPost)}`) continue;
      const r = await fetch('/Core/Libs/Common/Widgets/ModBugReplyList', {method: 'POST',
        headers: {'X-Requested-With': 'XMLHttpRequest', 'Content-Type': 'application/x-www-form-urlencoded'},
        body: 'issue_id=' + encodeURIComponent(b.id)});
      if (!r.ok) continue;
      const d = P('<table><tr>' + await r.text() + '</tr></table>');
      b.messages = [...d.querySelectorAll('li.comment')].map((li, i) => Object.assign(msg(li), {id: b.id + '-' + i}));
    }
    return JSON.stringify(out);
    """#
}

private extension Dictionary where Key == String, Value == Any {
    func s(_ k: String) -> String { (self[k] as? String) ?? (self[k].map { "\($0)" } ?? "") }
    func date(_ k: String) -> Date { Date(timeIntervalSince1970: (self[k] as? Double) ?? Double(self[k] as? Int ?? 0)) }
}
