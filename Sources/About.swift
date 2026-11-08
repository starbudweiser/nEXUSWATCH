// Fenêtre « À propos de nEXUSWATCH » : modèle Socle (DESIGN/Socle/swift/AboutWindow.swift), textes dans les 4 langues.
import AppKit

/// Fenêtre à nous plutôt que le panneau standard, dont la zone de texte a une hauteur fixe qui rogne les textes longs.
@MainActor
enum About {
    private static var window: NSWindow?

    private static let sideMargin: CGFloat = 28
    private static let textWidth: CGFloat = 300

    static func show() {
        if window == nil { window = makeWindow() }
        guard let window else { return }
        center(window)
        if ProcessInfo.processInfo.environment["SPLASH_QUIET"] != nil { window.orderBack(nil); return }  // essais discrets
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Centrée sur la fenêtre de l'appli ; sans fenêtre visible, au centre de l'écran.
    private static func center(_ window: NSWindow) {
        let others = NSApp.windows.filter { $0 !== window && $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }
        guard let host = others.first(where: { $0.isKeyWindow || $0.isMainWindow }) ?? others.first else { window.socleCenter(); return }
        window.setFrameOrigin(NSPoint(x: host.frame.midX - window.frame.width / 2, y: host.frame.midY - window.frame.height / 2))
    }

    private static func label(_ text: String, size: CGFloat = 12, bold: Bool = false, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
            .foregroundColor: secondary ? NSColor.secondaryLabelColor : NSColor.labelColor, .paragraphStyle: paragraph])
        // « n » du nom dans le bleu du logo (règle Socle « Nom de l'appli »)
        let name = (text as NSString).range(of: "nEXUSWATCH")
        if name.location != NSNotFound {
            attributed.addAttribute(.foregroundColor, value: NSColor(srgbRed: 0x0e / 255, green: 0xa5 / 255, blue: 0xe9 / 255, alpha: 1),
                                    range: NSRange(location: name.location, length: 1))
        }
        field.attributedStringValue = attributed
        field.alignment = .center
        field.preferredMaxLayoutWidth = textWidth
        field.isSelectable = false
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(lessThanOrEqualToConstant: textWidth).isActive = true
        return field
    }

    private static func makeWindow() -> NSWindow {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 84).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 84).isActive = true

        let views: [NSView] = [
            icon,
            label("nEXUSWATCH", size: 17, bold: true),
            label(L.t("about.version", version, build), secondary: true),
            label(L.t("about.tagline")),
            label("Starbudweiser & Claude Code (Anthropic)", bold: true),
            label(L.t("about.license")),
            label(L.t("about.disclaimer"), secondary: true),
        ]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(6, after: views[1])
        stack.setCustomSpacing(18, after: views[2])
        stack.edgeInsets = NSEdgeInsets(top: 28, left: sideMargin, bottom: 28, right: sideMargin)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Largeur fixée : le texte garde ses marges de chaque côté quelle que soit la langue.
        stack.widthAnchor.constraint(equalToConstant: textWidth + 2 * sideMargin).isActive = true

        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L.t("about.menu")
        window.isReleasedWhenClosed = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        content.layoutSubtreeIfNeeded()  // les textes à la ligne ne connaissent leur hauteur qu'après une première passe
        window.setContentSize(content.fittingSize)
        return window
    }
}
