// nEXUSWATCH — audit des bugs établi par l'appli, sans IA : plan de développement par priorité,
// dans la langue de l'interface, et fenêtre de lecture au format A4 (impression et PDF).
import AppKit
import PDFKit
import SwiftUI

enum LocalAudit {
    enum Priority: Int, Comparable {
        case low, medium, high, critical
        static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
        var key: String { ["low", "medium", "high", "critical"][rawValue] }
    }

    struct Item {
        let bug: Bug
        let priority: Priority
        let score: Int
        let reports: Int
        let linkedPosts: Int
        let currentVersion: Bool
        let answered: Bool
        let action: String
    }

    private static let crashWords = ["ctd", "crash", "freeze", "infinite load", "plante", "black screen"]
    private static let launchWords = [".dll", "address library", "not compatible", "incompatible", "newest skyrim",
                                      "new version", "update to work", "won't launch", "doesn't load", "fails to load"]
    private static let majorWords = ["camera", "lock", "spin", "stuck", "not working", "doesn't work", "broken", "can't", "cannot"]
    private static let solvedWords = ["false flag", "turns out", "my issue was", "the cause of", "was caused by", "solved",
                                      "fixed it", "figured it out", "nvm", "never mind"]
    private static let logWords = ["pastebin", "crash log", "crashlog", "netscriptframework", "crash-", ".log"]

    private static func has(_ text: String, _ words: [String]) -> Bool { words.contains { text.contains($0) } }

    /// Bugs ouverts classés, et ceux que leurs auteurs disent résolus.
    static func plan(_ m: ModState) -> (items: [Item], solved: [Bug]) {
        let version = m.stats?.version ?? ""
        var items: [Item] = [], solved: [Bug] = []
        for b in m.bugs where !Store.isClosed(b) {
            let text = ([b.title] + b.messages.map(\.text)).joined(separator: "\n").lowercased()
            let later = b.messages.dropFirst().map { $0.text.lowercased() }.joined(separator: "\n")
            if has(later, solvedWords) { solved.append(b); continue }
            let crash = has(text, crashWords), launch = has(text, launchWords), major = has(text, majorWords)
            let linked = m.postTags?.values.filter { $0.trackedAs == b.title }.count ?? 0
            let reports = 1 + max(b.replies, b.messages.count - 1) + linked
            let current = !version.isEmpty && b.version.hasSuffix(version)
            let recent = b.lastPost > Date().addingTimeInterval(-30 * 86_400)
            let answered = b.messages.contains { m.isOwn($0.author) }
            var score = (crash || launch ? 50 : major ? 25 : 10) + 6 * min(reports, 10) + 8 * linked
            score += (recent ? 15 : 0) + (current ? 10 : 0) + (answered ? 0 : 5)
            let priority: Priority = (crash || launch) && (recent || current) ? .critical
                : score >= 55 ? .high : score >= 35 ? .medium : .low
            let action = launch ? "compat" : crash ? (has(text, logWords) ? "logs" : "asklogs") : "fix"
            items.append(Item(bug: b, priority: priority, score: score, reports: reports, linkedPosts: linked,
                              currentVersion: current, answered: answered, action: action))
        }
        items.sort { ($0.priority, $0.score, $0.bug.lastPost) > ($1.priority, $1.score, $1.bug.lastPost) }
        return (items, solved)
    }

    /// Rapport complet en Markdown, dans la langue de l'interface.
    static func markdown(_ m: ModState, maxItems: Int = 15) -> String {
        let (items, solved) = plan(m)
        let open = m.bugs.filter { !Store.isClosed($0) }
        let unanswered = open.filter { b in !b.messages.contains { m.isOwn($0.author) } }.count
        let active = open.filter { $0.lastPost > Date().addingTimeInterval(-30 * 86_400) }.count
        let tags = m.postTags ?? [:]
        let bugPosts = m.posts.filter { tags[$0.id]?.isBug == true }
        let untracked = bugPosts.filter { tags[$0.id]?.trackedAs == nil }
        let features = m.posts.filter { tags[$0.id]?.isFeature == true }

        var s = "# \(L.t("report.title", m.displayName))\n\n"
        s += "\(L.t("report.generated", L.date(Date())))\n\n"
        s += "## \(L.t("report.summary"))\n\n"
        s += "- \(L.t("report.summary.bugs", open.count, m.bugs.count, unanswered, active))\n"
        if !m.posts.isEmpty {
            s += "- \(L.t("report.summary.posts", m.posts.count, bugPosts.count, untracked.count, features.count))\n"
        }
        if let v = m.stats?.version { s += "- \(L.t("report.summary.version", v))\n" }

        s += "\n## \(L.t("report.plan"))\n\n"
        if items.isEmpty { s += "\(L.t("report.none"))\n" }
        for (i, it) in items.prefix(maxItems).enumerated() {
            s += "### \(i + 1). \(it.bug.title) — \(L.t("report.prio.\(it.priority.key)"))\n\n"
            var facts = L.t("report.item.signals", it.reports, L.ago(it.bug.lastPost), versionNumber(it.bug.version))
            if it.currentVersion { facts += " \(L.t("report.item.current"))" }
            s += "- \(facts)\n"
            if it.linkedPosts > 0 { s += "- \(L.t("report.item.posts", it.linkedPosts))\n" }
            s += "- \(L.t(it.answered ? "report.item.answered" : "report.item.unanswered"))\n"
            s += "- **\(L.t("report.action"))** \(L.t("report.action.\(it.action)"))\n"
            if let first = it.bug.messages.first?.text, !first.isEmpty {
                s += "\n> \(excerpt(first))\n"
            }
            s += "\n"
        }
        if items.count > maxItems { s += "\(L.t("report.more", items.count - maxItems))\n" }

        if !solved.isEmpty {
            s += "\n## \(L.t("report.close"))\n\n"
            for b in solved { s += "- **\(b.title)** — \(L.t("report.close.item"))\n" }
        }
        if !untracked.isEmpty {
            s += "\n## \(L.t("report.untracked"))\n\n"
            for p in untracked { s += "- **\(p.author)** (\(L.ago(p.lastActivity))) — \(excerpt(p.text, 140))\n" }
        }
        if !features.isEmpty {
            s += "\n## \(L.t("report.features"))\n\n"
            for p in features { s += "- **\(p.author)** (\(L.ago(p.lastActivity))) — \(excerpt(p.text, 140))\n" }
        }
        s += "\n---\n\n\(L.t("report.local")) \(L.t("report.note.lang"))\n"
        return s
    }

    /// Prompt à donner à l'agent qui corrigera le mod : bugs par priorité avec les messages des joueurs,
    /// méthode de travail et compte rendu attendu.
    static func agentPrompt(_ m: ModState, maxItems: Int = 15) -> String {
        let (items, solved) = plan(m)
        let tags = m.postTags ?? [:]
        let untracked = m.posts.filter { tags[$0.id]?.isBug == true && tags[$0.id]?.trackedAs == nil }
        let version = m.stats.map { versionNumber($0.version) } ?? "—"

        var s = L.t("agent.intro", m.displayName, m.config.pageURL.absoluteString, version) + "\n\n"
        s += "## \(L.t("report.plan"))\n\n"
        if items.isEmpty { s += "\(L.t("report.none"))\n\n" }
        for (i, it) in items.prefix(maxItems).enumerated() {
            s += "### \(i + 1). \(it.bug.title) — \(L.t("report.prio.\(it.priority.key)"))\n\n"
            s += "- \(L.t("report.item.signals", it.reports, L.ago(it.bug.lastPost), versionNumber(it.bug.version)))\n"
            s += "- \(L.t("report.action")) \(L.t("report.action.\(it.action)"))\n"
            for msg in it.bug.messages.prefix(4) where !msg.text.isEmpty {
                s += "> \(L.t("agent.quote", msg.author, excerpt(msg.text, 600)))\n"
            }
            s += "\n"
        }
        if items.count > maxItems { s += "\(L.t("report.more", items.count - maxItems))\n\n" }
        if !solved.isEmpty {
            s += "## \(L.t("report.close"))\n\n\(L.t("agent.solved"))\n\n"
            for b in solved { s += "- \(b.title)\n" }
            s += "\n"
        }
        if !untracked.isEmpty {
            s += "## \(L.t("report.untracked"))\n\n\(L.t("agent.untracked"))\n\n"
            for p in untracked { s += "- \(L.t("agent.quote", p.author, excerpt(p.text, 300)))\n" }
            s += "\n"
        }
        s += "## \(L.t("agent.method"))\n\n\(L.t("agent.rules"))\n\n\(L.t("report.note.lang"))\n"
        return s
    }

    /// « True Directional Movement - Version 2.3.1 » → « 2.3.1 ».
    private static func versionNumber(_ v: String) -> String {
        guard let r = v.range(of: #"\d+(\.\d+)*[a-z]?\s*$"#, options: .regularExpression) else { return v.isEmpty ? "—" : v }
        return String(v[r]).trimmingCharacters(in: .whitespaces)
    }

    private static func excerpt(_ t: String, _ n: Int = 220) -> String {
        let one = t.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return one.count > n ? String(one.prefix(n)) + "…" : one
    }
}

// MARK: Lecture au format A4

/// Rapport ouvert dans sa propre fenêtre : mod et type de rapport.
struct ReportRequest: Codable, Hashable {
    var modId: String
    var ai: Bool
}

/// Page A4 claire (595 × 842 pt), quel que soit le thème de l'appli.
struct PaperPage: View {
    let text: String
    static let width: CGFloat = 595
    static let a4 = CGSize(width: 595, height: 842)

    var body: some View {
        MarkdownView(text: text)
            .padding(56)
            .frame(width: Self.width, alignment: .topLeading)
            .frame(minHeight: Self.width * 842 / 595, alignment: .topLeading)
            .background(Color.white)
            .environment(\.colorScheme, .light)
    }
}

struct ReportWindow: View {
    @EnvironmentObject var store: Store
    private var request: ReportRequest? { store.report }

    private var mod: ModState? { store.data.mods.first { $0.id == request?.modId } }
    private var text: String {
        guard let mod else { return "" }
        if request?.ai == true, let r = mod.aiReport { return r.text }
        return LocalAudit.markdown(mod, maxItems: 40)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Socle.M.space2) {
                Text(mod?.displayName ?? "").socle(Socle.T.label).foregroundStyle(Socle.C.textMuted).lineLimit(1)
                Spacer()
                CopyButton(title: L.t("ai.copyreport")) { text }
                if let mod { CopyButton(title: L.t("agent.copy")) { LocalAudit.agentPrompt(mod) } }
                Button(L.t("report.print")) { print() }
                    .buttonStyle(SocleButtonStyle(.primary, height: Socle.M.sizeControl)).fixedSize()
            }
            .padding(Socle.M.space3)
            .background(Socle.C.surfaceRaised)
            Divider().overlay(Socle.C.border)
            ScrollView {
                PaperPage(text: text)
                    .overlay(Rectangle().stroke(Socle.C.border, lineWidth: 1))
                    .padding(Socle.M.space6)
                    .frame(maxWidth: .infinity)
            }
            .background(Socle.C.bgInset)
        }
        .frame(minWidth: PaperPage.width + 80, minHeight: 500)
    }

    /// Fenêtre AppKit unique, réutilisée : une seconde scène SwiftUI empêchait la fenêtre principale de s'ouvrir.
    private static var window: NSWindow?

    static func show(_ store: Store) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PaperPage.width + 120, height: 900),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.title = L.t("report.window")
            w.contentView = NSHostingView(rootView: ReportWindow().environmentObject(store))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }

    /// Impression (ou « Enregistrer au format PDF » du dialogue) du rapport mis en pages A4.
    private func print() {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.paperSize = PaperPage.a4
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        guard let doc = PDFDocument(data: Self.pdf(text)),
              let op = doc.printOperation(for: info, scalingMode: .pageScaleNone, autoRotate: false) else { return }
        op.run()
    }

    /// PDF A4 vectoriel. Une vue SwiftUI hors fenêtre s'imprime blanche : chaque bloc est donc dessiné par ImageRenderer,
    /// et les pages se coupent entre deux blocs (un titre reste avec ce qui le suit), jamais au milieu d'une ligne.
    static func pdf(_ text: String) -> Data {
        let page = PaperPage.a4, margin: CGFloat = 56, width = page.width - 2 * margin, gap = Socle.M.space2
        var chunks: [String] = [], pending = ""
        for c in text.components(separatedBy: "\n\n").map({ $0.trimmingCharacters(in: .newlines) }) where !c.isEmpty {
            pending += pending.isEmpty ? c : "\n\n" + c
            if !c.hasPrefix("#") { chunks.append(pending); pending = "" }
        }
        if !pending.isEmpty { chunks.append(pending) }

        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: page)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        var y: CGFloat?
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            for chunk in chunks {
                let r = ImageRenderer(content: MarkdownView(text: chunk).frame(width: width).environment(\.colorScheme, .light))
                r.proposedSize = ProposedViewSize(width: width, height: nil)
                r.render { size, draw in
                    if y == nil || (y! + size.height > page.height - margin && y! > margin) {
                        if y != nil { ctx.endPDFPage() }
                        ctx.beginPDFPage(nil)
                        y = margin
                    }
                    ctx.saveGState()
                    ctx.translateBy(x: margin, y: page.height - y! - size.height)
                    draw(ctx)
                    ctx.restoreGState()
                    y! += size.height + gap
                }
            }
        }
        if y != nil { ctx.endPDFPage() }
        ctx.closePDF()
        return data as Data
    }
}
