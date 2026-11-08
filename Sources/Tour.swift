// nEXUSWATCH — visite guidée : un calque assombrit la fenêtre, éclaire la zone expliquée et lit la voix de l'étape.
// Voix : Resources/tour/tour-<langue>-<empreinte>.m4a (tools/gen_tour_audio.py : ElevenLabs en français et en anglais,
// voix locale en espagnol et en italien). L'empreinte (SHA-256 de « langue|titre. texte », 16 caractères) change avec le
// texte : une étape réécrite sans nouvelle voix est lue par la voix du système.
import AVFoundation
import CryptoKit
import SwiftUI

enum TourTarget: Hashable { case sidebar, stats, tabs, settings, watch }

struct TourStep {
    let key: String
    let target: TourTarget?
    var title: String { L.t("tour.\(key).title") }
    var text: String { L.t("tour.\(key).text") }
}

@MainActor
final class Tour: ObservableObject {
    static let shared = Tour()
    static let steps: [TourStep] = [
        TourStep(key: "welcome", target: nil),
        TourStep(key: "mods", target: .sidebar),
        TourStep(key: "stats", target: .stats),
        TourStep(key: "tabs", target: .tabs),
        TourStep(key: "ai", target: .tabs),
        TourStep(key: "watch", target: .watch),
        TourStep(key: "settings", target: .settings),
        TourStep(key: "end", target: nil),
    ]

    @Published private(set) var index: Int?
    @Published var muted = UserDefaults.standard.bool(forKey: "tour.muted") {
        didSet { UserDefaults.standard.set(muted, forKey: "tour.muted"); muted ? stopVoice() : speak() }
    }
    private weak var store: Store?
    private var selectionBefore: String?
    private var player: AVAudioPlayer?
    private let synth = AVSpeechSynthesizer()

    var step: TourStep? { index.map { Self.steps[$0] } }

    /// Au premier lancement, une fois le splash parti.
    func startIfFirstRun(_ store: Store) {
        guard !UserDefaults.standard.bool(forKey: "tour.done") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in self?.start(store) }
    }

    func start(_ store: Store) {
        self.store = store
        selectionBefore = store.data.selected
        go(0)
    }

    func next() { if let i = index { i + 1 < Self.steps.count ? go(i + 1) : finish() } }
    func previous() { if let i = index, i > 0 { go(i - 1) } }

    func finish() {
        stopVoice()
        index = nil
        UserDefaults.standard.set(true, forKey: "tour.done")
        if let store, let before = selectionBefore { store.data.selected = before; store.save() }
    }

    private func go(_ i: Int) {
        // La zone expliquée doit être à l'écran : la Veille pour son étape, un mod pour les autres.
        if let store {
            if Self.steps[i].target == .watch { store.selectWatch() }
            else if Self.steps[i].target != nil, store.showModule, let first = store.data.mods.first { store.select(first.id) }
        }
        index = i
        speak()
    }

    // MARK: Voix

    static func audioName(_ lang: String, _ step: TourStep) -> String {
        let digest = SHA256.hash(data: Data("\(lang)|\(step.title). \(step.text)".utf8))
        return "tour-\(lang)-" + digest.map { String(format: "%02x", $0) }.joined().prefix(16)
    }

    private func speak() {
        stopVoice()
        guard !muted, let step else { return }
        if let url = Bundle.main.url(forResource: Self.audioName(L.lang, step), withExtension: "m4a", subdirectory: "tour"),
           let p = try? AVAudioPlayer(contentsOf: url) {
            player = p
            p.play()
        } else {
            let u = AVSpeechUtterance(string: "\(step.title). \(step.text)".replacingOccurrences(of: "nEXUSWATCH", with: "Nexus Watch"))
            u.voice = AVSpeechSynthesisVoice(language: L.lang)
            synth.speak(u)
        }
    }

    private func stopVoice() {
        player?.stop(); player = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }
}

// MARK: Repères

struct TourAnchorKey: PreferenceKey {
    static var defaultValue: [TourTarget: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TourTarget: Anchor<CGRect>], nextValue: () -> [TourTarget: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Zone que la visite guidée peut éclairer.
    func tourAnchor(_ target: TourTarget) -> some View {
        // transform (et non anchorPreference) : garde les repères des vues contenues, comme la ligne Veille dans la barre latérale.
        transformAnchorPreference(key: TourAnchorKey.self, value: .bounds) { $0[target] = $1 }
    }

    /// Calque de la visite, posé sur la vue racine.
    func tourOverlay() -> some View {
        overlayPreferenceValue(TourAnchorKey.self) { anchors in
            GeometryReader { proxy in TourOverlay(anchors: anchors, proxy: proxy) }
        }
    }
}

// MARK: Calque

struct TourOverlay: View {
    @ObservedObject private var tour = Tour.shared
    let anchors: [TourTarget: Anchor<CGRect>]
    let proxy: GeometryProxy

    private let bubbleWidth: CGFloat = 380

    var body: some View {
        if let i = tour.index, let step = tour.step {
            let size = proxy.size
            let hole = step.target.flatMap { anchors[$0] }.map { proxy[$0].insetBy(dx: -6, dy: -6) }
            ZStack(alignment: .topLeading) {
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: size))
                    if let hole { p.addRoundedRect(in: hole, cornerSize: CGSize(width: 8, height: 8)) }
                }
                .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
                .contentShape(Rectangle())
                .onTapGesture {}
                if let hole {
                    RoundedRectangle(cornerRadius: 8).stroke(Socle.C.accentText, lineWidth: 2)
                        .frame(width: hole.width, height: hole.height).offset(x: hole.minX, y: hole.minY)
                        .allowsHitTesting(false)
                }
                bubble(step, i)
                    .frame(width: bubbleWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(position(hole, size))
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .animation(.easeInOut(duration: 0.25), value: i)
            .transition(.opacity)
        }
    }

    /// À droite de la zone si la place le permet, sinon dessous, sinon dessus ; au centre sans zone.
    private func position(_ hole: CGRect?, _ size: CGSize) -> CGSize {
        let margin: CGFloat = 16, h: CGFloat = 230
        guard let r = hole else { return CGSize(width: (size.width - bubbleWidth) / 2, height: (size.height - h) / 2) }
        let clampX = { (x: CGFloat) in min(max(margin, x), size.width - bubbleWidth - margin) }
        let clampY = { (y: CGFloat) in min(max(margin, y), size.height - h - margin) }
        if size.width - r.maxX > bubbleWidth + 2 * margin { return CGSize(width: r.maxX + margin, height: clampY(r.minY)) }
        if size.height - r.maxY > h + margin { return CGSize(width: clampX(r.minX), height: r.maxY + margin) }
        return CGSize(width: clampX(r.minX), height: clampY(r.minY - h - margin))
    }

    private func bubble(_ step: TourStep, _ i: Int) -> some View {
        VStack(alignment: .leading, spacing: Socle.M.space3) {
            HStack(spacing: Socle.M.space2) {
                Text(L.t("tour.count", i + 1, Tour.steps.count)).socle(Socle.T.eyebrow).foregroundStyle(Socle.C.textSubtle)
                Spacer()
                Button { tour.muted.toggle() } label: {
                    Image(systemName: tour.muted ? "speaker.slash" : "speaker.wave.2")
                }
                .buttonStyle(.plain).foregroundStyle(Socle.C.textMuted)
                .help(L.t(tour.muted ? "tour.sound.on" : "tour.sound.off"))
            }
            Text(branded: step.title).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong)
            Text(branded: step.text).socle(Socle.T.body).foregroundStyle(Socle.C.text)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Socle.M.space2) {
                if i + 1 < Tour.steps.count {
                    Button(L.t("tour.skip")) { tour.finish() }
                        .buttonStyle(SocleButtonStyle(.tertiary, height: Socle.M.sizeControl)).fixedSize()
                }
                Spacer()
                if i > 0 {
                    Button(L.t("tour.previous")) { tour.previous() }
                        .buttonStyle(SocleButtonStyle(.secondary, height: Socle.M.sizeControl)).fixedSize()
                }
                Button(L.t(i + 1 < Tour.steps.count ? "tour.next" : "tour.done")) { tour.next() }
                    .buttonStyle(SocleButtonStyle(.primary, height: Socle.M.sizeControl)).fixedSize()
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Socle.M.space4)
        .background(Socle.C.surfaceRaised, in: RoundedRectangle(cornerRadius: Socle.M.radius))
        .overlay(RoundedRectangle(cornerRadius: Socle.M.radius).stroke(Socle.C.border, lineWidth: 1))
    }
}
