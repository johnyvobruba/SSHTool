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
    var strength: CGFloat = 1   // síla barevné horní lišty
    // Volitelné přesné barvy profilu (Neon Orchid); bez nich se odvozují z nav / a / b.
    var header: (String, String)? = nil      // horní lišta
    var primary: (String, String)? = nil     // hlavní tlačítko (akce)
    var tab: (String, String)? = nil         // aktivní záložka
    var tabText: String? = nil
    var sel: (String, String)? = nil         // vybraný server / položka navigace
    var selText: String? = nil
    var hero: (String, String)? = nil        // úvodní panel Úklidu
    var heroText2: String? = nil
    var light: LightSurface? = nil           // barvy pro světlou pracovní plochu
    var primaryHover: (String, String)? = nil      // hlavní tlačítko při najetí
    var primaryDark: (String, String)? = nil       // hlavní tlačítko na tmavém úvodním panelu
    var primaryDarkHover: (String, String)? = nil
    var primaryDarkText: String? = nil
    var selStripe: String? = nil                   // levý proužek vybrané položky navigace
    var tile: (String, String, String)? = nil      // jednotné dlaždice modulů (horní, dolní, odlesk)

    static func of(_ t: Theme) -> Brand {
        switch t.id {
        case "tokyo":      return Brand(nav: "#15161F", a: "#7AA2F7", b: "#A77CF5", onGrad: "#FFFFFF")
        case "nord":       return Brand(nav: "#343B49", a: "#2F8796", b: "#88C8DC", onGrad: "#FFFFFF")
        case "catppuccin": return Brand(nav: "#28243A", a: "#B4BEFE", b: "#F5C2E7", onGrad: "#1E1E2E")
        case "emerald":    return Brand(nav: "#0D1714", a: "#10A777", b: "#2CCFBA", onGrad: "#FFFFFF")
        case "walnut":     return Brand(nav: "#261C15", a: "#B5652E", b: "#E3A03C", onGrad: "#FFFFFF")
        case "sandstone":  return Brand(nav: "#D6BF9C", a: "#94592A", b: "#C98B2E", onGrad: "#FFFFFF")
        case "orchid":     return Brand(nav: "#30143F", a: "#922DD0", b: "#96358D", onGrad: "#FFFFFF",
                                        header: ("#482064", "#96358D"), primary: ("#BC167E", "#9C146F"),
                                        tab: ("#E7C6FA", "#CF9FEE"), tabText: "#321343",
                                        sel: ("#8C28BD", "#70209C"), selText: "#FFFFFF",
                                        hero: ("#60218C", "#A42A87"), heroText2: "#F0DFF7",
                                        light: LightSurface(text: "#32183F", text2: "#705D7D", icon: "#78528E",
                                                            hover: "#EEE2F6", line: "#DED0E8", statCard: "#EFE5F7",
                                                            cardStroke: "#DDC9EB", resultCard: "#FCF9FE",
                                                            secondaryFill: "#EBDCF4", secondaryText: "#51236C",
                                                            inactiveSel: "#E9DFEF", accent: "#922DD0"),
                                        primaryHover: ("#CD208E", "#AD187D"))
        case "anthracite": return Brand(nav: "#292C2F", a: "#C4CBD2", b: "#8E979F", onGrad: "#25282B",
                                        header: ("#303336", "#565B60"), primary: ("#505A64", "#38414A"),
                                        tab: ("#E1E4E7", "#BEC4CA"), tabText: "#25282B",
                                        sel: ("#555E67", "#424A52"), selText: "#FFFFFF",
                                        hero: ("#303438", "#626B74"), heroText2: "#DFE4E9",
                                        light: LightSurface(text: "#292D31", text2: "#616970", icon: "#626D77",
                                                            hover: "#E4E7EA", line: "#CDD2D7", statCard: "#E7EBEF",
                                                            cardStroke: "#C9D0D7", resultCard: "#F9FAFB",
                                                            secondaryFill: "#E2E6EA", secondaryText: "#39434D",
                                                            inactiveSel: "#E0E3E6", accent: "#59636D"),
                                        primaryHover: ("#5C6772", "#434C56"),
                                        primaryDark: ("#E3E7EB", "#BCC4CC"), primaryDarkHover: ("#F0F3F6", "#CED5DC"),
                                        primaryDarkText: "#262B30", selStripe: "#D9DFE5",
                                        tile: ("#74808C", "#414B55", "#AEB8C2"))
        case "arctic":     return Brand(nav: "#E2E9F3", a: "#2F5BD3", b: "#1E98DE", onGrad: "#FFFFFF")
        default:           return Brand(nav: "#16181E", a: "#4A6E9E", b: "#3D82F7", onGrad: "#FFFFFF")   // Midnight Graphite
        }
    }

    /// Styl rozhraní: "vivid" (Výrazný, výchozí) | "subtle" (Jemný).
    static var vivid: Bool { UserDefaults.standard.string(forKey: "uiStyle") != "subtle" }
    static var styleKey: String { vivid ? "vivid" : "subtle" }
}

/// Barvy prvků na světlé pracovní ploše u profilu s tmavými lištami.
struct LightSurface {
    let text, text2, icon, hover, line, statCard, cardStroke, resultCard, secondaryFill, secondaryText, inactiveSel: String
    var accent: String? = nil        // akcent / indikátor na světlé ploše
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

    /// Hlavní akce (Prohledat, Vyčistit…) – u Neon Orchid růžová, jinak přechod profilu.
    static var primaryGradient: LinearGradient { primaryGradient() }
    /// onDark = tlačítko na tmavém úvodním panelu (Anthracite: stříbrné), hover = při najetí myší.
    static func primaryGradient(onDark: Bool = false, hover: Bool = false) -> LinearGradient {
        let pd = onDark ? (hover ? (brand.primaryDarkHover ?? brand.primaryDark) : brand.primaryDark) : nil
        guard let p = pd ?? (hover ? (brand.primaryHover ?? brand.primary) : brand.primary) else { return accentGradient }
        return LinearGradient(colors: v ? [c(p.0), c(p.1)] : [c(p.0), blend(p.0, p.1, 0.5)], startPoint: .top, endPoint: .bottom)
    }
    static var primaryText: SwiftUI.Color { primaryText() }
    static func primaryText(onDark: Bool = false) -> SwiftUI.Color {
        if onDark, brand.primaryDark != nil { return c(brand.primaryDarkText ?? "#000000") }
        return brand.primary == nil ? onGrad : .white
    }
    /// Proužek pod aktivní záložkou (na světlé záložce tmavší akcent plochy).
    static var tabIndicator: SwiftUI.Color {
        if brand.tab != nil, let a = brand.light?.accent { return c(a) }
        return accent
    }
    /// Levý proužek vybraného serveru / položky navigace.
    static var selStripe: SwiftUI.Color { brand.selStripe.map { c($0) } ?? accent }

    /// Aktivní záložka: výplň a text (Neon Orchid světlý přechod s tmavým textem).
    static func tabFill(_ active: Bool, inactive: SwiftUI.Color) -> AnyShapeStyle {
        guard active else { return AnyShapeStyle(inactive) }
        if let tb = brand.tab {
            return AnyShapeStyle(LinearGradient(colors: v ? [c(tb.0), c(tb.1)] : [c(tb.0), blend(tb.0, tb.1, 0.4)], startPoint: .top, endPoint: .bottom))
        }
        return AnyShapeStyle(selectedFill)
    }
    static func tabText(_ active: Bool, _ normal: SwiftUI.Color) -> SwiftUI.Color {
        active ? (brand.tabText.map { c($0) } ?? normal) : normal
    }
    /// Vybraný server / položka navigace.
    static func selFill(_ on: Bool, normal: SwiftUI.Color) -> AnyShapeStyle {
        guard on else { return AnyShapeStyle(SwiftUI.Color.clear) }
        if let s = brand.sel { return AnyShapeStyle(LinearGradient(colors: [c(s.0), c(s.1)], startPoint: .leading, endPoint: .trailing)) }
        return AnyShapeStyle(normal)
    }
    /// Ikona vybrané položky navigace (na přechodu výběru bílá).
    static func selIcon(_ on: Bool, normal: SwiftUI.Color, off: SwiftUI.Color) -> SwiftUI.Color {
        on ? (brand.sel != nil ? c(brand.selText ?? "#FFFFFF") : normal) : off
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
        if let h = brand.header {
            return LinearGradient(colors: v ? [c(h.0), c(h.1)] : [blend(brand.nav, h.0, 0.6), blend(brand.nav, h.1, 0.45)],
                                  startPoint: .leading, endPoint: .trailing)
        }
        let k: CGFloat = min(0.85, (v ? (d ? 0.42 : 0.30) : (d ? 0.16 : 0.10)) * brand.strength)
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

extension Theme {
    /// Tmavé lišty, ale světlá pracovní plocha (seznam souborů / terminál) – např. Neon Orchid.
    var mixedContent: Bool {
        guard isDark, let c = RGBColor(hex: background) else { return false }
        return (0.2126 * Double(c.r) + 0.7152 * Double(c.g) + 0.0722 * Double(c.b)) / 255 > 0.6
    }
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
        let tl = Modern.brand.tile             // jednotné dlaždice profilu (Anthracite Steel)
        let base = tl.map { Modern.c($0.1) } ?? Modern.blend(hue, Modern.brand.a, v ? 0.22 : 0.45)
        let light = tl.map { Modern.c($0.0) } ?? Modern.blend(hue, "#FFFFFF", v ? 0.28 : 0.12)
        let shine = tl.map { Modern.c($0.2) } ?? SwiftUI.Color.white
        let r = size * 0.29
        return ZStack {
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .fill(LinearGradient(colors: [light, base], startPoint: .top, endPoint: .bottom))
            // lesk v horní polovině = „plastický“ dojem (v jemném stylu slabší)
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .fill(LinearGradient(colors: [shine.opacity(v ? (tl == nil ? 0.32 : 0.55) : 0.12), shine.opacity(0)],
                                     startPoint: .top, endPoint: .center))
                .padding(1)
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .stroke(SwiftUI.Color.white.opacity(v ? 0.28 : 0.12), lineWidth: 0.8)
            Image(systemName: symbol).font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(SwiftUI.Color.white)
                .shadow(color: SwiftUI.Color.black.opacity(v ? 0.25 : 0), radius: 1, y: 0.5)
        }
        .frame(width: size, height: size)
        .shadow(color: (glow ? (tl == nil ? Modern.c(hue) : shine) : SwiftUI.Color.black).opacity(v ? (glow ? 0.55 : 0.25) : 0.10),
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
