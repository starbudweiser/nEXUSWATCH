// Génère l'icône (1024 px) : carré arrondi sombre Socle, œil stylisé d'accent et point ambre (alerte).
import Cocoa
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 100, y: 100, width: size - 200, height: size - 200)
NSColor(srgbRed: 0.13, green: 0.13, blue: 0.13, alpha: 1).setFill()
NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185).fill()
let accent = NSColor(srgbRed: 0x0e/255, green: 0xa5/255, blue: 0xe9/255, alpha: 1)
// Contour de l'œil : deux arcs qui se rejoignent aux coins.
let eye = NSBezierPath()
let l = NSPoint(x: 230, y: 512), r = NSPoint(x: 794, y: 512)
eye.move(to: l)
eye.curve(to: r, controlPoint1: NSPoint(x: 390, y: 760), controlPoint2: NSPoint(x: 634, y: 760))
eye.curve(to: l, controlPoint1: NSPoint(x: 634, y: 264), controlPoint2: NSPoint(x: 390, y: 264))
eye.close() // pointe gauche en jointure arrondie, comme la droite
eye.lineWidth = 44; eye.lineJoinStyle = .round; accent.setStroke(); eye.stroke()
let font = NSFont.systemFont(ofSize: 230, weight: .heavy)
let s = NSAttributedString(string: "N", attributes: [.font: font, .foregroundColor: NSColor(white: 0.96, alpha: 1)])
let b = s.size()
s.draw(at: NSPoint(x: (size - b.width)/2, y: (size - b.height)/2 + 4))
NSColor(srgbRed: 0.98, green: 0.75, blue: 0.14, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 700, y: 700, width: 140, height: 140)).fill()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
