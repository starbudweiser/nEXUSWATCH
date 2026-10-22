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
        .defaultSize(width: 1400, height: 780)
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
    func applicationDidFinishLaunching(_ notification: Notification) { Socle.apply() }
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
        case .accent, .info: Socle.C.accentTint
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
    @EnvironmentObject var store: Store
    @State private var selection: String?

    var body: some View {
        let posts = store.state.posts
        if !store.state.postsEnabled { EmptyState(text: L.t("posts.disabled")) }
        else if posts.isEmpty { EmptyState(text: L.t("posts.empty")) }
        else {
            SplitLayout {
                ForEach(posts) { p in
                    ListRow(selected: selection == p.id, unread: store.isUnread(p)) {
                        selection = p.id
                    } content: {
                        HStack(spacing: Socle.M.space1_5) {
                            Text(p.author).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textStrong).lineLimit(1)
                            if p.sticky { Badge(text: L.t("badge.sticky"), kind: .warning) }
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
            case .mcp:
                ScrollView { MCPHelp().padding(Socle.M.space4) }
            case .export:
                EmptyState(text: L.t("ai.empty.export"))
            case .openai, .anthropic:
                if let r = mod.aiReport {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Socle.M.space3) {
                            Text(L.t("ai.generated", L.date(r.date), r.model)).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
                            Text(Self.markdown(r.text)).socle(Socle.T.reading).foregroundStyle(Socle.C.text)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(Socle.M.space4)
                    }
                } else {
                    EmptyState(text: L.t("ai.empty"))
                }
            }
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private func save(_ text: String, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(name).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url { try? text.write(to: url, atomically: true, encoding: .utf8) }
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

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space4) {
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
            HStack(spacing: Socle.M.space2) {
                Spacer()
                Button(L.t("action.cancel")) { dismiss() }
                    .buttonStyle(SocleButtonStyle(.secondary)).fixedSize()
                Button(L.t("action.save")) {
                    store.updateSettings(interval: interval, notifications: notify)
                    store.updateAI(ai, openAIKey: openAIKey, anthropicKey: anthropicKey)
                    dismiss()
                }
                .buttonStyle(SocleButtonStyle(.primary)).fixedSize()
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Socle.M.space6)
        .frame(width: 600)
        .background(Socle.C.surface)
        .onAppear {
            interval = store.data.intervalMinutes
            notify = store.data.notifications
            ai = store.ai
            openAIKey = Keychain.get("openai")
            anthropicKey = Keychain.get("anthropic")
        }
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
        }
    }

    private func field<F: View>(_ label: String, @ViewBuilder _ input: () -> F) -> some View {
        VStack(alignment: .leading, spacing: Socle.M.space1) {
            Text(label).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted)
            input().textFieldStyle(.roundedBorder).socle(Socle.T.mono)
        }
    }
}
