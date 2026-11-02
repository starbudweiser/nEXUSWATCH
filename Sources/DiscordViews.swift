// nEXUSWATCH — vues du module Discord : fils des forums (liste/détail) et réglages du robot.
import SwiftUI

extension DiscordThread {
    func url(_ guild: String) -> URL { URL(string: "https://discord.com/channels/\(guild)/\(id)")! }
}

/// « Sans réponse depuis 26 h » / « … 3 j ».
func discordWaiting(since date: Date) -> String {
    let hours = max(1, Int(Date().timeIntervalSince(date) / 3600))
    return hours < 48 ? L.t("discord.waiting.h", hours) : L.t("discord.waiting.d", hours / 24)
}

// MARK: Écran principal

struct DiscordView: View {
    enum Filter: String, CaseIterable { case all, unread, waiting }
    @EnvironmentObject var store: Store
    @Binding var settings: Bool
    @State private var filter: Filter = .all
    @State private var forum = ""
    @State private var selection: String?

    var body: some View {
        let d = store.discord
        VStack(spacing: 0) {
            header
            Divider().overlay(Socle.C.border)
            stats
            if let e = store.discordError {
                Callout(kind: .warning, text: e)
                    .padding(.horizontal, Socle.M.space3).padding(.bottom, Socle.M.space3)
            }
            Divider().overlay(Socle.C.border)
            let threads = visible(d)
            if d.enabledThreads.isEmpty {
                EmptyState(text: L.t(d.lastCheck == nil && store.discordError == nil ? "status.loading" : "discord.empty"))
            } else {
                SplitLayout {
                    VStack(spacing: Socle.M.space2) {
                        Picker("", selection: $filter) {
                            ForEach(Filter.allCases, id: \.self) { Text(L.t("discord.filter.\($0.rawValue)")).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        if d.forums.count > 1 {
                            Picker("", selection: $forum) {
                                Text(L.t("discord.forum.all")).tag("")
                                ForEach(d.forums.filter(\.enabled)) { Text($0.name).tag($0.id) }
                            }
                            .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(Socle.M.space3)
                    Divider().overlay(Socle.C.borderSubtle)
                    ForEach(threads) { t in row(t, d) }
                } detail: {
                    if let t = d.threads.first(where: { $0.id == selection }) { DiscordDetail(thread: t).id(t.id) }
                    else { EmptyState(text: L.t("discord.select")) }
                }
                .onChange(of: selection) { _, id in
                    if let t = store.discord.threads.first(where: { $0.id == id }) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { store.markRead(t) }
                    }
                }
            }
        }
    }

    private func visible(_ d: DiscordState) -> [DiscordThread] {
        d.enabledThreads.filter { t in
            (forum.isEmpty || t.forumId == forum) && {
                switch filter {
                case .all: true
                case .unread: d.isUnread(t)
                case .waiting: d.awaitingSupport(t)
                }
            }()
        }
    }

    private func row(_ t: DiscordThread, _ d: DiscordState) -> some View {
        ListRow(selected: selection == t.id, unread: d.isUnread(t)) {
            selection = t.id
        } content: {
            Text(t.title).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textStrong).lineLimit(2)
            HStack(spacing: Socle.M.space1_5) {
                if let f = d.forum(t) { Badge(text: f.name) }
                ForEach(d.tagNames(t), id: \.self) { Badge(text: $0, kind: Self.tagKind($0)) }
            }
            HStack(spacing: Socle.M.space1_5) {
                Text(L.t("discord.by", t.author)).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).lineLimit(1)
                Spacer(minLength: 0)
                Text(L.ago(t.lastActivity)).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
            }
            if d.awaitingSupport(t) {
                Text(discordWaiting(since: t.created)).socle(Socle.T.meta).foregroundStyle(Socle.C.warning)
            } else if t.messages.count > 1 {
                Text(L.t("discord.messages", t.messages.count)).socle(Socle.T.meta).foregroundStyle(Socle.C.accentText)
            }
        }
    }

    static func tagKind(_ name: String) -> Badge.Kind {
        let n = name.lowercased()
        if ["solved", "resolved", "résolu", "resuelto", "risolto"].contains(where: n.contains) { return .success }
        if n.contains("bug") || n.contains("crash") { return .danger }
        if n.contains("info") { return .warning }
        return .neutral
    }

    private var header: some View {
        HStack(spacing: Socle.M.space2) {
            Text(branded: "nEXUSWATCH").socle(Socle.T.title).foregroundStyle(Socle.C.textStrong)
            Text(store.discord.guildName.isEmpty ? L.t("discord.title") : "Discord · \(store.discord.guildName)")
                .socle(Socle.T.body).foregroundStyle(Socle.C.textMuted).lineLimit(1)
            Spacer(minLength: Socle.M.space4)
            if store.discordBusy {
                ProgressView().controlSize(.small)
                Text(L.t("status.loading")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(store.discord.lastCheck.map { L.t("status.checked", L.ago($0)) } ?? L.t("status.never"))
                        .socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
                }
            }
            Button(L.t("action.readall")) { store.markAllDiscordRead() }
                .buttonStyle(SocleButtonStyle(.tertiary, height: Socle.M.sizeControl)).fixedSize()
                .disabled(store.discord.unreadThreads == 0)
            Button(L.t("discord.server")) {
                NSWorkspace.shared.open(URL(string: "https://discord.com/channels/\(store.discord.guildId)")!)
            }
            .buttonStyle(SocleButtonStyle(.secondary, height: Socle.M.sizeControl)).fixedSize()
            .disabled(store.discord.guildId.isEmpty)
            Button { settings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(SocleButtonStyle(.secondary, height: Socle.M.sizeControl)).fixedSize()
                .help(L.t("action.settings"))
            Button(L.t("action.refresh")) { Task { await store.refreshDiscord() } }
                .buttonStyle(SocleButtonStyle(.primary, height: Socle.M.sizeControl)).fixedSize()
                .disabled(store.discordBusy)
        }
        .padding(.horizontal, Socle.M.space3)
        .frame(minHeight: Socle.M.sizeBar + 8)
        .background(Socle.C.surfaceRaised)
    }

    private var stats: some View {
        let d = store.discord
        let waiting = d.awaiting.filter { d.forum($0)?.enabled ?? true }
        let loaded = d.lastCheck != nil
        return HStack(spacing: Socle.M.space2) {
            StatTile(label: L.t("discord.stat.unread"), value: loaded ? L.number(d.unreadThreads) : nil)
            StatTile(label: L.t("discord.stat.waiting"), value: loaded ? L.number(waiting.count) : nil,
                     note: waiting.map(\.created).min().map { L.t("discord.stat.oldest", discordWaiting(since: $0)) })
            StatTile(label: L.t("discord.stat.threads"), value: loaded ? L.number(d.enabledThreads.count) : nil)
            StatTile(label: L.t("discord.stat.forums"), value: loaded ? L.number(d.forums.filter(\.enabled).count) : nil)
        }
        .padding(Socle.M.space3)
    }
}

// MARK: Détail d'un fil

struct DiscordDetail: View {
    @EnvironmentObject var store: Store
    let thread: DiscordThread

    var body: some View {
        let d = store.discord
        ScrollView {
            VStack(alignment: .leading, spacing: Socle.M.space3) {
                Text(thread.title).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong).textSelection(.enabled)
                HStack(spacing: Socle.M.space2) {
                    if let f = d.forum(thread) { Badge(text: f.name) }
                    ForEach(d.tagNames(thread), id: \.self) { Badge(text: $0, kind: DiscordView.tagKind($0)) }
                    if d.awaitingSupport(thread) { Badge(text: discordWaiting(since: thread.created), kind: .warning) }
                    if thread.locked { Badge(text: L.t("discord.badge.locked")) }
                    else if thread.archived { Badge(text: L.t("discord.badge.archived")) }
                    Spacer()
                    Button(L.t("discord.reply")) { NSWorkspace.shared.open(thread.url(d.guildId)) }
                        .buttonStyle(SocleButtonStyle(.secondary, height: Socle.M.sizeControl)).fixedSize()
                }
                if thread.messages.isEmpty {
                    Text(L.t("discord.nomessages")).socle(Socle.T.body).foregroundStyle(Socle.C.textSubtle)
                }
                ForEach(Array(thread.messages.enumerated()), id: \.element.id) { i, m in
                    DiscordMessageBlock(message: m, unread: d.isUnread(m), own: m.authorId == d.ownerId)
                        .padding(.leading, i == 0 ? 0 : Socle.M.space6)
                }
            }
            .padding(Socle.M.space4)
        }
    }
}

struct DiscordMessageBlock: View {
    let message: DiscordMessage
    let unread: Bool
    let own: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space2) {
            HStack(spacing: Socle.M.space2) {
                Text(message.author).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textStrong)
                if own { Badge(text: L.t("badge.author"), kind: .accent) }
                else if message.isBot { Badge(text: L.t("discord.badge.bot")) }
                if unread { Badge(text: L.t("badge.new"), kind: .info) }
                Spacer()
                Text(L.date(message.date)).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
            }
            if !message.text.isEmpty {
                Text(message.text).socle(Socle.T.reading).foregroundStyle(Socle.C.text)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(message.files, id: \.self) { f in
                HStack(spacing: Socle.M.space1_5) {
                    Image(systemName: "paperclip")
                    Text(f.name).socle(Socle.T.mono)
                    if f.size > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(f.size), countStyle: .file))
                            .socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
                    }
                }
                .foregroundStyle(Socle.C.accentText)
            }
        }
        .padding(Socle.M.space3)
        .background(Socle.C.surface, in: RoundedRectangle(cornerRadius: Socle.M.radius))
        .overlay(RoundedRectangle(cornerRadius: Socle.M.radius).stroke(own ? Socle.C.infoBorder : Socle.C.border, lineWidth: 1))
    }
}

// MARK: Réglages

/// Bulle d'aide Socle : fond plein bleu, texte foncé, icône dans un carré.
struct SocleBubble: View {
    let title: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: Socle.M.space2) {
            Image(systemName: "info").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Socle.C.bubbleIcon, in: RoundedRectangle(cornerRadius: Socle.M.radius))
            VStack(alignment: .leading, spacing: Socle.M.space1) {
                Text(title).socle(Socle.T.labelStrong)
                Text(text).socle(Socle.T.body).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Socle.C.onBubble)
        }
        .padding(.horizontal, Socle.M.space2_5).padding(.vertical, Socle.M.space2)
        .frame(maxWidth: 420, alignment: .leading)
        .background(Socle.C.bubbleHelp, in: RoundedRectangle(cornerRadius: Socle.M.radiusMd))
    }
}

struct DiscordSettings: View {
    @EnvironmentObject var store: Store
    @Binding var applicationId: String
    @Binding var token: String
    @State private var replacing = false
    @State private var help = false
    @State private var testing = false
    @State private var checks: [DiscordCheck] = []
    @State private var removing = false

    var body: some View {
        Text(L.t("discord.settings.title")).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textStrong)
        Text(branded: L.t("discord.settings.note")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
            .fixedSize(horizontal: false, vertical: true)
        Button { help.toggle() } label: {
            HStack(spacing: Socle.M.space1_5) {
                Image(systemName: "questionmark.circle")
                Text(L.t("discord.help.button")).socle(Socle.T.label)
            }
            .foregroundStyle(Socle.C.accentText)
        }
        .buttonStyle(.plain)
        if help { SocleBubble(title: L.t("discord.help.title"), text: L.t("discord.help.steps")) }

        field(L.t("discord.appid")) { TextField("", text: $applicationId) }
        VStack(alignment: .leading, spacing: Socle.M.space1) {
            Text(L.t("discord.token")).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted)
            if store.hasDiscordToken && !replacing {
                HStack(spacing: Socle.M.space2) {
                    Text("••••••••••••").socle(Socle.T.mono).foregroundStyle(Socle.C.textSubtle)
                    Text(L.t("discord.token.saved")).socle(Socle.T.meta).foregroundStyle(Socle.C.success)
                    Spacer()
                    Button(L.t("discord.token.replace")) { replacing = true }
                        .buttonStyle(SocleButtonStyle(.secondary, height: Socle.M.sizeControl)).fixedSize()
                }
            } else {
                SecureField("", text: $token).textFieldStyle(.roundedBorder).socle(Socle.T.mono)
            }
        }
        HStack(spacing: Socle.M.space2) {
            if let url = Store.inviteURL(applicationId) {
                CopyButton(title: L.t("discord.invite.copy")) { url.absoluteString }
                Button(L.t("discord.invite.open")) { NSWorkspace.shared.open(url) }
                    .buttonStyle(SocleButtonStyle(.secondary, height: Socle.M.sizeControl)).fixedSize()
            }
            Spacer()
            if testing { ProgressView().controlSize(.small) }
            Button(L.t("discord.test")) {
                testing = true
                Task {
                    checks = await store.testDiscord(token: token)
                    testing = false
                }
            }
            .buttonStyle(SocleButtonStyle(.primary, height: Socle.M.sizeControl)).fixedSize()
            .disabled(testing)
        }
        ForEach(checks) { c in
            HStack(alignment: .firstTextBaseline, spacing: Socle.M.space1_5) {
                Image(systemName: c.ok ? "checkmark.circle" : "xmark.octagon")
                Text(c.text).socle(Socle.T.body).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(c.ok ? Socle.C.success : Socle.C.danger)
        }
        if !store.discord.forums.isEmpty {
            Text(L.t("discord.forums")).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted)
            ForEach(store.discord.forums) { f in
                Toggle(isOn: Binding(get: { f.enabled }, set: { store.setForum(f.id, enabled: $0) })) {
                    Text(f.name).socle(Socle.T.body)
                }
            }
        }
        if store.hasDiscordToken {
            Button(L.t("discord.remove")) { removing = true }
                .buttonStyle(SocleButtonStyle(.secondary, height: Socle.M.sizeControl)).fixedSize()
                .confirmationDialog(L.t("discord.remove.confirm"), isPresented: $removing) {
                    Button(L.t("discord.remove"), role: .destructive) { store.removeDiscord(); replacing = false; checks = [] }
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
