// nEXUSWATCH — surveille des mods Nexus Mods (stats, posts, bugs) sans ouvrir sa page.
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// « NexusWatch --mcp » sert les données à un agent IA sans ouvrir de fenêtre.
@main
enum Launcher {
    static func main() {
        if CommandLine.arguments.contains("--mcp") { MCPServer.run() } else { NexusWatchApp.main() }
    }
}

struct NexusWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = Store()

    var body: some Scene {
        Window("nEXUSWATCH", id: "main") {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 1180, minHeight: 640)
                .task { await store.refreshAll() }
        }
        .defaultSize(width: 1327, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button(L.t("action.refresh").capitalized) { Task { await store.refreshCurrent() } }
                    .keyboardShortcut("r")
                Button(L.t("action.refreshall")) { Task { await store.refreshAll() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Socle.apply()
        UpdateCheck.start(repo: "nEXUSWATCH", lang: L.lang)  // nouvelle version ? (au plus une fois par jour)
    }
    // La fenêtre fermée, l'appli continue de vérifier en arrière-plan (badge du Dock et notifications).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Le WKWebView de lecture doit appartenir à une fenêtre pour que la page s'exécute normalement.
struct HiddenWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        host.addSubview(webView)
        host.alphaValue = 0
        return host
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

enum Tab: String, CaseIterable { case posts, bugs, files, ai }

struct RootView: View {
    @EnvironmentObject var store: Store
    @State private var tab: Tab = .posts
    @State private var settings = false
    @State private var adding = false

    var body: some View {
        HStack(spacing: 0) {
            ModSidebar(adding: $adding)
            Divider().overlay(Socle.C.border)
            if store.hasMods { main }
            else {
                VStack(spacing: Socle.M.space3) {
                    EmptyState(text: L.t("mods.empty")).frame(maxHeight: 120)
                    Button(L.t("mods.add")) { adding = true }
                        .buttonStyle(SocleButtonStyle(.primary)).fixedSize()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Socle.C.bg)
        .background(HiddenWebView(webView: store.fetcher.webView).frame(width: 1, height: 1))
        .sheet(isPresented: $settings) { SettingsView().environmentObject(store) }
        .sheet(isPresented: $adding) { AddModView().environmentObject(store) }
    }

    private var main: some View {
        VStack(spacing: 0) {
            HeaderBar(settings: $settings)
            Divider().overlay(Socle.C.border)
            StatsRow()
            if let q = quarantined, q > 0 {
                Callout(kind: .danger, text: L.t("quarantine", q))
                    .padding(.horizontal, Socle.M.space3).padding(.bottom, Socle.M.space3)
            }
            if let e = store.error {
                Callout(kind: .warning, text: e)
                    .padding(.horizontal, Socle.M.space3).padding(.bottom, Socle.M.space3)
            }
            TabsBar(tab: $tab)
            Divider().overlay(Socle.C.border)
            Group {
                switch tab {
                case .posts: PostsView()
                case .bugs: BugsView()
                case .files: FilesView()
                case .ai: if store.ai.enabled { AIView() } else { PostsView() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var quarantined: Int? { store.state.stats?.files.filter { $0.scan == "QUARANTINED" }.count }
}

// MARK: Mods suivis

struct ModSidebar: View {
    @EnvironmentObject var store: Store
    @Binding var adding: Bool
    @State private var removing: ModState?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Socle.M.space1_5) {
                Text(L.t("mods.title").uppercased()).socle(Socle.T.eyebrow).foregroundStyle(Socle.C.textSubtle)
                Spacer()
                Button { Task { await store.refreshAll() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(Socle.C.textMuted)
                    .disabled(store.busy || !store.hasMods).help(L.t("action.refreshall"))
                Button { adding = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).foregroundStyle(Socle.C.textMuted).help(L.t("mods.add"))
            }
            .padding(.horizontal, Socle.M.space3)
            .frame(minHeight: Socle.M.sizeBar + 8)
            Divider().overlay(Socle.C.border)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.data.mods) { m in
                        ListRow(selected: m.id == store.state.id, unread: m.unreadPosts + m.unreadBugs > 0) {
                            store.select(m.id)
                        } content: {
                            HStack(spacing: Socle.M.space1_5) {
                                Text(m.displayName).socle(Socle.T.labelStrong).lineLimit(2)
                                    .foregroundStyle(m.id == store.state.id ? Socle.C.warning : Socle.C.textStrong)
                                Spacer(minLength: 0)
                                if store.refreshing == m.id { ProgressView().controlSize(.mini) }
                                else if m.unreadPosts + m.unreadBugs > 0 { CountBadge(n: m.unreadPosts + m.unreadBugs) }
                            }
                            HStack(spacing: Socle.M.space1_5) {
                                Text(m.config.domain).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle).lineLimit(1)
                                if store.errors[m.id] != nil {
                                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Socle.C.warning)
                                }
                                if m.stats?.files.contains(where: { $0.scan == "QUARANTINED" }) == true {
                                    Image(systemName: "exclamationmark.octagon").foregroundStyle(Socle.C.danger)
                                }
                            }
                        }
                        .contextMenu {
                            Button(L.t("action.open")) { NSWorkspace.shared.open(m.config.pageURL) }
                            Button(L.t("mods.remove")) { removing = m }
                        }
                    }
                }
            }
        }
        .frame(width: 230)
        .background(Socle.C.surface)
        .confirmationDialog(L.t("mods.remove.confirm", removing?.displayName ?? ""),
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(L.t("mods.remove"), role: .destructive) { if let m = removing { store.removeMod(m.id) } }
        }
    }
}

struct AddModView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var mod = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space4) {
            Text(L.t("mods.add")).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong)
            VStack(alignment: .leading, spacing: Socle.M.space1_5) {
                Text(L.t("settings.mod")).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted)
                TextField("", text: $mod).textFieldStyle(.roundedBorder).socle(Socle.T.mono)
                if let problem { Text(problem).socle(Socle.T.meta).foregroundStyle(Socle.C.danger) }
            }
            Text(L.t("settings.note")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
            HStack(spacing: Socle.M.space2) {
                Spacer()
                Button(L.t("action.cancel")) { dismiss() }
                    .buttonStyle(SocleButtonStyle(.secondary)).fixedSize()
                Button(L.t("action.add")) {
                    problem = store.addMod(mod)
                    if problem == nil { dismiss() }
                }
                .buttonStyle(SocleButtonStyle(.primary)).fixedSize()
                .keyboardShortcut(.defaultAction)
                .disabled(mod.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Socle.M.space6)
        .frame(width: 520)
        .background(Socle.C.surface)
    }
}

// MARK: En-tête

struct HeaderBar: View {
    @EnvironmentObject var store: Store
    @Binding var settings: Bool

    var body: some View {
        HStack(spacing: Socle.M.space2) {
            Text("nEXUSWATCH").socle(Socle.T.title).foregroundStyle(Socle.C.textStrong)
            Text(store.state.stats?.name ?? L.t("app.subtitle"))
                .socle(Socle.T.body).foregroundStyle(Socle.C.textMuted).lineLimit(1)
            Spacer(minLength: Socle.M.space4)
            if store.loading {
                ProgressView().controlSize(.small)
                Text(L.t("status.loading")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(store.state.lastCheck.map { L.t("status.checked", L.ago($0)) } ?? L.t("status.never"))
                        .socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
                }
            }
            Button(L.t("action.readall")) { store.markAllRead() }
                .buttonStyle(SocleButtonStyle(.tertiary, height: Socle.M.sizeControl)).fixedSize()
                .disabled(store.unreadPosts + store.unreadBugs == 0)
            Button(L.t("action.open")) { NSWorkspace.shared.open(store.config.pageURL) }
                .buttonStyle(SocleButtonStyle(.secondary, height: Socle.M.sizeControl)).fixedSize()
            Button { settings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(SocleButtonStyle(.secondary, height: Socle.M.sizeControl)).fixedSize()
                .help(L.t("action.settings"))
            Button(L.t("action.refresh")) { Task { await store.refreshCurrent() } }
                .buttonStyle(SocleButtonStyle(.primary, height: Socle.M.sizeControl)).fixedSize()
                .disabled(store.loading)
        }
        .padding(.horizontal, Socle.M.space3)
        .frame(minHeight: Socle.M.sizeBar + 8)
        .background(Socle.C.surfaceRaised)
    }
}

// MARK: Stats

struct StatsRow: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let s = store.state.stats
        HStack(spacing: Socle.M.space2) {
            StatTile(label: L.t("stat.endorsements"), value: s.map { L.number($0.endorsements) }, delta: store.delta(\.endorsements))
            StatTile(label: L.t("stat.downloads"), value: s.map { L.number($0.downloads) }, delta: store.delta(\.downloads))
            StatTile(label: L.t("stat.unique"), value: s.map { L.number($0.uniqueDownloads) }, delta: store.delta(\.unique))
            StatTile(label: L.t("stat.posts"), value: store.state.lastCheck == nil ? nil : L.number(store.state.postCount),
                     note: store.unreadPosts > 0 ? "\(store.unreadPosts) \(L.t("badge.new").lowercased())" : nil)
            StatTile(label: L.t("stat.bugs"), value: store.state.lastCheck == nil ? nil : L.number(store.openBugs),
                     note: store.unreadBugs > 0 ? "\(store.unreadBugs) \(L.t("badge.new").lowercased())" : nil)
            StatTile(label: L.t("stat.version"), value: s?.version,
                     note: s?.updatedAt.map { L.t("stat.updated", L.ago($0)) })
        }
        .padding(Socle.M.space3)
    }
}

struct StatTile: View {
    let label: String
    let value: String?
    var delta: Int? = nil
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space1) {
            Text(label.uppercased()).socle(Socle.T.eyebrow).foregroundStyle(Socle.C.textSubtle)
            Text(value ?? "—").socle(Socle.T.stat).foregroundStyle(Socle.C.textStrong).monospacedDigit()
            if let delta, delta != 0 {
                Text(L.t("stat.delta", (delta > 0 ? "+" : "") + L.number(delta)))
                    .socle(Socle.T.meta).foregroundStyle(delta > 0 ? Socle.C.success : Socle.C.danger)
            } else if let note {
                Text(note).socle(Socle.T.meta).foregroundStyle(Socle.C.accentText).lineLimit(1)
            } else {
                Text(" ").socle(Socle.T.meta)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Socle.M.space3)
        .background(Socle.C.surface, in: RoundedRectangle(cornerRadius: Socle.M.radius))
        .overlay(RoundedRectangle(cornerRadius: Socle.M.radius).stroke(Socle.C.border, lineWidth: 1))
    }
}

// MARK: Onglets

struct TabsBar: View {
    @EnvironmentObject var store: Store
    @Binding var tab: Tab

    var body: some View {
        HStack(spacing: Socle.M.space4) {
            item(.posts, L.t("tab.posts"), store.unreadPosts)
            item(.bugs, L.t("tab.bugs"), store.unreadBugs)
            item(.files, L.t("tab.files"), 0)
            if store.ai.enabled { item(.ai, L.t("tab.ai"), 0) }
            Spacer()
        }
        .padding(.horizontal, Socle.M.space3)
        .background(Socle.C.bg)
    }

    private func item(_ t: Tab, _ title: String, _ unread: Int) -> some View {
        Button { tab = t } label: {
            HStack(spacing: Socle.M.space1_5) {
                Text(title).socle(Socle.T.label)
                    .foregroundStyle(tab == t ? Socle.C.textStrong : Socle.C.textMuted)
                if unread > 0 { CountBadge(n: unread) }
            }
            .padding(.vertical, Socle.M.space2_5)
            .overlay(alignment: .bottom) {
                Rectangle().fill(tab == t ? Socle.C.accent : .clear).frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct CountBadge: View {
    let n: Int
    var body: some View {
        Text("\(n)").socle(Socle.T.monoSm).foregroundStyle(Socle.C.onAccentFill)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Socle.C.accentFill, in: Capsule())
    }
}

struct Badge: View {
    enum Kind { case neutral, accent, success, warning, danger, info }
    let text: String
    var kind: Kind = .neutral

    var body: some View {
        Text(text).socle(Socle.T.caption).fontWeight(.semibold)
            .foregroundStyle(fg)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(bg, in: RoundedRectangle(cornerRadius: Socle.M.radius))
            .overlay(RoundedRectangle(cornerRadius: Socle.M.radius).stroke(border, lineWidth: 1))
            .fixedSize()
    }
    private var fg: Color {
        switch kind {
        case .neutral: Socle.C.textMuted
        case .accent: Socle.C.accentText
        case .success: Socle.C.success
        case .warning: Socle.C.warning
        case .danger: Socle.C.danger
        case .info: Socle.C.infoSoft
        }
    }
    private var bg: Color {
        switch kind {
        case .neutral: Socle.C.control
        case .accent, .info: Socle.C.control
        case .success: Socle.C.successBg
        case .warning: Socle.C.warningBg
        case .danger: Socle.C.dangerBg
        }
    }
    private var border: Color {
        switch kind {
        case .neutral: Socle.C.border
        case .accent, .info: Socle.C.infoBorder
        case .success: Socle.C.successBorder
        case .warning: Socle.C.warningBorder
        case .danger: Socle.C.dangerBorder
        }
    }
}

struct Callout: View {
    let kind: Badge.Kind
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Socle.M.space2) {
            Image(systemName: kind == .danger ? "exclamationmark.octagon" : "exclamationmark.triangle")
            Text(text).socle(Socle.T.body).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(kind == .danger ? Socle.C.dangerSoft : Socle.C.warningSoft)
        .padding(Socle.M.space3)
        .background(kind == .danger ? Socle.C.dangerBg : Socle.C.warningBg, in: RoundedRectangle(cornerRadius: Socle.M.radius))
        .overlay(RoundedRectangle(cornerRadius: Socle.M.radius)
            .stroke(kind == .danger ? Socle.C.dangerBorder : Socle.C.warningBorder, lineWidth: 1))
    }
}

struct EmptyState: View {
    let text: String
    var body: some View {
        Text(text).socle(Socle.T.bodyLg).foregroundStyle(Socle.C.textSubtle)
            .multilineTextAlignment(.center).padding(Socle.M.space6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Liste à gauche, détail à droite, séparés par un filet.
struct SplitLayout<List: View, Detail: View>: View {
    @ViewBuilder var list: List
    @ViewBuilder var detail: Detail
    var body: some View {
        HStack(spacing: 0) {
            ScrollView { LazyVStack(spacing: 0) { list } }
                .frame(width: 380)
                .background(Socle.C.surface)
            Divider().overlay(Socle.C.border)
            detail.frame(maxWidth: .infinity, maxHeight: .infinity).background(Socle.C.bg)
        }
    }
}

struct ListRow<Content: View>: View {
    let selected: Bool
    let unread: Bool
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Socle.M.space2) {
                Circle().fill(unread ? Socle.C.accent : .clear).frame(width: 7, height: 7).padding(.top, 5)
                VStack(alignment: .leading, spacing: Socle.M.space1) { content }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Socle.M.space3).padding(.vertical, Socle.M.space2_5)
            .background(selected ? Socle.C.surfaceSelected : hover ? Socle.C.surfaceHover : .clear)
            .overlay(alignment: .leading) { Rectangle().fill(selected ? Socle.C.accent : .clear).frame(width: 2) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        Divider().overlay(Socle.C.borderSubtle)
    }
}

struct MessageBlock: View {
    @EnvironmentObject var store: Store
    let message: Message
    var unread = false
    var sticky = false

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space2) {
            HStack(spacing: Socle.M.space2) {
                Text(message.author.isEmpty ? "—" : message.author).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textStrong)
                if store.isOwnMessage(message) { Badge(text: L.t("badge.author"), kind: .accent) }
                else if !message.role.isEmpty { Badge(text: message.role) }
                if sticky { Badge(text: L.t("badge.sticky"), kind: .warning) }
                if unread { Badge(text: L.t("badge.new"), kind: .info) }
                Spacer()
                Text(L.date(message.date)).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
            }
            Text(message.text).socle(Socle.T.reading).foregroundStyle(Socle.C.text)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Socle.M.space3)
        .background(Socle.C.surface, in: RoundedRectangle(cornerRadius: Socle.M.radius))
        .overlay(RoundedRectangle(cornerRadius: Socle.M.radius)
            .stroke(store.isOwnMessage(message) ? Socle.C.infoBorder : Socle.C.border, lineWidth: 1))
    }
}

// MARK: Posts

struct PostsView: View {
    enum Filter: String, CaseIterable { case all, bug, feature }
    @EnvironmentObject var store: Store
    @State private var selection: String?
    @State private var filter: Filter = .all

    var body: some View {
        let posts = store.state.posts.filter { p in
            switch store.jevActive ? filter : .all {
            case .all: true
            case .bug: store.tag(p)?.isBug == true
            case .feature: store.tag(p)?.isFeature == true
            }
        }
        if !store.state.postsEnabled { EmptyState(text: L.t("posts.disabled")) }
        else if store.state.posts.isEmpty { EmptyState(text: L.t("posts.empty")) }
        else {
            SplitLayout {
                if store.jevActive {
                    Picker("", selection: $filter) {
                        ForEach(Filter.allCases, id: \.self) { Text(L.t("posts.filter.\($0.rawValue)")).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().padding(Socle.M.space3)
                    Divider().overlay(Socle.C.borderSubtle)
                }
                ForEach(posts) { p in
                    ListRow(selected: selection == p.id, unread: store.isUnread(p)) {
                        selection = p.id
                    } content: {
                        HStack(spacing: Socle.M.space1_5) {
                            Text(p.author).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textStrong).lineLimit(1)
                            if p.sticky { Badge(text: L.t("badge.sticky"), kind: .warning) }
                            JevBadges(tag: store.tag(p))
                            Spacer()
                            Text(L.ago(p.lastActivity)).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
                        }
                        Text(p.text).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted).lineLimit(2)
                        if !p.replies.isEmpty {
                            Text(L.t("posts.replies", p.replies.count)).socle(Socle.T.meta).foregroundStyle(Socle.C.accentText)
                        }
                    }
                }
                if store.state.postCount > posts.count {
                    Text(L.t("posts.shown", posts.count, store.state.postCount))
                        .socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle).padding(Socle.M.space3)
                }
            } detail: {
                if let p = posts.first(where: { $0.id == selection }) { PostDetail(post: p) }
                else { EmptyState(text: L.t("select.post")) }
            }
            .onChange(of: selection) { _, id in
                // Marque lu après l'affichage, pour que le badge « Nouveau » reste visible dans le détail.
                if let p = posts.first(where: { $0.id == id }) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { store.markRead(p) }
                }
            }
        }
    }
}

struct PostDetail: View {
    @EnvironmentObject var store: Store
    let post: Post

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Socle.M.space3) {
                if let tag = store.tag(post), tag.isBug || tag.isFeature {
                    HStack(spacing: Socle.M.space2) {
                        JevBadges(tag: tag)
                        if let tracked = tag.trackedAs {
                            Text(L.t("jev.tracked", tracked)).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).lineLimit(1)
                        }
                    }
                }
                MessageBlock(message: Message(id: post.id, author: post.author, role: post.role, date: post.date, text: post.text),
                             unread: !store.state.seen.contains("p:\(post.id)"), sticky: post.sticky)
                ForEach(post.replies) { r in
                    MessageBlock(message: r, unread: store.isUnread(r)).padding(.leading, Socle.M.space6)
                }
                HStack {
                    Spacer()
                    Button(L.t("action.reply")) { NSWorkspace.shared.open(replyURL) }
                        .buttonStyle(SocleButtonStyle(.secondary, height: Socle.M.sizeControl)).fixedSize()
                }
            }
            .padding(Socle.M.space4)
        }
    }

    private var replyURL: URL {
        URL(string: store.config.pageURL.absoluteString + "?tab=posts&jump_to_comment=\(post.id)")!
    }
}

/// Conclusions de Jev sur un post : bug, demande de fonction.
struct JevBadges: View {
    let tag: PostTag?
    var body: some View {
        if let tag {
            if tag.isBug { Badge(text: L.t(tag.trackedAs == nil ? "badge.bug" : "badge.tracked"), kind: tag.trackedAs == nil ? .danger : .neutral) }
            if tag.isFeature { Badge(text: L.t("badge.feature"), kind: .info) }
        }
    }
}

// MARK: Bugs

struct BugsView: View {
    enum Filter: String, CaseIterable { case all, open, unread }
    @EnvironmentObject var store: Store
    @State private var selection: String?
    @State private var filter: Filter = .open

    var body: some View {
        let bugs = store.state.bugs.filter {
            switch filter {
            case .all: true
            case .open: !Store.isClosed($0)
            case .unread: store.isUnread($0)
            }
        }
        if !store.state.bugsEnabled { EmptyState(text: L.t("bugs.disabled")) }
        else if store.state.bugs.isEmpty { EmptyState(text: L.t("bugs.empty")) }
        else {
            SplitLayout {
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text(L.t("bugs.filter.\($0.rawValue)")).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().padding(Socle.M.space3)
                if store.untrackedBugPosts > 0 {
                    Callout(kind: .warning, text: L.t("bugs.inposts", store.untrackedBugPosts))
                        .padding([.horizontal, .bottom], Socle.M.space3)
                }
                Divider().overlay(Socle.C.borderSubtle)
                ForEach(bugs) { b in
                    ListRow(selected: selection == b.id, unread: store.isUnread(b)) {
                        selection = b.id
                    } content: {
                        Text(b.title).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textStrong).lineLimit(2)
                        HStack(spacing: Socle.M.space1_5) {
                            Badge(text: b.status, kind: Self.kind(b.status))
                            Badge(text: L.t("follow.\(store.follow(b).rawValue)"), kind: store.follow(b) == .released ? .success : .neutral)
                            Spacer()
                            Text(L.ago(b.lastPost)).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
                        }
                    }
                }
            } detail: {
                if let b = store.state.bugs.first(where: { $0.id == selection }) { BugDetail(bug: b).id(b.id) }
                else { EmptyState(text: L.t("select.bug")) }
            }
            .onChange(of: selection) { _, id in
                if let b = store.state.bugs.first(where: { $0.id == id }) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { store.markRead(b) }
                }
            }
        }
    }

    static func kind(_ status: String) -> Badge.Kind {
        let s = status.lowercased()
        if s.contains("fixed") { return .success }
        if s.contains("new") { return .info }
        if s.contains("looked") || s.contains("known") || s.contains("more info") { return .warning }
        return .neutral
    }
}

struct BugDetail: View {
    @EnvironmentObject var store: Store
    let bug: Bug
    @State private var note = ""
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Socle.M.space3) {
                Text(bug.title).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong).textSelection(.enabled)
                HStack(spacing: Socle.M.space2) {
                    Badge(text: bug.status, kind: BugsView.kind(bug.status))
                    Text(L.t("bugs.meta", bug.version.isEmpty ? "—" : bug.version, bug.priority.isEmpty ? "—" : bug.priority, bug.replies))
                        .socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
                }
                HStack(spacing: Socle.M.space2) {
                    Text(L.t("bugs.follow")).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted)
                    Picker("", selection: Binding(get: { store.follow(bug) }, set: { store.setFollow($0, for: bug) })) {
                        ForEach(Follow.allCases) { Text(L.t("follow.\($0.rawValue)")).tag($0) }
                    }
                    .labelsHidden().frame(width: 200)
                    Spacer()
                    Button(copied ? L.t("action.copied") : L.t("action.copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(store.report(bug), forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    }
                    .buttonStyle(SocleButtonStyle(.secondary, height: Socle.M.sizeControl)).fixedSize()
                    Button(L.t("action.openbug")) {
                        NSWorkspace.shared.open(URL(string: store.config.pageURL.absoluteString + "?tab=bugs")!)
                    }
                    .buttonStyle(SocleButtonStyle(.secondary, height: Socle.M.sizeControl)).fixedSize()
                }
                if store.ai.enabled { BugAuditBox(bug: bug) }
                if bug.messages.isEmpty {
                    Text(L.t("bugs.nomessages")).socle(Socle.T.body).foregroundStyle(Socle.C.textSubtle)
                }
                ForEach(Array(bug.messages.enumerated()), id: \.element.id) { i, m in
                    MessageBlock(message: m).padding(.leading, i == 0 ? 0 : Socle.M.space6)
                }
                VStack(alignment: .leading, spacing: Socle.M.space1_5) {
                    Text(L.t("bugs.note")).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted)
                    TextEditor(text: $note)
                        .socle(Socle.T.mono).scrollContentBackground(.hidden)
                        .padding(Socle.M.space2).frame(minHeight: 110)
                        .background(Socle.C.bgInset, in: RoundedRectangle(cornerRadius: Socle.M.radius))
                        .overlay(RoundedRectangle(cornerRadius: Socle.M.radius).stroke(Socle.C.borderControl, lineWidth: 1))
                        .onChange(of: note) { _, v in store.setNote(v, for: bug) }
                }
            }
            .padding(Socle.M.space4)
        }
        .onAppear { note = store.note(bug) }
    }
}

/// Audit IA d'un bug : lancé ici avec une API, ou copié pour l'agent avec l'export et le MCP.
struct BugAuditBox: View {
    @EnvironmentObject var store: Store
    let bug: Bug

    var body: some View {
        let ai = store.ai, audit = store.bugAudit(bug), key = store.auditKey(bug)
        VStack(alignment: .leading, spacing: Socle.M.space2) {
            HStack(spacing: Socle.M.space2) {
                Image(systemName: "sparkles").foregroundStyle(Socle.C.warning)
                Text(L.t("ai.bug.title")).socle(Socle.T.title).foregroundStyle(Socle.C.textStrong)
                if let audit { Text(L.t("ai.generated", L.date(audit.date), audit.model)).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle) }
                Spacer()
                if store.analyzing == key {
                    ProgressView().controlSize(.small)
                    Text(L.t("ai.analyzing")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
                }
                if let audit, ai.method.usesAPI { CopyButton(title: L.t("ai.copyreport")) { audit.text } }
                CopyButton(title: L.t("ai.bug.copy")) {
                    AIDigest.bugInstructions + "\n\n---\n\n" + AIDigest.bugData(bug, in: store.state)
                }
                if ai.method.usesAPI {
                    Button(L.t(audit == nil ? "ai.bug.run" : "ai.bug.rerun")) { Task { await store.audit(bug) } }
                        .buttonStyle(SocleButtonStyle(.primary, height: Socle.M.sizeControl)).fixedSize()
                        .disabled(store.analyzing != nil)
                }
            }
            if let e = store.aiErrors[key] { Callout(kind: .warning, text: e) }
            if let audit, ai.method.usesAPI {
                MarkdownView(text: audit.text)
            } else {
                Text(L.t(ai.method.usesAPI ? "ai.bug.empty" : "ai.bug.empty.\(ai.method.rawValue)"))
                    .socle(Socle.T.body).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Socle.M.space3)
        .background(Socle.C.surface, in: RoundedRectangle(cornerRadius: Socle.M.radius))
        .overlay(RoundedRectangle(cornerRadius: Socle.M.radius).stroke(Socle.C.warningBorder, lineWidth: 1))
    }
}

// MARK: Fichiers

struct FilesView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let files = store.state.stats?.files ?? []
        if files.isEmpty { EmptyState(text: L.t("files.empty")) }
        else {
            Table(files.sorted { $0.total > $1.total }) {
                TableColumn(L.t("files.name")) { f in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.name).socle(Socle.T.label).foregroundStyle(Socle.C.textStrong)
                        Text("\(f.category) · \(L.date(f.date))").socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
                    }
                }
                TableColumn(L.t("files.version")) { f in Text(f.version).socle(Socle.T.mono) }.width(80)
                TableColumn(L.t("files.total")) { f in Text(L.number(f.total)).socle(Socle.T.mono).monospacedDigit() }.width(80)
                TableColumn(L.t("files.unique")) { f in Text(L.number(f.unique)).socle(Socle.T.mono).monospacedDigit() }.width(80)
                TableColumn(L.t("files.scan")) { f in
                    if f.scan == "QUARANTINED" { Badge(text: L.t("scan.QUARANTINED"), kind: .danger) }
                    else if f.scan.isEmpty { Text("—") }
                    else { Badge(text: ["CLEAN", "SAFE", "PASSED", "SCANNED"].contains(f.scan) ? L.t("scan.ok") : f.scan.capitalized,
                                 kind: ["CLEAN", "SAFE", "PASSED", "SCANNED"].contains(f.scan) ? .success : .neutral) }
                }.width(120)
            }
            .scrollContentBackground(.hidden)
            .background(Socle.C.bg)
        }
    }
}

// MARK: Agent IA

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// Bouton de copie qui affiche « Copié » deux secondes.
struct CopyButton: View {
    let title: String
    var style: SocleButtonStyle = SocleButtonStyle(.secondary, height: Socle.M.sizeControl)
    let text: () -> String
    @State private var copied = false

    var body: some View {
        Button(copied ? L.t("action.copied") : title) {
            copyToPasteboard(text()); copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
        }
        .buttonStyle(style).fixedSize()
    }
}

struct AIView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let ai = store.ai, mod = store.state
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Socle.M.space2) {
                Text(L.t("ai.method.\(ai.method.rawValue)")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle).lineLimit(1)
                Spacer(minLength: Socle.M.space4)
                if store.analyzing == mod.id {
                    ProgressView().controlSize(.small)
                    Text(L.t("ai.analyzing")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
                }
                if let r = mod.aiReport, ai.method.usesAPI { CopyButton(title: L.t("ai.copyreport")) { r.text } }
                CopyButton(title: L.t("ai.copy")) { AIDigest.prompt(mod) }
                if ai.method == .export {
                    Button(L.t("ai.save")) { save(AIDigest.prompt(mod), name: mod.displayName) }
                        .buttonStyle(SocleButtonStyle(.secondary, height: Socle.M.sizeControl)).fixedSize()
                }
                Button(L.t("report.paper")) {
                    store.report = ReportRequest(modId: mod.id, ai: ai.method.usesAPI && mod.aiReport != nil)
                    ReportWindow.show(store)
                }
                .buttonStyle(SocleButtonStyle(.secondary, height: Socle.M.sizeControl)).fixedSize()
                if ai.method.usesAPI {
                    Button(L.t("ai.analyze")) { Task { await store.analyze(mod.id) } }
                        .buttonStyle(SocleButtonStyle(.primary, height: Socle.M.sizeControl)).fixedSize()
                        .disabled(store.analyzing != nil)
                }
            }
            .padding(Socle.M.space3)
            Divider().overlay(Socle.C.border)
            if let e = store.aiErrors[mod.id] {
                Callout(kind: .warning, text: e).padding(Socle.M.space3)
            }
            switch ai.method {
            case .mcp, .export:
                ScrollView {
                    VStack(alignment: .leading, spacing: Socle.M.space3) {
                        AgentPromptBox(mod: mod)
                        MarkdownView(text: LocalAudit.markdown(mod))
                    }
                    .padding(Socle.M.space4)
                }
            case .openai, .anthropic:
                if let r = mod.aiReport {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Socle.M.space3) {
                            Text(L.t("ai.generated", L.date(r.date), r.model)).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
                            AgentPromptBox(mod: mod)
                            MarkdownView(text: r.text)
                        }
                        .padding(Socle.M.space4)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Socle.M.space3) {
                            Text(L.t("ai.empty")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
                            AgentPromptBox(mod: mod)
                            MarkdownView(text: LocalAudit.markdown(mod))
                        }
                        .padding(Socle.M.space4)
                    }
                }
            }
        }
    }

    private func save(_ text: String, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(name).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }
}

/// Prompt de correction prêt à copier, replié par défaut au-dessus du rapport.
struct AgentPromptBox: View {
    let mod: ModState
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space2) {
            HStack(spacing: Socle.M.space2) {
                Button { open.toggle() } label: {
                    HStack(spacing: Socle.M.space1_5) {
                        Image(systemName: open ? "chevron.down" : "chevron.right").foregroundStyle(Socle.C.textSubtle)
                        Text(L.t("agent.title")).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textStrong)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                CopyButton(title: L.t("agent.copy")) { LocalAudit.agentPrompt(mod) }
            }
            Text(L.t("agent.hint")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
            if open {
                Text(LocalAudit.agentPrompt(mod)).socle(Socle.T.mono).foregroundStyle(Socle.C.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Socle.M.space2)
                    .background(Socle.C.bgInset, in: RoundedRectangle(cornerRadius: Socle.M.radius))
            }
        }
        .padding(Socle.M.space3)
        .overlay(RoundedRectangle(cornerRadius: Socle.M.radius).stroke(Socle.C.border, lineWidth: 1))
    }
}

/// Affichage Markdown par blocs (titres, listes, citations, code) ; SwiftUI n'interprète que le Markdown en ligne.
struct MarkdownView: View {
    let text: String

    private enum Block {
        case heading(Int, String), bullet(String, String), quote([String]), code([String]), paragraph(String), space
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space1_5) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in view(block) }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(_ block: Block) -> some View {
        switch block {
        case let .heading(level, t):
            Text(Self.inline(t))
                .socle(level == 1 ? Socle.T.display : level == 2 ? Socle.T.heading : level == 3 ? Socle.T.title : Socle.T.labelStrong)
                .foregroundStyle(Socle.C.textStrong)
                .padding(.top, level <= 2 ? Socle.M.space3 : Socle.M.space1)
        case let .bullet(mark, t):
            HStack(alignment: .firstTextBaseline, spacing: Socle.M.space1_5) {
                Text(mark).socle(Socle.T.reading).foregroundStyle(Socle.C.textSubtle).monospacedDigit()
                Text(Self.inline(t)).socle(Socle.T.reading).foregroundStyle(Socle.C.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, Socle.M.space2)
        case let .quote(lines):
            Text(Self.inline(lines.joined(separator: "\n"))).socle(Socle.T.reading).foregroundStyle(Socle.C.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Socle.M.space3)
                .overlay(alignment: .leading) { Rectangle().fill(Socle.C.border).frame(width: 2) }
        case let .code(lines):
            Text(lines.joined(separator: "\n")).socle(Socle.T.mono).foregroundStyle(Socle.C.text)
                .padding(Socle.M.space2).frame(maxWidth: .infinity, alignment: .leading)
                .background(Socle.C.bgInset, in: RoundedRectangle(cornerRadius: Socle.M.radius))
        case let .paragraph(t):
            Text(Self.inline(t)).socle(Socle.T.reading).foregroundStyle(Socle.C.text)
                .fixedSize(horizontal: false, vertical: true)
        case .space:
            Color.clear.frame(height: Socle.M.space1)
        }
    }

    static func inline(_ t: String) -> AttributedString {
        (try? AttributedString(markdown: t, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(t)
    }

    private static func blocks(_ text: String) -> [Block] {
        var out: [Block] = [], quote: [String] = [], code: [String]? = nil
        func flushQuote() { if !quote.isEmpty { out.append(.quote(quote)); quote = [] } }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { out.append(.code(c)); code = nil } else { flushQuote(); code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
            if line.hasPrefix(">") { quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)); continue }
            flushQuote()
            if line.isEmpty {
                if case .space? = out.last {} else if !out.isEmpty { out.append(.space) }
            } else if let r = line.range(of: #"^#{1,6} "#, options: .regularExpression) {
                out.append(.heading(line.distance(from: r.lowerBound, to: r.upperBound) - 1, String(line[r.upperBound...])))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                out.append(.bullet("•", String(line.dropFirst(2))))
            } else if let r = line.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                out.append(.bullet(line[r].trimmingCharacters(in: .whitespaces), String(line[r.upperBound...])))
            } else if line.range(of: #"^(-{3,}|\*{3,})$"#, options: .regularExpression) != nil {
                out.append(.space)
            } else {
                out.append(.paragraph(line))
            }
        }
        flushQuote()
        if let c = code { out.append(.code(c)) }
        return out
    }
}

/// Mode d'emploi du serveur MCP, avec la configuration prête à copier.
struct MCPHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space2) {
            Text(L.t("ai.mcp.note")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Text(MCPServer.configJSON).socle(Socle.T.monoSm).foregroundStyle(Socle.C.text).textSelection(.enabled)
                .padding(Socle.M.space2).frame(maxWidth: .infinity, alignment: .leading)
                .background(Socle.C.bgInset, in: RoundedRectangle(cornerRadius: Socle.M.radius))
                .overlay(RoundedRectangle(cornerRadius: Socle.M.radius).stroke(Socle.C.borderControl, lineWidth: 1))
            HStack(spacing: Socle.M.space2) {
                CopyButton(title: L.t("ai.mcp.copyjson")) { MCPServer.configJSON }
                CopyButton(title: L.t("ai.mcp.copyclaude")) { MCPServer.claudeCommand }
            }
        }
    }
}

// MARK: Réglages

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var interval = 15
    @State private var notify = true
    @State private var ai = AISettings()
    @State private var openAIKey = ""
    @State private var anthropicKey = ""
    @State private var typesafeKey = ""

    var body: some View {
        VStack(spacing: 0) {
            // Le contenu défile si la fenêtre est trop basse ; les boutons restent visibles.
            ScrollView {
                VStack(alignment: .leading, spacing: Socle.M.space4) { content }
                    .padding(Socle.M.space6)
            }
            Divider().overlay(Socle.C.border)
            HStack(spacing: Socle.M.space2) {
                Spacer()
                Button(L.t("action.cancel")) { dismiss() }
                    .buttonStyle(SocleButtonStyle(.secondary)).fixedSize()
                Button(L.t("action.save")) {
                    store.updateSettings(interval: interval, notifications: notify)
                    store.updateAI(ai, openAIKey: openAIKey, anthropicKey: anthropicKey, typesafeKey: typesafeKey)
                    dismiss()
                }
                .buttonStyle(SocleButtonStyle(.primary)).fixedSize()
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Socle.M.space6).padding(.vertical, Socle.M.space4)
        }
        .frame(width: 600)
        .frame(minHeight: 360, idealHeight: 640, maxHeight: 640)
        .background(Socle.C.surface)
        .onAppear {
            interval = store.data.intervalMinutes
            notify = store.data.notifications
            ai = store.ai
            openAIKey = Keychain.get("openai")
            anthropicKey = Keychain.get("anthropic")
            typesafeKey = Keychain.get("typesafe")
        }
    }

    @ViewBuilder private var content: some View {
            Text(L.t("settings.title")).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong)
            HStack {
                Text(L.t("settings.interval")).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted)
                Picker("", selection: $interval) {
                    ForEach([5, 15, 30, 60, 180], id: \.self) { Text(L.t("settings.minutes", $0)).tag($0) }
                }
                .labelsHidden().frame(width: 180)
            }
            Toggle(L.t("settings.notify"), isOn: $notify).socle(Socle.T.body)
            Text(L.t("settings.note")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
            Divider().overlay(Socle.C.border)
            aiSection
    }

    @ViewBuilder private var aiSection: some View {
        Toggle(L.t("ai.enable"), isOn: $ai.enabled).socle(Socle.T.labelStrong)
        Text(L.t("ai.enable.note")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
            .fixedSize(horizontal: false, vertical: true)
        if ai.enabled {
            HStack {
                Text(L.t("ai.method")).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted)
                Picker("", selection: $ai.method) {
                    ForEach(AIMethod.allCases) { Text(L.t("ai.method.\($0.rawValue)")).tag($0) }
                }
                .labelsHidden()
            }
            switch ai.method {
            case .export:
                Text(L.t("ai.empty.export")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
            case .openai:
                field(L.t("ai.url")) { TextField("https://api.openai.com/v1", text: $ai.openAIURL) }
                field(L.t("ai.model")) { TextField(L.t("ai.model.hint"), text: $ai.openAIModel) }
                field(L.t("ai.key.optional")) { SecureField("", text: $openAIKey) }
                Toggle(L.t("ai.auto"), isOn: $ai.auto).socle(Socle.T.body)
            case .anthropic:
                field(L.t("ai.model")) { TextField("claude-sonnet-5-5", text: $ai.anthropicModel) }
                field(L.t("ai.key")) { SecureField("", text: $anthropicKey) }
                Toggle(L.t("ai.auto"), isOn: $ai.auto).socle(Socle.T.body)
            case .mcp:
                MCPHelp()
            }
            Toggle(L.t("jev.enable"), isOn: $ai.jev).socle(Socle.T.body)
            Text(L.t("jev.note")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
                .fixedSize(horizontal: false, vertical: true)
            if ai.jev {
                field(L.t("jev.key")) {
                    HStack(spacing: Socle.M.space2) {
                        SecureField("", text: $typesafeKey)
                        Link(destination: Jev.console) { Text(L.t("jev.balance")) }
                            .buttonStyle(SocleButtonStyle(.secondary, height: Socle.M.sizeControl)).fixedSize()
                    }
                }
                let u = (store.data.jevUsage ?? JevUsage()).thisMonth
                Text(L.t("jev.usage", u.requests, L.number(u.inputTokens + u.outputTokens), L.number(u.inputTokens), L.number(u.outputTokens)))
                    .socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).monospacedDigit()
            }
        }
    }

    private func field<F: View>(_ label: String, @ViewBuilder _ input: () -> F) -> some View {
        VStack(alignment: .leading, spacing: Socle.M.space1) {
            Text(label).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted)
            input().textFieldStyle(.roundedBorder).socle(Socle.T.mono)
        }
    }
}
