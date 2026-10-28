// Icône de nEXUSWATCH redessinée en vectoriel (mêmes cotes que Resources/make_icon.swift) pour le splash :
// l'œil cligne deux fois une fois l'arrivée de l'icône terminée.
import AppKit
import SwiftUI

struct BlinkingEyeIcon: View {
    @State private var openness = 1.0

    var body: some View {
        EyeIconShape(openness: openness)
            .task {
                guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
                // après l'arrivée en tourbillon de l'icône (1,3 s)
                try? await Task.sleep(for: .seconds(1.5))
                for _ in 0..<2 {
                    withAnimation(.easeIn(duration: 0.08)) { openness = 0 }
                    try? await Task.sleep(for: .seconds(0.1))
                    withAnimation(.easeOut(duration: 0.14)) { openness = 1 }
                    try? await Task.sleep(for: .seconds(0.3))
                }
            }
    }
}

/// `openness` : 1 œil ouvert, 0 paupière supérieure posée sur l'inférieure (le « N » est alors masqué).
private struct EyeIconShape: View, Animatable {
    var openness: Double
    var animatableData: Double {
        get { openness }
        set { openness = newValue }
    }

    var body: some View {
        Canvas { ctx, size in
            ctx.scaleBy(x: size.width / 1024, y: size.height / 1024)
            // repère de make_icon.swift (origine en bas) retourné : y → 1024 − y
            ctx.fill(Path(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerRadius: 185),
                     with: .color(Color(red: 0.13, green: 0.13, blue: 0.13)))
            let l = CGPoint(x: 230, y: 512), r = CGPoint(x: 794, y: 512)
            // paupière supérieure : de l'arc du haut (ouvert) à l'arc du bas (fermé)
            let up = 760 - 496 * openness
            var eye = Path()
            eye.move(to: l)
            eye.addCurve(to: r, control1: CGPoint(x: 390, y: up), control2: CGPoint(x: 634, y: up))
            eye.addCurve(to: l, control1: CGPoint(x: 634, y: 760), control2: CGPoint(x: 390, y: 760))
            // tracé fermé : pointe gauche en jointure arrondie, comme la droite (sinon deux bouts plats s'y croisent)
            eye.closeSubpath()
            var inner = ctx
            inner.clip(to: eye)
            inner.draw(Text("N").font(.system(size: 230, weight: .heavy)).foregroundColor(Color(white: 0.96)),
                       at: CGPoint(x: 512, y: 508))
            ctx.stroke(eye, with: .color(Color(red: 0x0e / 255, green: 0xa5 / 255, blue: 0xe9 / 255)),
                       style: StrokeStyle(lineWidth: 44, lineCap: .round, lineJoin: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: 700, y: 184, width: 140, height: 140)),
                     with: .color(Color(red: 0.98, green: 0.75, blue: 0.14)))
        }
    }
}
