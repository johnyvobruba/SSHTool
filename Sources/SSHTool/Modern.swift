import SwiftUI
import AppKit

// Moderní vzhled: celé rozhraní (okno, lišty, boční panel, Úklid, nastavení) se přebarvuje podle
// barevného profilu. Každý profil má vlastní „značkové“ barvy – navigaci a dvoubarevný přechod pro
// aktivní prvky. Styl rozhraní (Výrazný / Jemný) určuje jen sílu přechodů, stínů a barevných ikon;
// velikosti tlačítek ani rozložení se nemění. Významové barvy (zelená/oranžová/červená) zůstávají z profilu.

/// Značkové barvy profilu.
struct Brand {
    let nav: String        // navigace a horní lišty
    let a: String          // začátek přechodu (aktivní prvky)
    let b: String          // konec přechodu
    let onGrad: String     // text na přechodu

    static func of(_ t: Theme) -> Brand {
        switch t.id {
        case "tokyo":      return Brand(nav: "#15161F", a: "#7AA2F7", b: "#A77CF5", onGrad: "#FFFFFF")
        case "nord":       return Brand(nav: "#343B49", a: "#2F8796", b: "#88C8DC", onGrad: "#FFFFFF")
        case "catppuccin": return Brand(nav: "#28243A", a: "#B4BEFE", b: "#F5C2E7", onGrad: "#1E1E2E")
        case "emerald":    return Brand(nav: "#0D1714", a: "#10A777", b: "#2CCFBA", onGrad: "#FFFFFF")
        case "walnut":     return Brand(nav: "#261C15", a: "#B5652E", b: "#E3A03C", onGrad: "#FFFFFF")
        case "sandstone":  return Brand(nav: "#D6BF9C", a: "#94592A", b: "#C98B2E", onGrad: "#FFFFFF")
        case "arctic":     return Brand(nav: "#E2E9F3", a: "#2F5BD3", b: "#1E98DE", onGrad: "#FFFFFF")
        default:           return Brand(nav: "#16181E", a: "#4A6E9E", b: "#3D82F7", onGrad: "#FFFFFF")   // Midnight Graphite
        }
    }

    /// Styl rozhraní: "vivid" (Výrazný, výchozí) | "subtle" (Jemný).
    static var vivid: Bool { UserDefaults.standard.string(forKey: "uiStyle") != "subtle" }
    static var styleKey: String { vivid ? "vivid" : "subtle" }
}

enum Modern {
    private static var t: Theme { ThemeStore.ui }
    static var brand: Brand { Brand.of(t) }
    private static var v: Bool { Brand.vivid }

    /// Smíchá dvě barvy (f = podíl druhé barvy).
    static func blend(_ a: String, _ b: String, _ f: CGFloat) -> SwiftUI.Color {
        let ca = NSColor(SwiftUI.Color(hex: a) ?? .gray).usingColorSpace(.sRGB) ?? .gray
        let cb = NSColor(SwiftUI.Color(hex: b) ?? .gray).usingColorSpace(.sRGB) ?? .gray
        return SwiftUI.Color(nsColor: ca.blended(withFraction: f, of: cb) ?? ca)
    }
    static func c(_ h: String) -> SwiftUI.Color { SwiftUI.Color(hex: h) ?? .gray }

    // MARK: přechody profilu
    static var gradA: SwiftUI.Color { c(brand.a) }
    static var gradB: SwiftUI.Color { c(brand.b) }
    static var onGrad: SwiftUI.Color { c(brand.onGrad) }
    /// Přechod aktivních prvků (tlačítka, úvodní panel Úklidu); v jemném stylu méně kontrastní.
    static var accentGradient: LinearGradient {
        LinearGradient(colors: v ? [gradA, gradB] : [gradA, blend(brand.a, brand.b, 0.45)],
                       startPoint: .leading, endPoint: .trailing)
    }

    static var windowGradient: LinearGradient {
        let d = t.isDark
        return LinearGradient(colors: [blend(t.sidebarBackground, brand.a, v ? (d ? 0.16 : 0.10) : (d ? 0.08 : 0.05)),
                                       blend(t.appBackground, brand.b, v ? (d ? 0.22 : 0.13) : (d ? 0.12 : 0.07))],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    /// Horní lišta (titulek + nástroje/záložky): navigační barva prolnutá s přechodem profilu.
    static var headerGradient: LinearGradient {
        let d = t.isDark
        let k: CGFloat = v ? (d ? 0.42 : 0.30) : (d ? 0.16 : 0.10)
        return LinearGradient(colors: [blend(brand.nav, brand.a, k), blend(brand.nav, brand.b, k * 0.9)],
                              startPoint: .leading, endPoint: .trailing)
    }
    /// Navigace (boční panel se servery / disky).
    static var nav: SwiftUI.Color {
        blend(t.sidebarBackground, brand.nav, v ? 0.75 : 0.35).opacity(t.isDark ? 0.92 : 0.85)
    }
    /// Výplň aktivní záložky / vybrané položky: barva profilu jemně tónovaná přechodem.
    static var selectedFill: SwiftUI.Color {
        blend(t.tabActiveBackground, brand.b, v ? (t.isDark ? 0.30 : 0.22) : 0.10)
    }
    static var glow: SwiftUI.Color { gradB.opacity(v ? (t.isDark ? 0.26 : 0.16) : (t.isDark ? 0.14 : 0.08)) }
    static var glass: SwiftUI.Color { t.isDark ? .white.opacity(0.05) : .black.opacity(0.035) }
    static var glassStrong: SwiftUI.Color { t.isDark ? .white.opacity(0.09) : .black.opacity(0.06) }
    static var glassStroke: SwiftUI.Color { t.isDark ? .white.opacity(0.10) : .black.opacity(0.09) }
    static var accent: SwiftUI.Color { SwiftUI.Color(hex: t.accentColor) ?? .blue }
    static var shadow: SwiftUI.Color { .black.opacity(v ? (t.isDark ? 0.28 : 0.14) : 0.12) }
    static var shadowRadius: CGFloat { v ? 9 : 5 }
}

/// Pozadí okna: přechod z barev profilu, barevný pás pod horní lištou a záře v rohu.
/// `header` = výška horní lišty včetně titulku (pás se k dolnímu okraji jemně rozplývá).
struct ModernBackground: View {
    var header: CGFloat = 0
    var body: some View {
        ZStack(alignment: .top) {
            Modern.windowGradient
            if header > 0 {
                Modern.headerGradient
                    .frame(height: header + 14)
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                                 .init(color: .black, location: header / (header + 14)),
                                                 .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
            }
            RadialGradient(colors: [Modern.glow, .clear], center: .topTrailing, startRadius: 10, endRadius: 700)
        }
        .ignoresSafeArea()
    }
}

/// Plastická barevná dlaždice s ikonou (Úklid, přehledy). Barva = odstín modulu sladěný s profilem.
struct TileIcon: View {
    let symbol: String
    let hue: String            // základní odstín (hex)
    var size: CGFloat = 28
    var glow = false

    var body: some View {
        let v = Brand.vivid
        let base = Modern.blend(hue, Modern.brand.a, v ? 0.22 : 0.45)
        let light = Modern.blend(hue, "#FFFFFF", v ? 0.28 : 0.12)
        let r = size * 0.29
        return ZStack {
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .fill(LinearGradient(colors: [light, base], startPoint: .top, endPoint: .bottom))
            // lesk v horní polovině = „plastický“ dojem (v jemném stylu slabší)
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .fill(LinearGradient(colors: [SwiftUI.Color.white.opacity(v ? 0.32 : 0.10), SwiftUI.Color.white.opacity(0)],
                                     startPoint: .top, endPoint: .center))
                .padding(1)
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .stroke(SwiftUI.Color.white.opacity(v ? 0.28 : 0.12), lineWidth: 0.8)
            Image(systemName: symbol).font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(SwiftUI.Color.white)
                .shadow(color: SwiftUI.Color.black.opacity(v ? 0.25 : 0), radius: 1, y: 0.5)
        }
        .frame(width: size, height: size)
        .shadow(color: (glow ? Modern.c(hue) : SwiftUI.Color.black).opacity(v ? (glow ? 0.55 : 0.25) : 0.10),
                radius: v ? (glow ? 7 : 3) : 2, y: v ? 1.5 : 0.5)
    }
}

extension View {
    /// Zaoblená skleněná karta; aktivní s rámečkem v přechodu profilu.
    func glassCard(radius: CGFloat = 12, active: Bool = false, fill: SwiftUI.Color? = nil) -> some View {
        let o: Double = Brand.vivid ? 0.95 : 0.6
        let activeStroke = LinearGradient(colors: [Modern.gradA.opacity(o), Modern.gradB.opacity(o)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing)
        return self.background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill ?? Modern.glass))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(active ? AnyShapeStyle(activeStroke) : AnyShapeStyle(Modern.glassStroke),
                        lineWidth: active ? (Brand.vivid ? 2 : 1.5) : 1))
            .shadow(color: Modern.shadow, radius: Modern.shadowRadius, y: 2)
    }
}

/// Průhledná titulková lišta – přechod okna sahá až nahoru.
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
