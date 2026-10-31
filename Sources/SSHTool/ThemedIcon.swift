import AppKit

/// Ikona aplikace v Docku podle barevného profilu (Midnight = původní ikona z balíčku).
/// Kreslí se vektorově ve stejném motivu jako AppIcon.png: okno terminálu s „>_“ a zámek „SSH“.
/// Pozn.: macOS mění za běhu jen ikonu v Docku / ⌘Tab; Finder a Launchpad ukazují ikonu z balíčku.
@MainActor
enum ThemedIcon {
    static let key = "SSHTool.themedIcon"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    static func apply(_ t: Theme = ThemeStore.ui) {
        guard enabled, t.id != Theme.midnight.id else { NSApp.applicationIconImage = nil; return }
        NSApp.applicationIconImage = render(t)
    }

    /// PNG ikony (pro build-app.sh: ikona přibaleného RDP klienta s nápisem „RDP“).
    static func writePNG(_ t: Theme, label: String, to path: String) -> Bool {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        render(t, label: label).draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    static func render(_ t: Theme, size: CGFloat = 1024, label: String = "SSH") -> NSImage {
        func c(_ hex: String) -> NSColor { TabbyTheme.nsColor(hex) }
        let accent = c(t.accentColor)
        return NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let g = NSGraphicsContext.current?.cgContext else { return false }
            g.scaleBy(x: size / 1024, y: size / 1024)

            // podklad: zaoblený čtverec s jemným přechodem
            let base = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
            NSGraphicsContext.saveGraphicsState()
            g.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: NSColor.black.withAlphaComponent(0.45).cgColor)
            c(t.appBackground).setFill(); base.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGradient(starting: c(t.sidebarBackground).blended(withFraction: 0.12, of: .white) ?? c(t.sidebarBackground),
                       ending: c(t.appBackground))?.draw(in: base, angle: 90)
            c(t.borderColor).withAlphaComponent(0.8).setStroke()
            base.lineWidth = 3; base.stroke()

            // okno terminálu
            let win = NSBezierPath(roundedRect: NSRect(x: 210, y: 252, width: 600, height: 488), xRadius: 42, yRadius: 42)
            c(t.background).setFill(); win.fill()
            NSGraphicsContext.saveGraphicsState()
            win.addClip()
            c(t.toolbarBackground).setFill()
            NSRect(x: 210, y: 252, width: 600, height: 100).fill()
            c(t.borderColor).setFill()
            NSRect(x: 210, y: 350, width: 600, height: 4).fill()
            NSGraphicsContext.restoreGraphicsState()
            c(t.textTertiary).withAlphaComponent(0.7).setStroke()
            win.lineWidth = 7; win.stroke()
            for (i, hex) in ["#FF5F57", "#FEBC2E", "#28C840"].enumerated() {
                c(hex).setFill()
                NSBezierPath(ovalIn: NSRect(x: 262 + CGFloat(i) * 66, y: 284, width: 40, height: 40)).fill()
            }

            if label == "RDP" {
                // vzdálená plocha: kurzor myši místo výzvy terminálu
                NSGraphicsContext.saveGraphicsState()
                g.setShadow(offset: .zero, blur: 18, color: c(t.foreground).withAlphaComponent(0.5).cgColor)
                let arrow = NSBezierPath()
                arrow.move(to: NSPoint(x: 300, y: 410)); arrow.line(to: NSPoint(x: 300, y: 600))
                arrow.line(to: NSPoint(x: 346, y: 556)); arrow.line(to: NSPoint(x: 378, y: 626))
                arrow.line(to: NSPoint(x: 410, y: 612)); arrow.line(to: NSPoint(x: 378, y: 543))
                arrow.line(to: NSPoint(x: 440, y: 543)); arrow.close()
                arrow.lineJoinStyle = .round
                c(t.foreground).setFill(); arrow.fill()
                c(t.background).setStroke(); arrow.lineWidth = 8; arrow.stroke()
                NSGraphicsContext.restoreGraphicsState()
            } else {
            // výzva „>_“
            NSGraphicsContext.saveGraphicsState()
            g.setShadow(offset: .zero, blur: 18, color: c(t.foreground).withAlphaComponent(0.5).cgColor)
            c(t.foreground).setStroke()
            let chevron = NSBezierPath()
            chevron.move(to: NSPoint(x: 290, y: 432)); chevron.line(to: NSPoint(x: 368, y: 500)); chevron.line(to: NSPoint(x: 290, y: 568))
            chevron.lineWidth = 34; chevron.lineCapStyle = .round; chevron.lineJoinStyle = .round
            chevron.stroke()
            c(t.foreground).setFill()
            NSBezierPath(roundedRect: NSRect(x: 380, y: 580, width: 112, height: 26), xRadius: 13, yRadius: 13).fill()
            NSGraphicsContext.restoreGraphicsState()
            }

            // zámek „SSH“ v barvě zvýraznění profilu
            NSGraphicsContext.saveGraphicsState()
            g.setShadow(offset: .zero, blur: 30, color: accent.withAlphaComponent(0.65).cgColor)
            let shackle = NSBezierPath()
            shackle.appendArc(withCenter: NSPoint(x: 706, y: 578), radius: 70, startAngle: 180, endAngle: 0, clockwise: false)
            shackle.move(to: NSPoint(x: 636, y: 578)); shackle.line(to: NSPoint(x: 636, y: 615))
            shackle.move(to: NSPoint(x: 776, y: 578)); shackle.line(to: NSPoint(x: 776, y: 615))
            shackle.lineWidth = 30; shackle.lineCapStyle = .butt
            (accent.blended(withFraction: 0.35, of: c(t.toolbarBackground)) ?? accent).setStroke()
            shackle.stroke()
            let body = NSBezierPath(roundedRect: NSRect(x: 574, y: 610, width: 266, height: 200), xRadius: 34, yRadius: 34)
            (c(t.toolbarBackground).blended(withFraction: 0.18, of: accent) ?? c(t.toolbarBackground)).setFill()
            body.fill()
            accent.setStroke(); body.lineWidth = 6; body.stroke()
            NSGraphicsContext.restoreGraphicsState()
            let font = NSFont.systemFont(ofSize: 112, weight: .bold)
            let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: accent])
            let ts = text.size()
            text.draw(at: NSPoint(x: 707 - ts.width / 2, y: 710 - ts.height / 2))
            return true
        }
    }
}
