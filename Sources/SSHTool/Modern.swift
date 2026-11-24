import SwiftUI
import AppKit

// Moderní vzhled (inspirace okny Úklidu): okno s jemným přechodem z barev zvoleného profilu,
// obsah na zaoblených „skleněných“ kartách. Barvy zůstávají podle barevného profilu.

enum Modern {
    private static var t: Theme { ThemeStore.ui }

    /// Smíchá dvě barvy profilu (t = podíl druhé barvy).
    static func blend(_ a: String, _ b: String, _ f: CGFloat) -> SwiftUI.Color {
        let ca = NSColor(SwiftUI.Color(hex: a) ?? .gray).usingColorSpace(.sRGB) ?? .gray
        let cb = NSColor(SwiftUI.Color(hex: b) ?? .gray).usingColorSpace(.sRGB) ?? .gray
        return SwiftUI.Color(nsColor: ca.blended(withFraction: f, of: cb) ?? ca)
    }

    static var windowGradient: LinearGradient {
        LinearGradient(colors: [blend(t.sidebarBackground, t.accentColor, t.isDark ? 0.10 : 0.06),
                                blend(t.appBackground, t.accentColor, t.isDark ? 0.24 : 0.12)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var glow: SwiftUI.Color { (SwiftUI.Color(hex: t.accentColor) ?? .blue).opacity(t.isDark ? 0.20 : 0.12) }
    static var glass: SwiftUI.Color { t.isDark ? .white.opacity(0.05) : .black.opacity(0.035) }
    static var glassStrong: SwiftUI.Color { t.isDark ? .white.opacity(0.09) : .black.opacity(0.06) }
    static var glassStroke: SwiftUI.Color { t.isDark ? .white.opacity(0.10) : .black.opacity(0.09) }
    static var accent: SwiftUI.Color { SwiftUI.Color(hex: t.accentColor) ?? .blue }
}

/// Pozadí okna: přechod z barev profilu + jemná záře v rohu.
struct ModernBackground: View {
    var body: some View {
        ZStack {
            Modern.windowGradient
            RadialGradient(colors: [Modern.glow, .clear], center: .topTrailing, startRadius: 10, endRadius: 700)
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Zaoblená skleněná karta (jako v Úklidu); aktivní s tenkým rámečkem v barvě profilu.
    func glassCard(radius: CGFloat = 12, active: Bool = false, fill: SwiftUI.Color? = nil) -> some View {
        self.background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill ?? Modern.glass))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(active ? Modern.accent.opacity(0.6) : Modern.glassStroke, lineWidth: active ? 1.5 : 1))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }
}

/// Průhledná titulková lišta – přechod okna sahá až nahoru (jako v Úklidu).
struct TransparentTitlebar: NSViewRepresentable {
    final class V: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            w.titlebarAppearsTransparent = true
            w.styleMask.insert(.fullSizeContentView)
            w.isMovableByWindowBackground = false
        }
    }
    func makeNSView(context: Context) -> V { V() }
    func updateNSView(_ v: V, context: Context) {}
}
