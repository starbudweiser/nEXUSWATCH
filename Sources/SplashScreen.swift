// Splash animé commun aux applis SwiftUI (règle Socle « Splash animé », modèle : le splash de mORTEX).
// Fichier autonome, à copier tel quel dans une autre appli Swift :
//   1. au lancement (applicationWillFinishLaunching, avant l'ouverture des fenêtres) : Splash.shared.start(Splash.Config(…))
//   2. sur la vue racine de la fenêtre principale : .splashGated()
// Chronologie : t = 0 splash visible → t = 2 s fenêtre de l'appli → t = 4 s sortie du splash (600 ms).
// Fenêtre pas prête à 2 s : elle s'ouvre dès qu'elle l'est et le splash l'attend avant de sortir.
// « Réduire les animations » (Réglages Système) : splash fixe, mêmes durées.
import AppKit
import SwiftUI

@MainActor
final class Splash {
    struct Config {
        /// Nom de l'appli ; ses `accentLetters` premières lettres prennent le dégradé d'accent.
        var title: String
        var accentLetters = 1
        /// Sous-titre court (déjà traduit), affiché en capitales espacées.
        var subtitle: String
        /// Mention discrète en bas à droite (version…), facultative.
        var footer = ""
        var icon: NSImage = NSApp.applicationIconImage
        /// Dégradé d'accent (clair → soutenu) : première lettre, filet, lueur.
        var accent: (Color, Color) = (Color(red: 1, green: 0.757, blue: 0.353), Color(red: 1, green: 0.369, blue: 0.039))
    }

    static let shared = Splash()

    // Règle Socle : fenêtre de size-splash-width × size-splash-height (carte 476 × 166 et marge de 12 px).
    static let size = CGSize(width: 500, height: 190)
    static let openMainAfter: TimeInterval = 2
    static let minShown: TimeInterval = 4
    static let leaveDuration: TimeInterval = 0.6

    private var panel: NSPanel?
    private let model = SplashModel()
    private var shownAt = Date()
    private var mainOpenTime = false
    private var minShownReached = false
    private var mainShown = false
    private var leaving = false
    private var pending: NSWindow?
    private var gated = Set<ObjectIdentifier>()

    /// Trace la chronologie sur la sortie d'erreur si la variable SPLASH_TRACE est définie.
    private func trace(_ what: String) {
        guard ProcessInfo.processInfo.environment["SPLASH_TRACE"] != nil else { return }
        FileHandle.standardError.write(String(format: "splash %.3f s %@\n", Date().timeIntervalSince(shownAt), what).data(using: .utf8)!)
    }

    func start(_ config: Config) {
        guard panel == nil else { return }
        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        // pas d'ombre native : sur une fenêtre transparente, macOS la dessine autour du cadre entier
        p.hasShadow = false
        p.isMovable = false
        p.level = .floating
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView(rootView: SplashView(config: config, model: model))
        host.frame = NSRect(origin: .zero, size: Self.size)
        p.contentView = host
        p.center()
        p.orderFrontRegardless()
        panel = p
        shownAt = Date()
        model.appeared = true
        trace("splash visible")
        // fenêtre déjà créée (splash lancé tard) : retenue elle aussi
        for w in NSApp.windows where w !== p && w.canBecomeMain { gate(w) }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.openMainAfter) { [self] in
            mainOpenTime = true
            if let w = pending { reveal(w) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.minShown) { [self] in
            minShownReached = true
            leaveIfDone()
        }
        // garde-fou : sans fenêtre principale signalée, le splash ne reste pas indéfiniment
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [self] in
            mainShown = true
            leaveIfDone()
        }
    }

    /// Appelé quand la fenêtre principale reçoit sa vue (avant son affichage) : retenue jusqu'à t = 2 s.
    fileprivate func gate(_ window: NSWindow) {
        guard panel != nil, !mainShown, gated.insert(ObjectIdentifier(window)).inserted else { return }
        if mainOpenTime { reveal(window); return }
        trace("fenêtre prête, retenue (déjà visible : \(window.isVisible))")
        window.alphaValue = 0
        pending = window
    }

    private func reveal(_ window: NSWindow) {
        pending = nil
        window.alphaValue = 1
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel?.orderFrontRegardless()
        trace("fenêtre principale affichée")
        // le splash reste au moins un instant au-dessus d'une fenêtre ouverte tard
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            mainShown = true
            leaveIfDone()
        }
    }

    private func leaveIfDone() {
        guard minShownReached, mainShown, !leaving, panel != nil else { return }
        leaving = true
        trace("début de la sortie")
        model.leaving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.leaveDuration + 0.05) { [self] in
            panel?.orderOut(nil)
            panel = nil
            trace("splash fermé")
        }
    }
}

extension View {
    /// À poser sur la vue racine de la fenêtre principale : elle n'apparaît qu'à t = 2 s du splash.
    func splashGated() -> some View { background(SplashGate().frame(width: 0, height: 0)) }
}

private struct SplashGate: NSViewRepresentable {
    final class Probe: NSView {
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if let w = newWindow { MainActor.assumeIsolated { Splash.shared.gate(w) } }
        }
    }
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: Vue

@MainActor
private final class SplashModel: ObservableObject {
    @Published var appeared = false
    @Published var leaving = false
    var reduceMotion = false
}

private struct SplashView: View {
    let config: Splash.Config
    @ObservedObject var model: SplashModel

    private let card = CGSize(width: 476, height: 166)

    /// Animation après `delay` s, ou aucune si « réduire les animations » est actif.
    private func anim(_ a: Animation, _ delay: Double) -> Animation? {
        model.reduceMotion ? nil : a.delay(delay)
    }
    private static func curve(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ d: Double) -> Animation {
        .timingCurve(x1, y1, x2, y2, duration: d)
    }
    private var on: Bool { model.appeared || model.reduceMotion }

    var body: some View {
        ZStack {
            cardView
        }
        .frame(width: Splash.size.width, height: Splash.size.height)
        // sortie : zoom arrière avec rebond (easeInBack), fondu sur la fin
        .scaleEffect(model.leaving && !model.reduceMotion ? 0.05 : 1)
        .animation(model.reduceMotion ? nil : Self.curve(0.6, -0.28, 0.735, 0.045, 0.6), value: model.leaving)
        .opacity(model.leaving ? 0 : 1)
        .animation(model.reduceMotion ? nil : .easeIn(duration: 0.18).delay(0.42), value: model.leaving)
    }

    private var cardView: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return ZStack(alignment: .bottomTrailing) {
            // lueur d'accent derrière l'icône
            RadialGradient(colors: [config.accent.1.opacity(0.22), .clear], center: .center, startRadius: 0, endRadius: 120)
                .frame(width: 240, height: 240)
                .position(x: 80, y: card.height / 2)
                .opacity(on ? 1 : 0)
                .animation(anim(.easeOut(duration: 1.4), 0.3), value: on)

            HStack(spacing: 26) {
                icon
                text
            }
            .padding(.leading, 34).padding(.trailing, 30)
            .frame(width: card.width, height: card.height, alignment: .leading)

            if !config.footer.isEmpty {
                Text(config.footer.uppercased())
                    .font(.system(size: 9.5, weight: .medium)).tracking(0.6)
                    .foregroundStyle(Color(white: 0.667))
                    .padding(.trailing, 18).padding(.bottom, 10)
                    .opacity(on ? 1 : 0)
                    .animation(anim(.easeOut(duration: 0.6), 1.5), value: on)
            }

            Sheen(run: !model.reduceMotion).allowsHitTesting(false)
        }
        .frame(width: card.width, height: card.height)
        .background(LinearGradient(stops: [.init(color: Color(red: 0.204, green: 0.212, blue: 0.239), location: 0),
                                           .init(color: Color(red: 0.106, green: 0.110, blue: 0.129), location: 0.55),
                                           .init(color: Color(red: 0.071, green: 0.075, blue: 0.090), location: 1)],
                                   startPoint: UnitPoint(x: 0.33, y: 0), endPoint: UnitPoint(x: 0.67, y: 1)))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 12, y: 10)
        // entrée de la carte en 3D
        .opacity(on ? 1 : 0)
        .rotation3DEffect(.degrees(on ? 0 : 28), axis: (1, 0, 0), perspective: 0.5)
        .rotation3DEffect(.degrees(on ? 0 : -14), axis: (0, 1, 0), perspective: 0.5)
        .scaleEffect(on ? 1 : 0.92)
        .animation(anim(Self.curve(0.16, 1, 0.3, 1, 0.9), 0), value: on)
    }

    /// Icône de l'appli : arrivée en tourbillon, puis légère pulsation.
    private var icon: some View {
        TimelineView(.animation(paused: model.reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let beat = model.reduceMotion ? 1 : 1 + 0.025 * sin(t * 2 * .pi / 1.6)
            Image(nsImage: config.icon)
                .resizable().interpolation(.high)
                .frame(width: 108, height: 108)
                .scaleEffect(beat)
        }
        .shadow(color: config.accent.1.opacity(0.45), radius: 6)
        .rotationEffect(.degrees(on ? 0 : -420))
        .scaleEffect(on ? 1 : 0.2)
        .opacity(on ? 1 : 0)
        .animation(anim(Self.curve(0.22, 1, 0.36, 1, 1.3), 0), value: on)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(config.title.enumerated()), id: \.offset) { i, ch in
                    letter(String(ch), accent: i < config.accentLetters)
                        .opacity(on ? 1 : 0)
                        .blur(radius: on ? 0 : 3)
                        .offset(y: on ? 0 : 14)
                        .rotation3DEffect(.degrees(on ? 0 : -95), axis: (1, 0, 0), anchor: UnitPoint(x: 0.5, y: 0.85), perspective: 0.6)
                        .animation(anim(Self.curve(0.2, 1.2, 0.4, 1, 0.7), 0.45 + Double(i) * 0.07), value: on)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(config.title)
            .lineLimit(1)

            RoundedRectangle(cornerRadius: 1)
                .fill(LinearGradient(stops: [.init(color: config.accent.0, location: 0),
                                             .init(color: config.accent.1, location: 0.6),
                                             .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(height: 2)
                .scaleEffect(x: on ? 1 : 0, anchor: .leading)
                .animation(anim(Self.curve(0.65, 0, 0.35, 1, 0.7), 0.95), value: on)
                .padding(.top, 10).padding(.bottom, 9)

            Text(config.subtitle.uppercased())
                .font(.system(size: 15, weight: .semibold)).tracking(4)
                .foregroundStyle(Color(white: 0.847))
                .lineLimit(1).minimumScaleFactor(0.6)
                .opacity(on ? 1 : 0)
                .blur(radius: on ? 0 : 4)
                .scaleEffect(x: on ? 1 : 1.25, anchor: .leading)
                .animation(anim(Self.curve(0.16, 1, 0.3, 1, 0.9), 1.1), value: on)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Taille du titre : 50 pt comme mORTEX, réduite pour les noms longs afin de tenir dans la carte.
    private var titleSize: CGFloat { config.title.count <= 6 ? 50 : max(28, 50 * 6.4 / CGFloat(config.title.count)) }

    @ViewBuilder private func letter(_ s: String, accent: Bool) -> some View {
        let t = Text(s).font(.system(size: titleSize, weight: .heavy)).tracking(0.5)
        if accent {
            t.foregroundStyle(LinearGradient(colors: [config.accent.0, config.accent.1],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
        } else {
            t.foregroundStyle(.white)
        }
    }
}

/// Reflet qui balaie la carte une fois.
private struct Sheen: View {
    let run: Bool
    @State private var x: CGFloat = -0.6

    var body: some View {
        GeometryReader { g in
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: .white.opacity(0.10), location: 0.45),
                                   .init(color: .white.opacity(0.18), location: 0.5),
                                   .init(color: .white.opacity(0.10), location: 0.55),
                                   .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: g.size.width * 0.4, height: g.size.height * 2)
                .rotationEffect(.degrees(8))
                .offset(x: g.size.width * x, y: -g.size.height * 0.5)
        }
        .onAppear {
            guard run else { return }
            withAnimation(.easeInOut(duration: 1.1).delay(1.35)) { x = 1.4 }
        }
    }
}
